-- 22 — Pagos combinados en Ventas (hasta 2 medios de pago por venta)
--
-- Pedido: en el paso de confirmación de pago, poder elegir "Pago combinado" y repartir el total
-- entre hasta 2 medios de pago existentes, con el monto exacto de cada uno. Cuenta corriente
-- queda afuera de la combinación — sigue siendo un medio exclusivo, no combinable, para no tener
-- que rediseñar el cálculo de deuda de cliente (vista clientes_saldo, ClienteDetalleModal), que
-- hoy depende de ventas.forma_pago = 'cuenta_corriente'. El cierre de caja tiene que discriminar
-- cada parte del pago combinado por su propio medio, no cargar la venta completa a uno solo.
--
-- ATENCIÓN AL APLICAR EN SUPABASE: docs/21_apertura_caja.sql también reemplaza cerrar_caja (agrega
-- v_monto_base de apertura + cierra la apertura vigente si p_tipo='z'). Si los dos patches se van a
-- aplicar, hay que fusionar a mano el cerrar_caja final: la agregación por venta_pagos de este
-- archivo (sección 4) + v_monto_base/apertura_id de docs/21 — el que se corra último en Supabase,
-- si no se fusiona, pisa por completo los cambios del otro (CREATE OR REPLACE FUNCTION reemplaza
-- toda la función, no solo lo que cambió).

-- ============================================================
-- 1. Nuevo valor de enum — una venta combinada queda marcada así en ventas.forma_pago (columna
-- "resumen"; el detalle real de montos por medio vive en venta_pagos, tabla nueva de abajo).
-- ============================================================
ALTER TYPE forma_pago_venta ADD VALUE IF NOT EXISTS 'combinado';
-- (correr esta línea sola, esperar a que termine, recién después seguir con el resto —
-- Postgres no permite usar un valor de enum nuevo en la misma transacción que lo crea)

-- ============================================================
-- 2. venta_pagos — detalle de medios de pago por venta (1 fila = 1 parte del pago).
-- Se puebla para TODA venta que no sea cuenta corriente (1 fila si es pago simple, 2 si es
-- combinado) — así cerrar_caja tiene una sola fuente de verdad para discriminar por medio, en
-- vez de dos caminos distintos según si la venta fue simple o combinada.
-- ============================================================
CREATE TABLE IF NOT EXISTS venta_pagos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  venta_id UUID NOT NULL REFERENCES ventas(id) ON DELETE CASCADE,
  forma_pago forma_pago_venta NOT NULL,
  monto NUMERIC(12,2) NOT NULL,
  usuario_id UUID NOT NULL REFERENCES perfiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE venta_pagos ADD CONSTRAINT chk_venta_pagos_no_cta_cte
  CHECK (forma_pago NOT IN ('cuenta_corriente', 'combinado'));
ALTER TABLE venta_pagos ADD CONSTRAINT chk_venta_pagos_monto_positivo CHECK (monto > 0);
CREATE INDEX IF NOT EXISTS idx_venta_pagos_venta ON venta_pagos(venta_id);

ALTER TABLE venta_pagos ENABLE ROW LEVEL SECURITY;
CREATE POLICY "venta_pagos_todos" ON venta_pagos FOR ALL USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
);

-- Backfill: toda venta ya existente que no sea cuenta corriente pasa a tener su fila en
-- venta_pagos (pago simple = 1 fila por el total), para que cerrar_caja pueda sumar siempre
-- desde acá sin importar si la venta es de antes o de después de este cambio.
INSERT INTO venta_pagos (venta_id, forma_pago, monto, usuario_id, created_at)
SELECT id, forma_pago, total, usuario_id, created_at
FROM ventas
WHERE forma_pago <> 'cuenta_corriente'
  AND NOT EXISTS (SELECT 1 FROM venta_pagos vp WHERE vp.venta_id = ventas.id);

-- ============================================================
-- 3. confirmar_venta — agrega p_pagos JSONB opcional para pago combinado.
-- Sin p_pagos (o vacío): comportamiento idéntico a hoy, un solo medio (p_forma_pago), y se
-- inserta igual 1 fila en venta_pagos con el total — así cerrar_caja no distingue casos.
-- Con p_pagos: hasta 2 medios (ninguno puede ser cuenta_corriente), la suma tiene que dar
-- exactamente el total, y ventas.forma_pago queda en 'combinado'.
-- ============================================================
CREATE OR REPLACE FUNCTION confirmar_venta(
  p_cliente_id UUID,
  p_forma_pago forma_pago_venta,
  p_items JSONB,  -- [{"producto_id":"...", "cantidad":1, "precio_unitario":12500, "descuento_porcentaje":0}]
  p_descuento_porcentaje NUMERIC DEFAULT 0,
  p_nota TEXT DEFAULT NULL,
  p_recargo_porcentaje NUMERIC DEFAULT 0,
  p_pagos JSONB DEFAULT NULL  -- [{"forma_pago":"efectivo","monto":500},{"forma_pago":"tarjeta_credito","monto":1000}]
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_venta_id UUID;
  v_item JSONB;
  v_pago JSONB;
  v_subtotal NUMERIC := 0;
  v_total NUMERIC;
  v_importe NUMERIC;
  v_forma_pago_final forma_pago_venta;
  v_suma_pagos NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  SELECT COALESCE(SUM((i->>'cantidad')::NUMERIC * (i->>'precio_unitario')::NUMERIC
           * (1 - COALESCE((i->>'descuento_porcentaje')::NUMERIC,0)/100.0)), 0)
  INTO v_subtotal
  FROM jsonb_array_elements(p_items) AS i;

  v_total := ROUND(v_subtotal * (1 - COALESCE(p_descuento_porcentaje,0)/100.0)
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
    SELECT COALESCE(SUM((p->>'monto')::NUMERIC), 0) INTO v_suma_pagos FROM jsonb_array_elements(p_pagos) AS p;
    IF ROUND(v_suma_pagos, 2) <> v_total THEN
      RAISE EXCEPTION 'La suma de los pagos (%) no coincide con el total de la venta (%)', v_suma_pagos, v_total;
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

  INSERT INTO ventas (cliente_id, forma_pago, subtotal, descuento_porcentaje, recargo_porcentaje, total, nota, usuario_id)
  VALUES (p_cliente_id, v_forma_pago_final, v_subtotal, COALESCE(p_descuento_porcentaje,0),
          COALESCE(p_recargo_porcentaje,0), v_total, p_nota, auth.uid())
  RETURNING id INTO v_venta_id;

  IF v_forma_pago_final <> 'cuenta_corriente' THEN
    IF p_pagos IS NOT NULL AND jsonb_array_length(p_pagos) > 0 THEN
      FOR v_pago IN SELECT * FROM jsonb_array_elements(p_pagos)
      LOOP
        INSERT INTO venta_pagos (venta_id, forma_pago, monto, usuario_id)
        VALUES (v_venta_id, (v_pago->>'forma_pago')::forma_pago_venta, (v_pago->>'monto')::NUMERIC, auth.uid());
      END LOOP;
    ELSE
      INSERT INTO venta_pagos (venta_id, forma_pago, monto, usuario_id)
      VALUES (v_venta_id, v_forma_pago_final, v_total, auth.uid());
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
-- 4. cerrar_caja — discrimina por venta_pagos.monto en vez de ventas.total, así una venta
-- combinada aporta a cada medio por separado (ej. $500 efectivo + $1000 tarjeta → $500 a
-- total_efectivo y $1000 a total_tarjeta, no $1500 a uno solo).
-- ============================================================
CREATE OR REPLACE FUNCTION cerrar_caja(
  p_tipo tipo_cierre,
  p_efectivo_contado NUMERIC DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_cierre_id UUID;
  v_total_efectivo NUMERIC;
  v_total_transferencia NUMERIC;
  v_total_qr NUMERIC;
  v_total_tarjeta NUMERIC;
  v_total_cuenta_corriente NUMERIC;
  v_total_egresos NUMERIC;          -- total general, todas las formas, para mostrar en el resumen
  v_total_egresos_efectivo NUMERIC; -- solo esto resta del cajón físico
  v_total_retiros NUMERIC;          -- docs/17: retiros de efectivo del día — también salen del cajón físico
  v_efectivo_esperado NUMERIC;
  v_diferencia NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  -- Efectivo/transferencia/QR/tarjeta salen del detalle por parte (venta_pagos) — no de
  -- ventas.total, que en una venta combinada no pertenece a un solo medio.
  SELECT COALESCE(SUM(vp.monto) FILTER (WHERE vp.forma_pago = 'efectivo'), 0),
         COALESCE(SUM(vp.monto) FILTER (WHERE vp.forma_pago = 'transferencia'), 0),
         COALESCE(SUM(vp.monto) FILTER (WHERE vp.forma_pago = 'qr'), 0),
         COALESCE(SUM(vp.monto) FILTER (WHERE vp.forma_pago IN ('tarjeta_debito','tarjeta_credito')), 0)
  INTO v_total_efectivo, v_total_transferencia, v_total_qr, v_total_tarjeta
  FROM venta_pagos vp
  JOIN ventas v ON v.id = vp.venta_id
  WHERE v.created_at::date = current_date AND v.estado <> 'anulada';

  -- Cuenta corriente sigue sin combinarse — se sigue leyendo directo de ventas.total
  SELECT COALESCE(SUM(total), 0) INTO v_total_cuenta_corriente
  FROM ventas
  WHERE created_at::date = current_date AND estado <> 'anulada' AND forma_pago = 'cuenta_corriente';

  SELECT COALESCE(SUM(monto), 0) INTO v_total_egresos
  FROM egresos WHERE created_at::date = current_date;

  SELECT COALESCE(SUM(monto), 0) INTO v_total_egresos_efectivo
  FROM egresos WHERE created_at::date = current_date AND forma_pago = 'efectivo';

  SELECT COALESCE(SUM(monto), 0) INTO v_total_retiros
  FROM retiros_caja WHERE fecha = current_date;

  v_efectivo_esperado := v_total_efectivo - v_total_egresos_efectivo - v_total_retiros;
  v_diferencia := CASE WHEN p_efectivo_contado IS NOT NULL THEN p_efectivo_contado - v_efectivo_esperado ELSE NULL END;

  INSERT INTO cierres_caja (tipo, turno_fecha, total_efectivo, total_transferencia, total_qr, total_tarjeta,
         total_cuenta_corriente, total_egresos, total_retiros, efectivo_esperado, efectivo_contado, diferencia,
         estado_validacion, usuario_id)
  VALUES (p_tipo, current_date, v_total_efectivo, v_total_transferencia, v_total_qr, v_total_tarjeta,
         v_total_cuenta_corriente, v_total_egresos, v_total_retiros, v_efectivo_esperado, p_efectivo_contado, v_diferencia,
         CASE WHEN p_tipo = 'z' THEN 'pendiente_validacion'::estado_cierre_z ELSE NULL END, auth.uid())
  RETURNING id INTO v_cierre_id;

  RETURN v_cierre_id;
END;
$$;

-- ============================================================
-- 5. pagos_cliente (cobro de cuenta corriente) — el mismo enum forma_pago_venta se usa acá,
-- así que sin este ajuste "combinado" quedaría seleccionable como si fuera un medio real de
-- cobro. Un cobro de cliente siempre es un solo medio, igual que antes.
-- ============================================================
ALTER TABLE pagos_cliente DROP CONSTRAINT IF EXISTS chk_pago_cliente_forma_pago;
ALTER TABLE pagos_cliente ADD CONSTRAINT chk_pago_cliente_forma_pago
  CHECK (forma_pago NOT IN ('cuenta_corriente', 'combinado'));

-- ============================================================
-- Verificación:
-- 1. Hacer una venta combinada (ej. $500 efectivo + $1000 tarjeta_credito vía p_pagos) y
--    confirmar que queden 2 filas en venta_pagos y que ventas.forma_pago = 'combinado'.
-- 2. Correr cerrar_caja('x') y confirmar que total_efectivo y total_tarjeta reflejen cada
--    parte por separado, no el total combinado en un solo medio.
-- ============================================================
SELECT vp.forma_pago AS medio, vp.monto, v.numero, v.forma_pago AS forma_pago_venta, v.total
FROM venta_pagos vp
JOIN ventas v ON v.id = vp.venta_id
ORDER BY vp.created_at DESC
LIMIT 10;
