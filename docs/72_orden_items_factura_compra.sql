-- 72 — Orden de los ítems de los comprobantes de compra
--
-- Estado: ver el bloque "APLICADO" al final del encabezado (se completa al aplicar).
--
-- Correr desde la raíz del repo, después de 71. La PARTE A es re-corrible (IF NOT EXISTS + CREATE OR
-- REPLACE; el relleno solo toca filas con orden NULL). La PARTE B solo lee. La PARTE C es un test
-- (BEGIN … ROLLBACK): se puede correr en producción.
--
-- Pedido de Alicia (2026-11-11): los ítems se cargan en el orden del papel, pero al abrir el detalle
-- aparecen en otro orden.
--
-- Causa: facturas_compra_items no guardaba la posición del ítem. Su id es un UUID al azar
-- (gen_random_uuid) y el detalle (Gestión y Local) ordenaba por id → orden aleatorio. Copiar factura no
-- ordenaba por nada (orden físico: casi siempre el de carga, pero un UPDATE del ítem lo manda al final).
--
-- Qué hace:
--   1. facturas_compra_items.orden INTEGER: posición del ítem en el comprobante (1, 2, 3…), única por
--      factura.
--   2. Relleno de lo existente: el orden físico de la tabla (ctid), que es el de inserción salvo para
--      ítems modificados después (vincular a un producto, correcciones): esos quedan al final. Al
--      2026-11-11 eran 2 facturas de 45 (ver PARTE B, "facturas_con_items_modificados").
--   3. orden pasa a NOT NULL, sin default: si una función futura inserta ítems sin orden, falla en vez
--      de dejarlos desordenados.
--   4. cargar_factura_compra (única función que inserta ítems): misma firma, el loop de ítems recorre
--      p_items WITH ORDINALITY y guarda la posición. Lo demás es copia textual de la versión vigente
--      (docs/71). cargar_factura_compra_contado la llama: no cambia.
--
-- Las apps viejas siguen andando (no mandan orden; lo pone la función). Hasta actualizarlas, el detalle
-- sigue mostrando los ítems por id. Orden de despliegue: esta migración ANTES de las apps (las nuevas
-- piden .order('orden') y fallan si la columna no existe).
--
-- PROBADO: 2026-11-11 sobre la restauración local de virikyna_2026-11-11_pre-docs72-test, dos veces
-- seguidas (la segunda: UPDATE 0). PARTE B OK: 620 ítems / 45 facturas con orden 1..n, igual al orden
-- físico previo (0 diferencias). PARTE C: OK T1–T4. anon_sin_execute da f en la restauración porque no
-- trae los GRANT (también para _contado, que no se toca); en producción las dos funciones tienen ACL sin
-- anon y CREATE OR REPLACE la conserva.
-- APLICADO: 2026-11-11 en producción (backup previo virikyna_2026-11-11_pre-docs72-aplicar; antes se
-- verificó que cargar_factura_compra seguía idéntica a la copiada). PARTE B: todo OK (45 facturas con
-- orden 1..n, anon sin EXECUTE). PARTE C: OK T1–T4 (ROLLBACK, sin restos). FAYDI 0011-33182 y ANKAH
-- 0007-18720 quedan con los ítems modificados al final (aceptado por la dueña).

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios
-- ════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 1. Columna ─────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE facturas_compra_items ADD COLUMN IF NOT EXISTS orden INTEGER;

-- ── 2. Relleno (orden físico = orden de inserción) ─────────────────────────────────────────────────
-- Los ítems de una factura con orden ya puesto conservan el suyo; los que falten van después.
UPDATE facturas_compra_items i
SET orden = x.rn
FROM (
  SELECT n.id,
         COALESCE((SELECT max(o.orden) FROM facturas_compra_items o
                   WHERE o.factura_compra_id = n.factura_compra_id AND o.orden IS NOT NULL), 0)
         + row_number() OVER (PARTITION BY n.factura_compra_id ORDER BY n.ctid) AS rn
  FROM facturas_compra_items n
  WHERE n.orden IS NULL
) x
WHERE i.id = x.id AND i.orden IS NULL;

-- ── 3. Restricciones ───────────────────────────────────────────────────────────────────────────────
ALTER TABLE facturas_compra_items ALTER COLUMN orden SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'facturas_compra_items_orden_unico') THEN
    ALTER TABLE facturas_compra_items ADD CONSTRAINT facturas_compra_items_orden_unico
      UNIQUE (factura_compra_id, orden);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'facturas_compra_items_orden_positivo') THEN
    ALTER TABLE facturas_compra_items ADD CONSTRAINT facturas_compra_items_orden_positivo
      CHECK (orden > 0);
  END IF;
END $$;

COMMENT ON COLUMN facturas_compra_items.orden IS 'docs/72: posición del ítem en el comprobante (1, 2, 3…), en el orden en que se cargó. Única por factura. Las pantallas ordenan por esta columna.';

-- ── 4. cargar_factura_compra: guarda la posición de cada ítem ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.cargar_factura_compra(p_proveedor_id uuid, p_tipo_comprobante tipo_comprobante_compra, p_letra letra_comprobante_compra, p_punto_venta text, p_numero_comprobante text, p_fecha_comprobante date, p_fecha_fiscal date, p_forma_pago forma_pago_compra, p_items jsonb, p_copiada_de_id uuid DEFAULT NULL::uuid, p_iva_alicuota numeric DEFAULT 21, p_tipo_compra text DEFAULT 'articulos'::text, p_borrador_id uuid DEFAULT NULL::uuid, p_devuelve_mercaderia boolean DEFAULT false, p_ajuste_redondeo numeric DEFAULT 0)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_factura_id UUID;
  v_item JSONB;
  v_orden INTEGER;           -- docs/72
  v_precio_total_sin_iva NUMERIC;
  v_total_sin_iva NUMERIC := 0;
  v_iva NUMERIC;
  v_total NUMERIC;
  v_ajuste NUMERIC := ROUND(COALESCE(p_ajuste_redondeo, 0), 2);  -- docs/71
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

  -- docs/71 (D5): suma de las líneas YA redondeadas, igual que la pantalla y que precio_total_sin_iva.
  SELECT COALESCE(SUM(ROUND((i->>'cantidad')::NUMERIC * (i->>'precio_unitario_sin_iva')::NUMERIC
           * (1 - COALESCE((i->>'descuento_porcentaje')::NUMERIC,0)/100.0), 2)), 0)
  INTO v_total_sin_iva
  FROM jsonb_array_elements(p_items) AS i;

  v_iva := ROUND(v_total_sin_iva * p_iva_alicuota / 100, 2);  -- docs/45 (antes: × 0.21 fijo)
  v_total := v_total_sin_iva + v_iva + v_ajuste;               -- docs/71: + ajuste, fuera del IVA

  IF v_total < 0 THEN
    RAISE EXCEPTION 'El total del comprobante no puede quedar negativo: el ajuste por redondeo (%) es mayor que el total (%)',
      formato_pesos(v_ajuste), formato_pesos(v_total_sin_iva + v_iva);
  END IF;

  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, letra, punto_venta, numero_comprobante,
         fecha_comprobante, fecha_fiscal, forma_pago, total_sin_iva, iva, total, usuario_id, copiada_de_id,
         iva_alicuota,  -- docs/45
         tipo_compra,   -- docs/53
         devuelve_mercaderia,  -- docs/55
         ajuste_redondeo)      -- docs/71
  VALUES (p_proveedor_id, p_tipo_comprobante, p_letra, p_punto_venta, p_numero_comprobante,
         p_fecha_comprobante, p_fecha_fiscal, p_forma_pago, v_total_sin_iva, v_iva, v_total, auth.uid(), p_copiada_de_id,
         p_iva_alicuota,
         p_tipo_compra,
         v_devuelve,
         v_ajuste)
  RETURNING id INTO v_factura_id;

  -- Ítems y stock, línea por línea (igual que docs/13). docs/72: con su posición en p_items.
  FOR v_item, v_orden IN SELECT t.i, t.ord FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(i, ord)
  LOOP
    v_precio_total_sin_iva := ROUND((v_item->>'cantidad')::NUMERIC * (v_item->>'precio_unitario_sin_iva')::NUMERIC
                              * (1 - COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0)/100.0), 2);

    INSERT INTO facturas_compra_items (factura_compra_id, producto_id, descripcion, cantidad,
           precio_unitario_sin_iva, descuento_porcentaje, precio_total_sin_iva, ubicacion,
           orden)  -- docs/72
    VALUES (v_factura_id, NULLIF(v_item->>'producto_id','')::UUID, v_item->>'descripcion',
           (v_item->>'cantidad')::NUMERIC, (v_item->>'precio_unitario_sin_iva')::NUMERIC,
           COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0), v_precio_total_sin_iva,
           COALESCE((v_item->>'ubicacion')::ubicacion_stock, 'local'),
           v_orden);

    v_producto_id := NULLIF(v_item->>'producto_id','')::UUID;

    -- docs/55: una NC no suma stock nunca (antes sumaba como una compra). Con devolución de
    -- mercadería, resta lo devuelto (ajuste con referencia a la NC, igual que las devoluciones de
    -- venta de docs/24: el Historial no lo ofrece revertir suelto, se revierte anulando la NC).
    IF v_producto_id IS NOT NULL AND NOT v_nc THEN
      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, referencia_id, usuario_id, origen)  -- docs/70: origen
      VALUES (v_producto_id, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'),
             'compra', (v_item->>'cantidad')::NUMERIC, v_factura_id, auth.uid(), 'compra');

      INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
      VALUES (v_producto_id, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'), (v_item->>'cantidad')::NUMERIC)
      ON CONFLICT (producto_id, ubicacion)
      DO UPDATE SET cantidad = stock_ubicaciones.cantidad + (v_item->>'cantidad')::NUMERIC;
    ELSIF v_producto_id IS NOT NULL AND v_devuelve THEN
      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id, origen)  -- docs/70: origen
      VALUES (v_producto_id, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'), 'ajuste',
             -1 * (v_item->>'cantidad')::NUMERIC,
             'Devolucion a proveedor: NC ' || COALESCE(NULLIF(btrim(p_numero_comprobante), ''), 'sin numero'),
             v_factura_id, auth.uid(), 'devolucion_proveedor');

      UPDATE stock_ubicaciones SET cantidad = cantidad - (v_item->>'cantidad')::NUMERIC
      WHERE producto_id = v_producto_id AND ubicacion = COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local');
    END IF;
  END LOOP;

  PERFORM set_config('virikyna.origen_precio', 'factura', true);  -- docs/67
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
  PERFORM set_config('virikyna.origen_precio', '', true);  -- docs/67

  RETURN v_factura_id;
END;
$function$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (solo lectura)
-- ════════════════════════════════════════════════════════════════════════════════════════════════
SELECT 'items_sin_orden' AS control, count(*)::text AS valor, count(*) = 0 AS ok
FROM facturas_compra_items WHERE orden IS NULL
UNION ALL
-- Cada factura tiene orden 1..n sin huecos.
SELECT 'facturas_con_orden_1_a_n', count(*)::text, bool_and(ok)
FROM (SELECT factura_compra_id, min(orden) = 1 AND max(orden) = count(*) AS ok
      FROM facturas_compra_items GROUP BY 1) x
UNION ALL
SELECT 'columna_not_null', NULL, (SELECT a.attnotnull FROM pg_attribute a
  WHERE a.attrelid = 'facturas_compra_items'::regclass AND a.attname = 'orden')
UNION ALL
SELECT 'una_sola_firma_cargar_factura_compra', count(*)::text, count(*) = 1
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
WHERE p.proname = 'cargar_factura_compra'
UNION ALL
SELECT 'cargar_factura_compra_guarda_orden', NULL, bool_and(p.prosrc LIKE '%WITH ORDINALITY AS t(i, ord)%v_orden);%')
FROM pg_proc p WHERE p.proname = 'cargar_factura_compra'
UNION ALL
SELECT 'anon_sin_execute', NULL, bool_and(NOT has_function_privilege('anon', p.oid, 'EXECUTE'))
FROM pg_proc p WHERE p.proname IN ('cargar_factura_compra', 'cargar_factura_compra_contado')
UNION ALL
SELECT 'authenticated_con_execute', NULL, bool_and(has_function_privilege('authenticated', p.oid, 'EXECUTE'))
FROM pg_proc p WHERE p.proname IN ('cargar_factura_compra', 'cargar_factura_compra_contado')
ORDER BY 1;

-- Facturas con ítems modificados después de la carga (xmin distinto): su orden rellenado puede no
-- ser el del papel (el ítem modificado quedó al final). Solo informativo; sirve en producción, no en
-- una restauración (ahí todas las filas tienen el mismo xmin).
SELECT 'facturas_con_items_modificados' AS control, fc.id, pr.razon_social, fc.tipo_comprobante, fc.letra,
       fc.punto_venta, fc.numero_comprobante, fc.fecha_comprobante, count(*) AS items
FROM facturas_compra fc
JOIN proveedores pr ON pr.id = fc.proveedor_id
JOIN facturas_compra_items i ON i.factura_compra_id = fc.id
GROUP BY fc.id, pr.razon_social
HAVING count(DISTINCT i.xmin::text) > 1
ORDER BY fc.fecha_comprobante;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — tests (BEGIN … ROLLBACK). Corre como Alicia (admin) y como "Cajero de prueba".
-- Termina SIEMPRE con RAISE EXCEPTION 'RESULTADO: …' (la transacción aborta y no queda nada).
-- ════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
  c_alicia CONSTANT uuid := '696bd7fb-aa27-4051-b8cd-d611ee90d1ae';
  c_cajero CONSTANT uuid := 'c982462a-526a-4ee7-aade-4488b74966b3';
  v_prov uuid;
  v_f1 uuid; v_f2 uuid;
  v_orden text;
  v_ok text[] := '{}';
  v_hoy date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
BEGIN
  SET LOCAL virikyna.suppress_audit = 'false';
  INSERT INTO proveedores (razon_social) VALUES ('ZZ TEST DOCS72') RETURNING id INTO v_prov;

  -- T1. Cajero: 5 ítems en un orden que no es alfabético → se guardan 1..5 en el orden de carga.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_cajero, 'role', 'authenticated')::text, true);
  v_f1 := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
    p_punto_venta => '1', p_numero_comprobante => 'T1', p_fecha_comprobante => v_hoy, p_fecha_fiscal => NULL,
    p_forma_pago => 'cuenta_corriente',
    p_items => '[{"producto_id": null, "descripcion": "EEE", "cantidad": 1, "precio_unitario_sin_iva": 5},
                 {"producto_id": null, "descripcion": "BBB", "cantidad": 1, "precio_unitario_sin_iva": 2},
                 {"producto_id": null, "descripcion": "DDD", "cantidad": 1, "precio_unitario_sin_iva": 4},
                 {"producto_id": null, "descripcion": "AAA", "cantidad": 1, "precio_unitario_sin_iva": 1},
                 {"producto_id": null, "descripcion": "CCC", "cantidad": 1, "precio_unitario_sin_iva": 3}]',
    p_iva_alicuota => 21, p_tipo_compra => 'servicios');
  SELECT string_agg(orden || ':' || descripcion, ',' ORDER BY orden) INTO v_orden
  FROM facturas_compra_items WHERE factura_compra_id = v_f1;
  IF v_orden IS DISTINCT FROM '1:EEE,2:BBB,3:DDD,4:AAA,5:CCC' THEN
    RAISE EXCEPTION 'T1: %', v_orden;
  END IF;
  v_ok := array_append(v_ok, 'T1');

  -- T2. Alicia: ítems repetidos (misma descripción) conservan cada uno su posición; total sin cambios.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_alicia, 'role', 'authenticated')::text, true);
  v_f2 := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
    p_punto_venta => '1', p_numero_comprobante => 'T2', p_fecha_comprobante => v_hoy, p_fecha_fiscal => NULL,
    p_forma_pago => 'cuenta_corriente',
    p_items => '[{"producto_id": null, "descripcion": "XX", "cantidad": 1, "precio_unitario_sin_iva": 10},
                 {"producto_id": null, "descripcion": "YY", "cantidad": 1, "precio_unitario_sin_iva": 20},
                 {"producto_id": null, "descripcion": "XX", "cantidad": 1, "precio_unitario_sin_iva": 30}]',
    p_iva_alicuota => 0, p_tipo_compra => 'servicios');
  SELECT string_agg(orden || ':' || descripcion || ':' || trim_scale(precio_unitario_sin_iva), ',' ORDER BY orden) INTO v_orden
  FROM facturas_compra_items WHERE factura_compra_id = v_f2;
  IF v_orden IS DISTINCT FROM '1:XX:10,2:YY:20,3:XX:30'
     OR (SELECT total FROM facturas_compra WHERE id = v_f2) <> 60 THEN
    RAISE EXCEPTION 'T2: %', v_orden;
  END IF;
  v_ok := array_append(v_ok, 'T2');

  -- T3. Un UPDATE del ítem (como vincular) no cambia su orden.
  UPDATE facturas_compra_items SET descripcion = 'AAA BIS' WHERE factura_compra_id = v_f1 AND orden = 4;
  SELECT string_agg(orden || ':' || descripcion, ',' ORDER BY orden) INTO v_orden
  FROM facturas_compra_items WHERE factura_compra_id = v_f1;
  IF v_orden IS DISTINCT FROM '1:EEE,2:BBB,3:DDD,4:AAA BIS,5:CCC' THEN
    RAISE EXCEPTION 'T3: %', v_orden;
  END IF;
  v_ok := array_append(v_ok, 'T3');

  -- T4. Un insert sin orden falla (NOT NULL), y uno con orden repetido también (UNIQUE).
  BEGIN
    INSERT INTO facturas_compra_items (factura_compra_id, descripcion, cantidad, precio_unitario_sin_iva, precio_total_sin_iva)
    VALUES (v_f1, 'SIN ORDEN', 1, 1, 1);
    RAISE EXCEPTION 'T4: aceptó un ítem sin orden';
  EXCEPTION WHEN not_null_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO facturas_compra_items (factura_compra_id, descripcion, cantidad, precio_unitario_sin_iva, precio_total_sin_iva, orden)
    VALUES (v_f1, 'REPETIDO', 1, 1, 1, 2);
    RAISE EXCEPTION 'T4: aceptó un orden repetido';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  v_ok := array_append(v_ok, 'T4');

  RAISE EXCEPTION 'RESULTADO: OK %', array_to_string(v_ok, ' ');
END $$;
ROLLBACK;
