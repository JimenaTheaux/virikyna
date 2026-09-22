-- 20 — Recargo (R) en Ventas, simétrico al descuento (docs/06)
--
-- Pedido: además del descuento (D) sobre el total de la venta, poder aplicar un recargo (R) —
-- también sobre el total, no por ítem — combinable con el descuento en la misma venta. El
-- resumen (pantalla, comprobante, PDF/imagen) debe mostrar subtotal, descuento (si hay), recargo
-- (si hay) y total final.
--
-- Cálculo: como ambos son porcentajes multiplicativos sobre el mismo subtotal, el resultado final
-- no depende de en qué orden se hayan tipeado — se resuelve con una sola fórmula:
--   total = ROUND(subtotal * (1 - descuento/100) * (1 + recargo/100), 2)
-- Igual que con el descuento, esto se recalcula acá server-side — el front nunca decide el total.

-- ============================================================
-- 1. Nueva columna en ventas (a nivel venta completa, no por ítem — igual que pide el negocio)
-- ============================================================
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS recargo_porcentaje NUMERIC(5,2) NOT NULL DEFAULT 0;

-- ============================================================
-- 2. confirmar_venta — agrega p_recargo_porcentaje, se suma al cálculo del total
-- Único cambio real vs. docs/06: nuevo parámetro (con default 0, así el RPC sigue siendo
-- compatible si algún caller viejo no lo manda) y v_total ahora también multiplica por
-- (1 + recargo/100) además de (1 - descuento/100).
-- ============================================================
CREATE OR REPLACE FUNCTION confirmar_venta(
  p_cliente_id UUID,
  p_forma_pago forma_pago_venta,
  p_items JSONB,  -- [{"producto_id":"...", "cantidad":1, "precio_unitario":12500, "descuento_porcentaje":0}]
  p_descuento_porcentaje NUMERIC DEFAULT 0,
  p_nota TEXT DEFAULT NULL,
  p_recargo_porcentaje NUMERIC DEFAULT 0
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_venta_id UUID;
  v_item JSONB;
  v_subtotal NUMERIC := 0;
  v_total NUMERIC;
  v_importe NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  -- Corregido en QA: mensaje claro antes de chocar con el CHECK del schema
  IF p_forma_pago = 'cuenta_corriente' AND p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'Una venta a cuenta corriente necesita un cliente asignado';
  END IF;

  SELECT COALESCE(SUM((i->>'cantidad')::NUMERIC * (i->>'precio_unitario')::NUMERIC
           * (1 - COALESCE((i->>'descuento_porcentaje')::NUMERIC,0)/100.0)), 0)
  INTO v_subtotal
  FROM jsonb_array_elements(p_items) AS i;

  v_total := ROUND(v_subtotal * (1 - COALESCE(p_descuento_porcentaje,0)/100.0)
                    * (1 + COALESCE(p_recargo_porcentaje,0)/100.0), 2);

  INSERT INTO ventas (cliente_id, forma_pago, subtotal, descuento_porcentaje, recargo_porcentaje, total, nota, usuario_id)
  VALUES (p_cliente_id, p_forma_pago, v_subtotal, COALESCE(p_descuento_porcentaje,0),
          COALESCE(p_recargo_porcentaje,0), v_total, p_nota, auth.uid())
  RETURNING id INTO v_venta_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_importe := ROUND((v_item->>'cantidad')::NUMERIC * (v_item->>'precio_unitario')::NUMERIC
                 * (1 - COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0)/100.0), 2);

    INSERT INTO venta_items (venta_id, producto_id, cantidad, precio_unitario, descuento_porcentaje, importe)
    VALUES (v_venta_id, (v_item->>'producto_id')::UUID, (v_item->>'cantidad')::NUMERIC,
            (v_item->>'precio_unitario')::NUMERIC, COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0), v_importe);

    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, referencia_id, usuario_id)
    VALUES ((v_item->>'producto_id')::UUID, 'local', 'venta', -1 * (v_item->>'cantidad')::NUMERIC, v_venta_id, auth.uid());

    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES ((v_item->>'producto_id')::UUID, 'local', -1 * (v_item->>'cantidad')::NUMERIC)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad - (v_item->>'cantidad')::NUMERIC;
  END LOOP;

  RETURN v_venta_id;
END;
$$;

-- ============================================================
-- Verificación: hacer una venta con descuento y recargo combinados y confirmar que
-- ventas.recargo_porcentaje y ventas.total reflejan la fórmula de arriba.
-- ============================================================
SELECT numero, subtotal, descuento_porcentaje, recargo_porcentaje, total, created_at
FROM ventas
ORDER BY created_at DESC
LIMIT 5;
