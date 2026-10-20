-- 50 — Vincular un ítem libre de factura de compra a un producto (y sumar su stock)
--
-- ✅ APLICADO el 2026-10-20 (archivo completo). Antes se corrió entero dentro de BEGIN … ROLLBACK,
-- más 3 pruebas (re-vincular rechazado, cajero rechazado, anular la factura revierte su mitad).
-- Resultado = PARTE C: 16 ítems vinculados, stock local = 2 × cantidad de la factura.
--
-- Contexto (relevado contra la base real el 2026-10-20):
--   Jose cargó la factura A 0003-2742 y el remito R 0008-8778 de CHIKI TOYS (fecha 08/10, cargados
--   el 20/10) con los 8 renglones tipeados en "Producto" sin elegir ninguno del desplegable: los 16
--   ítems quedaron libres (producto_id NULL), así que `cargar_factura_compra` no sumó stock ni costo
--   — es lo que hace con un ítem libre, a propósito ("juguetes varios", flete). Como "no aparecían
--   en el inventario", después dio de alta los 8 productos aparte (con código y costo), sin stock.
--   El remito se cargó copiando la factura: la copia arrastra los ítems libres como libres.
--   Confirmado con la dueña: son dos compras (factura + remito), entró el doble de mercadería.
--
--   No había forma de arreglarlo desde las apps: los ítems de una factura no se editan y anular
--   + volver a cargar duplica el trabajo. Del lado de la carga, el arreglo está en las pantallas
--   (aviso por ítem libre + confirmación al guardar, packages/shared).
--
-- Qué hace:
--   PARTE A. RPC vincular_item_factura_compra(p_item_id, p_producto_id) — solo admin.
--     Vincula un ítem libre a un producto activo y hace con el stock exactamente lo que habría hecho
--     `cargar_factura_compra` si el ítem hubiera venido vinculado: movimiento 'compra' con
--     referencia_id = la factura (así `anular_factura_compra` también lo revierte) y suma en
--     stock_ubicaciones. NO toca costo, proveedor ni márgenes: el comprobante puede ser viejo y
--     pisaría un costo más nuevo; eso se corrige en la ficha del producto si hace falta.
--     Rechaza: ítem ya vinculado, comprobante anulado, producto inactivo o inexistente.
--   PARTE B. Corrección de los 16 ítems de CHIKI TOYS (corre como el admin Jimena vía jwt claims;
--     re-verifica los datos y aborta si algo cambió).
--   PARTE C. Verificación (solo lectura).

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A
-- ════════════════════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION vincular_item_factura_compra(p_item_id UUID, p_producto_id UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_item facturas_compra_items%ROWTYPE;
  v_anulada BOOLEAN;
  v_nombre TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede vincular un ítem de una factura ya cargada';
  END IF;

  -- FOR UPDATE: dos vínculos simultáneos del mismo ítem sumarían el stock dos veces.
  SELECT * INTO v_item FROM facturas_compra_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Ítem de factura no encontrado';
  END IF;
  IF v_item.producto_id IS NOT NULL THEN
    RAISE EXCEPTION 'Este ítem ya está vinculado a un producto';
  END IF;

  SELECT anulada INTO v_anulada FROM facturas_compra WHERE id = v_item.factura_compra_id;
  IF v_anulada THEN
    RAISE EXCEPTION 'El comprobante está anulado: no se le suma stock';
  END IF;

  SELECT nombre INTO v_nombre FROM productos WHERE id = p_producto_id AND estado = 'activo';
  IF v_nombre IS NULL THEN
    RAISE EXCEPTION 'El producto no existe o está inactivo';
  END IF;

  -- Igual que un ítem vinculado al cargar: la descripción es la copia del nombre del producto.
  UPDATE facturas_compra_items SET producto_id = p_producto_id, descripcion = v_nombre WHERE id = p_item_id;

  -- Mismo par de escrituras que cargar_factura_compra para un ítem vinculado.
  INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
  VALUES (p_producto_id, v_item.ubicacion, 'compra', v_item.cantidad,
          'Ítem de factura vinculado después de cargada', v_item.factura_compra_id, auth.uid());

  INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
  VALUES (p_producto_id, v_item.ubicacion, v_item.cantidad)
  ON CONFLICT (producto_id, ubicacion)
  DO UPDATE SET cantidad = stock_ubicaciones.cantidad + EXCLUDED.cantidad;
END;
$$;

-- docs/38: sin EXECUTE para PUBLIC/anon; las apps llaman como authenticated.
REVOKE ALL ON FUNCTION public.vincular_item_factura_compra(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vincular_item_factura_compra(uuid, uuid) TO authenticated, service_role;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — corrección CHIKI TOYS (una transacción; aborta si los datos no son los relevados)
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- auth.uid() = Jimena (admin) para el RPC y la auditoría.
SELECT set_config('request.jwt.claims', '{"sub":"4b6fc500-fa5f-4512-84b8-13345382b761","role":"authenticated"}', true);

DO $$
DECLARE
  -- descripción del ítem libre (ya en MAYÚSCULAS) → producto dado de alta por Jose el 20/10
  v_map JSONB := '{
    "MASA POP COLORES SURTIDOS - CHIKITOYS":      "8bda2c98-ac4e-4463-a551-0efd6bb713f1",
    "MASA POP X 2 CRANEO (SURTIDO) - CHIKITOYS":  "b3d78707-863a-47de-9558-2347158e7fe2",
    "PIELR MEGA - CHIKITOYS":                     "d4fc1f4d-9a3b-4999-af23-beaceb7397df",
    "PILER ORIGINAL - CHIKITOYS":                 "818fcdd6-343d-4da5-92ab-77f93c9be491",
    "PISTOLA DE AGUA A REPETICION - CHIKITOYS":   "4c36e7ec-4250-47ad-811b-42a8124c51eb",
    "PISTOLA KAWAII (4 FLECHAS) - CHIKITOYS":     "a5b7da4f-bccd-4c4e-bb01-4e3fc2a54039",
    "POWER SLIME DUO - COLORES FLUO - CHIKITOYS": "8d5b9f5a-85cc-4265-a2e2-e713f08444d9",
    "SLIME MAXI FLUO - CHIKITOYS":                "29a70c94-ff16-4f1a-b913-7097aab72b53"
  }';
  v_facturas UUID[] := ARRAY['73eccbf0-d708-4471-9779-53d015e60bc8', '03c58762-5fa6-4ce0-8ded-55bfd59c5daf']::UUID[];
  v_productos UUID[];
  v_item RECORD;
  v_n INT := 0;
BEGIN
  SELECT array_agg(value::UUID) INTO v_productos FROM jsonb_each_text(v_map);

  -- Re-verificación (los datos se editan a mano en producción: si algo cambió, no se toca nada).
  IF (SELECT count(*) FROM facturas_compra WHERE id = ANY(v_facturas) AND NOT anulada) <> 2 THEN
    RAISE EXCEPTION 'Las dos facturas no están (o alguna está anulada)';
  END IF;
  IF (SELECT count(*) FROM facturas_compra_items WHERE factura_compra_id = ANY(v_facturas)) <> 16
     OR EXISTS (SELECT 1 FROM facturas_compra_items WHERE factura_compra_id = ANY(v_facturas) AND producto_id IS NOT NULL)
     OR EXISTS (SELECT 1 FROM facturas_compra_items WHERE factura_compra_id = ANY(v_facturas) AND NOT v_map ? descripcion) THEN
    RAISE EXCEPTION 'Los ítems no coinciden con lo relevado';
  END IF;
  IF (SELECT count(*) FROM productos WHERE id = ANY(v_productos) AND estado = 'activo') <> 8 THEN
    RAISE EXCEPTION 'Algún producto no existe o está inactivo';
  END IF;
  IF EXISTS (SELECT 1 FROM stock_ubicaciones WHERE producto_id = ANY(v_productos) AND cantidad <> 0)
     OR EXISTS (SELECT 1 FROM movimientos_stock WHERE producto_id = ANY(v_productos)) THEN
    RAISE EXCEPTION 'Los productos ya tienen stock o movimientos: revisar antes de sumar';
  END IF;

  FOR v_item IN
    SELECT id, descripcion FROM facturas_compra_items WHERE factura_compra_id = ANY(v_facturas)
  LOOP
    PERFORM vincular_item_factura_compra(v_item.id, (v_map->>v_item.descripcion)::UUID);
    v_n := v_n + 1;
  END LOOP;
  RAISE NOTICE '% ítems vinculados', v_n;
END $$;

COMMIT;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — verificación (esperado: 8 filas, stock local = 2 × cantidad de la factura)
--   MASA POP EN POTE 24 · CRANEO 8 · MEGA PILER 6 · PILER ORIGINAL 10 · PILER 20 TIROS 6 ·
--   KAWAII 6 · SLIME POWER DUO 16 · SLIME POWER FLUO EN POTE 24
-- ════════════════════════════════════════════════════════════════════════════════════════════
SELECT p.nombre, p.codigo_barras,
       (SELECT cantidad FROM stock_ubicaciones s WHERE s.producto_id = p.id AND s.ubicacion = 'local') AS stock_local,
       (SELECT SUM(i.cantidad) FROM facturas_compra_items i WHERE i.producto_id = p.id) AS comprado,
       (SELECT count(*) FROM movimientos_stock m WHERE m.producto_id = p.id AND m.tipo = 'compra') AS movimientos
FROM productos p
WHERE p.id IN (SELECT producto_id FROM facturas_compra_items
               WHERE factura_compra_id IN ('73eccbf0-d708-4471-9779-53d015e60bc8', '03c58762-5fa6-4ce0-8ded-55bfd59c5daf'))
ORDER BY p.nombre;
