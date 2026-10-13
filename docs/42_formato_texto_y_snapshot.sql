-- 42 — Formato de texto de productos (MAYÚSCULAS) y snapshot de nombre/marca en ventas y devoluciones
--
-- docs/06_estructura_de_datos.md, sección 27, tiene el detalle. Correr desde la raíz del repo con
-- `npx supabase db query --linked -f docs/42_formato_texto_y_snapshot.sql` (o en el SQL Editor del
-- proyecto ccpinvtleqlsukcqnili), después de 41. La PARTE A va una sola vez; la PARTE B
-- (verificación) y la PARTE C (test, BEGIN … ROLLBACK) se pueden repetir.
-- (El número 40 lo usa docs/40_restauracion.md, la guía de backup.)
--
-- Contexto (relevado contra la base real el 2026-10-13):
--   - productos solo tenía un BEFORE UPDATE (trg_proteger_margen_producto, márgenes). Nombre, marca y
--     descripción se escriben desde 6 lugares: los formularios de las 3 apps (insert/update directo,
--     también el alta desde una factura de compra), carga_inicial_finalizar,
--     carga_inicial_editar_producto y revertir_alta/revertir_edicion (restauran desde auditoria).
--     Un trigger los cubre a todos sin tocar las apps.
--   - La búsqueda ya es case-insensitive en todos lados (ilike / toLowerCase): pasar a mayúsculas no
--     rompe nada. Los únicos UNIQUE son codigo_barras y codigo_interno, que NO se tocan (un Code 128
--     puede tener minúsculas).
--   - Collation ICU en-US: upper()/lower() respetan Ñ y acentos ('muñeca árbol' → 'MUÑECA ÁRBOL').
--   - venta_items y devolucion_items solo guardaban producto_id: los comprobantes y devoluciones
--     viejos mostraban el nombre ACTUAL del producto (join). Desde acá guardan el de ese momento.
--   - Funciones que insertan en venta_items / devolucion_items: solo confirmar_venta y
--     crear_devolucion (pg_get_functiondef del 2026-10-13, copiadas tal cual + el snapshot).
--   - productos_stock_bajo cambia su RETURNS TABLE (+ marca): no se puede con CREATE OR REPLACE,
--     va DROP + CREATE y se vuelven a poner los grants (authenticated y service_role, como antes).
--
-- Qué hace:
--   1. normalizar_texto_producto() + trg_normalizar_texto_producto (BEFORE INSERT OR UPDATE) en
--      productos: nombre y marca upper(btrim()); descripcion btrim, primera letra mayúscula y el
--      resto minúscula ('AUTO de Spiderman' → 'Auto de spiderman'). marca y descripcion vacías → null.
--   2. La misma función en carga_inicial_items (trg_normalizar_texto_carga_inicial): el borrador ya
--      se ve como va a quedar el producto.
--   3. normalizar_descripcion_item_libre() en facturas_compra_items: upper(btrim(descripcion)) solo
--      con producto_id null (ítem libre). En un ítem vinculado, descripcion es la copia de
--      producto.nombre, que ya viene en mayúsculas por el punto 1.
--   4. venta_items y devolucion_items: + producto_nombre, producto_marca (text, null). confirmar_venta
--      y crear_devolucion los copian del producto al insertar. Las filas existentes se completan con
--      el producto actual (backfill).
--   5. productos_stock_bajo: + marca.
--   6. Normaliza los productos existentes (UPDATE … SET nombre = nombre dispara el trigger; deja una
--      fila de auditoría 'edicion' por producto).
--
-- Las 2 funciones de trigger quedan sin EXECUTE para authenticated (mismo criterio que docs/39: un
-- trigger se dispara igual).
--
-- Efecto conocido: carga_inicial_editar_producto compara lo tipeado con lo guardado para decidir si
-- hace el UPDATE; con texto en minúsculas siempre "difiere" y hace un UPDATE que no cambia nada
-- (queda una fila de auditoría de más). Inofensivo.


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios (una transacción)
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 1 y 2. Texto de producto ──────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION normalizar_texto_producto()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_descripcion TEXT := NULLIF(btrim(NEW.descripcion), '');
BEGIN
  -- nombre es NOT NULL en las dos tablas: se deja que el constraint avise si viene null.
  NEW.nombre := upper(btrim(NEW.nombre));
  NEW.marca := NULLIF(upper(btrim(NEW.marca)), '');
  NEW.descripcion := upper(left(v_descripcion, 1)) || lower(substr(v_descripcion, 2));
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION normalizar_texto_producto() IS
  'Trigger (productos, carga_inicial_items): nombre y marca en MAYÚSCULAS, descripcion con solo la primera letra en mayúscula. No toca los códigos. docs/42.';

DROP TRIGGER IF EXISTS trg_normalizar_texto_producto ON productos;
CREATE TRIGGER trg_normalizar_texto_producto
  BEFORE INSERT OR UPDATE ON productos
  FOR EACH ROW EXECUTE FUNCTION normalizar_texto_producto();

DROP TRIGGER IF EXISTS trg_normalizar_texto_carga_inicial ON carga_inicial_items;
CREATE TRIGGER trg_normalizar_texto_carga_inicial
  BEFORE INSERT OR UPDATE ON carga_inicial_items
  FOR EACH ROW EXECUTE FUNCTION normalizar_texto_producto();

-- ── 3. Ítems libres de factura de compra ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION normalizar_descripcion_item_libre()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.producto_id IS NULL THEN
    NEW.descripcion := upper(btrim(NEW.descripcion));
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION normalizar_descripcion_item_libre() IS
  'Trigger (facturas_compra_items): descripcion en MAYÚSCULAS solo en ítems libres (producto_id null). docs/42.';

DROP TRIGGER IF EXISTS trg_normalizar_descripcion_item_libre ON facturas_compra_items;
CREATE TRIGGER trg_normalizar_descripcion_item_libre
  BEFORE INSERT OR UPDATE ON facturas_compra_items
  FOR EACH ROW EXECUTE FUNCTION normalizar_descripcion_item_libre();

REVOKE EXECUTE ON FUNCTION normalizar_texto_producto(), normalizar_descripcion_item_libre()
  FROM PUBLIC, anon, authenticated;

-- ── 4. Snapshot de nombre y marca ────────────────────────────────────────────────────────────
ALTER TABLE venta_items ADD COLUMN IF NOT EXISTS producto_nombre TEXT;
ALTER TABLE venta_items ADD COLUMN IF NOT EXISTS producto_marca TEXT;
ALTER TABLE devolucion_items ADD COLUMN IF NOT EXISTS producto_nombre TEXT;
ALTER TABLE devolucion_items ADD COLUMN IF NOT EXISTS producto_marca TEXT;

COMMENT ON COLUMN venta_items.producto_nombre IS
  'Nombre del producto al momento de la venta (snapshot, lo copia confirmar_venta). docs/42.';
COMMENT ON COLUMN venta_items.producto_marca IS
  'Marca del producto al momento de la venta (snapshot, null si no tenía). docs/42.';
COMMENT ON COLUMN devolucion_items.producto_nombre IS
  'Nombre del producto al momento de la devolución/cambio (snapshot, lo copia crear_devolucion). docs/42.';
COMMENT ON COLUMN devolucion_items.producto_marca IS
  'Marca del producto al momento de la devolución/cambio (snapshot, null si no tenía). docs/42.';

-- confirmar_venta: cuerpo de la base al 2026-10-13 (docs/23) + snapshot en el INSERT de venta_items.
CREATE OR REPLACE FUNCTION public.confirmar_venta(p_cliente_id uuid, p_forma_pago forma_pago_venta, p_items jsonb, p_descuento_porcentaje numeric DEFAULT 0, p_nota text DEFAULT NULL::text, p_recargo_porcentaje numeric DEFAULT 0, p_pagos jsonb DEFAULT NULL::jsonb, p_precio_cobrado numeric DEFAULT NULL::numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_venta_id UUID;
  v_item JSONB;
  v_pago JSONB;
  v_subtotal NUMERIC := 0;
  v_precio_oficial NUMERIC;
  v_precio_cobrado NUMERIC;
  v_ratio NUMERIC;
  v_importe NUMERIC;
  v_forma_pago_final forma_pago_venta;
  v_suma_pagos NUMERIC;
  v_suma_ajustada NUMERIC := 0;
  v_monto_ajustado NUMERIC;
  v_idx INT := 0;
  v_nombre TEXT;  -- docs/42
  v_marca TEXT;   -- docs/42
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  SELECT COALESCE(SUM((i->>'cantidad')::NUMERIC * (i->>'precio_unitario')::NUMERIC
           * (1 - COALESCE((i->>'descuento_porcentaje')::NUMERIC,0)/100.0)), 0)
  INTO v_subtotal
  FROM jsonb_array_elements(p_items) AS i;

  v_precio_oficial := ROUND(v_subtotal * (1 - COALESCE(p_descuento_porcentaje,0)/100.0)
                    * (1 + COALESCE(p_recargo_porcentaje,0)/100.0), 2);

  IF p_pagos IS NOT NULL AND jsonb_array_length(p_pagos) > 0 THEN
    IF jsonb_array_length(p_pagos) > 2 THEN
      RAISE EXCEPTION 'Un pago combinado admite hasta 2 medios de pago';
    END IF;
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_pagos) AS p
      WHERE (p->>'forma_pago') IN ('cuenta_corriente', 'combinado')
    ) THEN
      RAISE EXCEPTION 'La cuenta corriente no puede combinarse con otro medio de pago';
    END IF;
    -- La validación de la suma se hace contra el precio OFICIAL: es el monto con el que se armó
    -- el reparto en PagoCombinadoModal, antes de que el cajero edite el precio final a cobrar.
    SELECT COALESCE(SUM((p->>'monto')::NUMERIC), 0) INTO v_suma_pagos FROM jsonb_array_elements(p_pagos) AS p;
    IF ROUND(v_suma_pagos, 2) <> v_precio_oficial THEN
      RAISE EXCEPTION 'La suma de los pagos (%) no coincide con el total de la venta (%)', v_suma_pagos, v_precio_oficial;
    END IF;
    v_forma_pago_final := CASE WHEN jsonb_array_length(p_pagos) = 1
      THEN (p_pagos->0->>'forma_pago')::forma_pago_venta
      ELSE 'combinado'::forma_pago_venta END;
  ELSE
    v_forma_pago_final := p_forma_pago;
  END IF;

  -- Corregido en QA: mensaje claro antes de chocar con el CHECK del schema
  IF v_forma_pago_final = 'cuenta_corriente' AND p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'Una venta a cuenta corriente necesita un cliente asignado';
  END IF;

  v_precio_cobrado := COALESCE(p_precio_cobrado, v_precio_oficial);
  IF v_precio_cobrado <= 0 THEN
    RAISE EXCEPTION 'El precio final a cobrar debe ser mayor a 0';
  END IF;

  INSERT INTO ventas (cliente_id, forma_pago, subtotal, descuento_porcentaje, recargo_porcentaje, total,
         precio_oficial, precio_cobrado, nota, usuario_id)
  VALUES (p_cliente_id, v_forma_pago_final, v_subtotal, COALESCE(p_descuento_porcentaje,0),
          COALESCE(p_recargo_porcentaje,0), v_precio_cobrado, v_precio_oficial, v_precio_cobrado, p_nota, auth.uid())
  RETURNING id INTO v_venta_id;

  IF v_forma_pago_final <> 'cuenta_corriente' THEN
    IF p_pagos IS NOT NULL AND jsonb_array_length(p_pagos) > 0 THEN
      -- Reescala cada parte al precio cobrado, manteniendo la proporción del reparto original —
      -- la última parte absorbe el centavo de redondeo para que la suma dé exacta.
      v_ratio := CASE WHEN v_precio_oficial = 0 THEN 1 ELSE v_precio_cobrado / v_precio_oficial END;
      FOR v_pago IN SELECT * FROM jsonb_array_elements(p_pagos)
      LOOP
        v_idx := v_idx + 1;
        IF v_idx = jsonb_array_length(p_pagos) THEN
          v_monto_ajustado := v_precio_cobrado - v_suma_ajustada;
        ELSE
          v_monto_ajustado := ROUND((v_pago->>'monto')::NUMERIC * v_ratio, 2);
          v_suma_ajustada := v_suma_ajustada + v_monto_ajustado;
        END IF;
        INSERT INTO venta_pagos (venta_id, forma_pago, monto, usuario_id)
        VALUES (v_venta_id, (v_pago->>'forma_pago')::forma_pago_venta, v_monto_ajustado, auth.uid());
      END LOOP;
    ELSE
      INSERT INTO venta_pagos (venta_id, forma_pago, monto, usuario_id)
      VALUES (v_venta_id, v_forma_pago_final, v_precio_cobrado, auth.uid());
    END IF;
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_importe := ROUND((v_item->>'cantidad')::NUMERIC * (v_item->>'precio_unitario')::NUMERIC
                 * (1 - COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0)/100.0), 2);

    -- docs/42: snapshot de nombre y marca. Si el producto no existe, la FK del INSERT lo frena igual.
    SELECT nombre, marca INTO v_nombre, v_marca FROM productos WHERE id = (v_item->>'producto_id')::UUID;

    INSERT INTO venta_items (venta_id, producto_id, cantidad, precio_unitario, descuento_porcentaje, importe,
                             producto_nombre, producto_marca)
    VALUES (v_venta_id, (v_item->>'producto_id')::UUID, (v_item->>'cantidad')::NUMERIC,
            (v_item->>'precio_unitario')::NUMERIC, COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0), v_importe,
            v_nombre, v_marca);

    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, referencia_id, usuario_id)
    VALUES ((v_item->>'producto_id')::UUID, 'local', 'venta', -1 * (v_item->>'cantidad')::NUMERIC, v_venta_id, auth.uid());

    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES ((v_item->>'producto_id')::UUID, 'local', -1 * (v_item->>'cantidad')::NUMERIC)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad - (v_item->>'cantidad')::NUMERIC;
  END LOOP;

  RETURN v_venta_id;
END;
$function$;

-- crear_devolucion: cuerpo de la base al 2026-10-13 (docs/24) + snapshot en los dos INSERT de
-- devolucion_items.
CREATE OR REPLACE FUNCTION public.crear_devolucion(p_venta_id uuid, p_motivo motivo_devolucion, p_motivo_detalle text, p_observaciones text, p_items_devueltos jsonb, p_items_nuevos jsonb DEFAULT NULL::jsonb, p_forma_pago forma_pago_venta DEFAULT NULL::forma_pago_venta, p_pagos jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'America/Argentina/Buenos_Aires'
AS $function$
DECLARE
  v_venta ventas%ROWTYPE;
  v_row RECORD;
  v_devolucion_id UUID;
  v_vendida NUMERIC;
  v_ya_devuelta NUMERIC;
  v_precio NUMERIC;
  v_total_devuelto NUMERIC := 0;
  v_total_nuevo NUMERIC := 0;
  v_diferencia NUMERIC;
  v_forma_final forma_pago_venta;
  v_suma_pagos NUMERIC;
  v_suma_asignada NUMERIC := 0;
  v_monto NUMERIC;
  v_pago JSONB;
  v_idx INT := 0;
  v_reingresa BOOLEAN;
  v_nombre TEXT;
  v_marca TEXT;  -- docs/42
  v_items_devueltos JSONB := '[]'::jsonb;
  v_items_nuevos JSONB := '[]'::jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  -- Bloquea la venta: dos devoluciones simultáneas sobre la misma venta se serializan, así la
  -- validación de cantidad disponible no se puede saltear con una carrera.
  SELECT * INTO v_venta FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Venta no encontrada'; END IF;
  IF v_venta.estado = 'anulada' THEN
    RAISE EXCEPTION 'No se puede hacer una devolución sobre una venta anulada';
  END IF;

  -- Validación 1: plazo de 15 días
  IF v_venta.created_at::date < current_date - 15 THEN
    RAISE EXCEPTION 'Esta venta supera los 15 días permitidos para devolución/cambio';
  END IF;

  -- Validación 3: motivo obligatorio; "otro" exige detalle
  IF p_motivo IS NULL THEN RAISE EXCEPTION 'El motivo es obligatorio'; END IF;
  IF p_motivo = 'otro' AND (p_motivo_detalle IS NULL OR btrim(p_motivo_detalle) = '') THEN
    RAISE EXCEPTION 'Con motivo "otro" el detalle es obligatorio';
  END IF;

  IF p_items_devueltos IS NULL OR jsonb_typeof(p_items_devueltos) <> 'array' OR jsonb_array_length(p_items_devueltos) = 0 THEN
    RAISE EXCEPTION 'Elegí al menos un producto para devolver';
  END IF;

  v_reingresa := (p_motivo <> 'defectuoso');

  -- ---- Ítems devueltos (agrupados por producto por si el cliente manda repetidos) ----
  FOR v_row IN
    SELECT (i->>'producto_id')::UUID AS producto_id, SUM((i->>'cantidad')::NUMERIC) AS cantidad
    FROM jsonb_array_elements(p_items_devueltos) AS i
    GROUP BY 1
  LOOP
    IF v_row.cantidad IS NULL OR v_row.cantidad <= 0 THEN
      RAISE EXCEPTION 'La cantidad a devolver debe ser mayor a 0';
    END IF;

    SELECT COALESCE(SUM(cantidad), 0) INTO v_vendida
    FROM venta_items WHERE venta_id = p_venta_id AND producto_id = v_row.producto_id;

    SELECT nombre INTO v_nombre FROM productos WHERE id = v_row.producto_id;

    IF v_vendida = 0 THEN
      RAISE EXCEPTION 'El producto "%" no forma parte de esta venta', COALESCE(v_nombre, v_row.producto_id::text);
    END IF;

    -- Validación 2: no devolver más de lo vendido, descontando devoluciones activas previas
    SELECT COALESCE(SUM(di.cantidad), 0) INTO v_ya_devuelta
    FROM devolucion_items di
    JOIN devoluciones d ON d.id = di.devolucion_id
    WHERE d.venta_id = p_venta_id AND d.estado = 'activa'
      AND di.tipo = 'devuelto' AND di.producto_id = v_row.producto_id;

    IF v_row.cantidad > v_vendida - v_ya_devuelta THEN
      RAISE EXCEPTION 'No se puede devolver % de "%": solo quedan % disponibles (vendidas %, ya devueltas %)',
        v_row.cantidad, v_nombre, v_vendida - v_ya_devuelta, v_vendida, v_ya_devuelta;
    END IF;

    -- Precio efectivamente pagado por unidad (ver decisión 1 del encabezado)
    SELECT ROUND(
             (SUM(importe) / NULLIF(SUM(cantidad), 0))
             * (CASE WHEN v_venta.subtotal > 0 THEN v_venta.total / v_venta.subtotal ELSE 1 END), 2)
    INTO v_precio
    FROM venta_items WHERE venta_id = p_venta_id AND producto_id = v_row.producto_id;

    v_total_devuelto := v_total_devuelto + ROUND(v_row.cantidad * v_precio, 2);
    v_items_devueltos := v_items_devueltos || jsonb_build_object(
      'producto_id', v_row.producto_id, 'cantidad', v_row.cantidad, 'precio_unitario', v_precio);
  END LOOP;

  -- ---- Ítems nuevos (cambio), a precio actual de lista ----
  IF p_items_nuevos IS NOT NULL AND jsonb_typeof(p_items_nuevos) = 'array' AND jsonb_array_length(p_items_nuevos) > 0 THEN
    FOR v_row IN
      SELECT (i->>'producto_id')::UUID AS producto_id, SUM((i->>'cantidad')::NUMERIC) AS cantidad
      FROM jsonb_array_elements(p_items_nuevos) AS i
      GROUP BY 1
    LOOP
      IF v_row.cantidad IS NULL OR v_row.cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad del producto nuevo debe ser mayor a 0';
      END IF;
      SELECT nombre, precio_venta INTO v_nombre, v_precio
      FROM productos WHERE id = v_row.producto_id AND estado = 'activo';
      IF NOT FOUND THEN RAISE EXCEPTION 'Producto nuevo no encontrado o inactivo'; END IF;

      v_total_nuevo := v_total_nuevo + ROUND(v_row.cantidad * v_precio, 2);
      v_items_nuevos := v_items_nuevos || jsonb_build_object(
        'producto_id', v_row.producto_id, 'cantidad', v_row.cantidad, 'precio_unitario', v_precio);
    END LOOP;
  END IF;

  v_diferencia := ROUND(v_total_nuevo - v_total_devuelto, 2);

  -- ---- Forma de pago de la diferencia ----
  IF v_diferencia <> 0 THEN
    IF p_pagos IS NOT NULL AND jsonb_typeof(p_pagos) = 'array' AND jsonb_array_length(p_pagos) > 0 THEN
      IF jsonb_array_length(p_pagos) > 2 THEN
        RAISE EXCEPTION 'Un pago combinado admite hasta 2 medios de pago';
      END IF;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_pagos) AS p
                 WHERE (p->>'forma_pago') IN ('cuenta_corriente', 'combinado')) THEN
        RAISE EXCEPTION 'La diferencia no se puede saldar con cuenta corriente';
      END IF;
      SELECT COALESCE(SUM((p->>'monto')::NUMERIC), 0) INTO v_suma_pagos FROM jsonb_array_elements(p_pagos) AS p;
      IF ABS(v_suma_pagos - ABS(v_diferencia)) > 0.01 THEN
        RAISE EXCEPTION 'La suma de los pagos (%) no coincide con la diferencia (%)', v_suma_pagos, ABS(v_diferencia);
      END IF;
      v_forma_final := CASE WHEN jsonb_array_length(p_pagos) = 1
        THEN (p_pagos->0->>'forma_pago')::forma_pago_venta
        ELSE 'combinado'::forma_pago_venta END;
    ELSE
      IF p_forma_pago IS NULL THEN
        RAISE EXCEPTION 'Elegí la forma de pago para saldar la diferencia';
      END IF;
      IF p_forma_pago IN ('cuenta_corriente', 'combinado') THEN
        RAISE EXCEPTION 'Forma de pago inválida para saldar la diferencia';
      END IF;
      v_forma_final := p_forma_pago;
    END IF;
  ELSE
    v_forma_final := NULL;
  END IF;

  -- ---- Insert de la devolución ----
  INSERT INTO devoluciones (venta_id, usuario_id, motivo, motivo_detalle, observaciones,
                            diferencia_monto, diferencia_forma_pago)
  VALUES (p_venta_id, auth.uid(), p_motivo, NULLIF(btrim(p_motivo_detalle), ''), NULLIF(btrim(p_observaciones), ''),
          v_diferencia, v_forma_final)
  RETURNING id INTO v_devolucion_id;

  -- Pagos de la diferencia (monto siempre positivo). La última parte absorbe el centavo de redondeo.
  IF v_diferencia <> 0 THEN
    IF p_pagos IS NOT NULL AND jsonb_typeof(p_pagos) = 'array' AND jsonb_array_length(p_pagos) > 0 THEN
      FOR v_pago IN SELECT * FROM jsonb_array_elements(p_pagos)
      LOOP
        v_idx := v_idx + 1;
        IF v_idx = jsonb_array_length(p_pagos) THEN
          v_monto := ABS(v_diferencia) - v_suma_asignada;
        ELSE
          v_monto := ROUND((v_pago->>'monto')::NUMERIC, 2);
          v_suma_asignada := v_suma_asignada + v_monto;
        END IF;
        INSERT INTO devolucion_pagos (devolucion_id, forma_pago, monto)
        VALUES (v_devolucion_id, (v_pago->>'forma_pago')::forma_pago_venta, v_monto);
      END LOOP;
    ELSE
      INSERT INTO devolucion_pagos (devolucion_id, forma_pago, monto)
      VALUES (v_devolucion_id, v_forma_final, ABS(v_diferencia));
    END IF;
  END IF;

  -- Ítems devueltos: + stock local solo si reingresa (defectuoso queda separado, sin movimiento)
  FOR v_row IN SELECT (i->>'producto_id')::UUID AS producto_id, (i->>'cantidad')::NUMERIC AS cantidad,
                      (i->>'precio_unitario')::NUMERIC AS precio_unitario
               FROM jsonb_array_elements(v_items_devueltos) AS i
  LOOP
    SELECT nombre, marca INTO v_nombre, v_marca FROM productos WHERE id = v_row.producto_id;  -- docs/42

    INSERT INTO devolucion_items (devolucion_id, tipo, producto_id, cantidad, precio_unitario, reingresa_stock,
                                  producto_nombre, producto_marca)
    VALUES (v_devolucion_id, 'devuelto', v_row.producto_id, v_row.cantidad, v_row.precio_unitario, v_reingresa,
            v_nombre, v_marca);

    IF v_reingresa THEN
      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
      VALUES (v_row.producto_id, 'local', 'ajuste', v_row.cantidad,
              'Devolución de venta #' || v_venta.numero || ' (' || p_motivo::text || ')', v_devolucion_id, auth.uid());
      INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
      VALUES (v_row.producto_id, 'local', v_row.cantidad)
      ON CONFLICT (producto_id, ubicacion)
      DO UPDATE SET cantidad = stock_ubicaciones.cantidad + v_row.cantidad;
    END IF;
  END LOOP;

  -- Ítems nuevos: − stock local
  FOR v_row IN SELECT (i->>'producto_id')::UUID AS producto_id, (i->>'cantidad')::NUMERIC AS cantidad,
                      (i->>'precio_unitario')::NUMERIC AS precio_unitario
               FROM jsonb_array_elements(v_items_nuevos) AS i
  LOOP
    SELECT nombre, marca INTO v_nombre, v_marca FROM productos WHERE id = v_row.producto_id;  -- docs/42

    INSERT INTO devolucion_items (devolucion_id, tipo, producto_id, cantidad, precio_unitario, reingresa_stock,
                                  producto_nombre, producto_marca)
    VALUES (v_devolucion_id, 'nuevo', v_row.producto_id, v_row.cantidad, v_row.precio_unitario, true,
            v_nombre, v_marca);

    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
    VALUES (v_row.producto_id, 'local', 'ajuste', -1 * v_row.cantidad,
            'Cambio sobre venta #' || v_venta.numero, v_devolucion_id, auth.uid());
    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES (v_row.producto_id, 'local', -1 * v_row.cantidad)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad - v_row.cantidad;
  END LOOP;

  RETURN v_devolucion_id;
END;
$function$;

-- ── 5. productos_stock_bajo + marca (cambia el RETURNS TABLE: DROP + CREATE) ──────────────────
DROP FUNCTION IF EXISTS productos_stock_bajo(INT);

CREATE FUNCTION productos_stock_bajo(p_limite INT DEFAULT NULL)
RETURNS TABLE(id uuid, nombre text, marca text, stock_total numeric, stock_minimo numeric, total_count integer)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  WITH stock AS (
    SELECT p.id, p.nombre, p.marca, p.stock_minimo,
           COALESCE(SUM(s.cantidad), 0) AS stock_total
    FROM productos p
    LEFT JOIN stock_ubicaciones s ON s.producto_id = p.id
    WHERE p.estado = 'activo'
    GROUP BY p.id, p.nombre, p.marca, p.stock_minimo
  )
  SELECT st.id, st.nombre, st.marca, st.stock_total, st.stock_minimo,
         (COUNT(*) OVER ())::int AS total_count
  FROM stock st
  WHERE st.stock_total <= st.stock_minimo
  ORDER BY st.stock_total - st.stock_minimo, st.nombre
  LIMIT p_limite;
$$;

REVOKE EXECUTE ON FUNCTION productos_stock_bajo(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION productos_stock_bajo(INT) TO authenticated, service_role;

-- ── 6. Datos existentes ──────────────────────────────────────────────────────────────────────
-- Productos: el trigger normaliza al reescribir la fila (WHERE explícito por costumbre: safeupdate).
UPDATE productos SET nombre = nombre WHERE id IS NOT NULL;

-- Snapshots de filas anteriores: con el producto ya normalizado.
UPDATE venta_items vi SET producto_nombre = p.nombre, producto_marca = p.marca
FROM productos p WHERE p.id = vi.producto_id AND vi.producto_nombre IS NULL;

UPDATE devolucion_items di SET producto_nombre = p.nombre, producto_marca = p.marca
FROM productos p WHERE p.id = di.producto_id AND di.producto_nombre IS NULL;

COMMIT;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (repetible, solo lectura)
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- B1. Triggers nuevos.
SELECT tgrelid::regclass AS tabla, tgname, pg_get_triggerdef(oid) AS definicion
FROM pg_trigger
WHERE tgname IN ('trg_normalizar_texto_producto', 'trg_normalizar_texto_carga_inicial',
                 'trg_normalizar_descripcion_item_libre')
ORDER BY 1;

-- B2. Columnas de snapshot (text, nullable).
SELECT table_name, column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name IN ('venta_items', 'devolucion_items')
  AND column_name IN ('producto_nombre', 'producto_marca')
ORDER BY 1, 2;

-- B3. Grants: triggers sin EXECUTE para la API; productos_stock_bajo para authenticated, no anon.
SELECT p.proname,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon,
       has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role
FROM pg_proc p
WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('normalizar_texto_producto', 'normalizar_descripcion_item_libre', 'productos_stock_bajo')
ORDER BY 1;

-- B4. Ningún producto ni borrador fuera de formato (0 filas = OK).
SELECT 'productos' AS tabla, id, nombre, marca, descripcion FROM productos
WHERE nombre IS DISTINCT FROM upper(btrim(nombre))
   OR marca IS DISTINCT FROM NULLIF(upper(btrim(marca)), '')
   OR descripcion IS DISTINCT FROM upper(left(NULLIF(btrim(descripcion), ''), 1)) || lower(substr(NULLIF(btrim(descripcion), ''), 2))
UNION ALL
SELECT 'carga_inicial_items', id, nombre, marca, descripcion FROM carga_inicial_items
WHERE nombre IS DISTINCT FROM upper(btrim(nombre))
   OR marca IS DISTINCT FROM NULLIF(upper(btrim(marca)), '')
   OR descripcion IS DISTINCT FROM upper(left(NULLIF(btrim(descripcion), ''), 1)) || lower(substr(NULLIF(btrim(descripcion), ''), 2));

-- B5. Ítems de venta y devolución sin snapshot (0 = OK).
SELECT (SELECT count(*) FROM venta_items WHERE producto_nombre IS NULL) AS venta_items_sin_snapshot,
       (SELECT count(*) FROM devolucion_items WHERE producto_nombre IS NULL) AS devolucion_items_sin_snapshot;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (no deja nada: BEGIN … ROLLBACK)
-- ⚠ confirmar_venta y crear_devolucion consumen ventas.numero y devoluciones.numero aunque se haga
--   ROLLBACK (las secuencias no vuelven atrás): el próximo número real salta uno.
-- Resultado: una sola tabla con todas las filas ok = true.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- Un admin activo cualquiera como auth.uid() (las RPCs validan perfil activo).
SELECT set_config('request.jwt.claims',
                  json_build_object('sub', (SELECT id FROM perfiles WHERE activo AND rol = 'admin' LIMIT 1),
                                    'role', 'authenticated')::text, true);

CREATE TEMP TABLE t42 (orden INT, test TEXT, obtenido TEXT, ok BOOLEAN) ON COMMIT DROP;

DO $$
DECLARE
  v_prov UUID := (SELECT id FROM proveedores LIMIT 1);
  v_p1 UUID;
  v_p2 UUID;
  v_venta UUID;
  v_dev UUID;
  v_factura UUID;
  r RECORD;
BEGIN
  -- Alta con texto desprolijo y códigos en minúscula.
  INSERT INTO productos (nombre, marca, descripcion, codigo_barras, codigo_interno, precio_manual)
  VALUES ('  silla de comer osaka ', ' carestino ', '  AUTO de Spiderman ', 'abc-test-42', NULL, 1000)
  RETURNING id INTO v_p1;
  INSERT INTO productos (nombre, marca, descripcion, codigo_barras, codigo_interno, precio_manual)
  VALUES ('muñeca árbol', '', '   ', NULL, 'int-test-42x', 500)
  RETURNING id INTO v_p2;

  SELECT * INTO r FROM productos WHERE id = v_p1;
  INSERT INTO t42 VALUES
    (1, 'nombre → MAYÚSCULAS y trim', r.nombre, r.nombre = 'SILLA DE COMER OSAKA'),
    (2, 'marca → MAYÚSCULAS y trim', r.marca, r.marca = 'CARESTINO'),
    (3, 'descripcion → primera mayúscula', r.descripcion, r.descripcion = 'Auto de spiderman'),
    (4, 'codigo_barras sin tocar', r.codigo_barras, r.codigo_barras = 'abc-test-42');

  SELECT * INTO r FROM productos WHERE id = v_p2;
  INSERT INTO t42 VALUES
    (5, 'Ñ y acentos', r.nombre, r.nombre = 'MUÑECA ÁRBOL'),
    (6, 'marca vacía → null', coalesce(r.marca, '<null>'), r.marca IS NULL),
    (7, 'descripcion en blanco → null', coalesce(r.descripcion, '<null>'), r.descripcion IS NULL),
    (8, 'codigo_interno sin tocar', r.codigo_interno, r.codigo_interno = 'int-test-42x');

  -- UPDATE desde las apps (minúsculas) también se normaliza; descripcion con acento al inicio.
  UPDATE productos SET nombre = 'silla osaka v2', descripcion = 'ácido y SUAVE' WHERE id = v_p1;
  SELECT * INTO r FROM productos WHERE id = v_p1;
  INSERT INTO t42 VALUES
    (9, 'UPDATE normaliza nombre', r.nombre, r.nombre = 'SILLA OSAKA V2'),
    (10, 'descripcion con acento inicial', r.descripcion, r.descripcion = 'Ácido y suave');

  -- Carga inicial: borrador normalizado.
  INSERT INTO carga_inicial_items (usuario_id, codigo_barras, nombre, marca, descripcion, precio, cantidad)
  VALUES (auth.uid(), 'xyz-test-42', 'pelota de fútbol', 'nike', 'GRANDE de cuero', 100, 1);
  SELECT * INTO r FROM carga_inicial_items WHERE codigo_barras = 'xyz-test-42';
  INSERT INTO t42 VALUES
    (11, 'carga inicial: nombre/marca/desc',
     concat_ws(' | ', r.nombre, r.marca, r.descripcion),
     r.nombre = 'PELOTA DE FÚTBOL' AND r.marca = 'NIKE' AND r.descripcion = 'Grande de cuero'),
    (12, 'carga inicial: código sin tocar', r.codigo_barras, r.codigo_barras = 'xyz-test-42');

  -- Factura de compra: ítem libre en MAYÚSCULAS; ítem vinculado con la descripción tal cual.
  IF v_prov IS NOT NULL THEN
    v_factura := cargar_factura_compra(v_prov, 'factura', 'A', '0001', '99999942', current_date, current_date, 'contado',
      jsonb_build_array(
        jsonb_build_object('producto_id', NULL, 'descripcion', '  flete y embalaje ', 'cantidad', 1, 'precio_unitario_sin_iva', 10),
        jsonb_build_object('producto_id', v_p2, 'descripcion', 'Texto Tal Cual', 'cantidad', 1, 'precio_unitario_sin_iva', 10)));
    INSERT INTO t42
    SELECT 13, 'factura: ítem libre en mayúsculas', descripcion, descripcion = 'FLETE Y EMBALAJE'
    FROM facturas_compra_items WHERE factura_compra_id = v_factura AND producto_id IS NULL;
    INSERT INTO t42
    SELECT 14, 'factura: ítem vinculado sin tocar', descripcion, descripcion = 'Texto Tal Cual'
    FROM facturas_compra_items WHERE factura_compra_id = v_factura AND producto_id IS NOT NULL;
  ELSE
    INSERT INTO t42 VALUES (13, 'factura: sin proveedores para probar', NULL, NULL);
  END IF;

  -- confirmar_venta guarda el snapshot; renombrar el producto después no lo cambia.
  v_venta := confirmar_venta(NULL, 'efectivo',
    jsonb_build_array(jsonb_build_object('producto_id', v_p1, 'cantidad', 2, 'precio_unitario', 1000)));
  UPDATE productos SET nombre = 'otro nombre' WHERE id = v_p1;
  SELECT * INTO r FROM venta_items WHERE venta_id = v_venta;
  INSERT INTO t42 VALUES
    (15, 'confirmar_venta: producto_nombre', r.producto_nombre, r.producto_nombre = 'SILLA OSAKA V2'),
    (16, 'confirmar_venta: producto_marca', r.producto_marca, r.producto_marca = 'CARESTINO');

  -- crear_devolucion: devuelvo 1 de p1 y me llevo 1 de p2 (diferencia en efectivo).
  v_dev := crear_devolucion(v_venta, 'otro', 'test docs/42', NULL,
    jsonb_build_array(jsonb_build_object('producto_id', v_p1, 'cantidad', 1)),
    jsonb_build_array(jsonb_build_object('producto_id', v_p2, 'cantidad', 1)),
    'efectivo');
  INSERT INTO t42
  SELECT 17, 'crear_devolucion: snapshot ' || tipo::text,
         concat_ws(' | ', producto_nombre, coalesce(producto_marca, '<null>')),
         CASE tipo::text WHEN 'devuelto' THEN producto_nombre = 'OTRO NOMBRE' AND producto_marca = 'CARESTINO'
                         ELSE producto_nombre = 'MUÑECA ÁRBOL' AND producto_marca IS NULL END
  FROM devolucion_items WHERE devolucion_id = v_dev;

  -- productos_stock_bajo devuelve marca (p1 quedó con stock negativo, stock_minimo 0).
  INSERT INTO t42
  SELECT 18, 'productos_stock_bajo: marca', s.marca, s.marca = 'CARESTINO'
  FROM productos_stock_bajo(NULL) s WHERE s.id = v_p1;
END;
$$;

SELECT * FROM t42 ORDER BY orden;

ROLLBACK;
