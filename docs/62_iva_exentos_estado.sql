-- 62 — IVA de productos como estado: los exentos quedan tildados
--
-- Correr desde la raíz del repo con `supabase db query --linked -f docs/62_iva_exentos_estado.sql`
-- (o en el SQL Editor del proyecto ccpinvtleqlsukcqnili), después de 47. La PARTE A va una sola vez;
-- la PARTE B (verificación) y la PARTE C (test, BEGIN … ROLLBACK) se pueden repetir.
--
-- Pedido de Alicia (2026-10-27): la pantalla "IVA" abría siempre vacía, así que no se veía qué
-- productos ya eran exentos ni había forma simple de deshacer un tilde equivocado. Ahora la casilla
-- es "Exento (sin IVA)", abre tildada en los que tienen iva_porcentaje = 0, y al aplicar se mandan
-- las dos listas: los que pasan a sin IVA y los que vuelven a llevar IVA.
--
-- Qué hace:
--   1. fijar_iva_productos(p_sin_iva uuid[], p_con_iva uuid[]) → integer: admin activo, SECURITY
--      DEFINER; pone 0 en p_sin_iva y 21 en p_con_iva en un solo UPDATE (no puede quedar a medias),
--      solo en los que cambian, y devuelve cuántos cambió. Cada fila queda en auditoria por el
--      trigger genérico (edición), igual que marcar_iva_productos.
--   2. marcar_iva_productos (docs/47) queda: la usa Virikyna Local v0.9.0 ya instalado.

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios (una sola vez)
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.fijar_iva_productos(p_sin_iva uuid[], p_con_iva uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sin uuid[] := COALESCE(p_sin_iva, '{}');
  v_con uuid[] := COALESCE(p_con_iva, '{}');
  v_count INTEGER;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede cambiar el IVA de los productos';
  END IF;
  IF cardinality(v_sin) = 0 AND cardinality(v_con) = 0 THEN
    RAISE EXCEPTION 'Elegí al menos un producto';
  END IF;
  IF v_sin && v_con THEN
    RAISE EXCEPTION 'Un producto no puede quedar con y sin IVA a la vez';
  END IF;

  -- Solo los que cambian (auditoría sin ediciones vacías; el WHERE también cumple con safeupdate).
  UPDATE productos
  SET iva_porcentaje = CASE WHEN id = ANY(v_sin) THEN 0 ELSE 21 END,
      updated_at = now()
  WHERE (id = ANY(v_sin) AND iva_porcentaje <> 0)
     OR (id = ANY(v_con) AND iva_porcentaje <> 21);

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.fijar_iva_productos(uuid[], uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fijar_iva_productos(uuid[], uuid[]) TO authenticated, service_role;

COMMENT ON FUNCTION public.fijar_iva_productos(uuid[], uuid[]) IS
  'IVA de productos como estado (docs/62): admin activo; pone 0 en p_sin_iva y 21 en p_con_iva (solo los que cambian) y devuelve cuántos cambió.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (solo lectura)
-- ════════════════════════════════════════════════════════════════════════════════════════════
SELECT 'rpc' AS chequeo, p.oid::regprocedure::text || ' ' || array_to_string(p.proacl, ',') AS valor
FROM pg_proc p WHERE p.proname IN ('fijar_iva_productos', 'marcar_iva_productos') AND p.pronamespace = 'public'::regnamespace
UNION ALL
SELECT 'iva por producto', string_agg(iva::text || ': ' || n, ', ')
FROM (SELECT iva_porcentaje AS iva, count(*) AS n FROM productos GROUP BY 1) x;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (no deja nada: BEGIN … ROLLBACK)
-- Productos de prueba creados acá. Resultado: una tabla, todo ok = true.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TEMP TABLE t62 (orden int, caso text, ok boolean, detalle text) ON COMMIT DROP;

DO $test$
DECLARE
  v_admin uuid := (SELECT id FROM perfiles WHERE activo AND rol = 'admin' ORDER BY id LIMIT 1);
  v_cajero uuid := (SELECT id FROM perfiles WHERE activo AND rol <> 'admin' ORDER BY id LIMIT 1);
  v_a uuid;  -- con IVA, costo 1000, márgenes 100/0: con IVA 2500, sin IVA 2000
  v_b uuid;  -- sin IVA, mismo costo
  v_c uuid;  -- sin IVA con precio manual
  v_p productos%ROWTYPE;
  v_n int;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  INSERT INTO productos (nombre, costo, margen_1, margen_2, iva_porcentaje, estado)
  VALUES ('TEST 62 A', 1000, 100, 0, 21, 'activo') RETURNING id INTO v_a;
  INSERT INTO productos (nombre, costo, margen_1, margen_2, iva_porcentaje, estado)
  VALUES ('TEST 62 B', 1000, 100, 0, 0, 'activo') RETURNING id INTO v_b;
  INSERT INTO productos (nombre, precio_manual, iva_porcentaje, estado)
  VALUES ('TEST 62 C', 777, 0, 'activo') RETURNING id INTO v_c;

  -- 1. Tilda A y destilda B a la vez: A → 0 (2000), B → 21 (2500)
  v_n := fijar_iva_productos(ARRAY[v_a], ARRAY[v_b]);
  INSERT INTO t62 SELECT 1, 'A pasa a sin IVA y B vuelve con IVA en una llamada',
    v_n = 2
      AND (SELECT iva_porcentaje = 0 AND precio_venta = 2000 FROM productos WHERE id = v_a)
      AND (SELECT iva_porcentaje = 21 AND precio_venta = 2500 FROM productos WHERE id = v_b),
    format('n %s', v_n);

  -- 2. Repetir lo mismo no cambia nada
  v_n := fijar_iva_productos(ARRAY[v_a], ARRAY[v_b]);
  INSERT INTO t62 VALUES (2, 'repetir: 0 cambios', v_n = 0, format('n %s', v_n));

  -- 3. Solo una lista (la otra NULL o vacía)
  v_n := fijar_iva_productos(NULL, ARRAY[v_a]);
  INSERT INTO t62 SELECT 3, 'solo con IVA (sin_iva NULL)', v_n = 1 AND iva_porcentaje = 21, format('n %s', v_n) FROM productos WHERE id = v_a;
  v_n := fijar_iva_productos(ARRAY[v_a], '{}');
  INSERT INTO t62 SELECT 4, 'solo sin IVA (con_iva vacía)', v_n = 1 AND iva_porcentaje = 0, format('n %s', v_n) FROM productos WHERE id = v_a;

  -- 5. Precio manual: el IVA cambia, el precio no
  v_n := fijar_iva_productos('{}', ARRAY[v_c]);
  SELECT * INTO v_p FROM productos WHERE id = v_c;
  INSERT INTO t62 VALUES (5, 'precio manual: iva 21, precio 777 igual', v_n = 1 AND v_p.iva_porcentaje = 21 AND v_p.precio_venta = 777,
    format('iva %s venta %s', v_p.iva_porcentaje, v_p.precio_venta));

  -- 6. Auditoría: una edición por cambio (1: 2, 3: 1, 4: 1, 5: 1)
  INSERT INTO t62 SELECT 6, 'auditoría: una edición por cambio', count(*) = 5, format('%s ediciones', count(*))
  FROM auditoria WHERE tabla_afectada = 'productos' AND accion = 'edicion' AND registro_id IN (v_a, v_b, v_c)
    AND created_at = now();

  -- 7. Las dos listas vacías
  BEGIN
    PERFORM fijar_iva_productos('{}', NULL);
    INSERT INTO t62 VALUES (7, 'listas vacías: rechazado', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t62 VALUES (7, 'listas vacías: rechazado', SQLERRM = 'Elegí al menos un producto', SQLERRM);
  END;

  -- 8. Mismo producto en las dos listas
  BEGIN
    PERFORM fijar_iva_productos(ARRAY[v_a], ARRAY[v_a, v_b]);
    INSERT INTO t62 VALUES (8, 'producto en las dos listas: rechazado', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t62 VALUES (8, 'producto en las dos listas: rechazado', SQLERRM LIKE 'Un producto no puede%', SQLERRM);
  END;

  -- 9. Cajero
  IF v_cajero IS NULL THEN
    INSERT INTO t62 VALUES (9, 'cajero: no hay perfil no admin activo para probar', false, NULL);
  ELSE
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_cajero, 'role', 'authenticated')::text, true);
    BEGIN
      PERFORM fijar_iva_productos(ARRAY[v_b], NULL);
      INSERT INTO t62 VALUES (9, 'cajero: rechazado', false, 'no dio error');
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO t62 VALUES (9, 'cajero: rechazado', SQLERRM LIKE 'Solo un administrador%', SQLERRM);
    END;
  END IF;
END
$test$;

SELECT * FROM t62 ORDER BY orden;

ROLLBACK;
