-- 24 — Devoluciones y cambios de productos (Virikyna Local)
--
-- Una devolución/cambio es un DOCUMENTO NUEVO vinculado a una venta ya emitida — nunca modifica la
-- venta original (ni ventas, ni venta_items, ni venta_pagos). Mismo principio que la anulación:
-- las correcciones son filas nuevas, no ediciones.
--
-- Alcance EXCLUIDO a propósito (no implementado, solo registro interno):
--   - Comprobante impreso de la devolución.
--   - Cuenta corriente / vouchers formales: solo el campo `observaciones` de texto libre.
--   - Nota de crédito AFIP/ARCA: si la venta original tiene Factura C, la devolución es solo un
--     registro interno, no genera comprobante fiscal.
--
-- DECISIONES DE DISEÑO (revisar antes de aplicar):
--   1. Precio de lo devuelto = lo que el cliente realmente pagó por esa unidad: importe de la línea
--      de venta ÷ cantidad, reescalado por total/subtotal de la venta (así respeta el descuento y
--      recargo global y el redondeo manual de docs/23). Sin esto, devolver un ítem de una venta con
--      10% de descuento reintegraría de más. Lo calcula el RPC, no el cliente.
--   2. Precio de lo nuevo (cambio) = productos.precio_venta ACTUAL, también leído por el RPC.
--   3. Stock: se usa tipo 'ajuste' con referencia_id = devolucion_id (igual que anular_venta) — no
--      se agrega un valor nuevo al enum tipo_movimiento_stock. Por esa misma razón el Historial de
--      Gestión NO ofrece "Revertir" sobre estos movimientos (referencia_id IS NOT NULL); el camino
--      de reversión es anular_devolucion.
--   4. Ítems devueltos por motivo 'defectuoso' NO reingresan al stock (reingresa_stock = false, sin
--      movimiento de stock): quedan contados en el dashboard como "pendientes de revisión".
--   5. La diferencia se salda con UNA forma de pago o combinado (hasta 2 medios, tabla
--      devolucion_pagos). 'cuenta_corriente' NO se admite para saldar la diferencia: no hay sistema
--      de cuenta corriente para saldos a favor (para eso está `observaciones`).
--   6. Caja: los pagos de la diferencia impactan la caja ABIERTA AL MOMENTO de crear la devolución
--      (cerrar_caja filtra por devoluciones.fecha = current_date, igual que ventas/egresos/retiros),
--      nunca el cierre de la venta original. Una devolución en efectivo a favor del cliente resta de
--      efectivo_esperado igual que un retiro/egreso en efectivo.
--   7. anular_devolucion (solo admin) revierte el stock y saca la devolución de los cierres NO
--      emitidos todavía. Igual que anular_venta: anular una devolución de un día cuyo cierre ya se
--      hizo no reescribe ese cierre.
--
-- ORDEN: correr todo de una vez, en el SQL Editor de Supabase, DESPUÉS de docs/23 (la versión de
-- cerrar_caja de acá parte de la de docs/23 y la de validar_cierre_z parte de la de docs/14).
-- CREATE OR REPLACE FUNCTION reemplaza la función entera: si se vuelve a tocar cerrar_caja o
-- validar_cierre_z, partir de la versión de ESTE archivo.

-- ============================================================
-- 1. Tipos
-- ============================================================
CREATE TYPE motivo_devolucion AS ENUM ('regalo', 'defectuoso', 'arrepentimiento', 'otro');
CREATE TYPE estado_devolucion AS ENUM ('activa', 'anulada');
CREATE TYPE tipo_item_devolucion AS ENUM ('devuelto', 'nuevo');

-- ============================================================
-- 2. devoluciones — cabecera
-- ============================================================
CREATE TABLE devoluciones (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  numero BIGINT GENERATED ALWAYS AS IDENTITY,
  venta_id UUID NOT NULL REFERENCES ventas(id),
  fecha DATE NOT NULL DEFAULT current_date,              -- día de caja en el que impacta
  usuario_id UUID NOT NULL REFERENCES perfiles(id),      -- cajero o admin que la hizo
  motivo motivo_devolucion NOT NULL,
  motivo_detalle TEXT,                                   -- obligatorio si motivo = 'otro'
  observaciones TEXT,                                    -- libre: saldos a favor, vouchers internos, etc.
  -- total ítems nuevos − total ítems devueltos. > 0: paga el cliente. < 0: a favor del cliente.
  diferencia_monto NUMERIC(12,2) NOT NULL DEFAULT 0,
  diferencia_forma_pago forma_pago_venta,                -- null si diferencia_monto = 0; 'combinado' → ver devolucion_pagos
  estado estado_devolucion NOT NULL DEFAULT 'activa',
  anulada_por UUID REFERENCES perfiles(id),
  anulada_at TIMESTAMPTZ,
  motivo_anulacion TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_devolucion_motivo_otro
    CHECK (motivo <> 'otro' OR (motivo_detalle IS NOT NULL AND btrim(motivo_detalle) <> '')),
  CONSTRAINT chk_devolucion_forma_pago_coherente
    CHECK ((diferencia_monto = 0 AND diferencia_forma_pago IS NULL)
        OR (diferencia_monto <> 0 AND diferencia_forma_pago IS NOT NULL)),
  CONSTRAINT chk_devolucion_forma_pago_sin_cta_cte
    CHECK (diferencia_forma_pago IS NULL OR diferencia_forma_pago <> 'cuenta_corriente')
);
CREATE INDEX idx_devoluciones_venta ON devoluciones(venta_id);
CREATE INDEX idx_devoluciones_fecha ON devoluciones(fecha);

-- ============================================================
-- 3. devolucion_items — ítems devueltos y ítems nuevos (cambio)
-- ============================================================
CREATE TABLE devolucion_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  devolucion_id UUID NOT NULL REFERENCES devoluciones(id) ON DELETE CASCADE,
  tipo tipo_item_devolucion NOT NULL,
  producto_id UUID NOT NULL REFERENCES productos(id),
  cantidad NUMERIC(10,2) NOT NULL CHECK (cantidad > 0),
  precio_unitario NUMERIC(12,2) NOT NULL CHECK (precio_unitario >= 0),  -- snapshot al momento
  reingresa_stock BOOLEAN NOT NULL DEFAULT true          -- false = mercadería defectuosa, separada del stock
);
CREATE INDEX idx_devolucion_items_devolucion ON devolucion_items(devolucion_id);
CREATE INDEX idx_devolucion_items_producto ON devolucion_items(producto_id);
-- Para el contador del dashboard ("defectuosos pendientes de revisión")
CREATE INDEX idx_devolucion_items_defectuosos ON devolucion_items(devolucion_id) WHERE reingresa_stock = false;

-- ============================================================
-- 4. devolucion_pagos — cómo se saldó la diferencia (1 fila = 1 medio; 2 si es combinado)
-- El monto es siempre positivo: el sentido (entra/sale plata) lo da el signo de
-- devoluciones.diferencia_monto. Mismo criterio que venta_pagos (docs/22): cerrar_caja tiene una
-- sola fuente para discriminar por medio.
-- ============================================================
CREATE TABLE devolucion_pagos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  devolucion_id UUID NOT NULL REFERENCES devoluciones(id) ON DELETE CASCADE,
  forma_pago forma_pago_venta NOT NULL,
  monto NUMERIC(12,2) NOT NULL CHECK (monto > 0),
  CONSTRAINT chk_devolucion_pagos_forma CHECK (forma_pago NOT IN ('cuenta_corriente', 'combinado'))
);
CREATE INDEX idx_devolucion_pagos_devolucion ON devolucion_pagos(devolucion_id);

-- ============================================================
-- 5. RLS — lectura para cualquier usuario activo; SIN policies de escritura: el único camino es
-- crear_devolucion / anular_devolucion (SECURITY DEFINER), igual que aperturas_caja.
-- ============================================================
ALTER TABLE devoluciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE devolucion_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE devolucion_pagos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "devoluciones_ver_todos" ON devoluciones FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
);
CREATE POLICY "devolucion_items_ver_todos" ON devolucion_items FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
);
CREATE POLICY "devolucion_pagos_ver_todos" ON devolucion_pagos FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
);

-- Auditoría: solo el alta por trigger. La anulación inserta su propia fila (accion='anulacion')
-- desde el RPC — por eso el trigger NO cubre UPDATE (saldría duplicada como 'edicion').
CREATE TRIGGER trg_auditoria_devoluciones AFTER INSERT ON devoluciones
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_generica();

-- ============================================================
-- 6. cierres_caja — línea "Devoluciones" separada de las ventas.
-- Netos con signo por medio: positivo = el comercio cobró una diferencia, negativo = el comercio
-- devolvió plata al cliente. total_efectivo/transferencia/qr/tarjeta siguen siendo SOLO ventas.
-- ============================================================
ALTER TABLE cierres_caja ADD COLUMN IF NOT EXISTS cantidad_devoluciones INT NOT NULL DEFAULT 0;
ALTER TABLE cierres_caja ADD COLUMN IF NOT EXISTS total_devoluciones_efectivo NUMERIC(12,2) NOT NULL DEFAULT 0;
ALTER TABLE cierres_caja ADD COLUMN IF NOT EXISTS total_devoluciones_transferencia NUMERIC(12,2) NOT NULL DEFAULT 0;
ALTER TABLE cierres_caja ADD COLUMN IF NOT EXISTS total_devoluciones_qr NUMERIC(12,2) NOT NULL DEFAULT 0;
ALTER TABLE cierres_caja ADD COLUMN IF NOT EXISTS total_devoluciones_tarjeta NUMERIC(12,2) NOT NULL DEFAULT 0;

-- ============================================================
-- 7. crear_devolucion — único punto de entrada. Permitido a cajero y admin (mismo nivel que vender).
--
-- p_items_devueltos: [{"producto_id":"...", "cantidad":1}]           (obligatorio, al menos 1)
-- p_items_nuevos:    [{"producto_id":"...", "cantidad":1}]           (opcional — solo si es cambio)
-- p_forma_pago:      medio único para saldar la diferencia            (ignorado si no hay diferencia)
-- p_pagos:           [{"forma_pago":"efectivo","monto":500}, ...]     (opcional, hasta 2 — pago combinado)
--
-- Los precios NO vienen del cliente: se leen de la venta original (devuelto) y de productos (nuevo).
-- ============================================================
CREATE OR REPLACE FUNCTION crear_devolucion(
  p_venta_id UUID,
  p_motivo motivo_devolucion,
  p_motivo_detalle TEXT,
  p_observaciones TEXT,
  p_items_devueltos JSONB,
  p_items_nuevos JSONB DEFAULT NULL,
  p_forma_pago forma_pago_venta DEFAULT NULL,
  p_pagos JSONB DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
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
    INSERT INTO devolucion_items (devolucion_id, tipo, producto_id, cantidad, precio_unitario, reingresa_stock)
    VALUES (v_devolucion_id, 'devuelto', v_row.producto_id, v_row.cantidad, v_row.precio_unitario, v_reingresa);

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
    INSERT INTO devolucion_items (devolucion_id, tipo, producto_id, cantidad, precio_unitario, reingresa_stock)
    VALUES (v_devolucion_id, 'nuevo', v_row.producto_id, v_row.cantidad, v_row.precio_unitario, true);

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
$$;

-- ============================================================
-- 8. anular_devolucion — SOLO admin. Revierte el stock y marca la devolución como anulada.
-- Las filas originales nunca se borran (la reversión es un movimiento de stock nuevo).
-- ============================================================
CREATE OR REPLACE FUNCTION anular_devolucion(p_devolucion_id UUID, p_motivo TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_dev devoluciones%ROWTYPE;
  v_item RECORD;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede anular una devolución';
  END IF;
  IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
    RAISE EXCEPTION 'El motivo es obligatorio para anular una devolución';
  END IF;

  SELECT * INTO v_dev FROM devoluciones WHERE id = p_devolucion_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Devolución no encontrada'; END IF;
  IF v_dev.estado = 'anulada' THEN RAISE EXCEPTION 'Esta devolución ya está anulada'; END IF;

  FOR v_item IN SELECT * FROM devolucion_items WHERE devolucion_id = p_devolucion_id LOOP
    -- devuelto que había reingresado → sale del stock; nuevo entregado → vuelve al stock.
    -- Un devuelto defectuoso (reingresa_stock = false) nunca tocó el stock: no hay nada que revertir.
    IF v_item.tipo = 'devuelto' AND NOT v_item.reingresa_stock THEN CONTINUE; END IF;

    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
    VALUES (v_item.producto_id, 'local', 'ajuste',
            CASE WHEN v_item.tipo = 'devuelto' THEN -v_item.cantidad ELSE v_item.cantidad END,
            'Anulación de devolución #' || v_dev.numero || ': ' || p_motivo, p_devolucion_id, auth.uid());
    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES (v_item.producto_id, 'local',
            CASE WHEN v_item.tipo = 'devuelto' THEN -v_item.cantidad ELSE v_item.cantidad END)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad
                            + CASE WHEN v_item.tipo = 'devuelto' THEN -v_item.cantidad ELSE v_item.cantidad END;
  END LOOP;

  UPDATE devoluciones
  SET estado = 'anulada', anulada_por = auth.uid(), anulada_at = now(), motivo_anulacion = p_motivo
  WHERE id = p_devolucion_id;

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, valores_nuevos, usuario_id, nota)
  VALUES ('devoluciones', p_devolucion_id, 'anulacion', to_jsonb(v_dev),
          jsonb_set(to_jsonb(v_dev), '{estado}', '"anulada"'), auth.uid(), p_motivo);
END;
$$;

-- ============================================================
-- 9. cerrar_caja — versión de docs/23 + devoluciones como línea separada.
-- Únicos cambios vs. docs/23: (a) netos de devoluciones por medio (devolucion_pagos, solo
-- devoluciones activas de HOY), (b) efectivo_esperado suma el neto en efectivo — una devolución
-- en efectivo a favor del cliente (negativo) resta del cajón igual que un retiro/egreso —, y (c)
-- se guardan los nuevos totales en cierres_caja.
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
  v_dev_efectivo NUMERIC;
  v_dev_transferencia NUMERIC;
  v_dev_qr NUMERIC;
  v_dev_tarjeta NUMERIC;
  v_cant_devoluciones INT;
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

  -- Devoluciones/cambios de hoy: neto con signo por medio (+ el comercio cobró / − devolvió plata)
  SELECT COALESCE(SUM(CASE WHEN d.diferencia_monto >= 0 THEN dp.monto ELSE -dp.monto END)
                    FILTER (WHERE dp.forma_pago = 'efectivo'), 0),
         COALESCE(SUM(CASE WHEN d.diferencia_monto >= 0 THEN dp.monto ELSE -dp.monto END)
                    FILTER (WHERE dp.forma_pago = 'transferencia'), 0),
         COALESCE(SUM(CASE WHEN d.diferencia_monto >= 0 THEN dp.monto ELSE -dp.monto END)
                    FILTER (WHERE dp.forma_pago = 'qr'), 0),
         COALESCE(SUM(CASE WHEN d.diferencia_monto >= 0 THEN dp.monto ELSE -dp.monto END)
                    FILTER (WHERE dp.forma_pago IN ('tarjeta_debito','tarjeta_credito')), 0)
  INTO v_dev_efectivo, v_dev_transferencia, v_dev_qr, v_dev_tarjeta
  FROM devolucion_pagos dp
  JOIN devoluciones d ON d.id = dp.devolucion_id
  WHERE d.fecha = current_date AND d.estado = 'activa';

  SELECT COUNT(*) INTO v_cant_devoluciones
  FROM devoluciones WHERE fecha = current_date AND estado = 'activa';

  SELECT COALESCE(SUM(monto), 0) INTO v_total_egresos
  FROM egresos WHERE created_at::date = current_date;

  SELECT COALESCE(SUM(monto), 0) INTO v_total_egresos_efectivo
  FROM egresos WHERE created_at::date = current_date AND forma_pago = 'efectivo';

  SELECT COALESCE(SUM(monto), 0) INTO v_total_retiros
  FROM retiros_caja WHERE fecha = current_date;

  v_efectivo_esperado := v_monto_base + v_total_efectivo + v_dev_efectivo - v_total_egresos_efectivo - v_total_retiros;
  v_diferencia := CASE WHEN p_efectivo_contado IS NOT NULL THEN p_efectivo_contado - v_efectivo_esperado ELSE NULL END;

  INSERT INTO cierres_caja (tipo, turno_fecha, total_efectivo, total_transferencia, total_qr, total_tarjeta,
         total_cuenta_corriente, total_egresos, total_retiros, efectivo_esperado, efectivo_contado, diferencia,
         estado_validacion, usuario_id, apertura_id,
         cantidad_devoluciones, total_devoluciones_efectivo, total_devoluciones_transferencia,
         total_devoluciones_qr, total_devoluciones_tarjeta)
  VALUES (p_tipo, current_date, v_total_efectivo, v_total_transferencia, v_total_qr, v_total_tarjeta,
         v_total_cuenta_corriente, v_total_egresos, v_total_retiros, v_efectivo_esperado, p_efectivo_contado, v_diferencia,
         CASE WHEN p_tipo = 'z' THEN 'pendiente_validacion'::estado_cierre_z ELSE NULL END, auth.uid(), v_apertura.id,
         v_cant_devoluciones, v_dev_efectivo, v_dev_transferencia, v_dev_qr, v_dev_tarjeta)
  RETURNING id INTO v_cierre_id;

  IF p_tipo = 'z' AND v_apertura.id IS NOT NULL THEN
    UPDATE aperturas_caja SET cierre_z_id = v_cierre_id WHERE id = v_apertura.id;
  END IF;

  RETURN v_cierre_id;
END;
$$;

-- ============================================================
-- 10. validar_cierre_z — versión de docs/14 con el neto de devoluciones sumado a lo que se vuelca
-- a movimientos_cuenta por medio (transferencia → Mercado Pago, QR/tarjeta → Galicia). Sin esto,
-- una devolución por transferencia devolvería plata real que la cuenta nunca descuenta. Efectivo
-- sigue sin volcarse acá (docs/14). El monto puede ser negativo (ledger: negativo = egreso), por
-- eso el filtro pasa de "> 0" a "<> 0".
-- ============================================================
CREATE OR REPLACE FUNCTION validar_cierre_z(p_cierre_id UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_cierre cierres_caja%ROWTYPE;
  v_monto_tarjeta NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede validar un Cierre Z';
  END IF;

  SELECT * INTO v_cierre FROM cierres_caja WHERE id = p_cierre_id AND tipo = 'z';
  IF NOT FOUND THEN RAISE EXCEPTION 'Cierre Z no encontrado'; END IF;
  IF v_cierre.estado_validacion = 'validado' THEN RAISE EXCEPTION 'Este Cierre Z ya fue validado'; END IF;

  UPDATE cierres_caja SET estado_validacion = 'validado', validado_por = auth.uid(), validado_at = now()
  WHERE id = p_cierre_id;

  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
  SELECT cfp.cuenta_id, 'cierre_z', v.monto, p_cierre_id, auth.uid()
  FROM (VALUES
    ('transferencia'::forma_pago_venta, v_cierre.total_transferencia + v_cierre.total_devoluciones_transferencia),
    ('qr'::forma_pago_venta, v_cierre.total_qr + v_cierre.total_devoluciones_qr)
  ) AS v(forma_pago, monto)
  JOIN cuenta_forma_pago cfp ON cfp.forma_pago = v.forma_pago
  WHERE v.monto <> 0;

  -- Tarjeta (débito+crédito) va a la misma cuenta que QR (Galicia)
  v_monto_tarjeta := v_cierre.total_tarjeta + v_cierre.total_devoluciones_tarjeta;
  IF v_monto_tarjeta <> 0 THEN
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
    SELECT cuenta_id, 'cierre_z', v_monto_tarjeta, p_cierre_id, auth.uid()
    FROM cuenta_forma_pago WHERE forma_pago = 'qr';
  END IF;
END;
$$;

-- ============================================================
-- Verificación (después de aplicar)
-- 1. Devolución simple de una venta de hoy → 1 fila en devoluciones, filas 'devuelto' en
--    devolucion_items, stock del producto +cantidad, ventas/venta_items intactos.
-- 2. Motivo 'defectuoso' → reingresa_stock = false y stock SIN cambios.
-- 3. Intentar devolver más de lo vendido (o dos veces lo mismo) → error de cantidad disponible.
-- 4. Venta de hace más de 15 días → 'Esta venta supera los 15 días permitidos...'.
-- 5. Devolución en efectivo a favor del cliente + Cierre X → total_devoluciones_efectivo < 0 y
--    efectivo_esperado menor en ese monto.
-- ============================================================
SELECT d.numero, d.venta_id, d.motivo, d.diferencia_monto, d.diferencia_forma_pago, d.estado,
       (SELECT COUNT(*) FROM devolucion_items di WHERE di.devolucion_id = d.id) AS items
FROM devoluciones d
ORDER BY d.created_at DESC
LIMIT 10;
