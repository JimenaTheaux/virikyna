-- 36 — Limpieza de arranque: vaciar los datos de prueba antes de la puesta en marcha
--
-- Orden completo en docs/04_modulos_y_funciones.md, "Puesta en marcha". Se corre a mano en el SQL
-- Editor de Supabase (proyecto ccpinvtleqlsukcqnili), DESPUÉS DEL BACKUP, un bloque por vez
-- (seleccionar el bloque y Run). Con las tres apps cerradas: el TRUNCATE toma un lock exclusivo
-- sobre cada tabla.
--
-- Se CONSERVA: perfiles (y auth.users), cuentas, cuenta_forma_pago, arca_wsaa_tokens, configuracion.
-- Se VACÍA todo lo demás del schema public — también auditoria, carga_inicial_*, productos,
-- proveedores, clientes y la Factura C de producción (exportarla antes: bloque 1A).
--
-- Relevado (solo lectura de catálogos) el 2026-10-08:
--   - 31 tablas en public; se vacían 26 (lista en el bloque 3).
--   - Ninguna tabla conservada tiene FK hacia una que se vacía (configuracion → perfiles,
--     cuenta_forma_pago → cuentas, perfiles → auth.users). Las FKs de tablas vaciadas hacia
--     conservadas (movimientos_cuenta → cuentas, *.usuario_id → perfiles) no frenan un TRUNCATE.
--     Ninguna tabla de otro schema apunta a public. No hay triggers ON TRUNCATE.
--   - Secuencias: ventas.numero y devoluciones.numero son IDENTITY (las reinicia RESTART IDENTITY);
--     codigo_interno_seq (generar_codigo_interno, docs/34) no tiene dueño: se reinicia aparte.
--   - Vistas (proveedores_saldo, clientes_saldo, cuentas_saldo, facturas_compra_saldo,
--     notas_internas_con_autor, perfiles_publico): todas LEFT JOIN + COALESCE o sobre tablas
--     que quedan; con tablas vacías devuelven 0 filas o saldo 0, no fallan.
--   - abrir_caja NO necesita un cierre previo: sin Cierre Z anterior toma monto esperado 0 y
--     cierre_z_previo_id null. Ver "Primer turno" en docs/04.
--   - El UPDATE de configuracion dispara trg_auditoria_configuracion: se corre con
--     virikyna.suppress_audit para que auditoria quede en 0.


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- BLOQUE 1 — EXPORTACIÓN PREVIA (solo lectura). Dos consultas: correr 1A y 1B por separado.
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- 1A. Factura C de producción (punto de venta 0002) con su venta, cliente, ítems, pagos y
--     devoluciones, como JSON. Copiar el resultado y guardarlo FUERA del sistema (el comprobante
--     sigue existiendo en ARCA; esto es el respaldo de lo que había en Virikyna).
SELECT jsonb_pretty(jsonb_build_object(
  'exportado_at', now(),
  'proyecto', 'ccpinvtleqlsukcqnili',
  'facturas', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'factura_c', to_jsonb(f),
      'emitida_por', (SELECT nombre FROM perfiles WHERE id = f.usuario_id),
      'venta', to_jsonb(v),
      'cliente', (SELECT to_jsonb(c) FROM clientes c WHERE c.id = v.cliente_id),
      'items', (SELECT jsonb_agg(to_jsonb(i) || jsonb_build_object(
                         'producto_nombre', p.nombre, 'producto_marca', p.marca, 'producto_codigo', p.codigo_barras))
                FROM venta_items i LEFT JOIN productos p ON p.id = i.producto_id
                WHERE i.venta_id = v.id),
      'pagos', (SELECT jsonb_agg(to_jsonb(vp)) FROM venta_pagos vp WHERE vp.venta_id = v.id),
      'devoluciones', (SELECT jsonb_agg(to_jsonb(d)) FROM devoluciones d WHERE d.venta_id = v.id)
    ) ORDER BY f.created_at)
    FROM facturas_c f JOIN ventas v ON v.id = f.venta_id
    WHERE ltrim(f.punto_venta, '0') = '2'
  ), '[]'::jsonb)
)) AS factura_c_produccion;

-- 1B. Conteo de filas por tabla (antes).
SELECT c.relname AS tabla,
       (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM public.%I', c.relname), false, true, '')))[1]::text::bigint AS filas,
       c.relname = ANY (ARRAY['perfiles', 'cuentas', 'cuenta_forma_pago', 'arca_wsaa_tokens', 'configuracion']) AS se_conserva
FROM pg_class c
WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p')
ORDER BY se_conserva DESC, tabla;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- BLOQUE 2 — SIMULACIÓN. Corre la misma limpieza que el bloque 3 y la deshace.
-- El SQL Editor solo muestra el resultado de la última sentencia, así que el resultado sale como
-- un ERROR a propósito: "SIMULACION OK — se deshizo todo: {conteo por tabla}". Ese "error" es el
-- resultado esperado; cualquier OTRO error es un problema real y hay que frenar.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $$
DECLARE
  v_conservar CONSTANT TEXT[] := ARRAY['perfiles', 'cuentas', 'cuenta_forma_pago', 'arca_wsaa_tokens', 'configuracion'];
  v_esperadas CONSTANT TEXT[] := ARRAY[
    'aperturas_caja', 'auditoria', 'carga_inicial_items', 'carga_inicial_operaciones', 'cierres_caja', 'clientes',
    'devolucion_items', 'devolucion_pagos', 'devoluciones', 'egresos', 'facturas_c', 'facturas_compra',
    'facturas_compra_items', 'movimientos_cuenta', 'movimientos_stock', 'notas_internas', 'pagos_cliente',
    'pagos_proveedor', 'pagos_proveedor_aplicaciones', 'productos', 'proveedores', 'retiros_caja',
    'stock_ubicaciones', 'venta_items', 'venta_pagos', 'ventas'];
  v_tablas TEXT[];
  v_cuentas_antes TEXT;
  v_cfp_antes TEXT;
  v_conteo JSONB;
BEGIN
  SELECT array_agg(relname::TEXT ORDER BY relname::TEXT) INTO v_tablas
  FROM pg_class
  WHERE relnamespace = 'public'::regnamespace AND relkind IN ('r', 'p') AND NOT relname::TEXT = ANY (v_conservar);
  IF v_tablas IS DISTINCT FROM (SELECT array_agg(t ORDER BY t) FROM unnest(v_esperadas) t) THEN
    RAISE EXCEPTION 'La lista de tablas a vaciar no es la revisada. Hoy da: %', v_tablas;
  END IF;

  SELECT md5(COALESCE(string_agg(c::TEXT, '|' ORDER BY c.id), '')) INTO v_cuentas_antes FROM cuentas c;
  SELECT md5(COALESCE(string_agg(f::TEXT, '|' ORDER BY f.forma_pago::TEXT), '')) INTO v_cfp_antes FROM cuenta_forma_pago f;

  EXECUTE 'TRUNCATE TABLE ' || (SELECT string_agg(format('public.%I', t), ', ') FROM unnest(v_tablas) t) || ' RESTART IDENTITY';
  ALTER SEQUENCE public.codigo_interno_seq RESTART WITH 1;

  PERFORM set_config('virikyna.suppress_audit', 'true', true);
  UPDATE configuracion
  SET carga_inicial_abierta = false, abierta_at = NULL, abierta_por = NULL, cerrada_at = NULL, cerrada_por = NULL,
      datos_reset_at = now(), updated_at = now()
  WHERE fila_unica;
  PERFORM set_config('virikyna.suppress_audit', 'false', true);

  IF (SELECT md5(COALESCE(string_agg(c::TEXT, '|' ORDER BY c.id), '')) FROM cuentas c) IS DISTINCT FROM v_cuentas_antes THEN
    RAISE EXCEPTION 'cuentas cambió: se frena';
  END IF;
  IF (SELECT md5(COALESCE(string_agg(f::TEXT, '|' ORDER BY f.forma_pago::TEXT), '')) FROM cuenta_forma_pago f) IS DISTINCT FROM v_cfp_antes THEN
    RAISE EXCEPTION 'cuenta_forma_pago cambió: se frena';
  END IF;

  SELECT jsonb_object_agg(c.relname,
           (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM public.%I', c.relname), false, true, '')))[1]::text::bigint
           ORDER BY c.relname)
  INTO v_conteo
  FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p');

  RAISE EXCEPTION 'SIMULACION OK — se deshizo todo. Se vaciarían % tablas. Conteo después de limpiar: %',
    array_length(v_tablas, 1), v_conteo;
END;
$$;

ROLLBACK;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- BLOQUE 3 — LIMPIEZA REAL. Una sola transacción: si algo falla, no se aplica nada.
--
-- Tablas que se vacían (26), revisadas contra la base el 2026-10-08 — si hoy la lista dinámica no
-- coincide exactamente (se agregó o se borró una tabla), el bloque frena sin tocar nada:
--   aperturas_caja, auditoria, carga_inicial_items, carga_inicial_operaciones, cierres_caja,
--   clientes, devolucion_items, devolucion_pagos, devoluciones, egresos, facturas_c,
--   facturas_compra, facturas_compra_items, movimientos_cuenta, movimientos_stock,
--   notas_internas, pagos_cliente, pagos_proveedor, pagos_proveedor_aplicaciones, productos,
--   proveedores, retiros_caja, stock_ubicaciones, venta_items, venta_pagos, ventas
-- Se conservan (5): arca_wsaa_tokens, configuracion, cuenta_forma_pago, cuentas, perfiles.
--
-- Un solo TRUNCATE … RESTART IDENTITY, SIN CASCADE: si alguna tabla conservada apuntara a una de
-- la lista, el TRUNCATE falla y la transacción entera se deshace.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $$
DECLARE
  v_conservar CONSTANT TEXT[] := ARRAY['perfiles', 'cuentas', 'cuenta_forma_pago', 'arca_wsaa_tokens', 'configuracion'];
  v_esperadas CONSTANT TEXT[] := ARRAY[
    'aperturas_caja', 'auditoria', 'carga_inicial_items', 'carga_inicial_operaciones', 'cierres_caja', 'clientes',
    'devolucion_items', 'devolucion_pagos', 'devoluciones', 'egresos', 'facturas_c', 'facturas_compra',
    'facturas_compra_items', 'movimientos_cuenta', 'movimientos_stock', 'notas_internas', 'pagos_cliente',
    'pagos_proveedor', 'pagos_proveedor_aplicaciones', 'productos', 'proveedores', 'retiros_caja',
    'stock_ubicaciones', 'venta_items', 'venta_pagos', 'ventas'];
  v_tablas TEXT[];
  v_cuentas_antes TEXT;
  v_cfp_antes TEXT;
BEGIN
  -- Lista dinámica: todas las tablas de public menos las conservadas, comparada con la revisada.
  SELECT array_agg(relname::TEXT ORDER BY relname::TEXT) INTO v_tablas
  FROM pg_class
  WHERE relnamespace = 'public'::regnamespace AND relkind IN ('r', 'p') AND NOT relname::TEXT = ANY (v_conservar);
  IF v_tablas IS DISTINCT FROM (SELECT array_agg(t ORDER BY t) FROM unnest(v_esperadas) t) THEN
    RAISE EXCEPTION 'La lista de tablas a vaciar no es la revisada. Hoy da: %', v_tablas;
  END IF;

  -- Foto de las tablas conservadas que se verifican al final.
  SELECT md5(COALESCE(string_agg(c::TEXT, '|' ORDER BY c.id), '')) INTO v_cuentas_antes FROM cuentas c;
  SELECT md5(COALESCE(string_agg(f::TEXT, '|' ORDER BY f.forma_pago::TEXT), '')) INTO v_cfp_antes FROM cuenta_forma_pago f;

  -- Vaciado + reinicio de ventas.numero y devoluciones.numero (IDENTITY).
  EXECUTE 'TRUNCATE TABLE ' || (SELECT string_agg(format('public.%I', t), ', ') FROM unnest(v_tablas) t) || ' RESTART IDENTITY';

  -- Códigos internos EAN-13 (generar_codigo_interno, docs/34): vuelven a 2000000000015.
  ALTER SEQUENCE public.codigo_interno_seq RESTART WITH 1;

  -- configuracion: carga cerrada, sin apertura/cierre, y marca de vaciado (las pantallas descartan
  -- lo que tenían guardado en el navegador). Sin fila de auditoría: auditoria queda en 0.
  PERFORM set_config('virikyna.suppress_audit', 'true', true);
  UPDATE configuracion
  SET carga_inicial_abierta = false, abierta_at = NULL, abierta_por = NULL, cerrada_at = NULL, cerrada_por = NULL,
      datos_reset_at = now(), updated_at = now()
  WHERE fila_unica;
  PERFORM set_config('virikyna.suppress_audit', 'false', true);

  -- cuentas y cuenta_forma_pago intactas.
  IF (SELECT md5(COALESCE(string_agg(c::TEXT, '|' ORDER BY c.id), '')) FROM cuentas c) IS DISTINCT FROM v_cuentas_antes THEN
    RAISE EXCEPTION 'cuentas cambió: se frena';
  END IF;
  IF (SELECT md5(COALESCE(string_agg(f::TEXT, '|' ORDER BY f.forma_pago::TEXT), '')) FROM cuenta_forma_pago f) IS DISTINCT FROM v_cfp_antes THEN
    RAISE EXCEPTION 'cuenta_forma_pago cambió: se frena';
  END IF;

  RAISE NOTICE 'Limpieza aplicada: % tablas vaciadas (%)', array_length(v_tablas, 1), array_to_string(v_tablas, ', ');
END;
$$;

COMMIT;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- BLOQUE 4 — VERIFICACIÓN (solo lectura). Una sola consulta: todas las filas con ok = true.
-- ════════════════════════════════════════════════════════════════════════════════════════════
WITH conteo AS (
  SELECT c.relname::TEXT AS tabla,
         (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM public.%I', c.relname), false, true, '')))[1]::text::bigint AS filas,
         c.relname = ANY (ARRAY['perfiles', 'cuentas', 'cuenta_forma_pago', 'arca_wsaa_tokens', 'configuracion']) AS se_conserva
  FROM pg_class c
  WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p')
),
proximo AS (
  -- Próximo valor sin consumir la secuencia: si nunca se llamó desde el reinicio, es el inicial.
  SELECT sequencename::TEXT AS secuencia,
         CASE WHEN last_value IS NULL THEN start_value ELSE last_value + increment_by END AS siguiente
  FROM pg_sequences
  WHERE schemaname = 'public' AND sequencename IN ('ventas_numero_seq', 'devoluciones_numero_seq', 'codigo_interno_seq')
)
SELECT 1 AS orden, 'filas: ' || tabla AS chequeo,
       filas::TEXT || CASE WHEN se_conserva THEN ' (se conserva)' ELSE '' END AS detalle,
       se_conserva OR filas = 0 AS ok
FROM conteo
UNION ALL
SELECT 2, 'próximo número: ' || secuencia, siguiente::TEXT, siguiente = 1 FROM proximo
UNION ALL
SELECT 3, 'saldo cuenta: ' || nombre, saldo_actual::TEXT, saldo_actual = 0 FROM cuentas_saldo
UNION ALL
SELECT 4, 'configuracion',
       format('abierta=%s, datos_reset_at=%s', carga_inicial_abierta, datos_reset_at),
       NOT carga_inicial_abierta AND datos_reset_at IS NOT NULL AND abierta_at IS NULL AND cerrada_at IS NULL
FROM configuracion
UNION ALL
SELECT 5, 'usuario activo: ' || p.nombre, p.rol || ' · ' || COALESCE(u.email, '(sin email)'), true
FROM perfiles p LEFT JOIN auth.users u ON u.id = p.id
WHERE p.activo
ORDER BY 1, 2;
