-- 55 — Nota de crédito y stock: no suma; "Devolución de mercadería" opcional resta
--
-- ✅ APLICADO en producción el 2026-10-21 (archivo completo), con backup previo
-- virikyna_2026-10-21_pre-docs55. Antes se verificó que cargar_factura_compra (docs/54),
-- vincular_item_factura_compra (docs/53), anular_factura_compra y facturas_compra_saldo eran las
-- versiones de base. PARTE B ok (firma única con boolean al final, vista con security_invoker y la
-- columna); PARTE C 11/11, sin residuos. La API resuelve la firma nueva.
--
-- Correr desde la raíz del repo con
-- `npx supabase db query --linked -f docs/55_nc_stock.sql` (o en el SQL Editor del proyecto
-- ccpinvtleqlsukcqnili), después de 54. La PARTE A va una sola vez; la PARTE B (verificación) y la
-- PARTE C (test, BEGIN … ROLLBACK) se pueden repetir.
--
-- Contexto (relevado contra la base real el 2026-10-21):
--   - cargar_factura_compra trataba los ítems con producto de una NC igual que una compra: sumaba
--     stock (movimiento 'compra' positivo) y, si el proveedor del producto era otro, le pasaba el
--     proveedor y los márgenes de la NC (cambiando su precio de venta). El costo ya no lo tocaba.
--   - anular_factura_compra restaba la cantidad de cada ítem con producto, fuera cual fuera el tipo.
--   - Diagnóstico: en la base hay 0 notas de crédito (3 comprobantes: 2 facturas y 1 remito), así
--     que no hay datos históricos que corregir.
--
-- Qué hace:
--   1. facturas_compra.devuelve_mercaderia boolean NOT NULL DEFAULT false, solo posible en una NC
--      de artículos (CHECK). facturas_compra_saldo la suma al final (security_invoker, docs/38).
--   2. cargar_factura_compra(…, p_devuelve_mercaderia boolean DEFAULT false):
--      - NC: nunca suma stock, nunca toca costo, proveedor ni márgenes.
--      - NC con devolución: resta cada ítem con producto en su depósito (movimiento 'ajuste'
--        negativo con referencia a la NC — mismo criterio que las devoluciones de venta, docs/24 —,
--        motivo "Devolucion a proveedor: NC <número>"). Si no alcanza el stock de algún producto
--        (sumando ítems repetidos del mismo depósito), no carga nada y dice cuál falta.
--      - Sin el parámetro (apps viejas): NC sin devolución. Facturas, remitos, etc. igual que hoy.
--   3. anular_factura_compra: revierte exactamente lo que el comprobante movió en el stock (neto por
--      producto y depósito de sus movimientos), en vez de recorrer los ítems. Para una factura da
--      lo mismo que antes (incluye un ítem vinculado después, docs/50); una NC con devolución
--      vuelve a sumar lo devuelto; una NC sin devolución no mueve nada.
--   4. vincular_item_factura_compra (docs/50): rechaza ítems de una NC (vincular suma stock como
--      una compra). La UI tampoco lo ofrece.
--   Agregar un parámetro cambia la firma: DROP + CREATE + grants (patrón docs/45, 53 y 54).

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios (una sola vez)
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

ALTER TABLE public.facturas_compra
  ADD COLUMN IF NOT EXISTS devuelve_mercaderia BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE public.facturas_compra DROP CONSTRAINT IF EXISTS facturas_compra_devolucion_solo_nc;
ALTER TABLE public.facturas_compra
  ADD CONSTRAINT facturas_compra_devolucion_solo_nc
  CHECK (NOT devuelve_mercaderia OR (tipo_comprobante = 'nota_credito' AND tipo_compra = 'articulos'));

COMMENT ON COLUMN public.facturas_compra.devuelve_mercaderia IS
  'NC de artículos con devolución de mercadería: restó stock al cargarse (anularla lo vuelve a sumar). Sin marcar, una NC no toca el stock. docs/55.';

-- ─── cargar_factura_compra ────────────────────────────────────────────────────────────────────
DROP FUNCTION public.cargar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date, forma_pago_compra, jsonb, uuid, numeric, text, uuid);

CREATE FUNCTION public.cargar_factura_compra(p_proveedor_id uuid, p_tipo_comprobante tipo_comprobante_compra, p_letra letra_comprobante_compra, p_punto_venta text, p_numero_comprobante text, p_fecha_comprobante date, p_fecha_fiscal date, p_forma_pago forma_pago_compra, p_items jsonb, p_copiada_de_id uuid DEFAULT NULL::uuid, p_iva_alicuota numeric DEFAULT 21, p_tipo_compra text DEFAULT 'articulos'::text, p_borrador_id uuid DEFAULT NULL::uuid, p_devuelve_mercaderia boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_factura_id UUID;
  v_item JSONB;
  v_precio_total_sin_iva NUMERIC;
  v_total_sin_iva NUMERIC := 0;
  v_iva NUMERIC;
  v_total NUMERIC;
  v_producto_id UUID;
  v_producto_proveedor_id UUID;
  v_actualiza_costo BOOLEAN := p_tipo_comprobante NOT IN ('nota_credito', 'nota_debito');
  v_row RECORD;
  v_costo_actual NUMERIC;
  v_costo_nuevo NUMERIC;
  v_costo_linea NUMERIC;     -- docs/45
  v_cambia_proveedor BOOLEAN;
  v_precio_manual NUMERIC;   -- docs/34
  v_pone_costo BOOLEAN;      -- docs/34
  v_nc BOOLEAN := p_tipo_comprobante = 'nota_credito';             -- docs/55
  v_devuelve BOOLEAN := COALESCE(p_devuelve_mercaderia, false);    -- docs/55
  v_falta TEXT;                                                    -- docs/55
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  -- docs/54: confirmar un borrador lo elimina en la misma transacción. Va primero: si dos personas
  -- confirman el mismo borrador a la vez, la segunda espera el lock de la fila, no la encuentra y
  -- no se carga la factura dos veces. Si algo de abajo falla, el borrador vuelve con el ROLLBACK.
  IF p_borrador_id IS NOT NULL THEN
    DELETE FROM borradores WHERE id = p_borrador_id AND tipo = 'factura_compra';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'El borrador ya no existe: otro usuario lo confirmó o lo eliminó';
    END IF;
  END IF;

  -- docs/45: solo 21 o exento. El CHECK de la tabla también lo frena; esto da un mensaje legible.
  IF p_iva_alicuota IS NULL OR p_iva_alicuota NOT IN (0, 21) THEN
    RAISE EXCEPTION 'Alícuota de IVA inválida: tiene que ser 21 %% o exento (0)';
  END IF;

  -- docs/53: tipo de compra válido; en servicios ningún ítem lleva producto y la cantidad es 1.
  -- Sin esto, un payload armado a mano con producto_id movería stock y costo desde un servicio.
  IF p_tipo_compra IS NULL OR p_tipo_compra NOT IN ('articulos', 'servicios') THEN
    RAISE EXCEPTION 'Tipo de compra inválido: tiene que ser artículos o servicios';
  END IF;
  IF p_tipo_compra = 'servicios' THEN
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) AS i WHERE NULLIF(i->>'producto_id', '') IS NOT NULL) THEN
      RAISE EXCEPTION 'Una factura de servicios no lleva productos del inventario';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) AS i WHERE (i->>'cantidad')::NUMERIC IS DISTINCT FROM 1) THEN
      RAISE EXCEPTION 'En una factura de servicios cada ítem va con cantidad 1';
    END IF;
  END IF;

  -- docs/55: devolución de mercadería, solo en una NC de artículos. Tiene que alcanzar el stock de
  -- cada producto en el depósito de su ítem (sumando ítems repetidos). Las filas se bloquean antes
  -- de mirar, así dos devoluciones a la vez no dejan el stock en negativo.
  IF v_devuelve AND (NOT v_nc OR p_tipo_compra <> 'articulos') THEN
    RAISE EXCEPTION 'La devolución de mercadería es solo para notas de crédito de artículos';
  END IF;
  IF v_devuelve THEN
    PERFORM 1 FROM stock_ubicaciones s
    WHERE (s.producto_id, s.ubicacion) IN (
      SELECT NULLIF(i->>'producto_id', '')::UUID, COALESCE((i->>'ubicacion')::ubicacion_stock, 'local')
      FROM jsonb_array_elements(p_items) AS i WHERE NULLIF(i->>'producto_id', '') IS NOT NULL)
    FOR UPDATE;

    SELECT string_agg(format('%s (%s): hay %s, se devuelven %s', p.nombre,
             CASE WHEN x.ubicacion = 'deposito' THEN 'depósito' ELSE 'local' END,
             trim_scale(COALESCE(s.cantidad, 0)), trim_scale(x.pedida)), '; ' ORDER BY p.nombre)
    INTO v_falta
    FROM (
      SELECT NULLIF(i->>'producto_id', '')::UUID AS producto_id,
             COALESCE((i->>'ubicacion')::ubicacion_stock, 'local') AS ubicacion,
             SUM((i->>'cantidad')::NUMERIC) AS pedida
      FROM jsonb_array_elements(p_items) AS i
      WHERE NULLIF(i->>'producto_id', '') IS NOT NULL
      GROUP BY 1, 2
    ) x
    JOIN productos p ON p.id = x.producto_id
    LEFT JOIN stock_ubicaciones s ON s.producto_id = x.producto_id AND s.ubicacion = x.ubicacion
    WHERE COALESCE(s.cantidad, 0) < x.pedida;

    IF v_falta IS NOT NULL THEN
      RAISE EXCEPTION 'No alcanza el stock para devolver: %', v_falta;
    END IF;
  END IF;

  -- docs/33: la FK ya lo garantiza; esto da un mensaje legible en vez del error de constraint.
  IF p_copiada_de_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM facturas_compra WHERE id = p_copiada_de_id) THEN
    RAISE EXCEPTION 'La factura que se quiso copiar no existe';
  END IF;

  SELECT COALESCE(SUM((i->>'cantidad')::NUMERIC * (i->>'precio_unitario_sin_iva')::NUMERIC
           * (1 - COALESCE((i->>'descuento_porcentaje')::NUMERIC,0)/100.0)), 0)
  INTO v_total_sin_iva
  FROM jsonb_array_elements(p_items) AS i;

  v_iva := ROUND(v_total_sin_iva * p_iva_alicuota / 100, 2);  -- docs/45 (antes: × 0.21 fijo)
  v_total := v_total_sin_iva + v_iva;

  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, letra, punto_venta, numero_comprobante,
         fecha_comprobante, fecha_fiscal, forma_pago, total_sin_iva, iva, total, usuario_id, copiada_de_id,
         iva_alicuota,  -- docs/45
         tipo_compra,   -- docs/53
         devuelve_mercaderia)  -- docs/55
  VALUES (p_proveedor_id, p_tipo_comprobante, p_letra, p_punto_venta, p_numero_comprobante,
         p_fecha_comprobante, p_fecha_fiscal, p_forma_pago, v_total_sin_iva, v_iva, v_total, auth.uid(), p_copiada_de_id,
         p_iva_alicuota,
         p_tipo_compra,
         v_devuelve)
  RETURNING id INTO v_factura_id;

  -- Ítems y stock, línea por línea (igual que docs/13)
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_precio_total_sin_iva := ROUND((v_item->>'cantidad')::NUMERIC * (v_item->>'precio_unitario_sin_iva')::NUMERIC
                              * (1 - COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0)/100.0), 2);

    INSERT INTO facturas_compra_items (factura_compra_id, producto_id, descripcion, cantidad,
           precio_unitario_sin_iva, descuento_porcentaje, precio_total_sin_iva, ubicacion)
    VALUES (v_factura_id, NULLIF(v_item->>'producto_id','')::UUID, v_item->>'descripcion',
           (v_item->>'cantidad')::NUMERIC, (v_item->>'precio_unitario_sin_iva')::NUMERIC,
           COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0), v_precio_total_sin_iva,
           COALESCE((v_item->>'ubicacion')::ubicacion_stock, 'local'));

    v_producto_id := NULLIF(v_item->>'producto_id','')::UUID;

    -- docs/55: una NC no suma stock nunca (antes sumaba como una compra). Con devolución de
    -- mercadería, resta lo devuelto (ajuste con referencia a la NC, igual que las devoluciones de
    -- venta de docs/24: el Historial no lo ofrece revertir suelto, se revierte anulando la NC).
    IF v_producto_id IS NOT NULL AND NOT v_nc THEN
      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, referencia_id, usuario_id)
      VALUES (v_producto_id, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'),
             'compra', (v_item->>'cantidad')::NUMERIC, v_factura_id, auth.uid());

      INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
      VALUES (v_producto_id, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'), (v_item->>'cantidad')::NUMERIC)
      ON CONFLICT (producto_id, ubicacion)
      DO UPDATE SET cantidad = stock_ubicaciones.cantidad + (v_item->>'cantidad')::NUMERIC;
    ELSIF v_producto_id IS NOT NULL AND v_devuelve THEN
      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
      VALUES (v_producto_id, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'), 'ajuste',
             -1 * (v_item->>'cantidad')::NUMERIC,
             'Devolucion a proveedor: NC ' || COALESCE(NULLIF(btrim(p_numero_comprobante), ''), 'sin numero'),
             v_factura_id, auth.uid());

      UPDATE stock_ubicaciones SET cantidad = cantidad - (v_item->>'cantidad')::NUMERIC
      WHERE producto_id = v_producto_id AND ubicacion = COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local');
    END IF;
  END LOOP;

  -- Producto: proveedor/márgenes (docs/13) + costo. Una pasada por producto, con el precio de su
  -- ÚLTIMA línea en la factura (DISTINCT ON + ORDER BY ord DESC).
  FOR v_row IN
    SELECT DISTINCT ON (x.producto_id) x.producto_id, x.precio, x.descuento
    FROM (
      SELECT NULLIF(t.i->>'producto_id','')::UUID AS producto_id,
             (t.i->>'precio_unitario_sin_iva')::NUMERIC AS precio,
             COALESCE((t.i->>'descuento_porcentaje')::NUMERIC, 0) AS descuento,  -- docs/45
             t.ord
      FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(i, ord)
    ) x
    WHERE x.producto_id IS NOT NULL
      AND NOT v_nc  -- docs/55: una NC nunca toca costo, proveedor ni márgenes
    ORDER BY x.producto_id, x.ord DESC
  LOOP
    SELECT proveedor_id, costo, precio_manual INTO v_producto_proveedor_id, v_costo_actual, v_precio_manual  -- docs/34
    FROM productos WHERE id = v_row.producto_id FOR UPDATE;

    -- docs/45: el costo es el precio unitario sin IVA con el descuento de la línea ya aplicado.
    v_costo_linea := ROUND(v_row.precio * (1 - v_row.descuento / 100.0), 2);

    -- Producto sin proveedor (null): IS DISTINCT FROM da true → toma proveedor y márgenes default.
    v_cambia_proveedor := v_producto_proveedor_id IS DISTINCT FROM p_proveedor_id;
    -- docs/34: la factura le pone costo (no NC/ND, costo > 0). Desde ahí el precio sale de la fórmula.
    v_pone_costo := v_actualiza_costo AND v_costo_linea > 0;  -- docs/45: costo con descuento
    v_costo_nuevo := CASE WHEN v_pone_costo
                          THEN v_costo_linea ELSE v_costo_actual END;

    IF v_cambia_proveedor OR v_costo_nuevo IS DISTINCT FROM v_costo_actual
       OR (v_pone_costo AND v_precio_manual IS NOT NULL) THEN  -- docs/34
      IF v_cambia_proveedor THEN
        PERFORM set_config('virikyna.margen_auto_herencia', 'true', true);
      END IF;

      UPDATE productos
      SET proveedor_id = p_proveedor_id,
          margen_1 = CASE WHEN v_cambia_proveedor
                          THEN (SELECT margen_1_default FROM proveedores WHERE id = p_proveedor_id)
                          ELSE margen_1 END,
          margen_2 = CASE WHEN v_cambia_proveedor
                          THEN (SELECT margen_2_default FROM proveedores WHERE id = p_proveedor_id)
                          ELSE margen_2 END,
          costo = v_costo_nuevo,
          precio_manual = CASE WHEN v_pone_costo THEN NULL ELSE precio_manual END,  -- docs/34
          updated_at = now()
      WHERE id = v_row.producto_id;

      IF v_cambia_proveedor THEN
        PERFORM set_config('virikyna.margen_auto_herencia', 'false', true);
      END IF;
    END IF;
  END LOOP;

  RETURN v_factura_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.cargar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date, forma_pago_compra, jsonb, uuid, numeric, text, uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cargar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date, forma_pago_compra, jsonb, uuid, numeric, text, uuid, boolean) TO authenticated, service_role;

-- ─── anular_factura_compra: revierte los movimientos reales del comprobante ────────────────────
CREATE OR REPLACE FUNCTION public.anular_factura_compra(p_factura_id uuid, p_motivo text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_mov RECORD;   -- docs/55
  v_ya_anulada BOOLEAN;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede anular una factura de compra';
  END IF;
  IF p_motivo IS NULL OR trim(p_motivo) = '' THEN
    RAISE EXCEPTION 'El motivo es obligatorio para anular una factura de compra';
  END IF;

  SELECT anulada INTO v_ya_anulada FROM facturas_compra WHERE id = p_factura_id FOR UPDATE;
  IF v_ya_anulada IS NULL THEN
    RAISE EXCEPTION 'Factura de compra no encontrada';
  END IF;
  IF v_ya_anulada THEN
    RAISE EXCEPTION 'Esta factura ya estaba anulada';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pagos_proveedor_aplicaciones
    WHERE (factura_compra_id = p_factura_id OR nota_credito_id = p_factura_id)
      AND revertida_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Este comprobante tiene pagos o notas de crédito aplicadas — revertí esos pagos antes de anularlo';
  END IF;

  -- docs/55: lo que el comprobante movió de verdad (compra, ítem vinculado después, devolución de
  -- una NC), neto por producto y depósito. Antes se recorrían los ítems con producto: en una NC
  -- habría restado stock que nunca había sumado.
  FOR v_mov IN
    SELECT producto_id, ubicacion, SUM(cantidad) AS neto
    FROM movimientos_stock
    WHERE referencia_id = p_factura_id
    GROUP BY producto_id, ubicacion
    HAVING SUM(cantidad) <> 0
  LOOP
    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
    VALUES (v_mov.producto_id, v_mov.ubicacion, 'ajuste', -1 * v_mov.neto,
            'Anulación de factura de compra: ' || p_motivo, p_factura_id, auth.uid());

    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES (v_mov.producto_id, v_mov.ubicacion, -1 * v_mov.neto)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad + EXCLUDED.cantidad;
  END LOOP;

  UPDATE facturas_compra SET anulada = true WHERE id = p_factura_id;

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, nota, usuario_id)
  VALUES ('facturas_compra', p_factura_id, 'anulacion', p_motivo, auth.uid());
END;
$function$;

-- ─── vincular_item_factura_compra: no en notas de crédito ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.vincular_item_factura_compra(p_item_id uuid, p_producto_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_item facturas_compra_items%ROWTYPE;
  v_anulada BOOLEAN;
  v_tipo_compra TEXT;  -- docs/53
  v_tipo_comprobante tipo_comprobante_compra;  -- docs/55
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

  SELECT anulada, tipo_compra, tipo_comprobante INTO v_anulada, v_tipo_compra, v_tipo_comprobante
  FROM facturas_compra WHERE id = v_item.factura_compra_id;
  IF v_anulada THEN
    RAISE EXCEPTION 'El comprobante está anulado: no se le suma stock';
  END IF;
  -- docs/53: un servicio no es mercadería, no se vincula ni suma stock.
  IF v_tipo_compra = 'servicios' THEN
    RAISE EXCEPTION 'Es una factura de servicios: sus ítems no se vinculan a productos';
  END IF;
  -- docs/55: vincular suma stock como una compra; en una nota de crédito no corresponde.
  IF v_tipo_comprobante = 'nota_credito' THEN
    RAISE EXCEPTION 'Es una nota de crédito: sus ítems no se vinculan a productos';
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
$function$;

-- ─── facturas_compra_saldo: + devuelve_mercaderia (al final; los cálculos no cambian) ─────────
CREATE OR REPLACE VIEW public.facturas_compra_saldo WITH (security_invoker = on) AS
 SELECT fc.id,
    fc.proveedor_id,
    fc.tipo_comprobante,
    fc.letra,
    fc.punto_venta,
    fc.numero_comprobante,
    fc.fecha_comprobante,
    fc.fecha_fiscal,
    fc.forma_pago,
    fc.total_sin_iva,
    fc.iva,
    fc.total,
    fc.usuario_id,
    fc.created_at,
    fc.anulada,
    x.aplicado AS total_pagado,
        CASE
            WHEN fc.anulada OR fc.tipo_comprobante = 'nota_credito'::tipo_comprobante_compra THEN 0::numeric
            ELSE fc.total - x.aplicado
        END AS saldo_pendiente,
    x.aplicado AS total_aplicado,
        CASE
            WHEN fc.tipo_comprobante = 'nota_credito'::tipo_comprobante_compra AND NOT fc.anulada THEN fc.total - x.aplicado
            ELSE 0::numeric
        END AS credito_disponible,
        CASE
            WHEN fc.anulada THEN 'anulada'::text
            WHEN (fc.total - x.aplicado) <= 0::numeric THEN 'pagada'::text
            WHEN x.aplicado > 0::numeric THEN 'parcial'::text
            ELSE 'pendiente'::text
        END AS estado,
    fc.copiada_de_id,
    fc.iva_alicuota,
    fc.tipo_compra,
    fc.devuelve_mercaderia
   FROM facturas_compra fc
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN fc.tipo_comprobante = 'nota_credito'::tipo_comprobante_compra THEN ( SELECT COALESCE(sum(a.monto), 0::numeric) AS "coalesce"
                       FROM pagos_proveedor_aplicaciones a
                      WHERE a.nota_credito_id = fc.id AND a.revertida_at IS NULL)
                    ELSE ( SELECT COALESCE(sum(a.monto), 0::numeric) AS "coalesce"
                       FROM pagos_proveedor_aplicaciones a
                      WHERE a.factura_compra_id = fc.id AND a.revertida_at IS NULL)
                END AS aplicado) x;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (solo lectura)
-- Esperado: 1 firma de cargar_factura_compra (boolean al final) sin anon; vista con
-- security_invoker y la columna; ninguna NC con devolución todavía.
-- ════════════════════════════════════════════════════════════════════════════════════════════
SELECT 'firma' AS chequeo, p.oid::regprocedure::text AS valor, array_to_string(p.proacl, ',') AS detalle
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('cargar_factura_compra', 'anular_factura_compra')
UNION ALL
SELECT 'vista', array_to_string(c.reloptions, ','),
       (SELECT string_agg(attname, ',') FROM pg_attribute WHERE attrelid = c.oid AND attname = 'devuelve_mercaderia')
FROM pg_class c WHERE c.oid = 'public.facturas_compra_saldo'::regclass
UNION ALL
SELECT 'nc con devolución', count(*)::text, NULL FROM facturas_compra WHERE devuelve_mercaderia;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (no deja nada: BEGIN … ROLLBACK)
-- Usa un admin activo, el primer proveedor y un producto real de OTRO proveedor (para ver que la
-- NC no se lo cambia). Resultado: una tabla, todo ok = true.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

SELECT set_config('request.jwt.claims',
                  json_build_object('sub', (SELECT id FROM perfiles WHERE activo AND rol = 'admin' ORDER BY created_at LIMIT 1),
                                    'role', 'authenticated')::text, true);

CREATE TEMP TABLE t55 (orden int, caso text, ok boolean, detalle text) ON COMMIT DROP;

DO $test$
DECLARE
  v_prov uuid := (SELECT id FROM proveedores ORDER BY razon_social LIMIT 1);
  v_p uuid;
  v_prov_p uuid;
  v_costo0 numeric;
  v_m1 numeric;
  v_dep0 numeric;
  v_f uuid;
  v_nc uuid;
  v_nc2 uuid;
  v_saldo0 numeric;
  v_n int;
  v_items jsonb;
  v_dep numeric;
BEGIN
  SELECT id, proveedor_id, costo, margen_1 INTO v_p, v_prov_p, v_costo0, v_m1
  FROM productos WHERE estado = 'activo' AND proveedor_id IS DISTINCT FROM v_prov ORDER BY nombre LIMIT 1;
  SELECT COALESCE(cantidad, 0) INTO v_dep0 FROM stock_ubicaciones WHERE producto_id = v_p AND ubicacion = 'deposito';
  v_dep0 := COALESCE(v_dep0, 0);

  -- 1. Factura de 5 al depósito (regresión): suma 5 y pone costo y proveedor.
  v_f := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
           p_punto_venta => '9999', p_numero_comprobante => 'T55-1', p_fecha_comprobante => current_date,
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente',
           p_items => jsonb_build_array(jsonb_build_object('producto_id', v_p, 'descripcion', 'T55', 'cantidad', 5,
                        'precio_unitario_sin_iva', 300, 'ubicacion', 'deposito')),
           p_iva_alicuota => 0);
  INSERT INTO t55 SELECT 1, 'factura: suma 5 al depósito, pone costo y proveedor',
    (SELECT cantidad FROM stock_ubicaciones WHERE producto_id = v_p AND ubicacion = 'deposito') = v_dep0 + 5
      AND costo = 300 AND proveedor_id = v_prov, format('dep %s costo %s', v_dep0 + 5, costo)
  FROM productos WHERE id = v_p;

  -- Producto vuelve a "otro proveedor" y otro costo, para ver que la NC no lo toca.
  UPDATE productos SET proveedor_id = v_prov_p, costo = 111, margen_1 = v_m1 WHERE id = v_p;
  SELECT saldo_actual INTO v_saldo0 FROM proveedores_saldo WHERE id = v_prov;

  -- 2. NC sin devolución (llamada vieja, sin p_devuelve_mercaderia): no mueve stock ni producto.
  v_nc := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'nota_credito', p_letra => 'A',
           p_punto_venta => '9999', p_numero_comprobante => 'T55-2', p_fecha_comprobante => current_date,
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente',
           p_items => jsonb_build_array(jsonb_build_object('producto_id', v_p, 'descripcion', 'T55', 'cantidad', 2,
                        'precio_unitario_sin_iva', 300, 'ubicacion', 'deposito')),
           p_iva_alicuota => 0);
  SELECT count(*) INTO v_n FROM movimientos_stock WHERE referencia_id = v_nc;
  INSERT INTO t55 SELECT 2, 'NC sin devolución: sin movimientos, producto intacto',
    v_n = 0 AND (SELECT cantidad FROM stock_ubicaciones WHERE producto_id = v_p AND ubicacion = 'deposito') = v_dep0 + 5
      AND proveedor_id IS NOT DISTINCT FROM v_prov_p AND costo = 111
      AND NOT (SELECT devuelve_mercaderia FROM facturas_compra WHERE id = v_nc),
    format('movs %s proveedor igual %s costo %s', v_n, proveedor_id IS NOT DISTINCT FROM v_prov_p, costo)
  FROM productos WHERE id = v_p;

  -- 3. NC con devolución de 2 (+ un ítem libre): resta 2 del depósito, ajuste negativo, producto intacto.
  v_nc2 := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'nota_credito', p_letra => 'A',
           p_punto_venta => '9999', p_numero_comprobante => 'T55-3', p_fecha_comprobante => current_date,
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente',
           p_items => jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'descripcion', 'T55', 'cantidad', 2, 'precio_unitario_sin_iva', 300, 'ubicacion', 'deposito'),
             jsonb_build_object('producto_id', NULL, 'descripcion', 'flete', 'cantidad', 1, 'precio_unitario_sin_iva', 50)),
           p_iva_alicuota => 0, p_devuelve_mercaderia => true);
  INSERT INTO t55 SELECT 3, 'NC con devolución: depósito −2, ajuste −2, producto intacto',
    (SELECT cantidad FROM stock_ubicaciones WHERE producto_id = v_p AND ubicacion = 'deposito') = v_dep0 + 3
      AND (SELECT count(*) FROM movimientos_stock WHERE referencia_id = v_nc2) = 1
      AND (SELECT tipo = 'ajuste' AND cantidad = -2 AND ubicacion = 'deposito' AND motivo = 'Devolucion a proveedor: NC T55-3'
           FROM movimientos_stock WHERE referencia_id = v_nc2)
      AND proveedor_id IS NOT DISTINCT FROM v_prov_p AND costo = 111
      AND (SELECT devuelve_mercaderia FROM facturas_compra_saldo WHERE id = v_nc2),
    (SELECT tipo::text || ' ' || cantidad || ' ' || motivo FROM movimientos_stock WHERE referencia_id = v_nc2)
  FROM productos WHERE id = v_p;

  -- 4. Saldo: las dos NC restan deuda igual que siempre (600 + 650).
  INSERT INTO t55 SELECT 4, 'saldo: −600 −650', saldo_actual - v_saldo0 = -1250, format('delta %s', saldo_actual - v_saldo0)
  FROM proveedores_saldo WHERE id = v_prov;

  -- 5. Devolución sin stock suficiente (dos ítems del mismo producto suman más que lo que hay).
  SELECT cantidad INTO v_dep FROM stock_ubicaciones WHERE producto_id = v_p AND ubicacion = 'deposito';
  v_items := jsonb_build_array(
    jsonb_build_object('producto_id', v_p, 'descripcion', 'T55', 'cantidad', v_dep, 'precio_unitario_sin_iva', 1, 'ubicacion', 'deposito'),
    jsonb_build_object('producto_id', v_p, 'descripcion', 'T55', 'cantidad', 1, 'precio_unitario_sin_iva', 1, 'ubicacion', 'deposito'));
  BEGIN
    PERFORM cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'nota_credito', p_letra => 'A',
             p_punto_venta => '9999', p_numero_comprobante => 'T55-5', p_fecha_comprobante => current_date,
             p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente', p_items => v_items,
             p_iva_alicuota => 0, p_devuelve_mercaderia => true);
    INSERT INTO t55 VALUES (5, 'sin stock suficiente: rechazada', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t55 VALUES (5, 'sin stock suficiente: rechazada con detalle',
      SQLERRM LIKE 'No alcanza el stock para devolver:%depósito%' AND NOT EXISTS (SELECT 1 FROM facturas_compra WHERE numero_comprobante = 'T55-5'), SQLERRM);
  END;

  -- 6. Devolución en una factura o en una NC de servicios: rechazada.
  BEGIN
    PERFORM cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
             p_punto_venta => '9999', p_numero_comprobante => 'T55-6', p_fecha_comprobante => current_date,
             p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente',
             p_items => '[{"producto_id": null, "descripcion": "x", "cantidad": 1, "precio_unitario_sin_iva": 1}]',
             p_iva_alicuota => 0, p_devuelve_mercaderia => true);
    INSERT INTO t55 VALUES (6, 'devolución en factura: rechazada', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t55 VALUES (6, 'devolución en factura: rechazada', SQLERRM LIKE 'La devolución de mercadería es solo%', SQLERRM);
  END;
  BEGIN
    PERFORM cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'nota_credito', p_letra => 'A',
             p_punto_venta => '9999', p_numero_comprobante => 'T55-7', p_fecha_comprobante => current_date,
             p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente',
             p_items => '[{"producto_id": null, "descripcion": "x", "cantidad": 1, "precio_unitario_sin_iva": 1}]',
             p_iva_alicuota => 0, p_tipo_compra => 'servicios', p_devuelve_mercaderia => true);
    INSERT INTO t55 VALUES (7, 'devolución en NC de servicios: rechazada', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t55 VALUES (7, 'devolución en NC de servicios: rechazada', SQLERRM LIKE 'La devolución de mercadería es solo%', SQLERRM);
  END;

  -- 11. Vincular un ítem libre de una NC: rechazado (sumaría stock como una compra).
  BEGIN
    PERFORM vincular_item_factura_compra(
      (SELECT id FROM facturas_compra_items WHERE factura_compra_id = v_nc2 AND producto_id IS NULL), v_p);
    INSERT INTO t55 VALUES (11, 'vincular ítem de NC: rechazado', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t55 VALUES (11, 'vincular ítem de NC: rechazado', SQLERRM LIKE 'Es una nota de crédito%', SQLERRM);
  END;

  -- 8. Anular la NC con devolución: vuelve a sumar 2.
  PERFORM anular_factura_compra(v_nc2, 'test 55');
  INSERT INTO t55 SELECT 8, 'anular NC con devolución: depósito +2',
    cantidad = v_dep0 + 5, format('dep %s', cantidad)
  FROM stock_ubicaciones WHERE producto_id = v_p AND ubicacion = 'deposito';

  -- 9. Anular la NC sin devolución: no mueve stock.
  PERFORM anular_factura_compra(v_nc, 'test 55');
  INSERT INTO t55 SELECT 9, 'anular NC sin devolución: sin movimientos',
    NOT EXISTS (SELECT 1 FROM movimientos_stock WHERE referencia_id = v_nc)
      AND (SELECT cantidad FROM stock_ubicaciones WHERE producto_id = v_p AND ubicacion = 'deposito') = v_dep0 + 5, NULL;

  -- 10. Anular la factura (regresión): resta los 5 que había sumado.
  PERFORM anular_factura_compra(v_f, 'test 55');
  INSERT INTO t55 SELECT 10, 'anular factura: depósito vuelve al inicio',
    cantidad = v_dep0, format('dep %s (inicio %s)', cantidad, v_dep0)
  FROM stock_ubicaciones WHERE producto_id = v_p AND ubicacion = 'deposito';
END
$test$;

SELECT * FROM t55 ORDER BY orden;

ROLLBACK;
