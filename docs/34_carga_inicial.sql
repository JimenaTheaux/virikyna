-- 34 — Carga inicial de inventario: precio manual, modo "carga inicial" y borradores por usuario
--
-- docs/06_estructura_de_datos.md, sección 24, tiene el detalle. Correr en el SQL Editor de Supabase
-- (proyecto ccpinvtleqlsukcqnili), después de 33:
--   PARTE 0 — enum. Sola, fuera de transacción y ANTES que A: un valor de enum agregado no se puede
--             usar en la misma transacción en la que se creó.
--   PARTE A — cambios (una transacción). Una sola vez.
--   PARTE B — verificación. Se puede repetir.
--   PARTE C — tests, dentro de BEGIN … ROLLBACK. Se puede repetir; no deja datos.
--
-- Contexto (relevado contra la base real el 2026-10-08 con pg_get_functiondef / pg_attribute):
--   - productos.costo NUMERIC(12,2) NOT NULL DEFAULT 0. proveedor_id ya admite null.
--   - precio_calculado (GENERATED STORED) = ROUND(costo × (1+m1/100) × (1+m2/100) × (1+iva/100), 2).
--   - precio_venta     (GENERATED STORED) = redondear_precio_venta(<misma fórmula>) — docs/30.
--     Con costo null las dos dan null solas (aritmética con null + redondear_precio_venta STRICT).
--   - cargar_factura_compra: una sola firma (10 parámetros), cuerpo = docs/33.
--   - actualizar_precios_masivo: cuerpo = docs/06 sección 8 (solo toca costo).
--   - Ninguna vista depende de productos. revertir_edicion restaura todas las columnas de
--     valores_anteriores menos id/created_at/updated_at/precio_venta/precio_calculado, así que ya
--     maneja precio_manual y un costo null (format('%L', NULL) = NULL) sin cambios.
--   - No existe tabla de configuración. tipo_movimiento_stock = venta | compra | ajuste.
--
-- Qué hace:
--   0. tipo_movimiento_stock + 'inicial'.
--   1. productos: costo nullable sin default; precio_manual NUMERIC(12,2) (> 0); CHECK: costo o
--      precio_manual (un producto sin ninguno no tendría precio); precio_venta =
--      COALESCE(precio_manual, redondear_precio_venta(<fórmula>)). El precio manual es exacto, sin
--      redondeo. precio_calculado no cambia: ya es null cuando costo es null.
--   2. configuracion (fila única) con el estado de la carga inicial. Se lee directo; se cambia solo
--      con abrir_carga_inicial / cerrar_carga_inicial (admin).
--   3. codigo_interno_seq + generar_codigo_interno(): EAN-13 '20' + 10 dígitos + verificador.
--   4. carga_inicial_items: borradores de cada usuario.
--   5. RPCs carga_inicial_* (ver cada una). Permitidas con la carga abierta, o siempre a un admin.
--   6. cargar_factura_compra: si la factura le pone costo a un producto, borra su precio_manual.
--   7. actualizar_precios_masivo: a los productos con precio_manual les aplica el % sobre ese
--      precio (con redondeo escalonado); a los de costo, igual que antes.
--   8. Auditoría por trigger en configuracion y carga_inicial_items.


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE 0 — enum (sola, fuera de transacción)
-- ════════════════════════════════════════════════════════════════════════════════════════════
ALTER TYPE tipo_movimiento_stock ADD VALUE IF NOT EXISTS 'inicial';


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios (una transacción)
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ============================================================
-- 1. productos: costo opcional + precio manual
-- ============================================================
ALTER TABLE productos
  ALTER COLUMN costo DROP NOT NULL,
  ALTER COLUMN costo DROP DEFAULT;

ALTER TABLE productos ADD COLUMN precio_manual NUMERIC(12,2);

ALTER TABLE productos
  ADD CONSTRAINT productos_precio_manual_positivo CHECK (precio_manual IS NULL OR precio_manual > 0),
  ADD CONSTRAINT productos_costo_o_precio_manual CHECK (costo IS NOT NULL OR precio_manual IS NOT NULL);

-- Reescribe la tabla y recalcula precio_venta de todas las filas (todas tienen precio_manual null
-- → mismo valor que hoy). No dispara triggers de fila: no genera auditoría.
ALTER TABLE productos ALTER COLUMN precio_venta SET EXPRESSION AS (
  COALESCE(
    precio_manual,
    redondear_precio_venta(costo * (1 + margen_1/100.0) * (1 + margen_2/100.0) * (1 + iva_porcentaje/100.0))
  )
);

COMMENT ON COLUMN productos.precio_manual IS
  'Precio de venta cargado a mano (carga inicial, sin costo). Exacto, sin redondeo. Tiene prioridad sobre la fórmula; cargar_factura_compra lo borra al ponerle costo al producto.';

-- ============================================================
-- 2. configuracion — fila única
-- ============================================================
CREATE TABLE configuracion (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),  -- uuid: auditoria.registro_id es UUID
  fila_unica BOOLEAN NOT NULL DEFAULT true UNIQUE CHECK (fila_unica),
  carga_inicial_abierta BOOLEAN NOT NULL DEFAULT false,
  abierta_at TIMESTAMPTZ,
  abierta_por UUID REFERENCES perfiles(id),
  cerrada_at TIMESTAMPTZ,
  cerrada_por UUID REFERENCES perfiles(id),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO configuracion DEFAULT VALUES;

ALTER TABLE configuracion ENABLE ROW LEVEL SECURITY;

-- Solo lectura para perfiles activos. Sin policies de escritura: se cambia solo por RPC.
CREATE POLICY configuracion_select ON configuracion
  FOR SELECT USING (EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true));

-- ============================================================
-- 3. Código interno EAN-13 (prefijo 20 = uso interno GS1)
-- ============================================================
CREATE SEQUENCE codigo_interno_seq AS BIGINT MINVALUE 1 MAXVALUE 9999999999 NO CYCLE;

-- Dígito verificador EAN-13 de los 12 primeros dígitos: pesos 1-3 desde la izquierda.
CREATE OR REPLACE FUNCTION ean13_digito_verificador(p_doce TEXT) RETURNS INT
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path TO 'public'
AS $$
  SELECT (10 - (SUM(substr(p_doce, i, 1)::INT * CASE WHEN i % 2 = 0 THEN 3 ELSE 1 END) % 10)::INT) % 10
  FROM generate_series(1, 12) AS i;
$$;

-- Formas equivalentes de un código, igual que variantesCodigoBarras (packages/shared/lib/
-- productoBusqueda.ts): sin espacios, y los numéricos de 12/13 dígitos con y sin el 0 inicial.
CREATE OR REPLACE FUNCTION codigo_barras_variantes(p_codigo TEXT) RETURNS TEXT[]
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path TO 'public'
AS $$
  WITH c AS (SELECT regexp_replace(p_codigo, '\s+', '', 'g') AS v)
  SELECT CASE
    WHEN v = '' THEN ARRAY[]::TEXT[]
    WHEN v ~ '^\d{12}$' THEN ARRAY[v, '0' || v]
    WHEN v ~ '^0\d{12}$' THEN ARRAY[v, substr(v, 2)]
    ELSE ARRAY[v]
  END FROM c;
$$;

-- Próximo código libre: no lo usa ningún producto (código de barras o interno) ni ningún borrador.
CREATE OR REPLACE FUNCTION generar_codigo_interno() RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_base TEXT;
  v_codigo TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  LOOP
    v_base := '20' || lpad(nextval('codigo_interno_seq')::TEXT, 10, '0');
    v_codigo := v_base || ean13_digito_verificador(v_base);
    EXIT WHEN NOT EXISTS (SELECT 1 FROM productos WHERE codigo_barras = v_codigo OR codigo_interno = v_codigo)
          AND NOT EXISTS (SELECT 1 FROM carga_inicial_items WHERE codigo_barras = v_codigo);
  END LOOP;

  RETURN v_codigo;
END;
$$;

-- ============================================================
-- 4. carga_inicial_items — borradores
-- ============================================================
CREATE TABLE carga_inicial_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id UUID NOT NULL DEFAULT auth.uid() REFERENCES perfiles(id),
  codigo_barras TEXT CHECK (codigo_barras IS NULL OR btrim(codigo_barras) <> ''),
  nombre TEXT NOT NULL CHECK (btrim(nombre) <> ''),
  marca TEXT,
  descripcion TEXT,
  precio NUMERIC(12,2) NOT NULL CHECK (precio > 0),
  cantidad NUMERIC(10,2) NOT NULL CHECK (cantidad > 0),
  accion TEXT NOT NULL DEFAULT 'nuevo' CHECK (accion IN ('nuevo', 'sumar', 'reemplazar')),
  producto_id UUID REFERENCES productos(id) ON DELETE SET NULL,  -- el producto existente, si el código ya estaba
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_carga_inicial_items_usuario ON carga_inicial_items(usuario_id);
CREATE INDEX idx_carga_inicial_items_codigo ON carga_inicial_items(codigo_barras) WHERE codigo_barras IS NOT NULL;
-- Un código una sola vez por usuario: volver a cargarlo suma la cantidad (carga_inicial_guardar_item).
CREATE UNIQUE INDEX uq_carga_inicial_items_usuario_codigo
  ON carga_inicial_items(usuario_id, codigo_barras) WHERE codigo_barras IS NOT NULL;

ALTER TABLE carga_inicial_items ENABLE ROW LEVEL SECURITY;

-- Cada usuario ve y edita solo sus borradores. Escribirlos directo no saltea nada: solo se aplican
-- con carga_inicial_finalizar, que controla el modo.
CREATE POLICY carga_inicial_items_propios ON carga_inicial_items
  FOR ALL
  USING (usuario_id = auth.uid() AND EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true))
  WITH CHECK (usuario_id = auth.uid() AND EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true));

-- ============================================================
-- 5. RPCs de la carga inicial
-- ============================================================

-- Permiso común: perfil activo, y carga abierta salvo admin.
CREATE OR REPLACE FUNCTION carga_inicial_verificar_acceso() RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_rol rol_usuario;
BEGIN
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid() AND activo = true;
  IF v_rol IS NULL THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF v_rol = 'admin' THEN
    RETURN;
  END IF;
  IF NOT COALESCE((SELECT carga_inicial_abierta FROM configuracion), false) THEN
    RAISE EXCEPTION 'La carga inicial está cerrada. Solo un administrador puede usarla.';
  END IF;
END;
$$;

-- Producto con ese código (o una de sus variantes), el más exacto primero. NULL si no hay.
CREATE OR REPLACE FUNCTION carga_inicial_producto_por_codigo(p_codigo TEXT) RETURNS UUID
LANGUAGE sql STABLE
SET search_path TO 'public'
AS $$
  SELECT p.id FROM productos p
  WHERE p.codigo_barras = ANY(codigo_barras_variantes(p_codigo)) OR p.codigo_interno = p_codigo
  ORDER BY (p.codigo_barras = p_codigo) DESC NULLS LAST, p.created_at
  LIMIT 1;
$$;

-- Lo que hay con un código: el producto (si existe), mi borrador y los borradores de los demás.
CREATE OR REPLACE FUNCTION carga_inicial_buscar_codigo(p_codigo TEXT) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_codigo TEXT := regexp_replace(COALESCE(p_codigo, ''), '\s+', '', 'g');
  v_producto_id UUID;
  v_producto JSONB;
  v_mio JSONB;
  v_otros JSONB;
BEGIN
  PERFORM carga_inicial_verificar_acceso();
  IF v_codigo = '' THEN
    RAISE EXCEPTION 'Ingresá un código';
  END IF;

  v_producto_id := carga_inicial_producto_por_codigo(v_codigo);

  IF v_producto_id IS NOT NULL THEN
    SELECT jsonb_build_object(
             'id', p.id, 'nombre', p.nombre, 'marca', p.marca, 'descripcion', p.descripcion,
             'codigo_barras', p.codigo_barras, 'estado', p.estado,
             'precio_venta', p.precio_venta, 'precio_manual', p.precio_manual,
             'tiene_costo', p.costo IS NOT NULL,
             'stock_local', COALESCE((SELECT s.cantidad FROM stock_ubicaciones s
                                      WHERE s.producto_id = p.id AND s.ubicacion = 'local'), 0))
    INTO v_producto
    FROM productos p WHERE p.id = v_producto_id;
  END IF;

  SELECT to_jsonb(i) INTO v_mio
  FROM carga_inicial_items i
  WHERE i.usuario_id = auth.uid() AND i.codigo_barras = ANY(codigo_barras_variantes(v_codigo))
  LIMIT 1;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', i.id, 'usuario_id', i.usuario_id, 'usuario_nombre', u.nombre,
           'nombre', i.nombre, 'marca', i.marca, 'precio', i.precio, 'cantidad', i.cantidad,
           'accion', i.accion, 'updated_at', i.updated_at) ORDER BY i.updated_at), '[]'::JSONB)
  INTO v_otros
  FROM carga_inicial_items i
  JOIN perfiles u ON u.id = i.usuario_id
  WHERE i.usuario_id <> auth.uid() AND i.codigo_barras = ANY(codigo_barras_variantes(v_codigo));

  RETURN jsonb_build_object('codigo', v_codigo, 'producto', v_producto,
                            'mi_borrador', v_mio, 'borradores_otros', v_otros);
END;
$$;

-- Alta/edición de un borrador propio. Sin p_id y con un código que ya está en mis borradores:
-- suma la cantidad y pisa el resto con lo nuevo.
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
  IF p_accion IN ('sumar', 'reemplazar') AND v_producto_id IS NULL THEN
    RAISE EXCEPTION 'No hay ningún producto con ese código para %', p_accion;
  END IF;
  IF p_accion = 'reemplazar' THEN
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

CREATE OR REPLACE FUNCTION carga_inicial_eliminar_item(p_id UUID) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  PERFORM carga_inicial_verificar_acceso();
  DELETE FROM carga_inicial_items WHERE id = p_id AND usuario_id = auth.uid();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Borrador no encontrado';
  END IF;
END;
$$;

-- Aplica todos mis borradores en una transacción. Ver docs/06 sección 24 para las reglas.
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

    -- Producto: el que se resolvió al guardar el borrador, o el que tenga el código ahora.
    IF v_item.producto_id IS NOT NULL THEN
      SELECT id INTO v_producto_id FROM productos WHERE id = v_item.producto_id;
    END IF;
    IF v_producto_id IS NULL AND v_item.codigo_barras IS NOT NULL THEN
      v_producto_id := carga_inicial_producto_por_codigo(v_item.codigo_barras);
    END IF;

    IF v_producto_id IS NULL THEN
      -- Alta. Si el borrador no tiene código, se genera uno.
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

      IF v_producto_id IS NULL THEN
        -- Otro usuario lo dio de alta en el medio (el ON CONFLICT espera a que su transacción
        -- confirme): se suma el stock a ese producto.
        SELECT id INTO v_producto_id FROM productos WHERE codigo_barras = v_codigo;
        v_fusionados := v_fusionados + 1;
      ELSE
        v_creados := v_creados + 1;
        IF v_generado THEN
          v_codigos := v_codigos || jsonb_build_object('producto_id', v_producto_id, 'nombre', v_item.nombre, 'codigo', v_codigo);
        END IF;
      END IF;

    ELSIF v_item.accion = 'reemplazar' THEN
      SELECT costo, precio_venta INTO v_costo, v_precio_venta FROM productos WHERE id = v_producto_id FOR UPDATE;
      UPDATE productos
      SET nombre = v_item.nombre,
          marca = v_item.marca,
          descripcion = v_item.descripcion,
          precio_manual = CASE WHEN v_costo IS NULL THEN v_item.precio ELSE precio_manual END,
          updated_at = now()
      WHERE id = v_producto_id;
      -- Con costo, el precio sale de la fórmula: no se pisa (el borrador se validó al guardarlo,
      -- pero el costo pudo aparecer después).
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

-- Edición desde la vista de inventario total. p_precio null = no tocar el precio;
-- p_cantidad_local null = no tocar el stock.
CREATE OR REPLACE FUNCTION carga_inicial_editar_producto(
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
BEGIN
  PERFORM carga_inicial_verificar_acceso();

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
  -- Mandar el mismo precio que ya tiene no es un cambio (la pantalla manda siempre el actual).
  IF p_precio IS NOT NULL AND v_prod.costo IS NOT NULL AND p_precio <> v_prod.precio_venta THEN
    RAISE EXCEPTION 'Precio calculado por costo: este producto tiene costo cargado y su precio sale de la fórmula';
  END IF;

  v_precio_manual := CASE WHEN v_prod.costo IS NULL AND p_precio IS NOT NULL THEN p_precio ELSE v_prod.precio_manual END;

  -- Sin cambios, sin UPDATE (y sin fila de auditoría).
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

      -- Valor absoluto: la fila está bloqueada, así que coincide con actual + delta.
      INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
      VALUES (p_producto_id, 'local', p_cantidad_local)
      ON CONFLICT (producto_id, ubicacion) DO UPDATE SET cantidad = EXCLUDED.cantidad;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'producto_id', p_producto_id,
    'precio_venta', (SELECT precio_venta FROM productos WHERE id = p_producto_id),
    'cantidad_anterior', v_actual,
    'cantidad_nueva', p_cantidad_local,
    'delta', v_delta
  );
END;
$$;

-- Avance de la carga: lo aplicado (movimientos 'inicial'), lo pendiente (borradores) y por usuario.
CREATE OR REPLACE FUNCTION carga_inicial_resumen() RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_resultado JSONB;
BEGIN
  PERFORM carga_inicial_verificar_acceso();

  WITH aplicado AS (
    SELECT usuario_id, count(DISTINCT producto_id) AS productos, COALESCE(sum(cantidad), 0) AS unidades
    FROM movimientos_stock WHERE tipo = 'inicial' GROUP BY usuario_id
  ),
  pendiente AS (
    SELECT usuario_id, count(*) AS borradores, COALESCE(sum(cantidad), 0) AS unidades
    FROM carga_inicial_items GROUP BY usuario_id
  ),
  por_usuario AS (
    SELECT COALESCE(a.usuario_id, p.usuario_id) AS usuario_id,
           COALESCE(a.productos, 0) AS productos, COALESCE(a.unidades, 0) AS unidades,
           COALESCE(p.borradores, 0) AS borradores, COALESCE(p.unidades, 0) AS unidades_borradores
    FROM aplicado a FULL JOIN pendiente p ON p.usuario_id = a.usuario_id
  )
  SELECT jsonb_build_object(
    'abierta', c.carga_inicial_abierta,
    'abierta_at', c.abierta_at,
    'cerrada_at', c.cerrada_at,
    'productos', (SELECT count(DISTINCT producto_id) FROM movimientos_stock WHERE tipo = 'inicial'),
    'unidades', (SELECT COALESCE(sum(cantidad), 0) FROM movimientos_stock WHERE tipo = 'inicial'),
    'borradores', (SELECT count(*) FROM carga_inicial_items),
    'unidades_borradores', (SELECT COALESCE(sum(cantidad), 0) FROM carga_inicial_items),
    'por_usuario', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'usuario_id', pu.usuario_id, 'nombre', u.nombre,
               'productos', pu.productos, 'unidades', pu.unidades,
               'borradores', pu.borradores, 'unidades_borradores', pu.unidades_borradores)
             ORDER BY u.nombre)
      FROM por_usuario pu JOIN perfiles u ON u.id = pu.usuario_id), '[]'::JSONB)
  )
  INTO v_resultado
  FROM configuracion c;

  RETURN v_resultado;
END;
$$;

CREATE OR REPLACE FUNCTION abrir_carga_inicial() RETURNS configuracion
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_fila configuracion;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede abrir la carga inicial';
  END IF;
  IF (SELECT carga_inicial_abierta FROM configuracion) THEN
    RAISE EXCEPTION 'La carga inicial ya está abierta';
  END IF;

  UPDATE configuracion
  SET carga_inicial_abierta = true, abierta_at = now(), abierta_por = auth.uid(),
      cerrada_at = NULL, cerrada_por = NULL, updated_at = now()
  RETURNING * INTO v_fila;
  RETURN v_fila;
END;
$$;

-- Cierra para los cajeros. Los borradores que queden no se borran: el resultado avisa cuántos hay
-- (los de otros usuarios ya no se pueden aplicar hasta reabrir).
CREATE OR REPLACE FUNCTION cerrar_carga_inicial() RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_fila configuracion;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede cerrar la carga inicial';
  END IF;
  IF NOT (SELECT carga_inicial_abierta FROM configuracion) THEN
    RAISE EXCEPTION 'La carga inicial ya está cerrada';
  END IF;

  UPDATE configuracion
  SET carga_inicial_abierta = false, cerrada_at = now(), cerrada_por = auth.uid(), updated_at = now()
  RETURNING * INTO v_fila;

  RETURN jsonb_build_object(
    'configuracion', to_jsonb(v_fila),
    'borradores_pendientes', (SELECT count(*) FROM carga_inicial_items),
    'usuarios_con_borradores', (SELECT count(DISTINCT usuario_id) FROM carga_inicial_items)
  );
END;
$$;

-- ============================================================
-- 6. cargar_factura_compra — al poner costo, borra precio_manual
-- ============================================================
-- Cuerpo = docs/33 (base real 2026-10-08) con tres cambios marcados "docs/34". Misma firma: CREATE
-- OR REPLACE alcanza (no hay sobrecargas).
CREATE OR REPLACE FUNCTION public.cargar_factura_compra(p_proveedor_id uuid, p_tipo_comprobante tipo_comprobante_compra, p_letra letra_comprobante_compra, p_punto_venta text, p_numero_comprobante text, p_fecha_comprobante date, p_fecha_fiscal date, p_forma_pago forma_pago_compra, p_items jsonb, p_copiada_de_id uuid DEFAULT NULL::uuid)
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
  v_cambia_proveedor BOOLEAN;
  v_precio_manual NUMERIC;   -- docs/34
  v_pone_costo BOOLEAN;      -- docs/34
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  -- docs/33: la FK ya lo garantiza; esto da un mensaje legible en vez del error de constraint.
  IF p_copiada_de_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM facturas_compra WHERE id = p_copiada_de_id) THEN
    RAISE EXCEPTION 'La factura que se quiso copiar no existe';
  END IF;

  SELECT COALESCE(SUM((i->>'cantidad')::NUMERIC * (i->>'precio_unitario_sin_iva')::NUMERIC
           * (1 - COALESCE((i->>'descuento_porcentaje')::NUMERIC,0)/100.0)), 0)
  INTO v_total_sin_iva
  FROM jsonb_array_elements(p_items) AS i;

  v_iva := ROUND(v_total_sin_iva * 0.21, 2);
  v_total := v_total_sin_iva + v_iva;

  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, letra, punto_venta, numero_comprobante,
         fecha_comprobante, fecha_fiscal, forma_pago, total_sin_iva, iva, total, usuario_id, copiada_de_id)
  VALUES (p_proveedor_id, p_tipo_comprobante, p_letra, p_punto_venta, p_numero_comprobante,
         p_fecha_comprobante, p_fecha_fiscal, p_forma_pago, v_total_sin_iva, v_iva, v_total, auth.uid(), p_copiada_de_id)
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
    SELECT DISTINCT ON (x.producto_id) x.producto_id, x.precio
    FROM (
      SELECT NULLIF(t.i->>'producto_id','')::UUID AS producto_id,
             (t.i->>'precio_unitario_sin_iva')::NUMERIC AS precio,
             t.ord
      FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(i, ord)
    ) x
    WHERE x.producto_id IS NOT NULL
    ORDER BY x.producto_id, x.ord DESC
  LOOP
    SELECT proveedor_id, costo, precio_manual INTO v_producto_proveedor_id, v_costo_actual, v_precio_manual  -- docs/34
    FROM productos WHERE id = v_row.producto_id FOR UPDATE;

    -- Producto sin proveedor (null): IS DISTINCT FROM da true → toma proveedor y márgenes default.
    v_cambia_proveedor := v_producto_proveedor_id IS DISTINCT FROM p_proveedor_id;
    -- docs/34: la factura le pone costo (no NC/ND, precio > 0). Desde ahí el precio sale de la fórmula.
    v_pone_costo := v_actualiza_costo AND v_row.precio > 0;
    v_costo_nuevo := CASE WHEN v_pone_costo
                          THEN ROUND(v_row.precio, 2) ELSE v_costo_actual END;

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

-- ============================================================
-- 7. actualizar_precios_masivo — también sobre precio_manual
-- ============================================================
CREATE OR REPLACE FUNCTION public.actualizar_precios_masivo(p_porcentaje numeric, p_proveedor_id uuid DEFAULT NULL::uuid, p_producto_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_count INTEGER;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF (p_proveedor_id IS NULL) = (p_producto_ids IS NULL) THEN
    RAISE EXCEPTION 'Especificá exactamente uno: proveedor_id o producto_ids';
  END IF;
  -- docs/34: un precio manual tiene que quedar > 0 (CHECK).
  IF p_porcentaje IS NULL OR p_porcentaje <= -100 THEN
    RAISE EXCEPTION 'El porcentaje tiene que ser mayor a -100';
  END IF;

  -- docs/34: con precio_manual, el % va sobre ese precio con el redondeo escalonado (si el
  -- redondeo da 0 —precio nuevo menor a $50—, queda el valor exacto). Sin precio_manual, sobre
  -- el costo, como antes.
  UPDATE productos
  SET precio_manual = CASE
        WHEN precio_manual IS NULL THEN NULL
        WHEN redondear_precio_venta(precio_manual * (1 + p_porcentaje/100.0)) > 0
          THEN redondear_precio_venta(precio_manual * (1 + p_porcentaje/100.0))
        ELSE ROUND(precio_manual * (1 + p_porcentaje/100.0), 2)
      END,
      costo = CASE WHEN precio_manual IS NULL THEN ROUND(costo * (1 + p_porcentaje/100.0), 2) ELSE costo END
  WHERE (p_proveedor_id IS NOT NULL AND proveedor_id = p_proveedor_id)
     OR (p_producto_ids IS NOT NULL AND id = ANY(p_producto_ids));

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

-- ============================================================
-- 8. Auditoría
-- ============================================================
CREATE TRIGGER trg_auditoria_configuracion
  AFTER INSERT OR UPDATE ON configuracion
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_generica();

CREATE TRIGGER trg_auditoria_carga_inicial_items
  AFTER INSERT OR UPDATE OR DELETE ON carga_inicial_items
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_generica();

-- ============================================================
-- Permisos
-- ============================================================
GRANT SELECT ON configuracion TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON carga_inicial_items TO authenticated;
GRANT EXECUTE ON FUNCTION generar_codigo_interno() TO authenticated;
GRANT EXECUTE ON FUNCTION carga_inicial_buscar_codigo(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION carga_inicial_guardar_item(TEXT, TEXT, TEXT, TEXT, NUMERIC, NUMERIC, TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION carga_inicial_eliminar_item(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION carga_inicial_finalizar() TO authenticated;
GRANT EXECUTE ON FUNCTION carga_inicial_editar_producto(UUID, TEXT, TEXT, TEXT, NUMERIC, NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION carga_inicial_resumen() TO authenticated;
GRANT EXECUTE ON FUNCTION abrir_carga_inicial() TO authenticated;
GRANT EXECUTE ON FUNCTION cerrar_carga_inicial() TO authenticated;

-- PostgREST: refrescar el caché (tablas y funciones nuevas).
NOTIFY pgrst, 'reload schema';

COMMIT;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (después de A)
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- B1. Enum con 'inicial' (esperado: venta, compra, ajuste, inicial).
SELECT enum_range(NULL::tipo_movimiento_stock);

-- B2. productos: costo nullable sin default, precio_manual, expresiones de las generadas.
SELECT a.attname, a.attnotnull, a.attgenerated, pg_get_expr(d.adbin, d.adrelid) AS default_o_expr
FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
WHERE a.attrelid = 'public.productos'::regclass AND a.attname IN ('costo', 'precio_manual', 'precio_calculado', 'precio_venta');
SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
WHERE conrelid = 'public.productos'::regclass AND contype = 'c';

-- B3. Ningún producto cambió de precio con el SET EXPRESSION (esperado: 0 filas).
SELECT id, nombre, precio_venta FROM productos
WHERE precio_manual IS NULL AND precio_venta IS DISTINCT FROM redondear_precio_venta(precio_calculado);

-- B4. configuracion: una fila, cerrada.
SELECT * FROM configuracion;

-- B5. Tablas nuevas con RLS y triggers.
SELECT c.relname, c.relrowsecurity, (SELECT count(*) FROM pg_trigger t WHERE t.tgrelid = c.oid AND NOT t.tgisinternal) AS triggers
FROM pg_class c WHERE c.oid IN ('public.configuracion'::regclass, 'public.carga_inicial_items'::regclass);
SELECT tablename, policyname, cmd FROM pg_policies WHERE tablename IN ('configuracion', 'carga_inicial_items');

-- B6. Funciones nuevas: SECURITY DEFINER (prosecdef) salvo las auxiliares inmutables.
SELECT p.oid::regprocedure, p.prosecdef, p.provolatile FROM pg_proc p
WHERE p.pronamespace = 'public'::regnamespace
  AND (p.proname LIKE 'carga_inicial%' OR p.proname IN ('abrir_carga_inicial', 'cerrar_carga_inicial',
       'generar_codigo_interno', 'ean13_digito_verificador', 'codigo_barras_variantes'))
ORDER BY 1;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — TESTS (después de A). Todo dentro de BEGIN … ROLLBACK: no deja datos.
-- Usuarios: el primer admin activo y el primer cajero activo (auth.uid() vía request.jwt.claims).
-- Productos de prueba con códigos 'TEST34-…'. Si un ASSERT falla, aborta con su mensaje.
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
  v_prov UUID;
  pM UUID; pC UUID; pS UUID; pR UUID; pG UUID; pN UUID;
  v_prod productos%ROWTYPE;
  v_borrador carga_inicial_items%ROWTYPE;
  v_res JSONB;
  v_codigo TEXT;
  v_n INT;
  v_ok BOOLEAN;
  v_msg TEXT;
BEGIN
  SELECT id INTO v_admin FROM perfiles WHERE rol = 'admin' AND activo ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cajero FROM perfiles WHERE rol = 'cajero' AND activo ORDER BY created_at LIMIT 1;
  ASSERT v_admin IS NOT NULL, 'setup: no hay admin activo';
  ASSERT v_cajero IS NOT NULL, 'setup: no hay cajero activo';
  PERFORM pg_temp.como(v_admin);
  UPDATE configuracion SET carga_inicial_abierta = false;  -- arranca cerrada

  -- ── T1: precio manual 6300 queda 6300 (sin redondeo); precio_calculado null ──
  INSERT INTO productos (nombre, codigo_barras, costo, precio_manual) VALUES ('TEST34 manual', 'TEST34-M', NULL, 6300)
  RETURNING id INTO pM;
  SELECT * INTO v_prod FROM productos WHERE id = pM;
  ASSERT v_prod.precio_venta = 6300, 'T1: precio manual 6300 → precio_venta 6300 (dio ' || v_prod.precio_venta || ')';
  ASSERT v_prod.precio_calculado IS NULL, 'T1: sin costo, precio_calculado null';
  -- Precio manual con centavos: exacto.
  UPDATE productos SET precio_manual = 6321.55 WHERE id = pM;
  ASSERT (SELECT precio_venta FROM productos WHERE id = pM) = 6321.55, 'T1: precio manual exacto, sin redondeo';
  UPDATE productos SET precio_manual = 6300 WHERE id = pM;
  -- Sin costo ni precio manual → CHECK.
  v_ok := false;
  BEGIN
    INSERT INTO productos (nombre, costo, precio_manual) VALUES ('TEST34 sin precio', NULL, NULL);
  EXCEPTION WHEN check_violation THEN v_ok := true;
  END;
  ASSERT v_ok, 'T1: un producto sin costo ni precio manual tiene que fallar';

  -- ── T2: +2% sobre manual 6300 → 6426 → 6500 (escalonado); con costo, igual que antes ──
  INSERT INTO productos (nombre, codigo_barras, costo) VALUES ('TEST34 con costo', 'TEST34-C', 1000) RETURNING id INTO pC;
  v_n := actualizar_precios_masivo(2, NULL, ARRAY[pM, pC]);
  ASSERT v_n = 2, 'T2: 2 productos actualizados';
  SELECT * INTO v_prod FROM productos WHERE id = pM;
  ASSERT v_prod.precio_manual = 6500 AND v_prod.precio_venta = 6500 AND v_prod.costo IS NULL,
         'T2: manual 6300 + 2% → 6500 (dio ' || v_prod.precio_manual || ')';
  SELECT * INTO v_prod FROM productos WHERE id = pC;
  ASSERT v_prod.costo = 1020 AND v_prod.precio_manual IS NULL, 'T2: con costo → costo 1000 + 2% = 1020';
  ASSERT v_prod.precio_venta = redondear_precio_venta(1020 * 1.21), 'T2: con costo, precio por fórmula';

  -- ── T3: factura con costo borra precio_manual, aplica fórmula y hereda proveedor/márgenes ──
  INSERT INTO proveedores (razon_social, margen_1_default, margen_2_default) VALUES ('TEST34 Proveedor', 50, 10)
  RETURNING id INTO v_prov;
  ASSERT (SELECT proveedor_id FROM productos WHERE id = pM) IS NULL, 'T3: arranca sin proveedor';
  PERFORM cargar_factura_compra(v_prov, 'factura', 'A', '0001', '00034001', '2026-10-08', NULL, 'contado',
    jsonb_build_array(jsonb_build_object('producto_id', pM, 'descripcion', 'TEST34', 'cantidad', 1,
                                         'precio_unitario_sin_iva', 1000, 'ubicacion', 'local')));
  SELECT * INTO v_prod FROM productos WHERE id = pM;
  ASSERT v_prod.costo = 1000, 'T3: costo = precio de la factura';
  ASSERT v_prod.precio_manual IS NULL, 'T3: precio_manual borrado';
  ASSERT v_prod.proveedor_id = v_prov AND v_prod.margen_1 = 50 AND v_prod.margen_2 = 10,
         'T3: producto sin proveedor recibe proveedor y márgenes default';
  -- 1000 × 1,5 × 1,1 × 1,21 = 1996,50 → resto 496,50 > 200 → 2000
  ASSERT v_prod.precio_calculado = 1996.50 AND v_prod.precio_venta = 2000,
         'T3: precio por fórmula (dio ' || v_prod.precio_calculado || ' / ' || v_prod.precio_venta || ')';
  -- Una nota de crédito no pone costo: un precio manual sobrevive.
  UPDATE productos SET precio_manual = 7000 WHERE id = pM;
  PERFORM cargar_factura_compra(v_prov, 'nota_credito', 'A', '0001', '00034002', '2026-10-08', NULL, 'contado',
    jsonb_build_array(jsonb_build_object('producto_id', pM, 'descripcion', 'TEST34', 'cantidad', 1,
                                         'precio_unitario_sin_iva', 1500, 'ubicacion', 'local')));
  ASSERT (SELECT precio_manual FROM productos WHERE id = pM) = 7000, 'T3: una NC no borra el precio manual';
  -- Mismo costo que ya tenía, pero con precio manual: igual lo borra.
  PERFORM cargar_factura_compra(v_prov, 'factura', 'A', '0001', '00034003', '2026-10-08', NULL, 'contado',
    jsonb_build_array(jsonb_build_object('producto_id', pM, 'descripcion', 'TEST34', 'cantidad', 1,
                                         'precio_unitario_sin_iva', 1000, 'ubicacion', 'local')));
  ASSERT (SELECT precio_manual FROM productos WHERE id = pM) IS NULL, 'T3: factura con el mismo costo igual borra el manual';

  -- ── T4: cajero con modo cerrado → error; admin con modo cerrado → ok ──
  PERFORM pg_temp.como(v_cajero);
  v_ok := false;
  BEGIN
    PERFORM carga_inicial_resumen();
  EXCEPTION WHEN raise_exception THEN
    v_ok := SQLERRM = 'La carga inicial está cerrada. Solo un administrador puede usarla.';
  END;
  ASSERT v_ok, 'T4: cajero con la carga cerrada tiene que fallar con mensaje claro';
  v_ok := false;
  BEGIN
    PERFORM abrir_carga_inicial();
  EXCEPTION WHEN raise_exception THEN v_ok := true;
  END;
  ASSERT v_ok, 'T4: un cajero no puede abrir la carga';

  PERFORM pg_temp.como(v_admin);
  v_borrador := carga_inicial_guardar_item('TEST34-S', 'TEST34 sumar', 'Marca', NULL, 1500, 5, 'nuevo');
  ASSERT v_borrador.id IS NOT NULL AND v_borrador.usuario_id = v_admin, 'T4: admin con la carga cerrada puede guardar';
  v_res := carga_inicial_finalizar();
  ASSERT (v_res->>'productos_creados')::INT = 1, 'T4: admin finaliza con la carga cerrada';
  pS := carga_inicial_producto_por_codigo('TEST34-S');
  ASSERT pg_temp.stock_local(pS) = 5, 'T4: stock inicial 5';
  SELECT * INTO v_prod FROM productos WHERE id = pS;
  ASSERT v_prod.costo IS NULL AND v_prod.precio_manual = 1500 AND v_prod.precio_venta = 1500
         AND v_prod.proveedor_id IS NULL AND v_prod.margen_1 = 0 AND v_prod.iva_porcentaje = 21 AND v_prod.estado = 'activo',
         'T4: producto nuevo sin costo, con precio manual';
  ASSERT (SELECT count(*) FROM movimientos_stock WHERE producto_id = pS AND tipo = 'inicial' AND cantidad = 5) = 1,
         'T4: movimiento inicial +5';
  ASSERT NOT EXISTS (SELECT 1 FROM carga_inicial_items WHERE usuario_id = v_admin), 'T4: finalizar borra mis borradores';

  PERFORM abrir_carga_inicial();
  ASSERT (SELECT carga_inicial_abierta AND abierta_por = v_admin FROM configuracion), 'T4: admin abre la carga';

  -- ── T5: dos usuarios, mismo código, 'sumar' → stock suma ──
  PERFORM pg_temp.como(v_cajero);
  PERFORM carga_inicial_guardar_item('TEST34-S', 'TEST34 sumar', 'Marca', NULL, 1500, 3, 'sumar');
  v_borrador := carga_inicial_guardar_item(' TEST34-S ', 'TEST34 sumar', 'Marca', NULL, 1500, 1, 'sumar');
  ASSERT v_borrador.cantidad = 4 AND v_borrador.producto_id = pS, 'T5: mismo código en mis borradores suma (3 + 1)';
  ASSERT (SELECT count(*) FROM carga_inicial_items WHERE usuario_id = v_cajero) = 1, 'T5: un solo borrador por código';
  PERFORM pg_temp.como(v_admin);
  PERFORM carga_inicial_guardar_item('TEST34-S', 'TEST34 sumar', 'Marca', NULL, 1500, 2, 'sumar');
  v_res := carga_inicial_buscar_codigo('TEST34-S');
  ASSERT (v_res->'producto'->>'id')::UUID = pS AND (v_res->'producto'->>'stock_local')::NUMERIC = 5,
         'T5: buscar devuelve el producto con su stock local';
  ASSERT jsonb_array_length(v_res->'borradores_otros') = 1
         AND (v_res->'borradores_otros'->0->>'usuario_id')::UUID = v_cajero
         AND (v_res->'borradores_otros'->0->>'cantidad')::NUMERIC = 4,
         'T5: buscar muestra el borrador del otro usuario';
  ASSERT (v_res->'mi_borrador'->>'cantidad')::NUMERIC = 2, 'T5: y el mío aparte';
  -- RLS: el cajero ve solo los suyos.
  PERFORM pg_temp.como(v_cajero);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_n FROM carga_inicial_items;
  RESET ROLE;
  ASSERT v_n = 1, 'T5: RLS — el cajero ve solo su borrador (vio ' || v_n || ')';
  v_res := carga_inicial_finalizar();
  ASSERT (v_res->>'stock_sumado')::INT = 1, 'T5: cajero finaliza (sumar)';
  PERFORM pg_temp.como(v_admin);
  PERFORM carga_inicial_finalizar();
  ASSERT pg_temp.stock_local(pS) = 11, 'T5: 5 + 4 + 2 = 11 (dio ' || pg_temp.stock_local(pS) || ')';
  ASSERT (SELECT count(*) FROM movimientos_stock WHERE producto_id = pS AND tipo = 'inicial') = 3, 'T5: 3 movimientos inicial';

  -- ── T6: los dos cargan el mismo código como 'nuevo'; el segundo en finalizar suma ──
  PERFORM pg_temp.como(v_cajero);
  PERFORM carga_inicial_guardar_item('TEST34-N', 'TEST34 doble alta', NULL, NULL, 800, 2, 'nuevo');
  PERFORM pg_temp.como(v_admin);
  PERFORM carga_inicial_guardar_item('TEST34-N', 'TEST34 doble alta (admin)', NULL, NULL, 900, 3, 'nuevo');
  v_res := carga_inicial_finalizar();
  pN := carga_inicial_producto_por_codigo('TEST34-N');
  PERFORM pg_temp.como(v_cajero);
  v_res := carga_inicial_finalizar();
  ASSERT (v_res->>'fusionados')::INT = 1 AND (v_res->>'productos_creados')::INT = 0, 'T6: el segundo alta se fusiona';
  ASSERT pg_temp.stock_local(pN) = 5, 'T6: stock 3 + 2';
  ASSERT (SELECT count(*) FROM productos WHERE codigo_barras = 'TEST34-N') = 1, 'T6: un solo producto';
  -- Y 'nuevo' con un código que ya existe → error claro al guardar.
  v_ok := false;
  BEGIN
    PERFORM carga_inicial_guardar_item('TEST34-N', 'otro', NULL, NULL, 800, 1, 'nuevo');
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM LIKE 'Ya existe un producto con el código TEST34-N%';
  END;
  ASSERT v_ok, 'T6: nuevo con código existente falla al guardar';

  -- ── T7: 'reemplazar' cambia datos y suma stock ──
  PERFORM pg_temp.como(v_admin);
  PERFORM carga_inicial_guardar_item('TEST34-R', 'TEST34 viejo', 'Vieja', 'desc vieja', 1000, 4, 'nuevo');
  PERFORM carga_inicial_finalizar();
  pR := carga_inicial_producto_por_codigo('TEST34-R');
  PERFORM pg_temp.como(v_cajero);
  PERFORM carga_inicial_guardar_item('TEST34-R', 'TEST34 nuevo', 'Nueva', 'desc nueva', 1234.5, 6, 'reemplazar');
  v_res := carga_inicial_finalizar();
  SELECT * INTO v_prod FROM productos WHERE id = pR;
  ASSERT v_prod.nombre = 'TEST34 nuevo' AND v_prod.marca = 'Nueva' AND v_prod.descripcion = 'desc nueva'
         AND v_prod.precio_manual = 1234.5 AND v_prod.precio_venta = 1234.5, 'T7: reemplazar pisa nombre, marca, descripción y precio';
  ASSERT pg_temp.stock_local(pR) = 10, 'T7: y suma stock (4 + 6)';
  ASSERT (v_res->>'productos_reemplazados')::INT = 1, 'T7: resumen';
  -- reemplazar el precio de un producto con costo → error.
  v_ok := false;
  BEGIN
    PERFORM carga_inicial_guardar_item('TEST34-C', 'TEST34 con costo', NULL, NULL, 99999, 1, 'reemplazar');
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM LIKE 'Precio calculado por costo%';
  END;
  ASSERT v_ok, 'T7: reemplazar precio de un producto con costo falla';

  -- ── T8: sin código → EAN-13 válido generado ──
  PERFORM carga_inicial_guardar_item(NULL, 'TEST34 sin código', NULL, NULL, 300, 1, 'nuevo');
  PERFORM carga_inicial_guardar_item('', 'TEST34 sin código 2', NULL, NULL, 400, 1, 'nuevo');
  ASSERT (SELECT count(*) FROM carga_inicial_items WHERE usuario_id = v_cajero AND codigo_barras IS NULL) = 2,
         'T8: dos borradores sin código conviven (no se suman)';
  v_res := carga_inicial_finalizar();
  ASSERT jsonb_array_length(v_res->'codigos_generados') = 2, 'T8: dos códigos generados';
  v_codigo := v_res->'codigos_generados'->0->>'codigo';
  pG := (v_res->'codigos_generados'->0->>'producto_id')::UUID;
  ASSERT v_codigo ~ '^20\d{11}$', 'T8: 13 dígitos con prefijo 20 (dio ' || v_codigo || ')';
  -- Verificador calculado aparte (pesos 3-1 desde la derecha, como digitoVerificadorEanValido).
  SELECT (10 - sum(substr(reverse(left(v_codigo, 12)), i, 1)::INT * CASE WHEN i % 2 = 1 THEN 3 ELSE 1 END) % 10) % 10
         = right(v_codigo, 1)::INT INTO v_ok
  FROM generate_series(1, 12) i;
  ASSERT v_ok, 'T8: dígito verificador válido (' || v_codigo || ')';
  ASSERT (SELECT codigo_barras FROM productos WHERE id = pG) = v_codigo, 'T8: el código queda en codigo_barras';
  ASSERT v_codigo <> v_res->'codigos_generados'->1->>'codigo', 'T8: códigos distintos';
  ASSERT ean13_digito_verificador('779721600103') = 9, 'T8: verificador de un EAN real (7797216001039)';

  -- ── T9: editar cantidad de 5 a 3 → movimiento −2 ──
  PERFORM pg_temp.como(v_admin);
  PERFORM carga_inicial_guardar_item('TEST34-E', 'TEST34 editar', NULL, NULL, 500, 5, 'nuevo');
  PERFORM carga_inicial_finalizar();
  pN := carga_inicial_producto_por_codigo('TEST34-E');
  PERFORM pg_temp.como(v_cajero);
  v_res := carga_inicial_editar_producto(pN, 'TEST34 editado', 'M', NULL, 650, 3);
  ASSERT (v_res->>'delta')::NUMERIC = -2, 'T9: delta −2';
  ASSERT pg_temp.stock_local(pN) = 3, 'T9: stock 3';
  ASSERT (SELECT cantidad FROM movimientos_stock WHERE producto_id = pN AND tipo = 'inicial' ORDER BY created_at DESC, cantidad LIMIT 1) = -2
         AND (SELECT count(*) FROM movimientos_stock WHERE producto_id = pN AND tipo = 'inicial' AND cantidad = -2) = 1,
         'T9: movimiento inicial −2';
  ASSERT (SELECT nombre = 'TEST34 editado' AND precio_venta = 650 FROM productos WHERE id = pN), 'T9: nombre y precio editados';
  -- Misma cantidad → sin movimiento.
  v_res := carga_inicial_editar_producto(pN, 'TEST34 editado', 'M', NULL, 650, 3);
  ASSERT (v_res->>'delta')::NUMERIC = 0
         AND (SELECT count(*) FROM movimientos_stock WHERE producto_id = pN AND tipo = 'inicial') = 2, 'T9: sin cambio, sin movimiento';
  -- Producto con costo: mismo precio ok, otro precio → error.
  PERFORM carga_inicial_editar_producto(pC, 'TEST34 con costo', NULL, NULL, (SELECT precio_venta FROM productos WHERE id = pC), 1);
  v_ok := false;
  BEGIN
    PERFORM carga_inicial_editar_producto(pC, 'TEST34 con costo', NULL, NULL, 1, 1);
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM LIKE 'Precio calculado por costo%';
  END;
  ASSERT v_ok, 'T9: con costo, cambiar el precio falla';

  -- ── T10: resumen, eliminar, cerrar ──
  v_borrador := carga_inicial_guardar_item('TEST34-X', 'TEST34 borrar', NULL, NULL, 100, 1, 'nuevo');
  PERFORM carga_inicial_eliminar_item(v_borrador.id);
  ASSERT NOT EXISTS (SELECT 1 FROM carga_inicial_items WHERE id = v_borrador.id), 'T10: eliminar borrador';
  PERFORM carga_inicial_guardar_item('TEST34-X', 'TEST34 pendiente', NULL, NULL, 100, 7, 'nuevo');
  v_res := carga_inicial_resumen();
  ASSERT (v_res->>'abierta')::BOOLEAN AND (v_res->>'borradores')::INT >= 1
         AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'por_usuario') u
                     WHERE (u->>'usuario_id')::UUID = v_cajero AND (u->>'unidades_borradores')::NUMERIC = 7),
         'T10: resumen con pendientes por usuario';
  PERFORM pg_temp.como(v_admin);
  v_res := cerrar_carga_inicial();
  ASSERT (v_res->>'borradores_pendientes')::INT >= 1, 'T10: cerrar avisa borradores pendientes';
  ASSERT (SELECT NOT carga_inicial_abierta AND cerrada_por = v_admin FROM configuracion), 'T10: cerrada';
  ASSERT EXISTS (SELECT 1 FROM auditoria WHERE tabla_afectada = 'configuracion' AND accion = 'edicion'
                 AND (valores_nuevos->>'carga_inicial_abierta')::BOOLEAN = false AND usuario_id = v_admin),
         'T10: auditoría de configuracion';
  ASSERT EXISTS (SELECT 1 FROM auditoria WHERE tabla_afectada = 'carga_inicial_items' AND accion = 'alta'
                 AND valores_nuevos->>'codigo_barras' = 'TEST34-X'), 'T10: auditoría de borradores';

  RAISE NOTICE 'docs/34: todos los tests pasaron';
END;
$$;

ROLLBACK;
