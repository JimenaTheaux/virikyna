-- 53 — Tipo de compra: ARTICULOS / SERVICIOS en facturas de compra
--
-- ⏳ NO APLICADO todavía. Correr desde la raíz del repo con
-- `npx supabase db query --linked -f docs/53_tipo_compra.sql` (o en el SQL Editor del proyecto
-- ccpinvtleqlsukcqnili), después de 52. La PARTE A va una sola vez; la PARTE B (verificación) y la
-- PARTE C (test, BEGIN … ROLLBACK) se pueden repetir.
--
-- Contexto (relevado contra la base real el 2026-10-21):
--   - Una factura de servicios (flete, mantenimiento, honorarios) se cargaba como factura con ítems
--     libres (producto_id NULL): no tocaba stock ni costo, pero la pantalla pedía cantidad, código y
--     confirmar "ítems que no suman stock", y después ofrecía "Vincular a producto" (docs/50), que sí
--     suma stock.
--   - Los cuerpos de abajo son los de pg_get_functiondef de hoy (idénticos a docs/45 y docs/50), con
--     los cambios marcados "docs/53".
--   - facturas_compra_saldo no tiene vistas que dependan de ella: la columna nueva va al final,
--     repitiendo security_invoker (docs/38).
--
-- Qué hace:
--   1. facturas_compra.tipo_compra text NOT NULL DEFAULT 'articulos', CHECK ('articulos','servicios').
--      Lo existente queda en 'articulos', que es como se cargó.
--   2. cargar_factura_compra(…, p_tipo_compra text DEFAULT 'articulos'):
--      - Sin el parámetro (Local viejas instaladas) se comporta exactamente como antes.
--      - En servicios rechaza ítems con producto_id y con cantidad distinta de 1 (la pantalla oculta
--        la cantidad y manda 1). Sin producto no hay movimiento de stock ni cambio de costo/precio:
--        el resto del cuerpo no cambia. El depósito del ítem se guarda igual, es informativo.
--      - Vale para cualquier tipo de comprobante: una NC de servicios resta deuda igual que hoy.
--   3. vincular_item_factura_compra: rechaza ítems de una factura de servicios.
--   4. tipo_compra no se cambia nunca después de cargada (trigger): editar_factura_compra no lo
--      recibe, y un UPDATE directo también lo frena. Si está mal, se anula y se vuelve a cargar.
--   5. facturas_compra_saldo: + tipo_compra al final (los cálculos no cambian).
--   Pagos, aplicaciones, saldos, anulación y NC no cambian: una NC de servicios se aplica a una
--   factura de artículos y al revés, como cualquier NC del mismo proveedor.
--   Agregar un parámetro cambia la firma: DROP + CREATE en la misma transacción, con los grants.

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios (una sola vez)
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

ALTER TABLE public.facturas_compra
  ADD COLUMN IF NOT EXISTS tipo_compra TEXT NOT NULL DEFAULT 'articulos';

ALTER TABLE public.facturas_compra DROP CONSTRAINT IF EXISTS facturas_compra_tipo_compra_valido;
ALTER TABLE public.facturas_compra
  ADD CONSTRAINT facturas_compra_tipo_compra_valido CHECK (tipo_compra IN ('articulos', 'servicios'));

COMMENT ON COLUMN public.facturas_compra.tipo_compra IS
  'articulos (default) o servicios. Servicios: ítems sin producto y cantidad 1, no mueven stock ni costo. No se cambia después de cargada. docs/53.';

-- ─── tipo_compra fijo ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.proteger_tipo_compra()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  RAISE EXCEPTION 'El tipo de compra (artículos/servicios) no se cambia: anulá el comprobante y volvé a cargarlo';
END;
$$;

COMMENT ON FUNCTION public.proteger_tipo_compra() IS
  'Trigger (facturas_compra): tipo_compra no cambia después de cargada. docs/53.';

REVOKE EXECUTE ON FUNCTION public.proteger_tipo_compra() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_proteger_tipo_compra ON public.facturas_compra;
CREATE TRIGGER trg_proteger_tipo_compra
  BEFORE UPDATE OF tipo_compra ON public.facturas_compra
  FOR EACH ROW
  WHEN (OLD.tipo_compra IS DISTINCT FROM NEW.tipo_compra)
  EXECUTE FUNCTION public.proteger_tipo_compra();

-- ─── cargar_factura_compra ────────────────────────────────────────────────────────────────────
DROP FUNCTION public.cargar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date, forma_pago_compra, jsonb, uuid, numeric);

CREATE FUNCTION public.cargar_factura_compra(p_proveedor_id uuid, p_tipo_comprobante tipo_comprobante_compra, p_letra letra_comprobante_compra, p_punto_venta text, p_numero_comprobante text, p_fecha_comprobante date, p_fecha_fiscal date, p_forma_pago forma_pago_compra, p_items jsonb, p_copiada_de_id uuid DEFAULT NULL::uuid, p_iva_alicuota numeric DEFAULT 21, p_tipo_compra text DEFAULT 'articulos'::text)
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
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
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
         tipo_compra)   -- docs/53
  VALUES (p_proveedor_id, p_tipo_comprobante, p_letra, p_punto_venta, p_numero_comprobante,
         p_fecha_comprobante, p_fecha_fiscal, p_forma_pago, v_total_sin_iva, v_iva, v_total, auth.uid(), p_copiada_de_id,
         p_iva_alicuota,
         p_tipo_compra)
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

    IF v_producto_id IS NOT NULL THEN
      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, referencia_id, usuario_id)
      VALUES (v_producto_id, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'),
             'compra', (v_item->>'cantidad')::NUMERIC, v_factura_id, auth.uid());

      INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
      VALUES (v_producto_id, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'), (v_item->>'cantidad')::NUMERIC)
      ON CONFLICT (producto_id, ubicacion)
      DO UPDATE SET cantidad = stock_ubicaciones.cantidad + (v_item->>'cantidad')::NUMERIC;
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

REVOKE ALL ON FUNCTION public.cargar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date, forma_pago_compra, jsonb, uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cargar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date, forma_pago_compra, jsonb, uuid, numeric, text) TO authenticated, service_role;

-- ─── vincular_item_factura_compra ─────────────────────────────────────────────────────────────
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

  SELECT anulada, tipo_compra INTO v_anulada, v_tipo_compra FROM facturas_compra WHERE id = v_item.factura_compra_id;
  IF v_anulada THEN
    RAISE EXCEPTION 'El comprobante está anulado: no se le suma stock';
  END IF;
  -- docs/53: un servicio no es mercadería, no se vincula ni suma stock.
  IF v_tipo_compra = 'servicios' THEN
    RAISE EXCEPTION 'Es una factura de servicios: sus ítems no se vinculan a productos';
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

-- ─── facturas_compra_saldo: + tipo_compra (al final; los cálculos no cambian) ─────────────────
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
    fc.tipo_compra
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
-- Esperado: 1 fila por función (sin sobrecargas), grants authenticated + service_role, vista con
-- security_invoker=on y la columna, trigger presente, todo lo existente en 'articulos'.
-- ════════════════════════════════════════════════════════════════════════════════════════════
SELECT 'firma' AS chequeo, p.oid::regprocedure::text AS valor, array_to_string(p.proacl, ',') AS detalle
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('cargar_factura_compra', 'vincular_item_factura_compra', 'proteger_tipo_compra')
UNION ALL
SELECT 'vista', array_to_string(c.reloptions, ','),
       (SELECT string_agg(attname, ',') FROM pg_attribute WHERE attrelid = c.oid AND attname = 'tipo_compra')
FROM pg_class c WHERE c.oid = 'public.facturas_compra_saldo'::regclass
UNION ALL
SELECT 'trigger', tgname::text, pg_get_triggerdef(oid) FROM pg_trigger WHERE tgname = 'trg_proteger_tipo_compra'
UNION ALL
SELECT 'tipos de compra', string_agg(DISTINCT tipo_compra, ','), count(*)::text FROM facturas_compra;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (no deja nada: BEGIN … ROLLBACK)
-- Usa un admin activo, el primer proveedor y un producto real, todo dentro de la transacción.
-- No consume secuencias (facturas, pagos y egresos usan uuid). Resultado: una tabla, todo ok = true.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

SELECT set_config('request.jwt.claims',
                  json_build_object('sub', (SELECT id FROM perfiles WHERE activo AND rol = 'admin' ORDER BY created_at LIMIT 1),
                                    'role', 'authenticated')::text, true);

CREATE TEMP TABLE t53 (orden int, caso text, ok boolean, detalle text) ON COMMIT DROP;

DO $test$
DECLARE
  v_prov uuid := (SELECT id FROM proveedores ORDER BY razon_social LIMIT 1);
  v_p uuid;
  v_stock0 numeric;
  v_costo0 numeric;
  v_saldo0 numeric;
  v_f uuid;
  v_serv uuid;
  v_nc uuid;
  v_item uuid;
  v_fc facturas_compra%ROWTYPE;
  v_movs int;
  -- Un servicio de $1.000 con 10 % de descuento → 900 sin IVA, 1089 con 21 %.
  v_servicio jsonb := '[{"producto_id": null, "descripcion": "flete test 53", "cantidad": 1, "precio_unitario_sin_iva": 1000, "descuento_porcentaje": 10, "ubicacion": "deposito"}]';
BEGIN
  SELECT id INTO v_p FROM productos WHERE estado = 'activo' ORDER BY nombre LIMIT 1;
  SELECT COALESCE(sum(cantidad), 0) INTO v_stock0 FROM stock_ubicaciones WHERE producto_id = v_p;
  SELECT costo INTO v_costo0 FROM productos WHERE id = v_p;
  SELECT saldo_actual INTO v_saldo0 FROM proveedores_saldo WHERE id = v_prov;

  -- 1. Llamada vieja (Local instalada, sin p_tipo_compra): artículos, suma stock y pone costo.
  v_f := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
           p_punto_venta => '9999', p_numero_comprobante => 'T53-1', p_fecha_comprobante => current_date,
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente',
           p_items => jsonb_build_array(jsonb_build_object('producto_id', v_p, 'descripcion', 'TEST 53',
                        'cantidad', 2, 'precio_unitario_sin_iva', 777, 'descuento_porcentaje', 0)),
           p_iva_alicuota => 21);
  SELECT * INTO v_fc FROM facturas_compra WHERE id = v_f;
  INSERT INTO t53 SELECT 1, 'sin p_tipo_compra: artículos, stock +2, costo 777',
    v_fc.tipo_compra = 'articulos'
      AND (SELECT sum(cantidad) FROM stock_ubicaciones WHERE producto_id = v_p) = v_stock0 + 2
      AND (SELECT costo FROM productos WHERE id = v_p) = 777,
    format('tipo %s stock %s→%s costo %s→%s', v_fc.tipo_compra, v_stock0,
           (SELECT sum(cantidad) FROM stock_ubicaciones WHERE producto_id = v_p), v_costo0,
           (SELECT costo FROM productos WHERE id = v_p));

  -- 2. Servicios: total con descuento e IVA, sin movimientos de stock, depósito guardado.
  SELECT COALESCE(sum(cantidad), 0) INTO v_stock0 FROM stock_ubicaciones WHERE producto_id = v_p;
  v_serv := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
           p_punto_venta => '9999', p_numero_comprobante => 'T53-2', p_fecha_comprobante => current_date,
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente', p_items => v_servicio,
           p_iva_alicuota => 21, p_tipo_compra => 'servicios');
  SELECT * INTO v_fc FROM facturas_compra WHERE id = v_serv;
  SELECT count(*) INTO v_movs FROM movimientos_stock WHERE referencia_id = v_serv;
  SELECT id INTO v_item FROM facturas_compra_items WHERE factura_compra_id = v_serv;
  INSERT INTO t53 SELECT 2, 'servicios: 900 + 189 = 1089, sin stock, depósito, MAYÚSCULAS',
    v_fc.tipo_compra = 'servicios' AND v_fc.total_sin_iva = 900 AND v_fc.total = 1089 AND v_movs = 0
      AND i.ubicacion = 'deposito' AND i.descripcion = 'FLETE TEST 53'
      AND (SELECT tipo_compra FROM facturas_compra_saldo WHERE id = v_serv) = 'servicios'
      AND (SELECT sum(cantidad) FROM stock_ubicaciones WHERE producto_id = v_p) = v_stock0,
    format('total %s movs %s ubic %s desc %s', v_fc.total, v_movs, i.ubicacion, i.descripcion)
  FROM facturas_compra_items i WHERE i.id = v_item;

  -- 3. Servicios con producto_id → rechazado.
  BEGIN
    PERFORM cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
             p_punto_venta => '9999', p_numero_comprobante => 'T53-3', p_fecha_comprobante => current_date,
             p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente',
             p_items => jsonb_build_array(jsonb_build_object('producto_id', v_p, 'descripcion', 'TEST 53',
                          'cantidad', 1, 'precio_unitario_sin_iva', 100)),
             p_iva_alicuota => 21, p_tipo_compra => 'servicios');
    INSERT INTO t53 VALUES (3, 'servicios con producto_id rechazado', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t53 VALUES (3, 'servicios con producto_id rechazado', SQLERRM LIKE 'Una factura de servicios no lleva productos%', SQLERRM);
  END;

  -- 4. Servicios con cantidad 3 → rechazado.
  BEGIN
    PERFORM cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
             p_punto_venta => '9999', p_numero_comprobante => 'T53-4', p_fecha_comprobante => current_date,
             p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente',
             p_items => '[{"producto_id": null, "descripcion": "x", "cantidad": 3, "precio_unitario_sin_iva": 100}]',
             p_iva_alicuota => 21, p_tipo_compra => 'servicios');
    INSERT INTO t53 VALUES (4, 'servicios con cantidad 3 rechazado', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t53 VALUES (4, 'servicios con cantidad 3 rechazado', SQLERRM LIKE 'En una factura de servicios cada ítem%', SQLERRM);
  END;

  -- 5. Tipo de compra inválido → rechazado.
  BEGIN
    PERFORM cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
             p_punto_venta => '9999', p_numero_comprobante => 'T53-5', p_fecha_comprobante => current_date,
             p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente', p_items => v_servicio,
             p_iva_alicuota => 21, p_tipo_compra => 'otro');
    INSERT INTO t53 VALUES (5, 'tipo de compra inválido rechazado', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t53 VALUES (5, 'tipo de compra inválido rechazado', SQLERRM LIKE 'Tipo de compra inválido%', SQLERRM);
  END;

  -- 6. Vincular un ítem de servicios → rechazado, sin stock.
  BEGIN
    PERFORM vincular_item_factura_compra(v_item, v_p);
    INSERT INTO t53 VALUES (6, 'vincular ítem de servicios rechazado', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t53 VALUES (6, 'vincular ítem de servicios rechazado', SQLERRM LIKE 'Es una factura de servicios%', SQLERRM);
  END;

  -- 7. editar_factura_compra sobre servicios: número sí, tipo_compra se mantiene.
  PERFORM editar_factura_compra(p_factura_id => v_serv, p_tipo_comprobante => 'factura', p_numero_comprobante => 'T53-2B',
           p_iva_alicuota => 21);
  SELECT * INTO v_fc FROM facturas_compra WHERE id = v_serv;
  INSERT INTO t53 VALUES (7, 'editar servicios: cambia número, sigue servicios',
    v_fc.numero_comprobante = 'T53-2B' AND v_fc.tipo_compra = 'servicios', format('número %s tipo %s', v_fc.numero_comprobante, v_fc.tipo_compra));

  -- 8. UPDATE directo de tipo_compra → frenado por el trigger.
  BEGIN
    UPDATE facturas_compra SET tipo_compra = 'articulos' WHERE id = v_serv;
    INSERT INTO t53 VALUES (8, 'cambiar tipo_compra rechazado', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t53 VALUES (8, 'cambiar tipo_compra rechazado', SQLERRM LIKE 'El tipo de compra%no se cambia%', SQLERRM);
  END;

  -- 9. Pago de 89 imputado a la factura de servicios: saldo 1000.
  PERFORM registrar_pago_proveedor_v2(p_proveedor_id => v_prov, p_monto => 89, p_forma_pago => 'efectivo',
           p_factura_ids => ARRAY[v_serv], p_nota_credito_ids => NULL, p_origen => 'general');
  INSERT INTO t53 SELECT 9, 'pago a factura de servicios: saldo 1000',
    saldo_pendiente = 1000 AND estado = 'parcial', format('saldo %s estado %s', saldo_pendiente, estado)
  FROM facturas_compra_saldo WHERE id = v_serv;

  -- 10. NC de servicios (exenta, 500) aplicada a la factura de ARTÍCULOS del caso 1 (1554 + 326,34).
  v_nc := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'nota_credito', p_letra => 'A',
           p_punto_venta => '9999', p_numero_comprobante => 'T53-10', p_fecha_comprobante => current_date,
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente',
           p_items => '[{"producto_id": null, "descripcion": "bonificacion flete", "cantidad": 1, "precio_unitario_sin_iva": 500}]',
           p_iva_alicuota => 0, p_tipo_compra => 'servicios');
  PERFORM registrar_pago_proveedor_v2(p_proveedor_id => v_prov, p_monto => 0, p_forma_pago => 'efectivo',
           p_factura_ids => ARRAY[v_f], p_nota_credito_ids => ARRAY[v_nc], p_origen => 'general');
  INSERT INTO t53 SELECT 10, 'NC servicios aplicada a factura artículos: saldo 1880,34 − 500',
    f.saldo_pendiente = 1380.34 AND nc.credito_disponible = 0 AND nc.tipo_compra = 'servicios',
    format('saldo factura %s crédito NC %s', f.saldo_pendiente, nc.credito_disponible)
  FROM facturas_compra_saldo f, facturas_compra_saldo nc WHERE f.id = v_f AND nc.id = v_nc;

  -- 11. Saldo del proveedor: +1880,34 (art.) +1089 (serv.) −89 (pago) −500 (NC) = +2380,34
  INSERT INTO t53 SELECT 11, 'saldo proveedor: +2380,34',
    saldo_actual - v_saldo0 = 2380.34, format('delta %s', saldo_actual - v_saldo0)
  FROM proveedores_saldo WHERE id = v_prov;

  -- 12. Anular la factura de servicios con un pago aplicado: rechazado, como cualquier comprobante.
  BEGIN
    PERFORM anular_factura_compra(v_serv, 'test 53');
    INSERT INTO t53 VALUES (12, 'anular servicios con pago: rechazado como siempre', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t53 VALUES (12, 'anular servicios con pago: rechazado como siempre', SQLERRM LIKE 'Este comprobante tiene pagos%', SQLERRM);
  END;
END
$test$;

SELECT * FROM t53 ORDER BY orden;

ROLLBACK;
