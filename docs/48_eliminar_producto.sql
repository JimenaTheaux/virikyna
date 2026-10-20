-- 48 — Eliminar producto (solo admin) y RLS de productos por operación
--
-- Correr desde la raíz del repo con `npx supabase db query --linked -f docs/48_eliminar_producto.sql`
-- (o en el SQL Editor del proyecto ccpinvtleqlsukcqnili), después de 47. La PARTE A va una sola vez;
-- la PARTE B (verificación) y la PARTE C (test, BEGIN … ROLLBACK) se pueden repetir.
-- Auditoría que lo origina: docs/auditoria-2026-10-19.md, sección D.
--
-- Contexto (relevado contra la base real el 2026-10-19):
--   - productos tenía una sola policy, productos_todos (ALL, cualquier perfil activo), y
--     authenticated tenía GRANT de DELETE y TRUNCATE: un cajero podía borrar un producto llamando a
--     la API. Solo lo frenaban las FK de ventas/compras/movimientos.
--   - Ninguna app (código actual ni las versiones publicadas de Local v0.4.1 a v0.5.2) hace DELETE
--     sobre productos: revocarlo no rompe nada instalado.
--   - FK a productos: stock_ubicaciones CASCADE; carga_inicial_items SET NULL; movimientos_stock,
--     venta_items, devolucion_items y facturas_compra_items NO ACTION.
--   - INSERT de productos: los 3 formularios y carga_inicial_finalizar (proveedor null, márgenes
--     0/0, IVA 21). El formulario de cajero (Local, Inventario) no deja tocar márgenes ni IVA: manda
--     los márgenes default del proveedor (0/0 sin proveedor) y 21 % (docs/47). El trigger de márgenes
--     e IVA era solo BEFORE UPDATE: en un alta por API un cajero podía poner cualquier valor.
--
-- Qué hace:
--   1. eliminar_producto(p_producto_id uuid): admin activo, SECURITY DEFINER. Bloquea la fila del
--      producto (FOR UPDATE: una venta que entra al mismo tiempo espera, y la validación se hace con
--      lo ya confirmado) y:
--      - si tiene ventas, devoluciones, ítems de compra o movimientos de stock que no sean de carga
--        inicial → error con SQLSTATE 'VKH01' ("tiene historial"); la UI ofrece Inactivar;
--      - si no, borra sus movimientos 'inicial', su stock_ubicaciones y el producto.
--      El DELETE queda en auditoria como 'eliminacion' (trigger genérico, con todos sus valores).
--   2. RLS: productos_todos se parte en SELECT / INSERT / UPDATE para perfiles activos (igual que
--      hoy) y no hay policy de DELETE. REVOKE DELETE y TRUNCATE a authenticated y anon: borrar solo
--      por el RPC.
--   3. Alta: trigger BEFORE INSERT fn_proteger_alta_producto. Si quien inserta no es admin activo,
--      márgenes e IVA tienen que ser los default: márgenes del proveedor (0/0 sin proveedor) e IVA
--      21. Si no, rechaza.

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios (una sola vez)
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.eliminar_producto(p_producto_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_n int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede eliminar un producto';
  END IF;

  -- La fila bloqueada serializa contra una venta/compra simultánea (sus FK toman KEY SHARE sobre
  -- este producto): o la otra transacción termina antes y la vemos abajo, o espera y falla por FK.
  PERFORM 1 FROM productos WHERE id = p_producto_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El producto no existe (puede que ya se haya eliminado)';
  END IF;

  IF EXISTS (SELECT 1 FROM venta_items WHERE producto_id = p_producto_id)
     OR EXISTS (SELECT 1 FROM devolucion_items WHERE producto_id = p_producto_id)
     OR EXISTS (SELECT 1 FROM facturas_compra_items WHERE producto_id = p_producto_id)
     OR EXISTS (SELECT 1 FROM movimientos_stock WHERE producto_id = p_producto_id AND tipo <> 'inicial') THEN
    RAISE EXCEPTION 'Tiene movimientos registrados. No se puede eliminar.'
      USING ERRCODE = 'VKH01',
            HINT = 'Tiene ventas, devoluciones, compras o movimientos de stock: se puede inactivar.';
  END IF;

  DELETE FROM movimientos_stock WHERE producto_id = p_producto_id AND tipo = 'inicial';
  DELETE FROM stock_ubicaciones WHERE producto_id = p_producto_id;
  DELETE FROM productos WHERE id = p_producto_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'No se pudo eliminar el producto';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.eliminar_producto(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.eliminar_producto(uuid) TO authenticated, service_role;

COMMENT ON FUNCTION public.eliminar_producto(uuid) IS
  'Elimina un producto sin historial (solo admin activo). Con ventas, devoluciones, compras o movimientos que no sean de carga inicial: error VKH01 y la UI ofrece inactivar. docs/48.';

-- ─── RLS por operación ────────────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS productos_todos ON public.productos;
DROP POLICY IF EXISTS productos_select ON public.productos;
DROP POLICY IF EXISTS productos_insert ON public.productos;
DROP POLICY IF EXISTS productos_update ON public.productos;

CREATE POLICY productos_select ON public.productos FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));
CREATE POLICY productos_insert ON public.productos FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));
CREATE POLICY productos_update ON public.productos FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true))
  WITH CHECK (EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));
-- Sin policy de DELETE: nadie borra por la API. Solo eliminar_producto (SECURITY DEFINER).

REVOKE DELETE, TRUNCATE ON public.productos FROM authenticated, anon;

-- ─── Alta: márgenes e IVA default para quien no es admin ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_proteger_alta_producto()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_m1 NUMERIC;
  v_m2 NUMERIC;
BEGIN
  IF EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RETURN NEW;
  END IF;
  -- Defaults: los del proveedor elegido; sin proveedor, 0/0 (como el formulario y la carga inicial).
  SELECT margen_1_default, margen_2_default INTO v_m1, v_m2 FROM proveedores WHERE id = NEW.proveedor_id;
  IF NEW.margen_1 IS DISTINCT FROM COALESCE(v_m1, 0)
     OR NEW.margen_2 IS DISTINCT FROM COALESCE(v_m2, 0)
     OR NEW.iva_porcentaje IS DISTINCT FROM 21 THEN
    RAISE EXCEPTION 'Solo un administrador puede dar de alta un producto con márgenes o IVA distintos de los del proveedor';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_proteger_alta_producto ON public.productos;
CREATE TRIGGER trg_proteger_alta_producto BEFORE INSERT ON public.productos
  FOR EACH ROW EXECUTE FUNCTION fn_proteger_alta_producto();

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (solo lectura)
-- ════════════════════════════════════════════════════════════════════════════════════════════
SELECT 'policy' AS chequeo, policyname || ' ' || cmd AS valor FROM pg_policies WHERE tablename = 'productos'
UNION ALL
SELECT 'grants', array_to_string(relacl, ',') FROM pg_class WHERE oid = 'public.productos'::regclass
UNION ALL
SELECT 'rpc', p.oid::regprocedure::text || ' ' || array_to_string(p.proacl, ',')
FROM pg_proc p WHERE p.proname = 'eliminar_producto' AND p.pronamespace = 'public'::regnamespace
UNION ALL
SELECT 'trigger', tgname FROM pg_trigger WHERE tgrelid = 'public.productos'::regclass AND tgname = 'trg_proteger_alta_producto';

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (no deja nada: BEGIN … ROLLBACK)
-- Los casos de API corren con SET LOCAL ROLE authenticated (RLS y grants reales, como PostgREST).
-- Resultado: una tabla, todo ok = true.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TEMP TABLE t48 (orden int, caso text, ok boolean, detalle text) ON COMMIT DROP;
GRANT ALL ON t48 TO authenticated;

SELECT set_config('t48.admin', (SELECT id FROM perfiles WHERE activo AND rol = 'admin' ORDER BY id LIMIT 1)::text, true),
       set_config('t48.cajero', (SELECT id FROM perfiles WHERE activo AND rol <> 'admin' ORDER BY id LIMIT 1)::text, true),
       set_config('request.jwt.claims', json_build_object('sub', (SELECT id FROM perfiles WHERE activo AND rol = 'admin' ORDER BY id LIMIT 1), 'role', 'authenticated')::text, true);

DO $test$
DECLARE
  v_solo_inicial uuid;
  v_con_venta uuid;
  v_con_ajuste uuid;
  v_con_compra uuid;
  v_prov uuid := (SELECT id FROM proveedores ORDER BY razon_social LIMIT 1);
  v_aud int;
BEGIN
  -- Solo carga inicial: ni ventas, ni devoluciones, ni compras, ni otros movimientos.
  SELECT p.id INTO v_solo_inicial FROM productos p
  WHERE EXISTS (SELECT 1 FROM movimientos_stock m WHERE m.producto_id = p.id AND m.tipo = 'inicial')
    AND NOT EXISTS (SELECT 1 FROM movimientos_stock m WHERE m.producto_id = p.id AND m.tipo <> 'inicial')
    AND NOT EXISTS (SELECT 1 FROM venta_items v WHERE v.producto_id = p.id)
    AND NOT EXISTS (SELECT 1 FROM devolucion_items d WHERE d.producto_id = p.id)
    AND NOT EXISTS (SELECT 1 FROM facturas_compra_items f WHERE f.producto_id = p.id)
  ORDER BY p.nombre LIMIT 1;
  SELECT DISTINCT producto_id INTO v_con_venta FROM venta_items LIMIT 1;
  SELECT producto_id INTO v_con_ajuste FROM movimientos_stock WHERE tipo = 'ajuste' LIMIT 1;

  -- 1. Solo carga inicial: se borra con sus movimientos y su stock, y queda la auditoría
  PERFORM eliminar_producto(v_solo_inicial);
  SELECT count(*) INTO v_aud FROM auditoria WHERE tabla_afectada = 'productos' AND accion = 'eliminacion' AND registro_id = v_solo_inicial;
  INSERT INTO t48 VALUES (1, 'solo carga inicial: se elimina (producto, movimientos, stock) y queda auditado',
    NOT EXISTS (SELECT 1 FROM productos WHERE id = v_solo_inicial)
      AND NOT EXISTS (SELECT 1 FROM movimientos_stock WHERE producto_id = v_solo_inicial)
      AND NOT EXISTS (SELECT 1 FROM stock_ubicaciones WHERE producto_id = v_solo_inicial)
      AND v_aud = 1,
    v_solo_inicial::text);

  -- 2. Con venta
  BEGIN
    PERFORM eliminar_producto(v_con_venta);
    INSERT INTO t48 VALUES (2, 'con venta: error VKH01', false, 'no dio error');
  EXCEPTION WHEN SQLSTATE 'VKH01' THEN
    INSERT INTO t48 VALUES (2, 'con venta: error VKH01', true, SQLERRM);
  END;

  -- 3. Con ajuste de stock
  BEGIN
    PERFORM eliminar_producto(v_con_ajuste);
    INSERT INTO t48 VALUES (3, 'con ajuste: error VKH01', false, 'no dio error');
  EXCEPTION WHEN SQLSTATE 'VKH01' THEN
    INSERT INTO t48 VALUES (3, 'con ajuste: error VKH01', true, SQLERRM);
  END;

  -- 4. Con compra (hoy no hay facturas: se carga una acá, dentro del ROLLBACK)
  INSERT INTO productos (nombre, costo, margen_1, margen_2, iva_porcentaje, estado)
  VALUES ('TEST 48 COMPRA', 100, 0, 0, 21, 'activo') RETURNING id INTO v_con_compra;
  PERFORM cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'remito', p_letra => NULL,
           p_punto_venta => NULL, p_numero_comprobante => 'T48', p_fecha_comprobante => current_date,
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente',
           p_items => jsonb_build_array(jsonb_build_object('producto_id', v_con_compra, 'descripcion', 'TEST 48',
                        'cantidad', 1, 'precio_unitario_sin_iva', 100)), p_iva_alicuota => 0);
  BEGIN
    PERFORM eliminar_producto(v_con_compra);
    INSERT INTO t48 VALUES (4, 'con compra: error VKH01', false, 'no dio error');
  EXCEPTION WHEN SQLSTATE 'VKH01' THEN
    INSERT INTO t48 VALUES (4, 'con compra: error VKH01', true, SQLERRM);
  END;

  -- 5. Producto inexistente (ya eliminado)
  BEGIN
    PERFORM eliminar_producto(v_solo_inicial);
    INSERT INTO t48 VALUES (5, 'ya eliminado: error claro', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t48 VALUES (5, 'ya eliminado: error claro', SQLERRM LIKE 'El producto no existe%', SQLERRM);
  END;
END
$test$;

-- 6-11: como la API (rol authenticated, RLS y grants reales)
SET LOCAL ROLE authenticated;

-- 6. Admin: DELETE directo rechazado (sin grant)
DO $$
BEGIN
  DELETE FROM productos WHERE id = (SELECT id FROM productos ORDER BY nombre LIMIT 1);
  INSERT INTO t48 VALUES (6, 'admin: DELETE directo por API rechazado', false, 'no dio error');
EXCEPTION WHEN insufficient_privilege THEN
  INSERT INTO t48 VALUES (6, 'admin: DELETE directo por API rechazado', true, SQLERRM);
END $$;

-- Pasa a cajero
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('t48.cajero'), 'role', 'authenticated')::text, true);

-- 7. Cajero llamando al RPC
DO $$
BEGIN
  PERFORM eliminar_producto((SELECT id FROM productos ORDER BY nombre LIMIT 1));
  INSERT INTO t48 VALUES (7, 'cajero: eliminar_producto rechazado', false, 'no dio error');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO t48 VALUES (7, 'cajero: eliminar_producto rechazado', SQLERRM = 'Solo un administrador puede eliminar un producto', SQLERRM);
END $$;

-- 8. Cajero: DELETE directo rechazado
DO $$
BEGIN
  DELETE FROM productos WHERE id = (SELECT id FROM productos ORDER BY nombre LIMIT 1);
  INSERT INTO t48 VALUES (8, 'cajero: DELETE directo por API rechazado', false, 'no dio error');
EXCEPTION WHEN insufficient_privilege THEN
  INSERT INTO t48 VALUES (8, 'cajero: DELETE directo por API rechazado', true, SQLERRM);
END $$;

-- 9. Cajero: alta con los defaults del proveedor e IVA 21 → OK (lo que manda su formulario)
DO $$
DECLARE v_p record;
BEGIN
  SELECT id, margen_1_default, margen_2_default INTO v_p FROM proveedores WHERE margen_1_default > 0 ORDER BY razon_social LIMIT 1;
  INSERT INTO productos (nombre, costo, proveedor_id, margen_1, margen_2, iva_porcentaje, estado)
  VALUES ('TEST 48 CAJERO OK', 100, v_p.id, v_p.margen_1_default, v_p.margen_2_default, 21, 'activo');
  INSERT INTO productos (nombre, costo, margen_1, margen_2, estado) VALUES ('TEST 48 CAJERO SIN PROV', 100, 0, 0, 'activo');
  INSERT INTO t48 VALUES (9, 'cajero: alta con defaults (con y sin proveedor) permitida', true, format('proveedor %s/%s', v_p.margen_1_default, v_p.margen_2_default));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO t48 VALUES (9, 'cajero: alta con defaults (con y sin proveedor) permitida', false, SQLERRM);
END $$;

-- 10. Cajero: alta con márgenes distintos
DO $$
BEGIN
  INSERT INTO productos (nombre, costo, margen_1, margen_2, estado) VALUES ('TEST 48 CAJERO MARGEN', 100, 50, 0, 'activo');
  INSERT INTO t48 VALUES (10, 'cajero: alta con márgenes distintos rechazada', false, 'no dio error');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO t48 VALUES (10, 'cajero: alta con márgenes distintos rechazada', SQLERRM LIKE 'Solo un administrador puede dar de alta%', SQLERRM);
END $$;

-- 11. Cajero: alta sin IVA
DO $$
BEGIN
  INSERT INTO productos (nombre, costo, margen_1, margen_2, iva_porcentaje, estado) VALUES ('TEST 48 CAJERO IVA', 100, 0, 0, 0, 'activo');
  INSERT INTO t48 VALUES (11, 'cajero: alta sin IVA rechazada', false, 'no dio error');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO t48 VALUES (11, 'cajero: alta sin IVA rechazada', SQLERRM LIKE 'Solo un administrador puede dar de alta%', SQLERRM);
END $$;

-- 12. Cajero sigue pudiendo leer y editar (policies SELECT/UPDATE)
DO $$
DECLARE v_id uuid; v_n int;
BEGIN
  SELECT id INTO v_id FROM productos ORDER BY nombre LIMIT 1;
  UPDATE productos SET stock_minimo = stock_minimo WHERE id = v_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  INSERT INTO t48 VALUES (12, 'cajero: SELECT y UPDATE siguen permitidos', v_id IS NOT NULL AND v_n = 1, format('update %s fila', v_n));
END $$;

-- 13. Admin: alta con márgenes propios sigue permitida
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('t48.admin'), 'role', 'authenticated')::text, true);
DO $$
BEGIN
  INSERT INTO productos (nombre, costo, margen_1, margen_2, iva_porcentaje, estado) VALUES ('TEST 48 ADMIN', 100, 80, 10, 0, 'activo');
  INSERT INTO t48 VALUES (13, 'admin: alta con márgenes e IVA propios permitida', true, NULL);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO t48 VALUES (13, 'admin: alta con márgenes e IVA propios permitida', false, SQLERRM);
END $$;

RESET ROLE;

SELECT * FROM t48 ORDER BY orden;

ROLLBACK;
