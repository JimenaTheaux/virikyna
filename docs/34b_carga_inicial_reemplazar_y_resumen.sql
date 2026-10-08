-- 34b — Carga inicial: "usar mis datos" sobre borradores de otros, resumen con valor, datos_reset_at
--
-- docs/06_estructura_de_datos.md, sección 24 (subsección 34b), tiene el detalle. Correr en el SQL
-- Editor de Supabase (proyecto ccpinvtleqlsukcqnili), después de 34:
--   PARTE A — cambios (una transacción). Una sola vez.
--   PARTE B — verificación. Se puede repetir.
--   PARTE C — tests, dentro de BEGIN … ROLLBACK. Se puede repetir; no deja datos.
--
-- Contexto (base real 2026-10-08): docs/34 aplicado tal cual el archivo (cuerpos de
-- carga_inicial_guardar_item y carga_inicial_finalizar comparados por md5 contra el archivo).
--
-- Qué hace:
--   1. configuracion.datos_reset_at TIMESTAMPTZ (null). Marca "se vaciaron los datos": las filas
--      de carga inicial que una pantalla guardó en el navegador (localStorage) con una marca
--      anterior se descartan. Lo pone el script de vaciado de la base (UPDATE configuracion SET
--      datos_reset_at = now()); ninguna RPC lo toca.
--   2. carga_inicial_guardar_item: 'reemplazar' ya no exige que el producto exista — alcanza con
--      que haya código. Es el "Usar mis datos" de la pantalla cuando el código solo está en
--      borradores de otros usuarios (producto_id queda null). 'sumar' sigue exigiendo producto.
--   3. carga_inicial_finalizar: 'reemplazar' sin producto → si el código existe al finalizar
--      (otro usuario finalizó antes), reemplaza datos y suma stock; si no existe, lo crea con mis
--      datos. Mismo criterio si el alta choca con otra simultánea (ON CONFLICT).
--   4. carga_inicial_resumen: + valor (unidades × precio_venta actual), total y por usuario;
--      + abierta_por_nombre / cerrada_por_nombre.


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios (una transacción)
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ============================================================
-- 1. configuracion.datos_reset_at
-- ============================================================
ALTER TABLE configuracion ADD COLUMN datos_reset_at TIMESTAMPTZ;

COMMENT ON COLUMN configuracion.datos_reset_at IS
  'Último vaciado de datos. Lo pone el script de reset; las pantallas descartan lo guardado en el navegador con una marca anterior.';

-- ============================================================
-- 2. carga_inicial_guardar_item — 'reemplazar' sin producto
-- ============================================================
CREATE OR REPLACE FUNCTION carga_inicial_guardar_item(
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
  -- docs/34b: 'reemplazar' sin producto vale (código en borradores de otros: "usar mis datos").
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

  RETURN v_fila;
END;
$$;

-- ============================================================
-- 3. carga_inicial_finalizar — 'reemplazar' sin producto
-- ============================================================
-- Mismo cuerpo que docs/34 salvo el bloque de producto: primero se resuelve o se crea el
-- producto, y después —si no se acaba de crear— se decide según la acción. Así 'reemplazar' sin
-- producto_id reemplaza datos cuando el código apareció en el medio, igual que con producto.
CREATE OR REPLACE FUNCTION carga_inicial_finalizar() RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_item carga_inicial_items%ROWTYPE;
  v_producto_id UUID;
  v_codigo TEXT;
  v_generado BOOLEAN;
  v_creado BOOLEAN;
  v_costo NUMERIC;
  v_precio_venta NUMERIC;
  v_items INT := 0;
  v_creados INT := 0;
  v_reemplazados INT := 0;
  v_sumados INT := 0;
  v_fusionados INT := 0;
  v_precios_no_aplicados INT := 0;
  v_unidades NUMERIC := 0;
  v_codigos JSONB := '[]'::JSONB;
BEGIN
  PERFORM carga_inicial_verificar_acceso();

  FOR v_item IN
    SELECT * FROM carga_inicial_items WHERE usuario_id = auth.uid() ORDER BY created_at, id FOR UPDATE
  LOOP
    v_items := v_items + 1;
    v_producto_id := NULL;
    v_generado := false;
    v_creado := false;

    -- Producto: el que se resolvió al guardar el borrador, o el que tenga el código ahora.
    IF v_item.producto_id IS NOT NULL THEN
      SELECT id INTO v_producto_id FROM productos WHERE id = v_item.producto_id;
    END IF;
    IF v_producto_id IS NULL AND v_item.codigo_barras IS NOT NULL THEN
      v_producto_id := carga_inicial_producto_por_codigo(v_item.codigo_barras);
    END IF;

    IF v_producto_id IS NULL THEN
      -- Alta con mis datos. Si el borrador no tiene código, se genera uno.
      v_codigo := v_item.codigo_barras;
      IF v_codigo IS NULL THEN
        v_codigo := generar_codigo_interno();
        v_generado := true;
      END IF;

      INSERT INTO productos (nombre, marca, descripcion, codigo_barras, costo, precio_manual,
                             proveedor_id, margen_1, margen_2, iva_porcentaje, estado)
      VALUES (v_item.nombre, v_item.marca, v_item.descripcion, v_codigo, NULL, v_item.precio,
              NULL, 0, 0, 21, 'activo')
      ON CONFLICT (codigo_barras) DO NOTHING
      RETURNING id INTO v_producto_id;

      IF v_producto_id IS NOT NULL THEN
        v_creado := true;
        v_creados := v_creados + 1;
        IF v_generado THEN
          v_codigos := v_codigos || jsonb_build_object('producto_id', v_producto_id, 'nombre', v_item.nombre, 'codigo', v_codigo);
        END IF;
      ELSE
        -- Otro usuario lo dio de alta en el medio (el ON CONFLICT espera a que su transacción
        -- confirme): se sigue con ese producto según la acción.
        SELECT id INTO v_producto_id FROM productos WHERE codigo_barras = v_codigo;
      END IF;
    END IF;

    IF NOT v_creado THEN
      IF v_item.accion = 'reemplazar' THEN
        SELECT costo, precio_venta INTO v_costo, v_precio_venta FROM productos WHERE id = v_producto_id FOR UPDATE;
        UPDATE productos
        SET nombre = v_item.nombre,
            marca = v_item.marca,
            descripcion = v_item.descripcion,
            precio_manual = CASE WHEN v_costo IS NULL THEN v_item.precio ELSE precio_manual END,
            updated_at = now()
        WHERE id = v_producto_id;
        -- Con costo, el precio sale de la fórmula: no se pisa.
        IF v_costo IS NOT NULL AND v_item.precio <> v_precio_venta THEN
          v_precios_no_aplicados := v_precios_no_aplicados + 1;
        END IF;
        v_reemplazados := v_reemplazados + 1;
      ELSIF v_item.accion = 'nuevo' THEN
        -- Era nuevo al guardarlo, pero el código apareció después: se suma.
        v_fusionados := v_fusionados + 1;
      ELSE
        v_sumados := v_sumados + 1;
      END IF;
    END IF;

    -- Stock: siempre en 'local', sumando.
    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
    VALUES (v_producto_id, 'local', 'inicial', v_item.cantidad, 'Carga inicial', v_item.id, auth.uid());

    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES (v_producto_id, 'local', v_item.cantidad)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad + EXCLUDED.cantidad;

    v_unidades := v_unidades + v_item.cantidad;
  END LOOP;

  DELETE FROM carga_inicial_items WHERE usuario_id = auth.uid();

  RETURN jsonb_build_object(
    'items', v_items,
    'productos_creados', v_creados,
    'productos_reemplazados', v_reemplazados,
    'stock_sumado', v_sumados,
    'fusionados', v_fusionados,
    'precios_no_aplicados', v_precios_no_aplicados,
    'unidades', v_unidades,
    'codigos_generados', v_codigos
  );
END;
$$;

-- ============================================================
-- 4. carga_inicial_resumen — + valor y nombres
-- ============================================================
CREATE OR REPLACE FUNCTION carga_inicial_resumen() RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_resultado JSONB;
BEGIN
  PERFORM carga_inicial_verificar_acceso();

  -- Movimientos 'inicial' por usuario y producto, valuados al precio de venta actual.
  WITH mov AS (
    SELECT m.usuario_id, m.producto_id, sum(m.cantidad) AS unidades
    FROM movimientos_stock m WHERE m.tipo = 'inicial'
    GROUP BY m.usuario_id, m.producto_id
  ),
  aplicado AS (
    SELECT mov.usuario_id, count(DISTINCT mov.producto_id) AS productos,
           COALESCE(sum(mov.unidades), 0) AS unidades,
           COALESCE(sum(mov.unidades * p.precio_venta), 0) AS valor
    FROM mov JOIN productos p ON p.id = mov.producto_id
    GROUP BY mov.usuario_id
  ),
  pendiente AS (
    SELECT usuario_id, count(*) AS borradores, COALESCE(sum(cantidad), 0) AS unidades
    FROM carga_inicial_items GROUP BY usuario_id
  ),
  por_usuario AS (
    SELECT COALESCE(a.usuario_id, p.usuario_id) AS usuario_id,
           COALESCE(a.productos, 0) AS productos, COALESCE(a.unidades, 0) AS unidades,
           COALESCE(a.valor, 0) AS valor,
           COALESCE(p.borradores, 0) AS borradores, COALESCE(p.unidades, 0) AS unidades_borradores
    FROM aplicado a FULL JOIN pendiente p ON p.usuario_id = a.usuario_id
  )
  SELECT jsonb_build_object(
    'abierta', c.carga_inicial_abierta,
    'abierta_at', c.abierta_at,
    'abierta_por_nombre', (SELECT nombre FROM perfiles WHERE id = c.abierta_por),
    'cerrada_at', c.cerrada_at,
    'cerrada_por_nombre', (SELECT nombre FROM perfiles WHERE id = c.cerrada_por),
    'productos', (SELECT count(DISTINCT producto_id) FROM movimientos_stock WHERE tipo = 'inicial'),
    'unidades', (SELECT COALESCE(sum(cantidad), 0) FROM movimientos_stock WHERE tipo = 'inicial'),
    'valor', (SELECT COALESCE(sum(mov.unidades * p.precio_venta), 0) FROM mov JOIN productos p ON p.id = mov.producto_id),
    'borradores', (SELECT count(*) FROM carga_inicial_items),
    'unidades_borradores', (SELECT COALESCE(sum(cantidad), 0) FROM carga_inicial_items),
    'por_usuario', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'usuario_id', pu.usuario_id, 'nombre', u.nombre,
               'productos', pu.productos, 'unidades', pu.unidades, 'valor', pu.valor,
               'borradores', pu.borradores, 'unidades_borradores', pu.unidades_borradores)
             ORDER BY u.nombre)
      FROM por_usuario pu JOIN perfiles u ON u.id = pu.usuario_id), '[]'::JSONB)
  )
  INTO v_resultado
  FROM configuracion c;

  RETURN v_resultado;
END;
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (después de A)
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- B1. Columna nueva (esperado: datos_reset_at, timestamp with time zone, YES).
SELECT column_name, data_type, is_nullable FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'configuracion' AND column_name = 'datos_reset_at';

-- B2. Las funciones siguen con una sola firma cada una.
SELECT p.oid::regprocedure, p.prosecdef FROM pg_proc p
WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('carga_inicial_guardar_item', 'carga_inicial_finalizar', 'carga_inicial_resumen');


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — TESTS (después de A). Todo dentro de BEGIN … ROLLBACK: no deja datos.
-- Usuarios: el primer admin activo (A) y el primer cajero activo (B). Códigos 'TEST34B-…'.
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
  v_borrador carga_inicial_items%ROWTYPE;
  v_prod productos%ROWTYPE;
  v_res JSONB;
  v_ok BOOLEAN;
  v_valor_antes NUMERIC;
BEGIN
  SELECT id INTO v_admin FROM perfiles WHERE rol = 'admin' AND activo ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cajero FROM perfiles WHERE rol = 'cajero' AND activo ORDER BY created_at LIMIT 1;
  ASSERT v_admin IS NOT NULL AND v_cajero IS NOT NULL, 'setup: falta admin o cajero activo';
  UPDATE configuracion SET carga_inicial_abierta = true;
  ASSERT (SELECT datos_reset_at FROM configuracion) IS NULL, 'setup: datos_reset_at arranca null';

  PERFORM pg_temp.como(v_admin);
  v_valor_antes := (carga_inicial_resumen()->>'valor')::NUMERIC;

  -- ── T1: código solo en borradores de otro; "usar mis datos" → reemplazar sin producto ──
  PERFORM pg_temp.como(v_admin);
  PERFORM carga_inicial_guardar_item('TEST34B-1', 'Datos de A', 'Marca A', 'desc A', 1000, 2, 'nuevo');
  PERFORM pg_temp.como(v_cajero);
  v_borrador := carga_inicial_guardar_item('TEST34B-1', 'Datos de B', 'Marca B', 'desc B', 1500, 3, 'reemplazar');
  ASSERT v_borrador.accion = 'reemplazar' AND v_borrador.producto_id IS NULL, 'T1: reemplazar sin producto se guarda';
  -- A finaliza primero (crea con sus datos), B después: reemplaza datos y suma stock.
  PERFORM pg_temp.como(v_admin);
  PERFORM carga_inicial_finalizar();
  PERFORM pg_temp.como(v_cajero);
  v_res := carga_inicial_finalizar();
  ASSERT (v_res->>'productos_reemplazados')::INT = 1 AND (v_res->>'productos_creados')::INT = 0,
         'T1: B reemplaza (no crea): ' || v_res::TEXT;
  SELECT * INTO v_prod FROM productos WHERE codigo_barras = 'TEST34B-1';
  ASSERT v_prod.nombre = 'Datos de B' AND v_prod.marca = 'Marca B' AND v_prod.descripcion = 'desc B'
         AND v_prod.precio_manual = 1500, 'T1: quedan los datos de B';
  ASSERT pg_temp.stock_local(v_prod.id) = 5, 'T1: stock 2 + 3';

  -- ── T2: orden inverso — B (reemplazar) finaliza primero y crea con sus datos; A (nuevo) suma ──
  PERFORM pg_temp.como(v_admin);
  PERFORM carga_inicial_guardar_item('TEST34B-2', 'Datos de A', NULL, NULL, 1000, 2, 'nuevo');
  PERFORM pg_temp.como(v_cajero);
  PERFORM carga_inicial_guardar_item('TEST34B-2', 'Datos de B', NULL, NULL, 1500, 3, 'reemplazar');
  v_res := carga_inicial_finalizar();
  ASSERT (v_res->>'productos_creados')::INT = 1, 'T2: B crea con sus datos';
  PERFORM pg_temp.como(v_admin);
  v_res := carga_inicial_finalizar();
  ASSERT (v_res->>'fusionados')::INT = 1, 'T2: A suma (fusionado)';
  SELECT * INTO v_prod FROM productos WHERE codigo_barras = 'TEST34B-2';
  ASSERT v_prod.nombre = 'Datos de B' AND v_prod.precio_manual = 1500, 'T2: quedan los datos de B';
  ASSERT pg_temp.stock_local(v_prod.id) = 5, 'T2: stock 3 + 2';

  -- ── T3: reemplazar sin producto y sin nadie más → crea ──
  PERFORM carga_inicial_guardar_item('TEST34B-3', 'Solo', NULL, NULL, 700, 1, 'reemplazar');
  v_res := carga_inicial_finalizar();
  ASSERT (v_res->>'productos_creados')::INT = 1, 'T3: crea';
  ASSERT (SELECT precio_manual FROM productos WHERE codigo_barras = 'TEST34B-3') = 700, 'T3: con mis datos';

  -- ── T4: validaciones ──
  v_ok := false;
  BEGIN
    PERFORM carga_inicial_guardar_item('TEST34B-NO', 'x', NULL, NULL, 100, 1, 'sumar');
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM = 'No hay ningún producto con ese código para sumar';
  END;
  ASSERT v_ok, 'T4: sumar sin producto falla';
  v_ok := false;
  BEGIN
    PERFORM carga_inicial_guardar_item(NULL, 'x', NULL, NULL, 100, 1, 'reemplazar');
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM = 'Para reemplazar datos hace falta el código';
  END;
  ASSERT v_ok, 'T4: reemplazar sin código falla';

  -- ── T5: resumen con valor y nombres ──
  UPDATE configuracion SET abierta_por = v_admin;
  v_res := carga_inicial_resumen();
  -- TEST34B-1: 5 × 1500 + TEST34B-2: 5 × 1500 + TEST34B-3: 1 × 700 = 15700
  ASSERT (v_res->>'valor')::NUMERIC - v_valor_antes = 15700, 'T5: valor a precio de venta (+' || ((v_res->>'valor')::NUMERIC - v_valor_antes) || ')';
  ASSERT v_res->>'abierta_por_nombre' = (SELECT nombre FROM perfiles WHERE id = v_admin), 'T5: nombre de quien abrió';
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'por_usuario') u
                 WHERE (u->>'usuario_id')::UUID = v_cajero AND (u->>'valor')::NUMERIC >= 3 * 1500 + 3 * 1500),
         'T5: valor por usuario';

  RAISE NOTICE 'docs/34b: todos los tests pasaron';
END;
$$;

ROLLBACK;
