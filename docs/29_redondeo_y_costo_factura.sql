-- 29 — Precio de venta redondeado a la centena + costo actualizado desde la factura de compra
--
-- docs/06_estructura_de_datos.md, sección 20, tiene el detalle y la justificación.
-- Correr en el SQL Editor de Supabase (proyecto ccpinvtleqlsukcqnili), después de 28. Requiere
-- PostgreSQL 17 (ALTER COLUMN … SET EXPRESSION). Correr todo de una vez, una sola vez.
--
-- 1. productos.precio_calculado (nueva, generada): el precio exacto de la fórmula, a 2 decimales —
--    lo que antes era precio_venta. Sirve para ver cuánto se redondeó.
-- 2. productos.precio_venta pasa a redondearse a la centena (ROUND(…, -2): 2148 → 2100,
--    2150 → 2200). Se calcula desde la fórmula cruda, no desde precio_calculado: una columna
--    generada no puede leer otra columna generada.
-- 3. revertir_edicion: excluye precio_calculado de lo que restaura. Arma el UPDATE con todas las
--    claves de valores_anteriores menos las que no se pueden escribir; sin este cambio, revertir
--    cualquier edición de producto posterior a este script falla con "column precio_calculado can
--    only be updated to DEFAULT". Único cambio en esa función.
-- 4. cargar_factura_compra: cada ítem con producto vinculado pisa productos.costo con su
--    precio_unitario_sin_iva (precio de lista, antes del descuento de la línea — es el mismo valor
--    con el que la pantalla precarga el ítem la próxima vez). Ver reglas en la sección 4.
--
-- Al reescribir la tabla (pasos 1 y 2) no se disparan triggers de fila: no se generan filas de
-- auditoría por el recálculo de precios de este script.

BEGIN;

-- ============================================================
-- 1. precio_calculado — precio exacto, sin redondeo comercial
-- ============================================================
ALTER TABLE productos ADD COLUMN precio_calculado NUMERIC(12,2) GENERATED ALWAYS AS (
  ROUND(costo * (1 + margen_1/100.0) * (1 + margen_2/100.0) * (1 + iva_porcentaje/100.0), 2)
) STORED;

-- ============================================================
-- 2. precio_venta — redondeado a la centena
-- ============================================================
ALTER TABLE productos ALTER COLUMN precio_venta SET EXPRESSION AS (
  ROUND(costo * (1 + margen_1/100.0) * (1 + margen_2/100.0) * (1 + iva_porcentaje/100.0), -2)
);

-- ============================================================
-- 3. revertir_edicion — versión de docs/10 + 'precio_calculado' en la lista de exclusión
-- ============================================================
CREATE OR REPLACE FUNCTION revertir_edicion(p_auditoria_id UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_auditoria auditoria%ROWTYPE;
  v_set_clause TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede revertir acciones';
  END IF;

  SELECT * INTO v_auditoria FROM auditoria WHERE id = p_auditoria_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Acción no encontrada'; END IF;
  IF v_auditoria.accion <> 'edicion' THEN RAISE EXCEPTION 'Esta acción no es una edición reversible'; END IF;
  IF v_auditoria.tabla_afectada NOT IN ('productos', 'proveedores', 'clientes') THEN
    RAISE EXCEPTION 'Este cambio no se revierte con revertir_edicion — usá la función específica de ese tipo';
  END IF;
  IF EXISTS (SELECT 1 FROM auditoria WHERE revierte_auditoria_id = p_auditoria_id) THEN
    RAISE EXCEPTION 'Esta acción ya fue revertida';
  END IF;

  SELECT string_agg(format('%I = %L', kv.key, kv.value), ', ')
  INTO v_set_clause
  FROM jsonb_each_text(v_auditoria.valores_anteriores) AS kv(key, value)
  WHERE kv.key NOT IN ('id', 'created_at', 'updated_at', 'precio_venta', 'precio_calculado');

  IF v_set_clause IS NULL THEN RAISE EXCEPTION 'No hay valores anteriores para restaurar'; END IF;

  PERFORM set_config('virikyna.suppress_audit', 'true', true);
  EXECUTE format('UPDATE %I SET %s WHERE id = %L', v_auditoria.tabla_afectada, v_set_clause, v_auditoria.registro_id);
  IF v_auditoria.tabla_afectada = 'productos' THEN
    EXECUTE format('UPDATE productos SET updated_at = now() WHERE id = %L', v_auditoria.registro_id);
  END IF;
  PERFORM set_config('virikyna.suppress_audit', 'false', true);

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, valores_nuevos, usuario_id, revierte_auditoria_id)
  VALUES (v_auditoria.tabla_afectada, v_auditoria.registro_id, 'reversion',
          v_auditoria.valores_nuevos, v_auditoria.valores_anteriores, auth.uid(), p_auditoria_id);
END;
$$;

-- ============================================================
-- 4. cargar_factura_compra — versión de docs/13 + costo desde la factura.
--
-- Reglas:
--   - Actualiza costo en todo tipo de comprobante salvo nota_credito y nota_debito (hoy: factura,
--     remito, cupon; también cualquier tipo que se agregue al enum más adelante).
--   - Mismo producto repetido en la factura: gana la última línea.
--   - Un ítem con precio 0 (bonificación, sin cargo) no pisa el costo.
--   - La lógica de proveedor y márgenes es la de docs/13, sin cambios: proveedor distinto →
--     proveedor_id y margen_1/margen_2 pasan a los default del proveedor nuevo (también en NC/ND,
--     como hasta ahora).
--   - Proveedor, márgenes y costo se escriben en UN solo UPDATE por producto, así el Historial
--     muestra una sola fila 'edicion' (trg_auditoria_productos, el mismo mecanismo de siempre)
--     con costo, margen y precio_venta antes/después. Si no cambia nada, no hay UPDATE ni fila.
--   - Stock e ítems: sin cambios, se siguen procesando línea por línea.
-- ============================================================
CREATE OR REPLACE FUNCTION cargar_factura_compra(
  p_proveedor_id UUID,
  p_tipo_comprobante tipo_comprobante_compra,
  p_letra letra_comprobante_compra,
  p_punto_venta TEXT,
  p_numero_comprobante TEXT,
  p_fecha_comprobante DATE,
  p_fecha_fiscal DATE,
  p_forma_pago forma_pago_compra,
  p_items JSONB  -- [{"producto_id":"..."|null,"descripcion":"...","cantidad":1,"precio_unitario_sin_iva":100,"descuento_porcentaje":0,"ubicacion":"local"}]
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
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
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  SELECT COALESCE(SUM((i->>'cantidad')::NUMERIC * (i->>'precio_unitario_sin_iva')::NUMERIC
           * (1 - COALESCE((i->>'descuento_porcentaje')::NUMERIC,0)/100.0)), 0)
  INTO v_total_sin_iva
  FROM jsonb_array_elements(p_items) AS i;

  v_iva := ROUND(v_total_sin_iva * 0.21, 2);
  v_total := v_total_sin_iva + v_iva;

  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, letra, punto_venta, numero_comprobante,
         fecha_comprobante, fecha_fiscal, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (p_proveedor_id, p_tipo_comprobante, p_letra, p_punto_venta, p_numero_comprobante,
         p_fecha_comprobante, p_fecha_fiscal, p_forma_pago, v_total_sin_iva, v_iva, v_total, auth.uid())
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
    SELECT proveedor_id, costo INTO v_producto_proveedor_id, v_costo_actual
    FROM productos WHERE id = v_row.producto_id FOR UPDATE;

    v_cambia_proveedor := v_producto_proveedor_id IS DISTINCT FROM p_proveedor_id;
    v_costo_nuevo := CASE WHEN v_actualiza_costo AND v_row.precio > 0
                          THEN ROUND(v_row.precio, 2) ELSE v_costo_actual END;

    IF v_cambia_proveedor OR v_costo_nuevo IS DISTINCT FROM v_costo_actual THEN
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
          updated_at = now()
      WHERE id = v_row.producto_id;

      IF v_cambia_proveedor THEN
        PERFORM set_config('virikyna.margen_auto_herencia', 'false', true);
      END IF;
    END IF;
  END LOOP;

  RETURN v_factura_id;
END;
$$;

COMMIT;

-- ============================================================
-- 5. Verificación
-- ============================================================

-- 5a. Redondeo: 2100, 2200, 2200, 2100
SELECT ROUND(2148::numeric, -2), ROUND(2155::numeric, -2), ROUND(2150::numeric, -2), ROUND(2149.99::numeric, -2);

-- 5b. Ningún precio_venta fuera de la centena (debe dar 0)
SELECT COUNT(*) AS fuera_de_centena FROM productos WHERE precio_venta % 100 <> 0;

-- 5c. Muestra
SELECT nombre, costo, precio_calculado, precio_venta FROM productos LIMIT 10;

-- 5d. Factura de compra (desde la app): elegí un producto, anotá costo/precio_venta, cargá una
--     factura con otro precio unitario → costo = ese precio, precio_venta recalculado, y una
--     fila 'edicion' nueva en Historial con costo antes/después:
-- SELECT accion, valores_anteriores->>'costo' AS costo_antes, valores_nuevos->>'costo' AS costo_despues,
--        valores_anteriores->>'precio_venta' AS precio_antes, valores_nuevos->>'precio_venta' AS precio_despues,
--        created_at
-- FROM auditoria WHERE tabla_afectada = 'productos' AND registro_id = '<PRODUCTO_ID>'
-- ORDER BY created_at DESC LIMIT 5;

-- 5e. Nota de crédito con ese producto y otro precio → costo SIN cambios.
-- 5f. Factura con un proveedor distinto → proveedor_id y margen_1/margen_2 = default del
--     proveedor nuevo (mismo control que docs/13, 3c), en la misma fila de auditoría que el costo.
