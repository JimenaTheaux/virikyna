-- 34c — Carga inicial: guardado idempotente (client_id por operación)
--
-- docs/06_estructura_de_datos.md, sección 24 (subsección 34c), tiene el detalle. Correr en el SQL
-- Editor de Supabase (proyecto ccpinvtleqlsukcqnili), después de 34b:
--   PARTE A — cambios (una transacción). Una sola vez.
--   PARTE B — verificación. Se puede repetir.
--   PARTE C — tests, dentro de BEGIN … ROLLBACK. Se puede repetir; no deja datos.
--
-- Problema: si se pierde la respuesta de un guardado que sí llegó a la base, el reintento del
-- cliente vuelve a sumar la cantidad (alta con un código que ya está en mis borradores → suma).
--
-- Contexto (base real 2026-10-08): 34b aplicado. Firmas vivas:
--   carga_inicial_guardar_item(text, text, text, text, numeric, numeric, text, uuid)
--   carga_inicial_editar_producto(uuid, text, text, text, numeric, numeric)
--
-- Qué hace:
--   1. carga_inicial_operaciones: un client_id (UUID que genera el cliente por operación) = una
--      sola aplicación. RLS: cada usuario lee las suyas; se escribe solo desde las RPCs.
--   2. carga_inicial_guardar_item + p_client_id (obligatorio, primer parámetro). Si ese client_id
--      ya se aplicó, no hace nada y devuelve la fila tal como está ahora (si ya no existe —se
--      finalizó o se eliminó— devuelve solo su id, el resto en null). Si no, aplica igual que 34b
--      y registra el client_id en la misma transacción. Si la operación falla, el registro se
--      deshace con ella: el mismo client_id se puede reintentar.
--      El client_id se reclama al principio (INSERT … ON CONFLICT DO NOTHING): dos llamadas
--      simultáneas con el mismo id se ordenan por la PK y la segunda ve la primera como aplicada.
--   3. carga_inicial_editar_producto + p_client_id (mismo mecanismo): devuelve el resultado
--      guardado de la primera aplicación.
--   Por qué DROP + CREATE: agregar un parámetro cambia la firma; con CREATE OR REPLACE quedarían
--   las dos versiones vivas (y una llamada de PostgREST podría encajar en cualquiera). Ninguna app
--   publicada llama todavía a estas RPCs.
--
-- Verificado sin cambios (tests C3 y C6):
--   - Editar un borrador existente (p_id) FIJA los valores (UPDATE … SET cantidad = p_cantidad),
--     no suma. Solo el alta sin p_id con un código que ya está en mis borradores suma.
--   - carga_inicial_finalizar no aplica dos veces: bloquea mis borradores (FOR UPDATE) y los borra
--     en la misma transacción. Una segunda llamada —seguida o simultánea— ya no encuentra
--     borradores y devuelve items = 0. No necesita client_id.
--   - carga_inicial_editar_producto ya era idempotente en la cantidad (recibe el valor absoluto:
--     repetirla da delta 0); el client_id además evita repetir el UPDATE y su fila de auditoría,
--     y devuelve el delta original.
--
-- ⚠ Los tests de docs/34 y docs/34b llaman a las firmas viejas: después de 34c ya no corren tal cual.


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios (una transacción)
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ============================================================
-- 1. carga_inicial_operaciones
-- ============================================================
CREATE TABLE carga_inicial_operaciones (
  client_id UUID PRIMARY KEY,
  usuario_id UUID NOT NULL REFERENCES perfiles(id),
  operacion TEXT NOT NULL CHECK (operacion IN ('guardar_item', 'editar_producto')),
  -- guardar_item: el borrador; editar_producto: el producto. Sin FK: el borrador se borra al finalizar.
  item_id UUID,
  resultado JSONB,  -- editar_producto: lo que devolvió la primera aplicación
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_carga_inicial_operaciones_usuario ON carga_inicial_operaciones(usuario_id);

ALTER TABLE carga_inicial_operaciones ENABLE ROW LEVEL SECURITY;

CREATE POLICY carga_inicial_operaciones_propias ON carga_inicial_operaciones
  FOR SELECT USING (usuario_id = auth.uid());

-- Reclama un client_id para el usuario actual. true = es nuevo (aplicar); false = ya se aplicó.
-- Error si es de otro usuario o de otra operación.
CREATE OR REPLACE FUNCTION carga_inicial_reclamar_operacion(p_client_id UUID, p_operacion TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_op carga_inicial_operaciones%ROWTYPE;
BEGIN
  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'Falta el identificador de la operación (p_client_id)';
  END IF;

  INSERT INTO carga_inicial_operaciones (client_id, usuario_id, operacion)
  VALUES (p_client_id, auth.uid(), p_operacion)
  ON CONFLICT (client_id) DO NOTHING;
  IF FOUND THEN
    RETURN true;
  END IF;

  SELECT * INTO v_op FROM carga_inicial_operaciones WHERE client_id = p_client_id;
  IF v_op.usuario_id IS DISTINCT FROM auth.uid() OR v_op.operacion <> p_operacion THEN
    RAISE EXCEPTION 'Identificador de operación inválido';
  END IF;
  RETURN false;
END;
$$;

REVOKE EXECUTE ON FUNCTION carga_inicial_reclamar_operacion(UUID, TEXT) FROM PUBLIC, anon, authenticated;

-- ============================================================
-- 2. carga_inicial_guardar_item + p_client_id
-- ============================================================
DROP FUNCTION carga_inicial_guardar_item(TEXT, TEXT, TEXT, TEXT, NUMERIC, NUMERIC, TEXT, UUID);

CREATE FUNCTION carga_inicial_guardar_item(
  p_client_id UUID,
  p_codigo_barras TEXT,
  p_nombre TEXT,
  p_marca TEXT,
  p_descripcion TEXT,
  p_precio NUMERIC,
  p_cantidad NUMERIC,
  p_accion TEXT DEFAULT 'nuevo',
  p_id UUID DEFAULT NULL
) RETURNS carga_inicial_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_codigo TEXT := NULLIF(regexp_replace(COALESCE(p_codigo_barras, ''), '\s+', '', 'g'), '');
  v_nombre TEXT := NULLIF(btrim(COALESCE(p_nombre, '')), '');
  v_marca TEXT := NULLIF(btrim(COALESCE(p_marca, '')), '');
  v_descripcion TEXT := NULLIF(btrim(COALESCE(p_descripcion, '')), '');
  v_producto_id UUID;
  v_costo NUMERIC;
  v_precio_venta NUMERIC;
  v_fila carga_inicial_items;
BEGIN
  PERFORM carga_inicial_verificar_acceso();

  -- docs/34c: operación ya aplicada → la fila como está ahora (o solo su id si ya no existe).
  IF NOT carga_inicial_reclamar_operacion(p_client_id, 'guardar_item') THEN
    SELECT i.* INTO v_fila
    FROM carga_inicial_operaciones o JOIN carga_inicial_items i ON i.id = o.item_id
    WHERE o.client_id = p_client_id;
    IF v_fila.id IS NULL THEN
      v_fila.id := (SELECT item_id FROM carga_inicial_operaciones WHERE client_id = p_client_id);
    END IF;
    RETURN v_fila;
  END IF;

  IF p_accion IS NULL OR p_accion NOT IN ('nuevo', 'sumar', 'reemplazar') THEN
    RAISE EXCEPTION 'Acción inválida: tiene que ser nuevo, sumar o reemplazar';
  END IF;
  IF v_nombre IS NULL THEN
    RAISE EXCEPTION 'El nombre es obligatorio';
  END IF;
  IF p_precio IS NULL OR p_precio <= 0 THEN
    RAISE EXCEPTION 'El precio tiene que ser mayor a 0';
  END IF;
  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RAISE EXCEPTION 'La cantidad tiene que ser mayor a 0';
  END IF;

  IF v_codigo IS NOT NULL THEN
    v_producto_id := carga_inicial_producto_por_codigo(v_codigo);
  END IF;

  IF p_accion = 'nuevo' AND v_producto_id IS NOT NULL THEN
    RAISE EXCEPTION 'Ya existe un producto con el código %: elegí sumar stock o reemplazar sus datos', v_codigo;
  END IF;
  IF p_accion = 'sumar' AND v_producto_id IS NULL THEN
    RAISE EXCEPTION 'No hay ningún producto con ese código para sumar';
  END IF;
  IF p_accion = 'reemplazar' AND v_codigo IS NULL THEN
    RAISE EXCEPTION 'Para reemplazar datos hace falta el código';
  END IF;
  IF p_accion = 'reemplazar' AND v_producto_id IS NOT NULL THEN
    SELECT costo, precio_venta INTO v_costo, v_precio_venta FROM productos WHERE id = v_producto_id;
    IF v_costo IS NOT NULL AND p_precio <> v_precio_venta THEN
      RAISE EXCEPTION 'Precio calculado por costo: este producto tiene costo cargado y su precio sale de la fórmula. Dejá el precio actual (%) o usá sumar.', v_precio_venta;
    END IF;
  END IF;

  IF p_id IS NOT NULL THEN
    -- Edición: FIJA los valores (no suma).
    BEGIN
      UPDATE carga_inicial_items
      SET codigo_barras = v_codigo, nombre = v_nombre, marca = v_marca, descripcion = v_descripcion,
          precio = p_precio, cantidad = p_cantidad, accion = p_accion, producto_id = v_producto_id,
          updated_at = now()
      WHERE id = p_id AND usuario_id = auth.uid()
      RETURNING * INTO v_fila;
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'Ya tenés otro borrador con el código %', v_codigo;
    END;
    IF v_fila.id IS NULL THEN
      RAISE EXCEPTION 'Borrador no encontrado';
    END IF;
  ELSIF v_codigo IS NOT NULL THEN
    -- Alta: si el código ya está en mis borradores, suma la cantidad.
    INSERT INTO carga_inicial_items (usuario_id, codigo_barras, nombre, marca, descripcion, precio, cantidad, accion, producto_id)
    VALUES (auth.uid(), v_codigo, v_nombre, v_marca, v_descripcion, p_precio, p_cantidad, p_accion, v_producto_id)
    ON CONFLICT (usuario_id, codigo_barras) WHERE codigo_barras IS NOT NULL
    DO UPDATE SET cantidad = carga_inicial_items.cantidad + EXCLUDED.cantidad,
                  nombre = EXCLUDED.nombre, marca = EXCLUDED.marca, descripcion = EXCLUDED.descripcion,
                  precio = EXCLUDED.precio, accion = EXCLUDED.accion, producto_id = EXCLUDED.producto_id,
                  updated_at = now()
    RETURNING * INTO v_fila;
  ELSE
    INSERT INTO carga_inicial_items (usuario_id, codigo_barras, nombre, marca, descripcion, precio, cantidad, accion, producto_id)
    VALUES (auth.uid(), NULL, v_nombre, v_marca, v_descripcion, p_precio, p_cantidad, p_accion, NULL)
    RETURNING * INTO v_fila;
  END IF;

  UPDATE carga_inicial_operaciones SET item_id = v_fila.id WHERE client_id = p_client_id;  -- docs/34c

  RETURN v_fila;
END;
$$;

-- ============================================================
-- 3. carga_inicial_editar_producto + p_client_id
-- ============================================================
DROP FUNCTION carga_inicial_editar_producto(UUID, TEXT, TEXT, TEXT, NUMERIC, NUMERIC);

CREATE FUNCTION carga_inicial_editar_producto(
  p_client_id UUID,
  p_producto_id UUID,
  p_nombre TEXT,
  p_marca TEXT,
  p_descripcion TEXT,
  p_precio NUMERIC,
  p_cantidad_local NUMERIC
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_nombre TEXT := NULLIF(btrim(COALESCE(p_nombre, '')), '');
  v_marca TEXT := NULLIF(btrim(COALESCE(p_marca, '')), '');
  v_descripcion TEXT := NULLIF(btrim(COALESCE(p_descripcion, '')), '');
  v_prod productos%ROWTYPE;
  v_precio_manual NUMERIC;
  v_actual NUMERIC;
  v_delta NUMERIC := 0;
  v_resultado JSONB;
BEGIN
  PERFORM carga_inicial_verificar_acceso();

  -- docs/34c: operación ya aplicada → lo que devolvió la primera vez.
  IF NOT carga_inicial_reclamar_operacion(p_client_id, 'editar_producto') THEN
    RETURN (SELECT resultado FROM carga_inicial_operaciones WHERE client_id = p_client_id);
  END IF;

  SELECT * INTO v_prod FROM productos WHERE id = p_producto_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Producto no encontrado';
  END IF;
  IF v_nombre IS NULL THEN
    RAISE EXCEPTION 'El nombre es obligatorio';
  END IF;
  IF p_precio IS NOT NULL AND p_precio <= 0 THEN
    RAISE EXCEPTION 'El precio tiene que ser mayor a 0';
  END IF;
  IF p_cantidad_local IS NOT NULL AND p_cantidad_local < 0 THEN
    RAISE EXCEPTION 'La cantidad no puede ser negativa';
  END IF;
  IF p_precio IS NOT NULL AND v_prod.costo IS NOT NULL AND p_precio <> v_prod.precio_venta THEN
    RAISE EXCEPTION 'Precio calculado por costo: este producto tiene costo cargado y su precio sale de la fórmula';
  END IF;

  v_precio_manual := CASE WHEN v_prod.costo IS NULL AND p_precio IS NOT NULL THEN p_precio ELSE v_prod.precio_manual END;

  IF v_nombre IS DISTINCT FROM v_prod.nombre OR v_marca IS DISTINCT FROM v_prod.marca
     OR v_descripcion IS DISTINCT FROM v_prod.descripcion OR v_precio_manual IS DISTINCT FROM v_prod.precio_manual THEN
    UPDATE productos
    SET nombre = v_nombre, marca = v_marca, descripcion = v_descripcion,
        precio_manual = v_precio_manual, updated_at = now()
    WHERE id = p_producto_id;
  END IF;

  IF p_cantidad_local IS NOT NULL THEN
    SELECT cantidad INTO v_actual FROM stock_ubicaciones
    WHERE producto_id = p_producto_id AND ubicacion = 'local' FOR UPDATE;
    v_actual := COALESCE(v_actual, 0);
    v_delta := p_cantidad_local - v_actual;

    IF v_delta <> 0 THEN
      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, usuario_id)
      VALUES (p_producto_id, 'local', 'inicial', v_delta,
              format('Carga inicial: corrección de cantidad (%s → %s)', v_actual, p_cantidad_local), auth.uid());

      INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
      VALUES (p_producto_id, 'local', p_cantidad_local)
      ON CONFLICT (producto_id, ubicacion) DO UPDATE SET cantidad = EXCLUDED.cantidad;
    END IF;
  END IF;

  v_resultado := jsonb_build_object(
    'producto_id', p_producto_id,
    'precio_venta', (SELECT precio_venta FROM productos WHERE id = p_producto_id),
    'cantidad_anterior', v_actual,
    'cantidad_nueva', p_cantidad_local,
    'delta', v_delta
  );

  UPDATE carga_inicial_operaciones SET item_id = p_producto_id, resultado = v_resultado  -- docs/34c
  WHERE client_id = p_client_id;

  RETURN v_resultado;
END;
$$;

-- ============================================================
-- Permisos
-- ============================================================
GRANT SELECT ON carga_inicial_operaciones TO authenticated;
GRANT EXECUTE ON FUNCTION carga_inicial_guardar_item(UUID, TEXT, TEXT, TEXT, TEXT, NUMERIC, NUMERIC, TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION carga_inicial_editar_producto(UUID, UUID, TEXT, TEXT, TEXT, NUMERIC, NUMERIC) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (después de A)
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- B1. Una sola firma de cada RPC, con p_client_id primero.
SELECT p.oid::regprocedure FROM pg_proc p
WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('carga_inicial_guardar_item', 'carga_inicial_editar_producto', 'carga_inicial_reclamar_operacion');

-- B2. Tabla con RLS y su policy (esperado: true, una policy SELECT).
SELECT relrowsecurity FROM pg_class WHERE oid = 'public.carga_inicial_operaciones'::regclass;
SELECT policyname, cmd FROM pg_policies WHERE tablename = 'carga_inicial_operaciones';

-- B3. reclamar_operacion no es invocable desde la API (esperado: false, false).
SELECT has_function_privilege('authenticated', 'carga_inicial_reclamar_operacion(uuid, text)', 'EXECUTE'),
       has_function_privilege('anon', 'carga_inicial_reclamar_operacion(uuid, text)', 'EXECUTE');


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — TESTS (después de A). Todo dentro de BEGIN … ROLLBACK: no deja datos.
-- Usuarios: el primer admin activo (A) y el primer cajero activo (B). Códigos 'TEST34C-…'.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE FUNCTION pg_temp.como(p_usuario UUID) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_usuario, 'role', 'authenticated')::text, true);
$$;

CREATE FUNCTION pg_temp.stock_local(p_producto UUID) RETURNS NUMERIC LANGUAGE sql AS $$
  SELECT COALESCE((SELECT cantidad FROM stock_ubicaciones WHERE producto_id = p_producto AND ubicacion = 'local'), 0);
$$;

DO $$
DECLARE
  v_admin UUID;
  v_cajero UUID;
  c1 UUID := gen_random_uuid();
  c2 UUID := gen_random_uuid();
  c3 UUID := gen_random_uuid();
  v_f1 carga_inicial_items%ROWTYPE;
  v_f2 carga_inicial_items%ROWTYPE;
  v_res JSONB;
  v_res2 JSONB;
  v_prod UUID;
  v_ok BOOLEAN;
BEGIN
  SELECT id INTO v_admin FROM perfiles WHERE rol = 'admin' AND activo ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cajero FROM perfiles WHERE rol = 'cajero' AND activo ORDER BY created_at LIMIT 1;
  ASSERT v_admin IS NOT NULL AND v_cajero IS NOT NULL, 'setup: falta admin o cajero activo';
  UPDATE configuracion SET carga_inicial_abierta = true;
  PERFORM pg_temp.como(v_cajero);

  -- ── C1: mismo client_id dos veces (alta) → una sola fila, una sola cantidad ──
  v_f1 := carga_inicial_guardar_item(c1, 'TEST34C-1', 'Prueba', NULL, NULL, 1000, 3, 'nuevo');
  v_f2 := carga_inicial_guardar_item(c1, 'TEST34C-1', 'Prueba', NULL, NULL, 1000, 3, 'nuevo');
  ASSERT v_f2.id = v_f1.id AND v_f2.cantidad = 3, 'C1: el reintento devuelve la misma fila, sin sumar (' || v_f2.cantidad || ')';
  ASSERT (SELECT cantidad FROM carga_inicial_items WHERE id = v_f1.id) = 3, 'C1: cantidad 3';
  ASSERT (SELECT count(*) FROM carga_inicial_operaciones WHERE client_id = c1 AND item_id = v_f1.id) = 1, 'C1: operación registrada';

  -- ── C2: alta que suma a mi fila del mismo código, repetida → suma una sola vez ──
  v_f2 := carga_inicial_guardar_item(c2, 'TEST34C-1', 'Prueba', NULL, NULL, 1000, 2, 'nuevo');
  ASSERT v_f2.id = v_f1.id AND v_f2.cantidad = 5, 'C2: suma a la fila existente (3 + 2)';
  v_f2 := carga_inicial_guardar_item(c2, 'TEST34C-1', 'Prueba', NULL, NULL, 1000, 2, 'nuevo');
  ASSERT v_f2.cantidad = 5 AND (SELECT cantidad FROM carga_inicial_items WHERE id = v_f1.id) = 5,
         'C2: el reintento no vuelve a sumar';
  -- Un client_id NUEVO con el mismo código sí suma (es otra carga del mismo producto).
  v_f2 := carga_inicial_guardar_item(gen_random_uuid(), 'TEST34C-1', 'Prueba', NULL, NULL, 1000, 1, 'nuevo');
  ASSERT v_f2.cantidad = 6, 'C2: otra operación suma';

  -- ── C3: edición (p_id) fija el valor, no suma ──
  v_f2 := carga_inicial_guardar_item(gen_random_uuid(), 'TEST34C-1', 'Prueba', NULL, NULL, 1000, 7, 'nuevo', v_f1.id);
  ASSERT v_f2.cantidad = 7, 'C3: edición fija 7';
  v_f2 := carga_inicial_guardar_item(gen_random_uuid(), 'TEST34C-1', 'Prueba', NULL, NULL, 1000, 7, 'nuevo', v_f1.id);
  ASSERT v_f2.cantidad = 7, 'C3: repetir la edición (otro client_id) sigue en 7';

  -- ── C4: un error no consume el client_id ──
  v_ok := false;
  BEGIN
    PERFORM carga_inicial_guardar_item(c3, 'TEST34C-2', 'Prueba 2', NULL, NULL, 0, 1, 'nuevo');
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM = 'El precio tiene que ser mayor a 0';
  END;
  ASSERT v_ok, 'C4: precio 0 falla';
  ASSERT NOT EXISTS (SELECT 1 FROM carga_inicial_operaciones WHERE client_id = c3), 'C4: el client_id no quedó registrado';
  v_f2 := carga_inicial_guardar_item(c3, 'TEST34C-2', 'Prueba 2', NULL, NULL, 500, 1, 'nuevo');
  ASSERT v_f2.id IS NOT NULL AND v_f2.cantidad = 1, 'C4: corregido, el mismo client_id aplica';

  -- ── C5: client_id de otro usuario, o null → error ──
  PERFORM pg_temp.como(v_admin);
  v_ok := false;
  BEGIN
    PERFORM carga_inicial_guardar_item(c1, 'TEST34C-9', 'x', NULL, NULL, 100, 1, 'nuevo');
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM = 'Identificador de operación inválido';
  END;
  ASSERT v_ok, 'C5: client_id ajeno falla';
  v_ok := false;
  BEGIN
    PERFORM carga_inicial_guardar_item(NULL, 'TEST34C-9', 'x', NULL, NULL, 100, 1, 'nuevo');
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM LIKE 'Falta el identificador%';
  END;
  ASSERT v_ok, 'C5: sin client_id falla';

  -- ── C6: finalizar dos veces seguidas no aplica dos veces ──
  PERFORM pg_temp.como(v_cajero);
  v_res := carga_inicial_finalizar();
  ASSERT (v_res->>'items')::INT = 2, 'C6: primera vez aplica 2 filas';
  v_prod := carga_inicial_producto_por_codigo('TEST34C-1');
  ASSERT pg_temp.stock_local(v_prod) = 7, 'C6: stock 7';
  v_res := carga_inicial_finalizar();
  ASSERT (v_res->>'items')::INT = 0, 'C6: la segunda no encuentra borradores';
  ASSERT pg_temp.stock_local(v_prod) = 7, 'C6: el stock no cambia';

  -- Reintento de un guardado cuya fila ya se finalizó → solo el id, no crea nada.
  v_f2 := carga_inicial_guardar_item(c1, 'TEST34C-1', 'Prueba', NULL, NULL, 1000, 3, 'nuevo');
  ASSERT v_f2.id = v_f1.id AND v_f2.nombre IS NULL, 'C6: fila finalizada → solo el id';
  ASSERT NOT EXISTS (SELECT 1 FROM carga_inicial_items WHERE usuario_id = v_cajero), 'C6: no se recreó el borrador';

  -- ── C7: editar_producto con el mismo client_id → un solo movimiento ──
  -- Un client_id de otra operación (c2 es de guardar_item) falla.
  v_ok := false;
  BEGIN
    PERFORM carga_inicial_editar_producto(c2, v_prod, 'Prueba', NULL, NULL, NULL, 4);
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM = 'Identificador de operación inválido';
  END;
  ASSERT v_ok, 'C7: client_id de otra operación falla';
  c3 := gen_random_uuid();
  v_res := carga_inicial_editar_producto(c3, v_prod, 'Prueba', NULL, NULL, NULL, 4);
  ASSERT (v_res->>'delta')::NUMERIC = -3, 'C7: delta −3 (7 → 4)';
  v_res2 := carga_inicial_editar_producto(c3, v_prod, 'Prueba', NULL, NULL, NULL, 4);
  ASSERT v_res2 = v_res, 'C7: el reintento devuelve el resultado original';
  ASSERT (SELECT count(*) FROM movimientos_stock WHERE producto_id = v_prod AND tipo = 'inicial' AND cantidad = -3) = 1,
         'C7: un solo movimiento −3';
  ASSERT pg_temp.stock_local(v_prod) = 4, 'C7: stock 4';

  RAISE NOTICE 'docs/34c: todos los tests pasaron';
END;
$$;

ROLLBACK;
