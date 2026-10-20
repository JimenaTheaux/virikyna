-- 47 — Producto con / sin IVA ("Lleva IVA")
--
-- Correr desde la raíz del repo con `npx supabase db query --linked -f docs/47_iva_producto.sql`
-- (o en el SQL Editor del proyecto ccpinvtleqlsukcqnili), después de 46. La PARTE A va una sola vez;
-- la PARTE B (verificación) y la PARTE C (test, BEGIN … ROLLBACK) se pueden repetir.
-- Auditoría que lo origina: docs/auditoria-2026-10-19.md, sección E.
--
-- Contexto (relevado contra la base real el 2026-10-19):
--   - productos.iva_porcentaje numeric(5,2) NOT NULL DEFAULT 21 ya existe y la columna generada lo
--     usa: precio_calculado = ROUND(costo × (1+m1/100) × (1+m2/100) × (1+iva/100), 2) y
--     precio_venta = COALESCE(precio_manual, redondear_precio_venta(precio_calculado)). No hace falta
--     una columna nueva ni tocar la fórmula: "sin IVA" es iva_porcentaje = 0.
--   - Los 2.164 productos tienen 21 (2.163 con precio manual, que no cambia con el IVA).
--   - Ningún RPC cambia iva_porcentaje en un UPDATE (solo carga_inicial_finalizar lo inserta).
--   - Los márgenes se protegen con el trigger BEFORE UPDATE fn_proteger_margen_producto: solo un
--     admin activo los cambia (o un RPC que hereda los del proveedor con
--     virikyna.margen_auto_herencia). En INSERT no hay protección (ni de márgenes ni de IVA).
--   - actualizar_precios_masivo cambia costo o precio_manual, nunca el IVA: el precio sale de la
--     columna generada, así que un producto sin IVA ya se actualiza sin IVA (test 7).
--
-- Qué hace:
--   1. CHECK (iva_porcentaje IN (0, 21)).
--   2. fn_proteger_margen_producto también protege iva_porcentaje, con la misma regla que los
--      márgenes: solo admin activo. La herencia de márgenes del proveedor no habilita el IVA (el
--      IVA nunca se hereda).
--   3. marcar_iva_productos(p_ids uuid[], p_lleva_iva boolean) → integer: admin activo, SECURITY
--      DEFINER; pone 21 o 0 en los productos pedidos que todavía no lo tienen y devuelve cuántos
--      cambió. Cada fila queda en auditoria por el trigger genérico (edición).

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios (una sola vez)
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM productos WHERE iva_porcentaje NOT IN (0, 21)) THEN
    RAISE EXCEPTION 'Hay productos con IVA distinto de 0 o 21: revisar antes de agregar el CHECK';
  END IF;
END
$$;

ALTER TABLE public.productos DROP CONSTRAINT IF EXISTS productos_iva_porcentaje_valido;
ALTER TABLE public.productos
  ADD CONSTRAINT productos_iva_porcentaje_valido CHECK (iva_porcentaje IN (0, 21));

COMMENT ON COLUMN public.productos.iva_porcentaje IS
  'IVA del producto para el precio de venta: 21 (lleva IVA) o 0 (sin IVA). Solo admin lo cambia (fn_proteger_margen_producto). No afecta un precio manual. docs/47.';

CREATE OR REPLACE FUNCTION public.fn_proteger_margen_producto()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF (NEW.margen_1 IS DISTINCT FROM OLD.margen_1) OR (NEW.margen_2 IS DISTINCT FROM OLD.margen_2) THEN
    IF current_setting('virikyna.margen_auto_herencia', true) = 'true' THEN
      NULL;  -- docs/47: antes RETURN NEW; ahora sigue para revisar el IVA (que no se hereda)
    ELSIF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
      RAISE EXCEPTION 'Solo un administrador puede modificar el margen de un producto';
    END IF;
  END IF;
  -- docs/47: el IVA define el precio igual que los márgenes → misma regla, solo admin.
  IF NEW.iva_porcentaje IS DISTINCT FROM OLD.iva_porcentaje
     AND NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede modificar el IVA de un producto';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.marcar_iva_productos(p_ids uuid[], p_lleva_iva boolean)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_iva NUMERIC;
  v_count INTEGER;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede cambiar el IVA de los productos';
  END IF;
  IF p_ids IS NULL OR cardinality(p_ids) = 0 THEN
    RAISE EXCEPTION 'Elegí al menos un producto';
  END IF;
  IF p_lleva_iva IS NULL THEN
    RAISE EXCEPTION 'Indicá si los productos llevan IVA o no';
  END IF;

  v_iva := CASE WHEN p_lleva_iva THEN 21 ELSE 0 END;

  -- Solo los que cambian: así la auditoría no se llena de ediciones vacías y la cantidad devuelta
  -- es la de productos realmente modificados. El WHERE también cumple con safeupdate.
  UPDATE productos
  SET iva_porcentaje = v_iva,
      updated_at = now()
  WHERE id = ANY(p_ids) AND iva_porcentaje <> v_iva;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.marcar_iva_productos(uuid[], boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.marcar_iva_productos(uuid[], boolean) TO authenticated, service_role;

COMMENT ON FUNCTION public.marcar_iva_productos(uuid[], boolean) IS
  'Acción masiva "Lleva IVA" (docs/47): admin activo; pone iva_porcentaje 21 o 0 en los productos que no lo tienen y devuelve cuántos cambió.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (solo lectura)
-- ════════════════════════════════════════════════════════════════════════════════════════════
SELECT 'check' AS chequeo, pg_get_constraintdef(oid) AS valor
FROM pg_constraint WHERE conrelid = 'public.productos'::regclass AND conname = 'productos_iva_porcentaje_valido'
UNION ALL
SELECT 'rpc', p.oid::regprocedure::text || ' ' || array_to_string(p.proacl, ',')
FROM pg_proc p WHERE p.proname = 'marcar_iva_productos' AND p.pronamespace = 'public'::regnamespace
UNION ALL
SELECT 'trigger protege iva', (prosrc LIKE '%NEW.iva_porcentaje IS DISTINCT FROM OLD.iva_porcentaje%')::text
FROM pg_proc WHERE proname = 'fn_proteger_margen_producto'
UNION ALL
SELECT 'iva por producto', string_agg(iva::text || ': ' || n, ', ')
FROM (SELECT iva_porcentaje AS iva, count(*) AS n FROM productos GROUP BY 1) x;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (no deja nada: BEGIN … ROLLBACK)
-- Usa el único producto con costo y uno con precio manual; productos de prueba creados acá.
-- Resultado: una tabla, todo ok = true.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TEMP TABLE t47 (orden int, caso text, ok boolean, detalle text) ON COMMIT DROP;

DO $test$
DECLARE
  v_admin uuid := (SELECT id FROM perfiles WHERE activo AND rol = 'admin' ORDER BY id LIMIT 1);
  v_cajero uuid := (SELECT id FROM perfiles WHERE activo AND rol <> 'admin' ORDER BY id LIMIT 1);
  v_costo uuid;    -- producto con costo (sin precio manual)
  v_manual uuid;   -- producto con precio manual
  v_sin uuid;      -- producto de prueba sin IVA con costo
  v_p productos%ROWTYPE;
  v_n int;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  SELECT id INTO v_costo FROM productos WHERE costo IS NOT NULL AND precio_manual IS NULL ORDER BY nombre LIMIT 1;
  SELECT id INTO v_manual FROM productos WHERE precio_manual IS NOT NULL AND costo IS NULL ORDER BY nombre LIMIT 1;

  -- Producto de prueba con costo 1000, márgenes 100/0: con IVA 2420 → 2500; sin IVA 2000.
  INSERT INTO productos (nombre, costo, margen_1, margen_2, iva_porcentaje, estado)
  VALUES ('TEST 47 CON COSTO', 1000, 100, 0, 21, 'activo') RETURNING id INTO v_sin;

  -- 1. Con costo 21 → 0: el precio baja (columna generada)
  v_n := marcar_iva_productos(ARRAY[v_sin], false);
  SELECT * INTO v_p FROM productos WHERE id = v_sin;
  INSERT INTO t47 VALUES (1, 'con costo 21 → 0: 2500 → 2000', v_n = 1 AND v_p.iva_porcentaje = 0 AND v_p.precio_venta = 2000,
    format('n %s iva %s venta %s', v_n, v_p.iva_porcentaje, v_p.precio_venta));

  -- 2. Con costo 0 → 21: vuelve a 2500
  v_n := marcar_iva_productos(ARRAY[v_sin], true);
  SELECT * INTO v_p FROM productos WHERE id = v_sin;
  INSERT INTO t47 VALUES (2, 'con costo 0 → 21: 2000 → 2500', v_n = 1 AND v_p.iva_porcentaje = 21 AND v_p.precio_venta = 2500,
    format('n %s iva %s venta %s', v_n, v_p.iva_porcentaje, v_p.precio_venta));

  -- 3. Precio manual: el IVA cambia, el precio no
  SELECT * INTO v_p FROM productos WHERE id = v_manual;
  v_n := marcar_iva_productos(ARRAY[v_manual], false);
  INSERT INTO t47 SELECT 3, 'precio manual: iva 0, precio igual', v_n = 1 AND p.iva_porcentaje = 0 AND p.precio_venta = v_p.precio_venta,
    format('antes %s después %s', v_p.precio_venta, p.precio_venta)
  FROM productos p WHERE p.id = v_manual;

  -- 4. Masiva con mezcla: uno ya sin IVA (v_manual) + dos con IVA → marcar sin IVA cambia 2
  v_n := marcar_iva_productos(ARRAY[v_manual, v_sin, v_costo], false);
  INSERT INTO t47 VALUES (4, 'masiva mixta: solo cuenta los que cambian (2 de 3)', v_n = 2
      AND (SELECT count(*) FROM productos WHERE id IN (v_manual, v_sin, v_costo) AND iva_porcentaje = 0) = 3,
    format('n %s', v_n));

  -- 5. Auditoría por el trigger genérico
  INSERT INTO t47 SELECT 5, 'auditoría: una edición por cambio', count(*) = 5, format('%s ediciones', count(*))
  FROM auditoria WHERE tabla_afectada = 'productos' AND accion = 'edicion' AND registro_id IN (v_manual, v_sin, v_costo)
    AND created_at = now();

  -- 6. Admin cambiando el IVA por UPDATE directo (formulario): permitido
  UPDATE productos SET iva_porcentaje = 21 WHERE id = v_sin;
  INSERT INTO t47 SELECT 6, 'admin por UPDATE directo: permitido', iva_porcentaje = 21, iva_porcentaje::text FROM productos WHERE id = v_sin;

  -- 7. Actualizar precios % sobre producto sin IVA: el precio nuevo sale sin IVA
  UPDATE productos SET iva_porcentaje = 0 WHERE id = v_sin;
  PERFORM actualizar_precios_masivo(10, NULL, ARRAY[v_sin]);
  SELECT * INTO v_p FROM productos WHERE id = v_sin;
  -- costo 1100 × 2 = 2200 (sin IVA) → redondeo escalonado → 2000
  INSERT INTO t47 VALUES (7, 'actualizar precios +10 % sin IVA: costo 1100, calculado 2200 (sin IVA)',
    v_p.costo = 1100 AND v_p.precio_calculado = 2200 AND v_p.precio_venta = redondear_precio_venta(2200),
    format('costo %s calculado %s venta %s', v_p.costo, v_p.precio_calculado, v_p.precio_venta));

  -- 8. Valor inválido: CHECK
  BEGIN
    UPDATE productos SET iva_porcentaje = 10.5 WHERE id = v_sin;
    INSERT INTO t47 VALUES (8, 'iva 10,5 rechazado por CHECK', false, 'no dio error');
  EXCEPTION WHEN check_violation THEN
    INSERT INTO t47 VALUES (8, 'iva 10,5 rechazado por CHECK', true, SQLERRM);
  END;

  -- 9-11. Cajero
  IF v_cajero IS NULL THEN
    INSERT INTO t47 VALUES (9, 'cajero: no hay perfil no admin activo para probar', false, NULL);
  ELSE
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_cajero, 'role', 'authenticated')::text, true);
    BEGIN
      UPDATE productos SET iva_porcentaje = 21 WHERE id = v_sin;
      INSERT INTO t47 VALUES (9, 'cajero cambia IVA por UPDATE: rechazado', false, 'no dio error');
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO t47 VALUES (9, 'cajero cambia IVA por UPDATE: rechazado', SQLERRM = 'Solo un administrador puede modificar el IVA de un producto', SQLERRM);
    END;
    BEGIN
      PERFORM marcar_iva_productos(ARRAY[v_sin], true);
      INSERT INTO t47 VALUES (10, 'cajero usa la masiva: rechazado', false, 'no dio error');
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO t47 VALUES (10, 'cajero usa la masiva: rechazado', SQLERRM LIKE 'Solo un administrador%', SQLERRM);
    END;
    -- El cajero sigue pudiendo editar otros campos (mismo IVA, sin cambio)
    UPDATE productos SET stock_minimo = 3, iva_porcentaje = 0 WHERE id = v_sin;
    INSERT INTO t47 SELECT 11, 'cajero edita otro campo sin tocar el IVA: permitido', stock_minimo = 3, stock_minimo::text FROM productos WHERE id = v_sin;
    -- Herencia de márgenes del proveedor no habilita el IVA
    BEGIN
      PERFORM set_config('virikyna.margen_auto_herencia', 'true', true);
      UPDATE productos SET margen_1 = 50, iva_porcentaje = 21 WHERE id = v_sin;
      INSERT INTO t47 VALUES (12, 'herencia de márgenes no habilita el IVA', false, 'no dio error');
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO t47 VALUES (12, 'herencia de márgenes no habilita el IVA', SQLERRM = 'Solo un administrador puede modificar el IVA de un producto', SQLERRM);
    END;
    PERFORM set_config('virikyna.margen_auto_herencia', 'false', true);
    -- y la herencia sola sigue andando para el cajero (márgenes sin IVA)
    PERFORM set_config('virikyna.margen_auto_herencia', 'true', true);
    UPDATE productos SET margen_1 = 50 WHERE id = v_sin;
    PERFORM set_config('virikyna.margen_auto_herencia', 'false', true);
    INSERT INTO t47 SELECT 13, 'herencia de márgenes sin IVA: sigue permitida', margen_1 = 50, margen_1::text FROM productos WHERE id = v_sin;
  END IF;
END
$test$;

SELECT * FROM t47 ORDER BY orden;

ROLLBACK;
