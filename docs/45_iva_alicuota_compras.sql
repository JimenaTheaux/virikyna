-- 45 — IVA por comprobante de compra (21 % / exento) y costo con el descuento de línea
--
-- Correr desde la raíz del repo con `npx supabase db query --linked -f docs/45_iva_alicuota_compras.sql`
-- (o en el SQL Editor del proyecto ccpinvtleqlsukcqnili), después de 44. La PARTE A va una sola vez;
-- la PARTE B (verificación) y la PARTE C (test, BEGIN … ROLLBACK) se pueden repetir.
-- Auditoría que lo origina: docs/auditoria-2026-10-19.md, secciones E.4 y F.
--
-- Contexto (relevado contra la base real el 2026-10-19):
--   - cargar_factura_compra calculaba `iva = ROUND(total_sin_iva * 0.21, 2)` para todos los tipos:
--     un cupón o un remito sin IVA quedaba con 21 % sumado al total (y a la deuda).
--   - El costo que pone la factura era el precio unitario sin IVA de la línea, sin restarle el
--     descuento % de esa misma línea (E.4).
--   - editar_factura_compra cambiaba el tipo sin recalcular IVA ni total.
--   - Los cuerpos de abajo son los de pg_get_functiondef de hoy, con los cambios marcados "docs/45".
--   - Grants actuales de las dos funciones: EXECUTE para authenticated y service_role, sin PUBLIC
--     ni anon. Nadie más las llama desde SQL (prosrc). Solo las llaman las apps, con argumentos
--     por nombre (PostgREST).
--   - facturas_compra_saldo lista las columnas una por una: la columna nueva hay que agregarla a
--     mano, al final, repitiendo security_invoker (ver docs/38).
--
-- Qué hace:
--   1. facturas_compra.iva_alicuota numeric(5,2) NOT NULL DEFAULT 21, CHECK (0 o 21). Lo existente
--      queda en 21, que es lo que tenía calculado.
--   2. cargar_factura_compra(…, p_iva_alicuota numeric DEFAULT 21):
--      - iva = ROUND(total_sin_iva × alícuota / 100, 2); total = total_sin_iva + iva.
--      - Sin el parámetro (las apps viejas instaladas) se comporta exactamente como antes: 21 %.
--      - Valida la alícuota en el servidor y la guarda en la factura.
--      - Costo del producto = precio unitario sin IVA × (1 − descuento % / 100) de la última línea.
--        NC/ND y costo efectivo 0 (precio 0 o descuento 100 %) siguen sin tocar el costo.
--      - El IVA del comprobante no toca el costo ni el IVA del producto.
--   3. editar_factura_compra(…, p_iva_alicuota numeric DEFAULT NULL): null = sin cambio.
--      - Si cambia el tipo o la alícuota, recalcula iva y total con la alícuota final.
--      - Si el comprobante tiene pagos o NC aplicados vigentes, no deja cambiar ni el tipo ni la
--        alícuota (antes solo bloqueaba el cambio de/a NC; ese caso queda incluido). El resto de los
--        campos se sigue pudiendo editar.
--      - Elegir el default de la alícuota al cambiar el tipo es cosa de la UI (alicuotaDefault en
--        packages/shared): el RPC no lo adivina, para no cambiarle el total a una app vieja que
--        solo manda el tipo.
--   Agregar un parámetro cambia la firma: CREATE OR REPLACE crearía una sobrecarga (y la llamada
--   sin el parámetro nuevo quedaría ambigua). Va DROP + CREATE en la misma transacción, y se vuelven
--   a poner los grants.
--   Saldos, pagos y NC no cambian: las vistas ya usan el `total` guardado.

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios (una sola vez)
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

ALTER TABLE public.facturas_compra
  ADD COLUMN IF NOT EXISTS iva_alicuota NUMERIC(5,2) NOT NULL DEFAULT 21;

ALTER TABLE public.facturas_compra DROP CONSTRAINT IF EXISTS facturas_compra_iva_alicuota_valida;
ALTER TABLE public.facturas_compra
  ADD CONSTRAINT facturas_compra_iva_alicuota_valida CHECK (iva_alicuota IN (0, 21));

COMMENT ON COLUMN public.facturas_compra.iva_alicuota IS
  'Alícuota de IVA del comprobante completo: 21 o 0 (exento). iva = ROUND(total_sin_iva × alícuota / 100, 2). No afecta el costo ni el IVA del producto. docs/45.';

-- ─── cargar_factura_compra ────────────────────────────────────────────────────────────────────
DROP FUNCTION public.cargar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date, forma_pago_compra, jsonb, uuid);

CREATE FUNCTION public.cargar_factura_compra(p_proveedor_id uuid, p_tipo_comprobante tipo_comprobante_compra, p_letra letra_comprobante_compra, p_punto_venta text, p_numero_comprobante text, p_fecha_comprobante date, p_fecha_fiscal date, p_forma_pago forma_pago_compra, p_items jsonb, p_copiada_de_id uuid DEFAULT NULL::uuid, p_iva_alicuota numeric DEFAULT 21)
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
         iva_alicuota)  -- docs/45
  VALUES (p_proveedor_id, p_tipo_comprobante, p_letra, p_punto_venta, p_numero_comprobante,
         p_fecha_comprobante, p_fecha_fiscal, p_forma_pago, v_total_sin_iva, v_iva, v_total, auth.uid(), p_copiada_de_id,
         p_iva_alicuota)
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

REVOKE ALL ON FUNCTION public.cargar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date, forma_pago_compra, jsonb, uuid, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cargar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date, forma_pago_compra, jsonb, uuid, numeric) TO authenticated, service_role;

-- ─── editar_factura_compra ────────────────────────────────────────────────────────────────────
DROP FUNCTION public.editar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date, forma_pago_compra);

CREATE FUNCTION public.editar_factura_compra(p_factura_id uuid, p_tipo_comprobante tipo_comprobante_compra DEFAULT NULL::tipo_comprobante_compra, p_letra letra_comprobante_compra DEFAULT NULL::letra_comprobante_compra, p_punto_venta text DEFAULT NULL::text, p_numero_comprobante text DEFAULT NULL::text, p_fecha_comprobante date DEFAULT NULL::date, p_fecha_fiscal date DEFAULT NULL::date, p_forma_pago forma_pago_compra DEFAULT NULL::forma_pago_compra, p_iva_alicuota numeric DEFAULT NULL::numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tipo_actual tipo_comprobante_compra;
  v_alicuota_actual NUMERIC;    -- docs/45
  v_tipo_nuevo tipo_comprobante_compra;
  v_alicuota_nueva NUMERIC;
  v_cambia_importes BOOLEAN;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede editar una factura de compra ya cargada';
  END IF;
  IF EXISTS (SELECT 1 FROM facturas_compra WHERE id = p_factura_id AND anulada = true) THEN
    RAISE EXCEPTION 'Esta factura está anulada, no se edita';
  END IF;
  IF p_iva_alicuota IS NOT NULL AND p_iva_alicuota NOT IN (0, 21) THEN
    RAISE EXCEPTION 'Alícuota de IVA inválida: tiene que ser 21 %% o exento (0)';
  END IF;

  SELECT tipo_comprobante, iva_alicuota INTO v_tipo_actual, v_alicuota_actual
  FROM facturas_compra WHERE id = p_factura_id FOR UPDATE;

  -- docs/45: tipo y alícuota definen el total (y, de/a NC, si suma o resta deuda). Con pagos o NC
  -- aplicados vigentes no se tocan: cambiaría lo que ya se imputó. Mandar el mismo valor no cuenta
  -- como cambio (la UI manda todos los campos siempre).
  v_tipo_nuevo := COALESCE(p_tipo_comprobante, v_tipo_actual);
  v_alicuota_nueva := COALESCE(p_iva_alicuota, v_alicuota_actual);
  v_cambia_importes := v_tipo_nuevo IS DISTINCT FROM v_tipo_actual
                       OR v_alicuota_nueva IS DISTINCT FROM v_alicuota_actual;

  IF v_cambia_importes AND EXISTS (
       SELECT 1 FROM pagos_proveedor_aplicaciones
       WHERE (factura_compra_id = p_factura_id OR nota_credito_id = p_factura_id)
         AND revertida_at IS NULL
     ) THEN
    RAISE EXCEPTION 'Este comprobante ya tiene pagos o notas de crédito aplicados: no se puede cambiar el tipo ni el IVA. Revertí esos pagos primero';
  END IF;

  UPDATE facturas_compra SET
    tipo_comprobante = v_tipo_nuevo,
    letra = COALESCE(p_letra, letra),
    punto_venta = COALESCE(p_punto_venta, punto_venta),
    numero_comprobante = COALESCE(p_numero_comprobante, numero_comprobante),
    fecha_comprobante = COALESCE(p_fecha_comprobante, fecha_comprobante),
    fecha_fiscal = COALESCE(p_fecha_fiscal, fecha_fiscal),
    forma_pago = COALESCE(p_forma_pago, forma_pago),
    -- docs/45: mismo cálculo que cargar_factura_compra, sobre el total sin IVA guardado.
    iva_alicuota = v_alicuota_nueva,
    iva = CASE WHEN v_cambia_importes THEN ROUND(total_sin_iva * v_alicuota_nueva / 100, 2) ELSE iva END,
    total = CASE WHEN v_cambia_importes THEN total_sin_iva + ROUND(total_sin_iva * v_alicuota_nueva / 100, 2) ELSE total END
  WHERE id = p_factura_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.editar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date, forma_pago_compra, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.editar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date, forma_pago_compra, numeric) TO authenticated, service_role;

-- ─── facturas_compra_saldo: + iva_alicuota (al final; los cálculos no cambian) ────────────────
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
    fc.iva_alicuota
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
-- security_invoker=on y la columna, y ninguna factura con un total distinto del recalculado.
-- ════════════════════════════════════════════════════════════════════════════════════════════
SELECT 'firma' AS chequeo, p.oid::regprocedure::text AS valor, array_to_string(p.proacl, ',') AS detalle
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('cargar_factura_compra', 'editar_factura_compra')
UNION ALL
SELECT 'vista', array_to_string(c.reloptions, ','),
       (SELECT string_agg(attname, ',') FROM pg_attribute WHERE attrelid = c.oid AND attname = 'iva_alicuota')
FROM pg_class c WHERE c.oid = 'public.facturas_compra_saldo'::regclass
UNION ALL
SELECT 'facturas con total inconsistente', count(*)::text, NULL
FROM facturas_compra
WHERE total <> total_sin_iva + ROUND(total_sin_iva * iva_alicuota / 100, 2)
UNION ALL
SELECT 'alícuotas', string_agg(DISTINCT iva_alicuota::text, ','), count(*)::text FROM facturas_compra;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (no deja nada: BEGIN … ROLLBACK)
-- Usa un admin activo, el primer proveedor y dos productos reales, todo dentro de la transacción.
-- No consume secuencias (facturas, pagos y egresos usan uuid). Resultado: una tabla, todo ok = true.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

SELECT set_config('request.jwt.claims',
                  json_build_object('sub', (SELECT id FROM perfiles WHERE activo AND rol = 'admin' ORDER BY created_at LIMIT 1),
                                    'role', 'authenticated')::text, true);

CREATE TEMP TABLE t45 (orden int, caso text, ok boolean, detalle text) ON COMMIT DROP;

DO $test$
DECLARE
  v_prov uuid := (SELECT id FROM proveedores ORDER BY razon_social LIMIT 1);
  v_p1 uuid;   -- producto para el costo con descuento
  v_p2 uuid;   -- producto para el descuento 100 %
  v_saldo0 numeric;
  v_f uuid;
  v_fc facturas_compra%ROWTYPE;
  v_costo numeric;
  v_ok boolean;
  v_msg text;
  -- Un ítem libre de $1.000 (sin producto: no toca stock ni costo)
  v_libre jsonb := '[{"producto_id": null, "descripcion": "TEST 45", "cantidad": 2, "precio_unitario_sin_iva": 500, "descuento_porcentaje": 0}]';
BEGIN
  SELECT id INTO v_p1 FROM productos WHERE estado = 'activo' ORDER BY nombre LIMIT 1;
  SELECT id INTO v_p2 FROM productos WHERE estado = 'activo' AND id <> v_p1 ORDER BY nombre LIMIT 1;
  SELECT saldo_actual INTO v_saldo0 FROM proveedores_saldo WHERE id = v_prov;

  -- 1. Factura 21 %
  v_f := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
           p_punto_venta => '9999', p_numero_comprobante => 'T45-1', p_fecha_comprobante => current_date,
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente', p_items => v_libre, p_iva_alicuota => 21);
  SELECT * INTO v_fc FROM facturas_compra WHERE id = v_f;
  INSERT INTO t45 VALUES (1, 'factura 21 %: 1000 + 210 = 1210',
    v_fc.iva_alicuota = 21 AND v_fc.iva = 210 AND v_fc.total = 1210, format('iva %s total %s', v_fc.iva, v_fc.total));

  -- 2. Factura exenta
  v_f := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
           p_punto_venta => '9999', p_numero_comprobante => 'T45-2', p_fecha_comprobante => current_date,
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente', p_items => v_libre, p_iva_alicuota => 0);
  SELECT * INTO v_fc FROM facturas_compra WHERE id = v_f;
  INSERT INTO t45 VALUES (2, 'factura exenta: total 1000',
    v_fc.iva_alicuota = 0 AND v_fc.iva = 0 AND v_fc.total = 1000, format('iva %s total %s', v_fc.iva, v_fc.total));

  -- 3. Remito con el default de la UI (alicuotaDefault('remito') = 0)
  v_f := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'remito', p_letra => NULL,
           p_punto_venta => NULL, p_numero_comprobante => 'T45-3', p_fecha_comprobante => current_date,
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente', p_items => v_libre, p_iva_alicuota => 0);
  SELECT * INTO v_fc FROM facturas_compra WHERE id = v_f;
  INSERT INTO t45 VALUES (3, 'remito exento (default UI): total 1000',
    v_fc.iva = 0 AND v_fc.total = 1000, format('iva %s total %s', v_fc.iva, v_fc.total));

  -- 4. Remito con 21 % elegido a mano
  v_f := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'remito', p_letra => NULL,
           p_punto_venta => NULL, p_numero_comprobante => 'T45-4', p_fecha_comprobante => current_date,
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente', p_items => v_libre, p_iva_alicuota => 21);
  SELECT * INTO v_fc FROM facturas_compra WHERE id = v_f;
  INSERT INTO t45 VALUES (4, 'remito con 21 %: total 1210',
    v_fc.iva = 210 AND v_fc.total = 1210, format('iva %s total %s', v_fc.iva, v_fc.total));

  -- 5. NC exenta: resta 1000 de la deuda
  v_f := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'nota_credito', p_letra => 'A',
           p_punto_venta => '9999', p_numero_comprobante => 'T45-5', p_fecha_comprobante => current_date,
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente', p_items => v_libre, p_iva_alicuota => 0);
  SELECT * INTO v_fc FROM facturas_compra WHERE id = v_f;
  INSERT INTO t45 VALUES (5, 'NC exenta: total 1000, crédito 1000',
    v_fc.iva = 0 AND v_fc.total = 1000
      AND (SELECT credito_disponible FROM facturas_compra_saldo WHERE id = v_f) = 1000,
    format('iva %s total %s', v_fc.iva, v_fc.total));

  -- Saldo del proveedor tras 1-5: +1210 +1000 +1000 +1210 −1000 = +3420
  INSERT INTO t45 SELECT 6, 'saldo proveedor tras 1-5: +3420',
    saldo_actual - v_saldo0 = 3420, format('delta %s', saldo_actual - v_saldo0)
  FROM proveedores_saldo WHERE id = v_prov;

  -- 7. Línea con descuento 10 %: costo = 1000 × 0,9 = 900. Subtotal 2 × 900 = 1800, IVA 378.
  v_f := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
           p_punto_venta => '9999', p_numero_comprobante => 'T45-7', p_fecha_comprobante => current_date,
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente',
           p_items => jsonb_build_array(jsonb_build_object('producto_id', v_p1, 'descripcion', 'TEST 45',
                        'cantidad', 2, 'precio_unitario_sin_iva', 1000, 'descuento_porcentaje', 10)),
           p_iva_alicuota => 21);
  SELECT * INTO v_fc FROM facturas_compra WHERE id = v_f;
  SELECT costo INTO v_costo FROM productos WHERE id = v_p1;
  INSERT INTO t45 VALUES (7, 'descuento 10 %: costo 900, total 1800 + 378',
    v_costo = 900 AND v_fc.total_sin_iva = 1800 AND v_fc.total = 2178 AND
      (SELECT iva_porcentaje FROM productos WHERE id = v_p1) = 21,
    format('costo %s total %s', v_costo, v_fc.total));

  -- 8. Descuento 100 %: costo efectivo 0 → no toca el costo (como precio 0)
  SELECT costo INTO v_costo FROM productos WHERE id = v_p2;
  PERFORM cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
           p_punto_venta => '9999', p_numero_comprobante => 'T45-8', p_fecha_comprobante => current_date,
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente',
           p_items => jsonb_build_array(jsonb_build_object('producto_id', v_p2, 'descripcion', 'TEST 45',
                        'cantidad', 1, 'precio_unitario_sin_iva', 1000, 'descuento_porcentaje', 100)),
           p_iva_alicuota => 21);
  INSERT INTO t45 SELECT 8, 'descuento 100 %: costo sin cambio',
    costo IS NOT DISTINCT FROM v_costo, format('antes %s después %s', v_costo, costo)
  FROM productos WHERE id = v_p2;

  -- 9. Llamada vieja: exactamente los parámetros de antes, sin p_iva_alicuota → 21 %
  v_f := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'cupon', p_letra => NULL,
           p_punto_venta => NULL, p_numero_comprobante => 'T45-9', p_fecha_comprobante => current_date,
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente', p_items => v_libre);
  SELECT * INTO v_fc FROM facturas_compra WHERE id = v_f;
  INSERT INTO t45 VALUES (9, 'sin p_iva_alicuota (app vieja): 21 % como antes',
    v_fc.iva_alicuota = 21 AND v_fc.total = 1210, format('alícuota %s total %s', v_fc.iva_alicuota, v_fc.total));

  -- 10. Alícuota inválida
  BEGIN
    PERFORM cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => NULL,
             p_punto_venta => NULL, p_numero_comprobante => 'T45-10', p_fecha_comprobante => current_date,
             p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente', p_items => v_libre, p_iva_alicuota => 10.5);
    INSERT INTO t45 VALUES (10, 'alícuota 10,5 rechazada', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t45 VALUES (10, 'alícuota 10,5 rechazada', SQLERRM LIKE 'Alícuota de IVA inválida%', SQLERRM);
  END;

  -- 11. Edición sin pagos: el cupón del caso 9 pasa a exento (lo que hará la UI al recargar)
  PERFORM editar_factura_compra(p_factura_id => v_f, p_tipo_comprobante => 'cupon', p_iva_alicuota => 0);
  SELECT * INTO v_fc FROM facturas_compra WHERE id = v_f;
  INSERT INTO t45 VALUES (11, 'edición sin pagos: 21 → exento recalcula a 1000',
    v_fc.iva_alicuota = 0 AND v_fc.iva = 0 AND v_fc.total = 1000
      AND (SELECT saldo_pendiente FROM facturas_compra_saldo WHERE id = v_f) = 1000,
    format('iva %s total %s', v_fc.iva, v_fc.total));

  -- 12. Edición de solo el tipo (app vieja, sin p_iva_alicuota): conserva la alícuota → total igual
  PERFORM editar_factura_compra(p_factura_id => v_f, p_tipo_comprobante => 'remito');
  SELECT * INTO v_fc FROM facturas_compra WHERE id = v_f;
  INSERT INTO t45 VALUES (12, 'cambio de tipo sin alícuota: conserva exento',
    v_fc.tipo_comprobante = 'remito' AND v_fc.iva_alicuota = 0 AND v_fc.total = 1000,
    format('tipo %s total %s', v_fc.tipo_comprobante, v_fc.total));

  -- 13-15. Edición con un pago aplicado: tipo y alícuota bloqueados, el resto sí
  PERFORM registrar_pago_proveedor_v2(p_proveedor_id => v_prov, p_monto => 100, p_forma_pago => 'efectivo',
           p_factura_ids => ARRAY[v_f], p_nota_credito_ids => NULL, p_origen => 'general');
  BEGIN
    PERFORM editar_factura_compra(p_factura_id => v_f, p_iva_alicuota => 21);
    INSERT INTO t45 VALUES (13, 'con pago: cambiar alícuota bloqueado', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t45 VALUES (13, 'con pago: cambiar alícuota bloqueado', SQLERRM LIKE 'Este comprobante ya tiene pagos%', SQLERRM);
  END;
  BEGIN
    PERFORM editar_factura_compra(p_factura_id => v_f, p_tipo_comprobante => 'factura');
    INSERT INTO t45 VALUES (14, 'con pago: cambiar tipo bloqueado', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t45 VALUES (14, 'con pago: cambiar tipo bloqueado', SQLERRM LIKE 'Este comprobante ya tiene pagos%', SQLERRM);
  END;
  PERFORM editar_factura_compra(p_factura_id => v_f, p_tipo_comprobante => 'remito', p_iva_alicuota => 0,
           p_numero_comprobante => 'T45-9B');
  SELECT * INTO v_fc FROM facturas_compra WHERE id = v_f;
  INSERT INTO t45 VALUES (15, 'con pago: mismo tipo/alícuota + otro número pasa',
    v_fc.numero_comprobante = 'T45-9B' AND v_fc.total = 1000
      AND (SELECT saldo_pendiente FROM facturas_compra_saldo WHERE id = v_f) = 900,
    format('número %s saldo %s', v_fc.numero_comprobante, (SELECT saldo_pendiente FROM facturas_compra_saldo WHERE id = v_f)));

  -- 16. Saldo final del proveedor: 1-5 (3420) + 7 (2178) + 8 (0 + 0) + 9 editado (1000) − pago 100 = 6498
  INSERT INTO t45 SELECT 16, 'saldo proveedor final: +6498',
    saldo_actual - v_saldo0 = 6498, format('delta %s', saldo_actual - v_saldo0)
  FROM proveedores_saldo WHERE id = v_prov;
END
$test$;

SELECT * FROM t45 ORDER BY orden;

ROLLBACK;
