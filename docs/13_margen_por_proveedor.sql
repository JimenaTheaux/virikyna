-- 13 — Margen por proveedor al reingresar stock (carga de factura de compra)
--
-- docs/06_estructura_de_datos (1).md, sección 13, tiene el detalle y la justificación completa.
-- Correr en el SQL Editor de Supabase (proyecto ccpinvtleqlsukcqnili), después de 06 (y 09/10/12
-- si ya se corrieron). Correr todo de una vez, en orden, una sola vez.
--
-- Regla: al cargar una factura de compra con un ítem vinculado a un producto existente,
--   - mismo proveedor  -> no se toca margen_1/margen_2 (se mantiene, incluida excepción manual)
--   - proveedor nuevo  -> productos.proveedor_id pasa al proveedor nuevo, y margen_1/margen_2
--                         se pisan con margen_1_default/margen_2_default de ese proveedor nuevo
-- No se toca el cálculo de precio_venta ni ninguna otra regla de stock.

-- ============================================================
-- 1. Válvula de escape en fn_proteger_margen_producto para la herencia automática de margen
--    por cambio de proveedor (no es una edición manual, no debe exigir rol admin). No afecta
--    la auditoría: trg_auditoria_productos sigue logueando el UPDATE como 'edicion' normal.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_proteger_margen_producto() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF (NEW.margen_1 IS DISTINCT FROM OLD.margen_1) OR (NEW.margen_2 IS DISTINCT FROM OLD.margen_2) THEN
    IF current_setting('virikyna.margen_auto_herencia', true) = 'true' THEN
      RETURN NEW;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
      RAISE EXCEPTION 'Solo un administrador puede modificar el margen de un producto';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- ============================================================
-- 2. cargar_factura_compra — agrega la comparación de proveedor por ítem con producto_id.
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
      SELECT proveedor_id INTO v_producto_proveedor_id FROM productos WHERE id = v_producto_id;

      IF v_producto_proveedor_id IS DISTINCT FROM p_proveedor_id THEN
        PERFORM set_config('virikyna.margen_auto_herencia', 'true', true);
        UPDATE productos
        SET proveedor_id = p_proveedor_id,
            margen_1 = (SELECT margen_1_default FROM proveedores WHERE id = p_proveedor_id),
            margen_2 = (SELECT margen_2_default FROM proveedores WHERE id = p_proveedor_id),
            updated_at = now()
        WHERE id = v_producto_id;
        PERFORM set_config('virikyna.margen_auto_herencia', 'false', true);
      END IF;

      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, referencia_id, usuario_id)
      VALUES (v_producto_id, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'),
             'compra', (v_item->>'cantidad')::NUMERIC, v_factura_id, auth.uid());

      INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
      VALUES (v_producto_id, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'), (v_item->>'cantidad')::NUMERIC)
      ON CONFLICT (producto_id, ubicacion)
      DO UPDATE SET cantidad = stock_ubicaciones.cantidad + (v_item->>'cantidad')::NUMERIC;
    END IF;
  END LOOP;

  RETURN v_factura_id;
END;
$$;

-- ============================================================
-- 3. Verificación — correr DESPUÉS de cargar una factura de compra real de prueba.
-- ============================================================

-- 3a. Elegí un producto y anotá su proveedor y margen actuales ANTES de la prueba.
-- SELECT id, nombre, proveedor_id, margen_1, margen_2 FROM productos WHERE id = '<PRODUCTO_ID>';

-- 3b. Caso "mismo proveedor": cargá una factura de compra con ese producto y el MISMO
--     proveedor_id que ya tenía. Después corré esto — margen_1/margen_2 deben ser IGUALES
--     a los de 3a, y updated_at NO debe haber cambiado (el trigger no se disparó).
-- SELECT id, nombre, proveedor_id, margen_1, margen_2, updated_at FROM productos WHERE id = '<PRODUCTO_ID>';

-- 3c. Caso "proveedor nuevo": cargá otra factura con ese mismo producto pero eligiendo un
--     proveedor_id DISTINTO. Después corré esto — proveedor_id debe ser el nuevo, y
--     margen_1/margen_2 deben ser IGUALES a margen_1_default/margen_2_default de ese
--     proveedor nuevo (pisando lo que tenía en 3b, incluida cualquier excepción manual).
-- SELECT p.id, p.nombre, p.proveedor_id, p.margen_1, p.margen_2, p.updated_at,
--        pr.margen_1_default, pr.margen_2_default
-- FROM productos p JOIN proveedores pr ON pr.id = p.proveedor_id
-- WHERE p.id = '<PRODUCTO_ID>';

-- 3d. El cambio quedó en auditoría (como 'edicion' normal, visible en Historial):
-- SELECT accion, valores_anteriores->>'margen_1' AS margen_1_antes, valores_nuevos->>'margen_1' AS margen_1_despues,
--        valores_anteriores->>'proveedor_id' AS proveedor_antes, valores_nuevos->>'proveedor_id' AS proveedor_despues,
--        created_at
-- FROM auditoria
-- WHERE tabla_afectada = 'productos' AND registro_id = '<PRODUCTO_ID>'
-- ORDER BY created_at DESC LIMIT 5;
