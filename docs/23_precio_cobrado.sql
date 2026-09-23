-- 23 — Precio final a cobrar editable en la confirmación de venta
--
-- Pedido: en la ventanita de confirmación de venta (post primer Enter), mostrar siempre un
-- recuadro con el "Precio final a cobrar", precargado con el precio oficial que calcula el
-- sistema (con descuentos/recargos aplicados). El cajero puede dejarlo igual o redondearlo
-- hacia arriba o hacia abajo sin restricción de monto. Se guardan AMBOS valores:
--   - precio_oficial: el calculado por el sistema — es lo que antes era el único valor y vivía
--     en ventas.total.
--   - precio_cobrado: el confirmado/editado por el cajero (puede ser igual al oficial).
--
-- ventas.total pasa a significar precio_cobrado de acá en más — así todo lo que ya lee
-- ventas.total (comprobante impreso, Factura C/ARCA, saldo de cuenta corriente, historial) sigue
-- funcionando sin tocarlo y automáticamente refleja lo realmente cobrado, no el precio de lista.
--
-- venta_pagos (docs/22) también pasa a sumar precio_cobrado: si el pago es combinado, cada parte
-- se reescala proporcionalmente al reparto original para que la suma dé exacto el precio cobrado
-- (la última parte absorbe el centavo de redondeo) — así cerrar_caja, que arma
-- total_efectivo/tarjeta/etc. sumando venta_pagos.monto, siempre refleja el efectivo/plástico
-- realmente recibido, no el oficial.
--
-- ATENCIÓN AL APLICAR EN SUPABASE: cerrar_caja de este archivo ya incluye el merge de docs/21
-- (apertura de caja) + docs/22 (venta_pagos) tal como está hoy en producción — solo se le cambia
-- la línea de v_total_cuenta_corriente para leer precio_cobrado en vez de total. Si se vuelve a
-- tocar cerrar_caja más adelante, partir de la versión de ESTE archivo, no de docs/21 ni docs/22
-- por separado.

-- ============================================================
-- 1. ventas — dos columnas nuevas. Backfill de lo ya cargado: toda venta previa a este cambio no
-- tuvo redondeo manual, así que precio_oficial = precio_cobrado = total.
-- ============================================================
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS precio_oficial NUMERIC(12,2);
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS precio_cobrado NUMERIC(12,2);

UPDATE ventas SET precio_oficial = total, precio_cobrado = total WHERE precio_oficial IS NULL;

ALTER TABLE ventas ALTER COLUMN precio_oficial SET NOT NULL;
ALTER TABLE ventas ALTER COLUMN precio_cobrado SET NOT NULL;
ALTER TABLE ventas ADD CONSTRAINT chk_ventas_precio_cobrado_positivo CHECK (precio_cobrado > 0);

-- ============================================================
-- 2. confirmar_venta — agrega p_precio_cobrado. Sin él (o NULL): comportamiento idéntico a hoy,
-- precio_cobrado = precio_oficial. De paso se limpia el overload de 5 parámetros que había
-- quedado huérfano desde antes de docs/20 (sin recargo ni pagos, ya no lo llama nadie).
-- ============================================================
DROP FUNCTION IF EXISTS confirmar_venta(UUID, forma_pago_venta, JSONB, NUMERIC, TEXT);
DROP FUNCTION IF EXISTS confirmar_venta(UUID, forma_pago_venta, JSONB, NUMERIC, TEXT, NUMERIC, JSONB);

CREATE OR REPLACE FUNCTION confirmar_venta(
  p_cliente_id UUID,
  p_forma_pago forma_pago_venta,
  p_items JSONB,  -- [{"producto_id":"...", "cantidad":1, "precio_unitario":12500, "descuento_porcentaje":0}]
  p_descuento_porcentaje NUMERIC DEFAULT 0,
  p_nota TEXT DEFAULT NULL,
  p_recargo_porcentaje NUMERIC DEFAULT 0,
  p_pagos JSONB DEFAULT NULL,  -- [{"forma_pago":"efectivo","monto":500},{"forma_pago":"tarjeta_credito","monto":1000}]
  p_precio_cobrado NUMERIC DEFAULT NULL  -- precio final editado por el cajero; NULL = igual al oficial
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
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
-- 3. cerrar_caja — versión completa (docs/21 apertura + docs/22 venta_pagos, ya mergeadas en
-- producción) con un solo cambio: la rama de cuenta corriente lee precio_cobrado en vez de total
-- (hoy da lo mismo porque total = precio_cobrado, pero así queda explícito y no depende de esa
-- equivalencia si el día de mañana cambia).
-- ============================================================
CREATE OR REPLACE FUNCTION cerrar_caja(
  p_tipo tipo_cierre,
  p_efectivo_contado NUMERIC DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_cierre_id UUID;
  v_apertura aperturas_caja%ROWTYPE;
  v_monto_base NUMERIC;
  v_total_efectivo NUMERIC;
  v_total_transferencia NUMERIC;
  v_total_qr NUMERIC;
  v_total_tarjeta NUMERIC;
  v_total_cuenta_corriente NUMERIC;
  v_total_egresos NUMERIC;
  v_total_egresos_efectivo NUMERIC;
  v_total_retiros NUMERIC;
  v_efectivo_esperado NUMERIC;
  v_diferencia NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  SELECT * INTO v_apertura FROM aperturas_caja WHERE cierre_z_id IS NULL ORDER BY abierta_at DESC LIMIT 1;
  v_monto_base := COALESCE(v_apertura.monto_real, 0);

  SELECT COALESCE(SUM(vp.monto) FILTER (WHERE vp.forma_pago = 'efectivo'), 0),
         COALESCE(SUM(vp.monto) FILTER (WHERE vp.forma_pago = 'transferencia'), 0),
         COALESCE(SUM(vp.monto) FILTER (WHERE vp.forma_pago = 'qr'), 0),
         COALESCE(SUM(vp.monto) FILTER (WHERE vp.forma_pago IN ('tarjeta_debito','tarjeta_credito')), 0)
  INTO v_total_efectivo, v_total_transferencia, v_total_qr, v_total_tarjeta
  FROM venta_pagos vp
  JOIN ventas v ON v.id = vp.venta_id
  WHERE v.created_at::date = current_date AND v.estado <> 'anulada';

  SELECT COALESCE(SUM(precio_cobrado), 0) INTO v_total_cuenta_corriente
  FROM ventas
  WHERE created_at::date = current_date AND estado <> 'anulada' AND forma_pago = 'cuenta_corriente';

  SELECT COALESCE(SUM(monto), 0) INTO v_total_egresos
  FROM egresos WHERE created_at::date = current_date;

  SELECT COALESCE(SUM(monto), 0) INTO v_total_egresos_efectivo
  FROM egresos WHERE created_at::date = current_date AND forma_pago = 'efectivo';

  SELECT COALESCE(SUM(monto), 0) INTO v_total_retiros
  FROM retiros_caja WHERE fecha = current_date;

  v_efectivo_esperado := v_monto_base + v_total_efectivo - v_total_egresos_efectivo - v_total_retiros;
  v_diferencia := CASE WHEN p_efectivo_contado IS NOT NULL THEN p_efectivo_contado - v_efectivo_esperado ELSE NULL END;

  INSERT INTO cierres_caja (tipo, turno_fecha, total_efectivo, total_transferencia, total_qr, total_tarjeta,
         total_cuenta_corriente, total_egresos, total_retiros, efectivo_esperado, efectivo_contado, diferencia,
         estado_validacion, usuario_id, apertura_id)
  VALUES (p_tipo, current_date, v_total_efectivo, v_total_transferencia, v_total_qr, v_total_tarjeta,
         v_total_cuenta_corriente, v_total_egresos, v_total_retiros, v_efectivo_esperado, p_efectivo_contado, v_diferencia,
         CASE WHEN p_tipo = 'z' THEN 'pendiente_validacion'::estado_cierre_z ELSE NULL END, auth.uid(), v_apertura.id)
  RETURNING id INTO v_cierre_id;

  IF p_tipo = 'z' AND v_apertura.id IS NOT NULL THEN
    UPDATE aperturas_caja SET cierre_z_id = v_cierre_id WHERE id = v_apertura.id;
  END IF;

  RETURN v_cierre_id;
END;
$$;

-- ============================================================
-- Verificación:
-- 1. Confirmar una venta sin tocar el precio final → precio_oficial = precio_cobrado = total.
-- 2. Confirmar una venta bajando y otra subiendo el precio final → precio_oficial y
--    precio_cobrado quedan distintos, total = precio_cobrado.
-- 3. Venta combinada con precio final editado → las 2 filas de venta_pagos deben sumar
--    exactamente precio_cobrado, no precio_oficial.
-- 4. cerrar_caja('x') → total_efectivo/tarjeta/etc. y total_cuenta_corriente tienen que reflejar
--    precio_cobrado, no precio_oficial.
-- ============================================================
SELECT numero, forma_pago, subtotal, precio_oficial, precio_cobrado, total,
       (precio_cobrado - precio_oficial) AS diferencia
FROM ventas
ORDER BY created_at DESC
LIMIT 10;
