-- 64 — Alerta de stock solo para productos con mínimo definido
--
-- ✅ APLICADO en producción el 2026-10-27 (PARTE A), con backup previo virikyna_2026-10-27_pre-docs64-aplicar.
-- Antes se re-verificó que productos_stock_bajo seguía como en docs/42. PARTE B ok (invoker, sin
-- anon, filtra mínimo); alerta de 94 a 33 productos. PARTE C 7/7 antes de aplicar.
-- Correr desde la raíz del repo con
-- `supabase db query --linked -f docs/64_alerta_stock_con_minimo.sql` (o en el SQL Editor del
-- proyecto ccpinvtleqlsukcqnili). La PARTE A se puede re-correr (CREATE OR REPLACE); la PARTE B solo
-- lee y la PARTE C es un test (BEGIN … ROLLBACK, termina con RAISE EXCEPTION 'RESULTADO: …' a
-- propósito para que nada quede escrito).
--
-- Contexto (relevado contra la base real el 2026-10-27):
--   - productos.stock_minimo es NUMERIC NOT NULL DEFAULT 0. De 2317 activos, solo 34 tienen mínimo
--     > 0; los otros 2283 tienen 0 porque nadie lo cargó.
--   - productos_stock_bajo (docs/42) filtra stock_total <= stock_minimo: con mínimo 0, cualquier
--     producto en 0 o negativo cuenta como "stock bajo". Devolvía 94 = 61 sin stock + 33 bajo real.
--
-- Decisión (2026-10-27): mínimo 0 = "sin definir", sin migrar a NULL — los formularios de las apps
-- instaladas mandan `Number(x) || 0` y volverían a escribir 0 en cada edición.
--
-- Qué hace:
--   1. productos_stock_bajo: misma firma y mismo orden; solo cuentan productos con stock_minimo > 0.
--      Las apps ya instaladas (Local v0.9.0) lo toman sin actualizar.
--   2. RPC nueva resumen_stock_inventario(): contadores de los productos ACTIVOS para la card del
--      Dashboard y los chips de Inventario, con las mismas definiciones que la pantalla
--      (packages/shared/lib/estadoStock.ts):
--        sin_stock  = stock total <= 0
--        negativo   = stock total < 0 (subconjunto de sin_stock)
--        bajo       = mínimo > 0, stock > 0 y stock <= mínimo
--        sin_minimo = mínimo = 0
--      Igual que productos_stock_bajo: SQL invoker (la RLS de productos aplica), sin anon.

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ─── 1. productos_stock_bajo: solo con mínimo definido ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public.productos_stock_bajo(p_limite integer DEFAULT NULL::integer)
RETURNS TABLE(id uuid, nombre text, marca text, stock_total numeric, stock_minimo numeric, total_count integer)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  WITH stock AS (
    SELECT p.id, p.nombre, p.marca, p.stock_minimo,
           COALESCE(SUM(s.cantidad), 0) AS stock_total
    FROM productos p
    LEFT JOIN stock_ubicaciones s ON s.producto_id = p.id
    WHERE p.estado = 'activo'
      AND p.stock_minimo > 0  -- docs/64: mínimo 0 = sin definir, no alerta
    GROUP BY p.id, p.nombre, p.marca, p.stock_minimo
  )
  SELECT st.id, st.nombre, st.marca, st.stock_total, st.stock_minimo,
         (COUNT(*) OVER ())::int AS total_count
  FROM stock st
  WHERE st.stock_total <= st.stock_minimo
  ORDER BY st.stock_total - st.stock_minimo, st.nombre
  LIMIT p_limite;
$$;

REVOKE EXECUTE ON FUNCTION public.productos_stock_bajo(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.productos_stock_bajo(integer) TO authenticated, service_role;

-- ─── 2. resumen_stock_inventario ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.resumen_stock_inventario()
RETURNS TABLE(activos integer, sin_stock integer, negativo integer, bajo integer, sin_minimo integer)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  WITH stock AS (
    SELECT p.stock_minimo, COALESCE(SUM(s.cantidad), 0) AS stock_total
    FROM productos p
    LEFT JOIN stock_ubicaciones s ON s.producto_id = p.id
    WHERE p.estado = 'activo'
    GROUP BY p.id, p.stock_minimo
  )
  SELECT count(*)::int,
         (count(*) FILTER (WHERE stock_total <= 0))::int,
         (count(*) FILTER (WHERE stock_total < 0))::int,
         (count(*) FILTER (WHERE stock_minimo > 0 AND stock_total > 0 AND stock_total <= stock_minimo))::int,
         (count(*) FILTER (WHERE stock_minimo <= 0))::int
  FROM stock;
$$;

REVOKE EXECUTE ON FUNCTION public.resumen_stock_inventario() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resumen_stock_inventario() TO authenticated, service_role;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (solo lectura)
-- ════════════════════════════════════════════════════════════════════════════════════════════
SELECT p.proname,
       p.prosecdef AS security_definer,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_puede,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_puede,
       pg_get_functiondef(p.oid) LIKE '%stock_minimo > 0%' AS filtra_minimo
FROM pg_proc p
WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('productos_stock_bajo', 'resumen_stock_inventario')
ORDER BY p.proname;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (BEGIN … ROLLBACK). Compara contra un cálculo directo sobre los datos reales y
-- prueba bordes cambiando mínimos y estado dentro de la transacción. Siempre aborta.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $$
DECLARE
  v_ok int := 0;
  v_total int := 0;
  v_fallas text := '';
  v_n int;
  v_esperado int;
  v_res record;
  v_res2 record;
  v_sin_min_vacio uuid;  -- activo, mínimo 0, stock <= 0
  v_sin_min_con uuid;    -- activo, mínimo 0, stock > 0
  v_stock numeric;
  v_bajo uuid;           -- activo, mínimo > 0, en alerta
BEGIN
  CREATE TEMP TABLE t63 ON COMMIT DROP AS
    SELECT p.id, p.estado, p.stock_minimo, COALESCE(SUM(s.cantidad), 0) AS stock_total
    FROM productos p LEFT JOIN stock_ubicaciones s ON s.producto_id = p.id
    GROUP BY p.id;

  -- 1. productos_stock_bajo == cálculo directo (activos, mínimo > 0, stock <= mínimo)
  SELECT count(*) INTO v_esperado FROM t63 WHERE estado = 'activo' AND stock_minimo > 0 AND stock_total <= stock_minimo;
  SELECT count(*) INTO v_n FROM productos_stock_bajo(NULL);
  v_total := v_total + 1;
  IF v_n = v_esperado THEN v_ok := v_ok + 1; ELSE v_fallas := v_fallas || format(' [1: %s vs %s]', v_n, v_esperado); END IF;

  -- 2. ningún producto con mínimo 0 en la alerta
  v_total := v_total + 1;
  IF NOT EXISTS (SELECT 1 FROM productos_stock_bajo(NULL) WHERE stock_minimo <= 0) THEN v_ok := v_ok + 1;
  ELSE v_fallas := v_fallas || ' [2: hay mínimo 0]'; END IF;

  -- 3. total_count con límite == total sin límite
  v_total := v_total + 1;
  IF v_esperado = 0 OR (SELECT total_count FROM productos_stock_bajo(1)) = v_esperado THEN v_ok := v_ok + 1;
  ELSE v_fallas := v_fallas || ' [3: total_count]'; END IF;

  -- 4. resumen == cálculo directo
  SELECT * INTO v_res FROM resumen_stock_inventario();
  v_total := v_total + 1;
  IF v_res.activos = (SELECT count(*) FROM t63 WHERE estado = 'activo')
     AND v_res.sin_stock = (SELECT count(*) FROM t63 WHERE estado = 'activo' AND stock_total <= 0)
     AND v_res.negativo = (SELECT count(*) FROM t63 WHERE estado = 'activo' AND stock_total < 0)
     AND v_res.bajo = (SELECT count(*) FROM t63 WHERE estado = 'activo' AND stock_minimo > 0 AND stock_total > 0 AND stock_total <= stock_minimo)
     AND v_res.sin_minimo = (SELECT count(*) FROM t63 WHERE estado = 'activo' AND stock_minimo <= 0) THEN
    v_ok := v_ok + 1;
  ELSE v_fallas := v_fallas || format(' [4: %s]', row_to_json(v_res)); END IF;

  -- 5. sin stock + mínimo 0 → no alerta; con mínimo 5 → alerta, cuenta en sin_stock y no en bajo
  SELECT id INTO v_sin_min_vacio FROM t63 WHERE estado = 'activo' AND stock_minimo = 0 AND stock_total <= 0 LIMIT 1;
  v_total := v_total + 1;
  IF v_sin_min_vacio IS NULL THEN v_ok := v_ok + 1;  -- sin caso en los datos: no aplica
  ELSIF EXISTS (SELECT 1 FROM productos_stock_bajo(NULL) WHERE id = v_sin_min_vacio) THEN
    v_fallas := v_fallas || ' [5a: mínimo 0 en alerta]';
  ELSE
    UPDATE productos SET stock_minimo = 5 WHERE id = v_sin_min_vacio;
    SELECT * INTO v_res2 FROM resumen_stock_inventario();
    IF EXISTS (SELECT 1 FROM productos_stock_bajo(NULL) WHERE id = v_sin_min_vacio)
       AND v_res2.bajo = v_res.bajo AND v_res2.sin_stock = v_res.sin_stock AND v_res2.sin_minimo = v_res.sin_minimo - 1 THEN
      v_ok := v_ok + 1;
    ELSE v_fallas := v_fallas || format(' [5b: %s]', row_to_json(v_res2)); END IF;
    UPDATE productos SET stock_minimo = 0 WHERE id = v_sin_min_vacio;
  END IF;

  -- 6. con stock y mínimo 0 → al cargar mínimo = stock pasa a bajo
  SELECT id, stock_total INTO v_sin_min_con, v_stock FROM t63 WHERE estado = 'activo' AND stock_minimo = 0 AND stock_total > 0 LIMIT 1;
  v_total := v_total + 1;
  UPDATE productos SET stock_minimo = v_stock WHERE id = v_sin_min_con;
  SELECT * INTO v_res2 FROM resumen_stock_inventario();
  IF EXISTS (SELECT 1 FROM productos_stock_bajo(NULL) WHERE id = v_sin_min_con) AND v_res2.bajo = v_res.bajo + 1 THEN
    v_ok := v_ok + 1;
  ELSE v_fallas := v_fallas || format(' [6: %s]', row_to_json(v_res2)); END IF;
  UPDATE productos SET stock_minimo = 0 WHERE id = v_sin_min_con;

  -- 7. un producto en alerta que pasa a inactivo sale de la alerta y del resumen
  SELECT id INTO v_bajo FROM productos_stock_bajo(NULL) LIMIT 1;
  v_total := v_total + 1;
  IF v_bajo IS NULL THEN v_ok := v_ok + 1;
  ELSE
    UPDATE productos SET estado = 'inactivo' WHERE id = v_bajo;
    SELECT * INTO v_res2 FROM resumen_stock_inventario();
    IF NOT EXISTS (SELECT 1 FROM productos_stock_bajo(NULL) WHERE id = v_bajo) AND v_res2.activos = v_res.activos - 1 THEN
      v_ok := v_ok + 1;
    ELSE v_fallas := v_fallas || ' [7: inactivo sigue]'; END IF;
  END IF;

  RAISE EXCEPTION 'RESULTADO: % de % ok%. Resumen real: %', v_ok, v_total,
    CASE WHEN v_fallas = '' THEN '' ELSE ' — FALLAS:' || v_fallas END, row_to_json(v_res);
END;
$$;

ROLLBACK;
