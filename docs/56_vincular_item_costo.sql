-- 56 — Vincular un ítem de factura también actualiza costo y precio (si es la compra más nueva)
--
-- ✅ APLICADO en producción el 2026-10-21 (archivo completo). Antes se corrió A + B + C dentro de
-- BEGIN … ROLLBACK: 7/7 casos ok y el BASTIDOR en costo 5391 / precio 16000. PARTE B aplicada
-- (BASTIDOR 2695,50 → 5391, precio 8000 → 16000); PARTE D: 4 funciones, grants como se esperaba.
--
-- Correr desde la raíz del repo con
-- `npx supabase db query --linked -f docs/56_vincular_item_costo.sql` (o en el SQL Editor del
-- proyecto ccpinvtleqlsukcqnili), después de 55. La PARTE A se puede re-correr (CREATE OR REPLACE);
-- la PARTE B re-verifica los datos y no hace nada si ya se aplicó; la PARTE C es un test
-- (BEGIN … ROLLBACK) y la PARTE D solo lee.
--
-- Contexto (relevado contra la base real el 2026-10-21):
--   - docs/50 hizo que vincular un ítem libre sumara stock pero NO tocara costo, proveedor ni
--     márgenes ("el comprobante puede ser viejo y pisaría un costo más nuevo"). Al cargar una
--     factura con el producto ya elegido, en cambio, cargar_factura_compra sí pone el costo siempre.
--   - Criterio acordado con la dueña: costo de reposición. Si la factura es la compra más nueva del
--     producto, todo el stock toma su costo, como si el ítem se hubiera vinculado al cargarla.
--   - Primer vínculo real (21/10, 19:32 AR): BASTIDOR CON PINTURAS 30 X 40 de la factura 18720 de
--     ANKHA (fecha 17/10, 2 u. a $5.990 − 10 %). Sumó stock pero quedó con costo $2.695,50 (el de la
--     factura 187201 del 17/10, anulada). Se corrige en la PARTE B.
--
-- Qué hace:
--   PARTE A.
--   1. plan_costo_vinculo_item(item, producto) — interna, solo lectura: qué le haría el ítem al
--      producto, con las mismas reglas que cargar_factura_compra para un ítem vinculado:
--        - costo = precio unitario sin IVA con el descuento de la línea (docs/45), salvo nota de
--          débito o costo 0;
--        - si le pone costo, borra el precio manual (docs/34): el precio sale de la fórmula;
--        - si el proveedor de la factura es otro, toma ese proveedor y sus márgenes default (docs/13).
--      Solo aplica si NO hay una compra posterior del producto: otro comprobante no anulado, que no
--      sea NC, con ese producto y (fecha_comprobante, created_at) mayor. Las anuladas no cuentan.
--   2. aplicar_costo_vinculo_item(item, producto) — interna: bloquea el producto, arma el plan y lo
--      aplica (mismo UPDATE que cargar_factura_compra). Devuelve el plan.
--   3. vista_previa_vincular_item_factura_compra(item, producto) — RPC solo admin, solo lectura:
--      el plan, para mostrar en el modal antes de confirmar.
--   4. vincular_item_factura_compra: igual que docs/50/53/55 + aplicar_costo_vinculo_item al final.
--      Misma firma (void): las apps instaladas siguen andando y ya aplican el costo.
--   PARTE B. Corrige el vínculo del BASTIDOR (corre como admin vía jwt claims; re-verifica los datos
--     y aborta si cambiaron).
--   No cambia: anular la factura revierte el stock pero no el costo (igual que hoy al anular una
--   factura cargada con el producto vinculado).

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ─── plan ─────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.plan_costo_vinculo_item(p_item_id uuid, p_producto_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  v_item facturas_compra_items%ROWTYPE;
  v_fc facturas_compra%ROWTYPE;
  v_prod productos%ROWTYPE;
  v_prov proveedores%ROWTYPE;
  v_post RECORD;
  v_costo_linea numeric;
  v_pone_costo boolean;
  v_cambia_proveedor boolean;
  v_costo_nuevo numeric;
  v_m1 numeric;
  v_m2 numeric;
  v_manual_nuevo numeric;
  v_cambia boolean;
BEGIN
  SELECT * INTO v_item FROM facturas_compra_items WHERE id = p_item_id;
  SELECT * INTO v_fc FROM facturas_compra WHERE id = v_item.factura_compra_id;
  SELECT * INTO v_prod FROM productos WHERE id = p_producto_id;
  IF v_item.id IS NULL OR v_fc.id IS NULL OR v_prod.id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_prov FROM proveedores WHERE id = v_fc.proveedor_id;

  -- Compra posterior del mismo producto: si existe, ese comprobante ya definió el costo.
  SELECT f2.id, f2.fecha_comprobante, f2.tipo_comprobante, f2.letra, f2.punto_venta, f2.numero_comprobante
  INTO v_post
  FROM facturas_compra f2
  JOIN facturas_compra_items i2 ON i2.factura_compra_id = f2.id
  WHERE i2.producto_id = p_producto_id
    AND f2.id <> v_fc.id
    AND NOT f2.anulada
    AND f2.tipo_comprobante <> 'nota_credito'
    AND (f2.fecha_comprobante, f2.created_at) > (v_fc.fecha_comprobante, v_fc.created_at)
  ORDER BY f2.fecha_comprobante DESC, f2.created_at DESC
  LIMIT 1;

  -- Mismas reglas que cargar_factura_compra (docs/13, docs/34, docs/45).
  v_costo_linea := ROUND(v_item.precio_unitario_sin_iva * (1 - v_item.descuento_porcentaje / 100.0), 2);
  v_pone_costo := v_fc.tipo_comprobante NOT IN ('nota_credito', 'nota_debito') AND v_costo_linea > 0;
  v_cambia_proveedor := v_prod.proveedor_id IS DISTINCT FROM v_fc.proveedor_id;
  v_costo_nuevo := CASE WHEN v_pone_costo THEN v_costo_linea ELSE v_prod.costo END;
  v_m1 := CASE WHEN v_cambia_proveedor THEN v_prov.margen_1_default ELSE v_prod.margen_1 END;
  v_m2 := CASE WHEN v_cambia_proveedor THEN v_prov.margen_2_default ELSE v_prod.margen_2 END;
  v_manual_nuevo := CASE WHEN v_pone_costo THEN NULL ELSE v_prod.precio_manual END;
  v_cambia := v_cambia_proveedor OR v_costo_nuevo IS DISTINCT FROM v_prod.costo
              OR (v_pone_costo AND v_prod.precio_manual IS NOT NULL);

  RETURN jsonb_build_object(
    'aplica', v_post.id IS NULL AND v_cambia,
    'compra_posterior', CASE WHEN v_post.id IS NULL THEN NULL ELSE jsonb_build_object(
        'fecha_comprobante', v_post.fecha_comprobante, 'tipo_comprobante', v_post.tipo_comprobante,
        'letra', v_post.letra, 'punto_venta', v_post.punto_venta, 'numero_comprobante', v_post.numero_comprobante) END,
    'pone_costo', v_pone_costo,
    'costo_antes', v_prod.costo,
    'costo_nuevo', v_costo_nuevo,
    'precio_antes', v_prod.precio_venta,
    'precio_manual_antes', v_prod.precio_manual,
    -- Misma expresión que la columna generada productos.precio_venta.
    'precio_nuevo', COALESCE(v_manual_nuevo, redondear_precio_venta(
        v_costo_nuevo * (1 + v_m1 / 100.0) * (1 + v_m2 / 100.0) * (1 + v_prod.iva_porcentaje / 100.0))),
    'cambia_proveedor', v_cambia_proveedor,
    'proveedor_id_nuevo', v_fc.proveedor_id,
    'proveedor_nuevo', v_prov.razon_social,
    'margen_1_nuevo', v_m1,
    'margen_2_nuevo', v_m2);
END;
$$;

COMMENT ON FUNCTION public.plan_costo_vinculo_item(uuid, uuid) IS
  'Interna: qué le hace al producto vincularle un ítem de factura (costo, precio manual, proveedor/márgenes), si es la compra más nueva. docs/56.';

REVOKE ALL ON FUNCTION public.plan_costo_vinculo_item(uuid, uuid) FROM PUBLIC, anon, authenticated;

-- ─── aplicar ──────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.aplicar_costo_vinculo_item(p_item_id uuid, p_producto_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_plan jsonb;
  v_cambia_proveedor boolean;
BEGIN
  -- Lock antes del plan: una carga de factura simultánea del mismo producto espera.
  PERFORM 1 FROM productos WHERE id = p_producto_id FOR UPDATE;
  v_plan := plan_costo_vinculo_item(p_item_id, p_producto_id);
  IF v_plan IS NULL OR NOT (v_plan->>'aplica')::boolean THEN
    RETURN v_plan;
  END IF;

  v_cambia_proveedor := (v_plan->>'cambia_proveedor')::boolean;
  IF v_cambia_proveedor THEN
    PERFORM set_config('virikyna.margen_auto_herencia', 'true', true);
  END IF;

  UPDATE productos
  SET proveedor_id = (v_plan->>'proveedor_id_nuevo')::uuid,
      margen_1 = (v_plan->>'margen_1_nuevo')::numeric,
      margen_2 = (v_plan->>'margen_2_nuevo')::numeric,
      costo = (v_plan->>'costo_nuevo')::numeric,
      precio_manual = CASE WHEN (v_plan->>'pone_costo')::boolean THEN NULL ELSE precio_manual END,
      updated_at = now()
  WHERE id = p_producto_id;

  IF v_cambia_proveedor THEN
    PERFORM set_config('virikyna.margen_auto_herencia', 'false', true);
  END IF;
  RETURN v_plan;
END;
$$;

COMMENT ON FUNCTION public.aplicar_costo_vinculo_item(uuid, uuid) IS
  'Interna: aplica plan_costo_vinculo_item al producto (mismo UPDATE que cargar_factura_compra). docs/56.';

REVOKE ALL ON FUNCTION public.aplicar_costo_vinculo_item(uuid, uuid) FROM PUBLIC, anon, authenticated;

-- ─── vista previa (RPC) ───────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.vista_previa_vincular_item_factura_compra(p_item_id uuid, p_producto_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede vincular un ítem de una factura ya cargada';
  END IF;
  RETURN plan_costo_vinculo_item(p_item_id, p_producto_id);
END;
$$;

COMMENT ON FUNCTION public.vista_previa_vincular_item_factura_compra(uuid, uuid) IS
  'Solo admin, solo lectura: cómo quedan costo y precio del producto si se le vincula el ítem. docs/56.';

REVOKE ALL ON FUNCTION public.vista_previa_vincular_item_factura_compra(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vista_previa_vincular_item_factura_compra(uuid, uuid) TO authenticated, service_role;

-- ─── vincular ─────────────────────────────────────────────────────────────────────────────────
-- Cuerpo = pg_get_functiondef de hoy (docs/50 + docs/53 + docs/55) con el cambio marcado docs/56.
CREATE OR REPLACE FUNCTION public.vincular_item_factura_compra(p_item_id uuid, p_producto_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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

  -- docs/56: costo, precio manual y proveedor/márgenes como al cargar, si es la compra más nueva.
  PERFORM aplicar_costo_vinculo_item(p_item_id, p_producto_id);
END;
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — corrección del primer vínculo (BASTIDOR CON PINTURAS 30 X 40, factura 18720 de ANKHA)
-- Esperado: costo 2695,50 → 5391 (5990 − 10 %), precio de venta 8000 → 16000. Si los datos ya no
-- son los relevados (alguien lo editó, o ya se aplicó), no hace nada y lo avisa.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

SELECT set_config('request.jwt.claims', '{"sub":"4b6fc500-fa5f-4512-84b8-13345382b761","role":"authenticated"}', true);

DO $$
DECLARE
  v_item uuid := '00607384-e874-4c68-b675-ba66feb96280';
  v_prod uuid := '4eeed9ab-2595-4956-a9c0-cc0afb4b73a3';
  v_plan jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM facturas_compra_items WHERE id = v_item AND producto_id = v_prod)
     OR NOT EXISTS (SELECT 1 FROM productos WHERE id = v_prod AND costo = 2695.5 AND precio_manual IS NULL
                      AND proveedor_id = '999cc0cb-65bc-4d57-8582-ac6c5ccd6902'
                      AND updated_at = '2026-10-20 20:00:08.974587+00') THEN
    RAISE NOTICE 'PARTE B: los datos no son los relevados (o ya se aplicó): no se toca nada';
    RETURN;
  END IF;
  v_plan := aplicar_costo_vinculo_item(v_item, v_prod);
  RAISE NOTICE 'PARTE B: %', v_plan;
END;
$$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (no deja nada: BEGIN … ROLLBACK)
-- Un producto real y dos proveedores reales, todo dentro de la transacción; fechas en 2036 para
-- que ninguna compra real sea "posterior". Resultado: una tabla, todo ok = true.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

SELECT set_config('request.jwt.claims',
                  json_build_object('sub', (SELECT id FROM perfiles WHERE activo AND rol = 'admin' ORDER BY created_at LIMIT 1),
                                    'role', 'authenticated')::text, true);

CREATE TEMP TABLE t56 (orden int, caso text, ok boolean, detalle text) ON COMMIT DROP;

DO $test$
DECLARE
  v_a uuid := (SELECT id FROM proveedores ORDER BY razon_social LIMIT 1);
  v_b uuid := (SELECT id FROM proveedores ORDER BY razon_social OFFSET 1 LIMIT 1);
  v_p uuid;
  v_f uuid;
  v_item uuid;
  v_plan jsonb;
  v_prod productos%ROWTYPE;
  v_stock0 numeric;
  v_err text;

  -- Carga un comprobante con un ítem libre y devuelve el id del ítem.
  v_libre jsonb;
BEGIN
  SELECT id INTO v_p FROM productos WHERE estado = 'activo' ORDER BY nombre LIMIT 1;
  UPDATE productos SET proveedor_id = v_a, costo = 100, precio_manual = 999 WHERE id = v_p;

  -- 1. Factura más nueva: pone costo (con descuento) y borra el precio manual.
  v_libre := '[{"producto_id": null, "descripcion": "TEST 56 A", "cantidad": 3, "precio_unitario_sin_iva": 200, "descuento_porcentaje": 10, "ubicacion": "local"}]';
  v_f := cargar_factura_compra(p_proveedor_id => v_a, p_tipo_comprobante => 'factura', p_letra => 'A',
           p_punto_venta => '9999', p_numero_comprobante => 'T56-1', p_fecha_comprobante => '2036-01-10',
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente', p_items => v_libre, p_iva_alicuota => 21);
  SELECT id INTO v_item FROM facturas_compra_items WHERE factura_compra_id = v_f;
  SELECT COALESCE(sum(cantidad), 0) INTO v_stock0 FROM stock_ubicaciones WHERE producto_id = v_p;
  v_plan := vista_previa_vincular_item_factura_compra(v_item, v_p);
  PERFORM vincular_item_factura_compra(v_item, v_p);
  SELECT * INTO v_prod FROM productos WHERE id = v_p;
  INSERT INTO t56 SELECT 1, 'más nueva: costo 180, sin manual, stock +3, precio = vista previa',
    (v_plan->>'aplica')::boolean AND v_prod.costo = 180 AND v_prod.precio_manual IS NULL
      AND v_prod.precio_venta = (v_plan->>'precio_nuevo')::numeric
      AND (SELECT sum(cantidad) FROM stock_ubicaciones WHERE producto_id = v_p) = v_stock0 + 3,
    format('plan %s costo %s manual %s precio %s', v_plan, v_prod.costo, v_prod.precio_manual, v_prod.precio_venta);

  -- 2. Factura más vieja: suma stock, el costo queda.
  v_libre := '[{"producto_id": null, "descripcion": "TEST 56 B", "cantidad": 1, "precio_unitario_sin_iva": 50, "descuento_porcentaje": 0, "ubicacion": "local"}]';
  v_f := cargar_factura_compra(p_proveedor_id => v_a, p_tipo_comprobante => 'factura', p_letra => 'A',
           p_punto_venta => '9999', p_numero_comprobante => 'T56-2', p_fecha_comprobante => '2036-01-05',
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente', p_items => v_libre, p_iva_alicuota => 21);
  SELECT id INTO v_item FROM facturas_compra_items WHERE factura_compra_id = v_f;
  v_plan := vista_previa_vincular_item_factura_compra(v_item, v_p);
  PERFORM vincular_item_factura_compra(v_item, v_p);
  SELECT * INTO v_prod FROM productos WHERE id = v_p;
  INSERT INTO t56 SELECT 2, 'más vieja: no aplica, avisa la posterior (10/01), costo 180',
    NOT (v_plan->>'aplica')::boolean AND v_plan->'compra_posterior'->>'fecha_comprobante' = '2036-01-10'
      AND v_prod.costo = 180 AND (SELECT sum(cantidad) FROM stock_ubicaciones WHERE producto_id = v_p) = v_stock0 + 4,
    format('plan %s costo %s', v_plan, v_prod.costo);

  -- 3. La posterior anulada no cuenta: una del 07/01 pasa a ser la más nueva.
  PERFORM anular_factura_compra((SELECT id FROM facturas_compra WHERE punto_venta = '9999' AND numero_comprobante = 'T56-1'),
                                'test 56');
  v_libre := '[{"producto_id": null, "descripcion": "TEST 56 C", "cantidad": 1, "precio_unitario_sin_iva": 70, "descuento_porcentaje": 0, "ubicacion": "local"}]';
  v_f := cargar_factura_compra(p_proveedor_id => v_a, p_tipo_comprobante => 'factura', p_letra => 'A',
           p_punto_venta => '9999', p_numero_comprobante => 'T56-3', p_fecha_comprobante => '2036-01-07',
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente', p_items => v_libre, p_iva_alicuota => 21);
  SELECT id INTO v_item FROM facturas_compra_items WHERE factura_compra_id = v_f;
  PERFORM vincular_item_factura_compra(v_item, v_p);
  SELECT * INTO v_prod FROM productos WHERE id = v_p;
  INSERT INTO t56 SELECT 3, 'posterior anulada no cuenta: costo 70', v_prod.costo = 70, format('costo %s', v_prod.costo);

  -- 4. Otro proveedor: toma proveedor y márgenes default.
  v_libre := '[{"producto_id": null, "descripcion": "TEST 56 D", "cantidad": 1, "precio_unitario_sin_iva": 300, "descuento_porcentaje": 0, "ubicacion": "deposito"}]';
  v_f := cargar_factura_compra(p_proveedor_id => v_b, p_tipo_comprobante => 'factura', p_letra => 'A',
           p_punto_venta => '9999', p_numero_comprobante => 'T56-4', p_fecha_comprobante => '2036-02-01',
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente', p_items => v_libre, p_iva_alicuota => 21);
  SELECT id INTO v_item FROM facturas_compra_items WHERE factura_compra_id = v_f;
  PERFORM vincular_item_factura_compra(v_item, v_p);
  SELECT * INTO v_prod FROM productos WHERE id = v_p;
  INSERT INTO t56 SELECT 4, 'otro proveedor: proveedor B, márgenes default de B, costo 300',
    v_prod.proveedor_id = v_b AND v_prod.costo = 300
      AND v_prod.margen_1 = (SELECT margen_1_default FROM proveedores WHERE id = v_b)
      AND v_prod.margen_2 = (SELECT margen_2_default FROM proveedores WHERE id = v_b),
    format('prov %s costo %s m1 %s m2 %s', v_prod.proveedor_id = v_b, v_prod.costo, v_prod.margen_1, v_prod.margen_2);

  -- 5. Nota de débito más nueva: suma stock, no pone costo.
  v_libre := '[{"producto_id": null, "descripcion": "TEST 56 E", "cantidad": 1, "precio_unitario_sin_iva": 999, "descuento_porcentaje": 0, "ubicacion": "local"}]';
  v_f := cargar_factura_compra(p_proveedor_id => v_b, p_tipo_comprobante => 'nota_debito', p_letra => 'A',
           p_punto_venta => '9999', p_numero_comprobante => 'T56-5', p_fecha_comprobante => '2036-03-01',
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente', p_items => v_libre, p_iva_alicuota => 21);
  SELECT id INTO v_item FROM facturas_compra_items WHERE factura_compra_id = v_f;
  v_plan := vista_previa_vincular_item_factura_compra(v_item, v_p);
  PERFORM vincular_item_factura_compra(v_item, v_p);
  SELECT * INTO v_prod FROM productos WHERE id = v_p;
  INSERT INTO t56 SELECT 5, 'nota de débito: no aplica, costo 300', NOT (v_plan->>'aplica')::boolean AND v_prod.costo = 300,
    format('plan %s costo %s', v_plan, v_prod.costo);

  -- 6. Las funciones internas no se pueden llamar desde las apps.
  INSERT INTO t56 SELECT 6, 'internas sin EXECUTE para authenticated',
    NOT has_function_privilege('authenticated', 'public.plan_costo_vinculo_item(uuid, uuid)', 'EXECUTE')
      AND NOT has_function_privilege('authenticated', 'public.aplicar_costo_vinculo_item(uuid, uuid)', 'EXECUTE')
      AND has_function_privilege('authenticated', 'public.vista_previa_vincular_item_factura_compra(uuid, uuid)', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'public.vista_previa_vincular_item_factura_compra(uuid, uuid)', 'EXECUTE'),
    '';

  -- 7. Vista previa: un cajero no puede.
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', (SELECT id FROM perfiles WHERE activo AND rol <> 'admin' ORDER BY created_at LIMIT 1),
                                       'role', 'authenticated')::text, true);
  BEGIN
    PERFORM vista_previa_vincular_item_factura_compra(v_item, v_p);
    v_err := NULL;
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  INSERT INTO t56 SELECT 7, 'vista previa rechazada a no admin', v_err LIKE 'Solo un administrador%', coalesce(v_err, 'no falló');
END;
$test$;

SELECT * FROM t56 ORDER BY orden;

ROLLBACK;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE D — verificación (solo lectura)
-- Esperado: 4 funciones sin sobrecargas; vista previa con EXECUTE para authenticated, las internas
-- sin; el BASTIDOR con costo 5391 y precio 16000.
-- ════════════════════════════════════════════════════════════════════════════════════════════
SELECT 'firma' AS chequeo, p.oid::regprocedure::text AS valor, coalesce(array_to_string(p.proacl, ','), '') AS detalle
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('plan_costo_vinculo_item', 'aplicar_costo_vinculo_item',
        'vista_previa_vincular_item_factura_compra', 'vincular_item_factura_compra')
UNION ALL
SELECT 'bastidor', format('costo %s precio %s manual %s', costo, precio_venta, precio_manual), updated_at::text
FROM productos WHERE id = '4eeed9ab-2595-4956-a9c0-cc0afb4b73a3';
