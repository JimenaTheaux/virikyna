-- 21 — Inicio de caja (apertura), integrado al Cierre Z existente
--
-- Contexto: el Cierre Z ya guarda efectivo_contado (efectivo físico final) + usuario_id (quién
-- cerró). Hasta ahora no existía ningún registro de CÓMO arrancaba el cajón al turno siguiente —
-- `cerrar_caja` (docs/17) calcula efectivo_esperado solo a partir de ventas/egresos/retiros del
-- día, asumiendo implícitamente que el cajón arranca en $0.
--
-- Este patch agrega la apertura de caja: al empezar el turno, el cajero ve el monto esperado
-- (= efectivo_contado del último Cierre Z) y elige Confirmar (coincide) o Modificar (corrige el
-- monto real que tiene en mano). Si corrige, queda registrada la diferencia
-- (monto_real - monto_esperado), visible para la dueña. Ese monto_real pasa a ser la base de la
-- que parte efectivo_esperado en cerrar_caja — antes arrancaba de 0, ahora arranca del efectivo
-- real con el que se abrió la caja.
--
-- Solo puede haber una apertura sin cerrar a la vez (índice único parcial más abajo) — no se
-- puede reabrir mientras la caja sigue abierta. La apertura se "cierra" (queda con cierre_z_id
-- seteado) automáticamente al hacer el próximo Cierre Z, dentro de la misma transacción de
-- cerrar_caja.

-- ============================================================
-- 1. Tabla aperturas_caja
-- ============================================================
CREATE TABLE IF NOT EXISTS aperturas_caja (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cierre_z_previo_id UUID REFERENCES cierres_caja(id),  -- Cierre Z del que sale monto_esperado; null si es la primera apertura del sistema
  monto_esperado NUMERIC(12,2) NOT NULL DEFAULT 0,      -- efectivo_contado de ese Cierre Z (0 si todavía no hubo ninguno)
  monto_real NUMERIC(12,2) NOT NULL,                    -- lo que el cajero confirmó o corrigió que tiene físicamente
  diferencia NUMERIC(12,2) NOT NULL DEFAULT 0,          -- monto_real - monto_esperado
  cierre_z_id UUID REFERENCES cierres_caja(id),         -- Cierre Z que cierra este período; null mientras la caja sigue abierta
  usuario_id UUID NOT NULL REFERENCES perfiles(id),     -- quién abrió
  abierta_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_aperturas_caja_abierta_at ON aperturas_caja(abierta_at DESC);

-- Como máximo una fila sin cerrar a la vez — es lo que impide reabrir la caja mientras sigue abierta.
CREATE UNIQUE INDEX IF NOT EXISTS ux_aperturas_caja_abierta ON aperturas_caja ((true)) WHERE cierre_z_id IS NULL;

-- Nueva columna en cierres_caja: qué apertura estaba vigente al momento de este cierre (X o Z) —
-- permite mostrar "monto base de apertura" en el detalle de cualquier cierre, no solo del Z que
-- cierra el período.
ALTER TABLE cierres_caja ADD COLUMN IF NOT EXISTS apertura_id UUID REFERENCES aperturas_caja(id);

-- Mismo patrón "_todos" para lectura que cierres_caja: cajero y admin acceden por igual — el
-- cajero necesita ver si hay caja abierta y con qué monto arrancó su propio turno, y la dueña
-- necesita ver todas las aperturas (alerta de diferencia + historial).
ALTER TABLE aperturas_caja ENABLE ROW LEVEL SECURITY;
CREATE POLICY "aperturas_ver_todos" ON aperturas_caja FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
);
-- Sin policy de INSERT/UPDATE: el único camino es abrir_caja / cerrar_caja (SECURITY DEFINER),
-- igual criterio que cierres_caja/egresos/retiros_caja — nunca un insert/update libre del cliente.

CREATE TRIGGER trg_auditoria_aperturas_caja AFTER INSERT OR UPDATE ON aperturas_caja
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_generica();

-- ============================================================
-- 2. abrir_caja — único punto de entrada para abrir la caja
-- ============================================================
CREATE OR REPLACE FUNCTION abrir_caja(p_monto_real NUMERIC) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_apertura_id UUID;
  v_ultimo_z cierres_caja%ROWTYPE;
  v_monto_esperado NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF p_monto_real IS NULL OR p_monto_real < 0 THEN
    RAISE EXCEPTION 'El monto de apertura debe ser mayor o igual a 0';
  END IF;
  IF EXISTS (SELECT 1 FROM aperturas_caja WHERE cierre_z_id IS NULL) THEN
    RAISE EXCEPTION 'Ya hay una caja abierta — no se puede abrir de nuevo hasta el próximo Cierre Z';
  END IF;

  SELECT * INTO v_ultimo_z FROM cierres_caja WHERE tipo = 'z' ORDER BY created_at DESC LIMIT 1;
  v_monto_esperado := COALESCE(v_ultimo_z.efectivo_contado, 0);

  INSERT INTO aperturas_caja (cierre_z_previo_id, monto_esperado, monto_real, diferencia, usuario_id)
  VALUES (v_ultimo_z.id, v_monto_esperado, p_monto_real, p_monto_real - v_monto_esperado, auth.uid())
  RETURNING id INTO v_apertura_id;

  RETURN v_apertura_id;
END;
$$;

-- ============================================================
-- 3. cerrar_caja — patch: usa el monto real de apertura como base del efectivo esperado,
-- guarda qué apertura estaba vigente, y cierra esa apertura cuando el cierre es un Z.
-- Único cambio real vs. docs/17: se suma v_monto_base (aperturas_caja.monto_real de la apertura
-- vigente, 0 si no hay ninguna) al cálculo de efectivo_esperado, se guarda apertura_id en el
-- insert, y si p_tipo='z' se marca esa apertura como cerrada (cierre_z_id) al final.
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
  v_total_egresos NUMERIC;          -- total general, todas las formas, para mostrar en el resumen
  v_total_egresos_efectivo NUMERIC; -- corregido en QA: solo esto resta del cajón físico
  v_total_retiros NUMERIC;          -- docs/17: retiros de efectivo del día — también salen del cajón físico
  v_efectivo_esperado NUMERIC;
  v_diferencia NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  -- docs/21: apertura vigente (sin cerrar) — su monto_real es la base del cajón físico.
  -- Si no hay ninguna abierta (turno viejo sin apertura registrada), la base sigue siendo 0,
  -- igual que el comportamiento anterior a este patch.
  SELECT * INTO v_apertura FROM aperturas_caja WHERE cierre_z_id IS NULL ORDER BY abierta_at DESC LIMIT 1;
  v_monto_base := COALESCE(v_apertura.monto_real, 0);

  SELECT COALESCE(SUM(total) FILTER (WHERE forma_pago = 'efectivo'), 0),
         COALESCE(SUM(total) FILTER (WHERE forma_pago = 'transferencia'), 0),
         COALESCE(SUM(total) FILTER (WHERE forma_pago = 'qr'), 0),
         COALESCE(SUM(total) FILTER (WHERE forma_pago IN ('tarjeta_debito','tarjeta_credito')), 0),
         COALESCE(SUM(total) FILTER (WHERE forma_pago = 'cuenta_corriente'), 0)
  INTO v_total_efectivo, v_total_transferencia, v_total_qr, v_total_tarjeta, v_total_cuenta_corriente
  FROM ventas
  WHERE created_at::date = current_date AND estado <> 'anulada';

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

  -- El Cierre Z cierra el período: la apertura vigente queda vinculada a este cierre y deja de
  -- contar como "abierta" — así se puede volver a abrir la caja para el próximo turno.
  IF p_tipo = 'z' AND v_apertura.id IS NOT NULL THEN
    UPDATE aperturas_caja SET cierre_z_id = v_cierre_id WHERE id = v_apertura.id;
  END IF;

  RETURN v_cierre_id;
END;
$$;

-- ============================================================
-- Verificación 1: abrir caja y confirmar que toma el efectivo_contado del último Z como esperado,
-- y que la diferencia es 0 si se confirmó tal cual o el delta correcto si se modificó el monto.
-- ============================================================
SELECT a.id, a.monto_esperado, a.monto_real, a.diferencia, a.cierre_z_id, a.usuario_id, a.abierta_at
FROM aperturas_caja a
ORDER BY a.abierta_at DESC
LIMIT 5;

-- Verificación 2: con una apertura abierta, hacer una venta en efectivo y un Cierre X — confirmar
-- que efectivo_esperado = monto_real de la apertura + ventas en efectivo del día (sin egresos/retiros).
SELECT c.id, c.tipo, c.apertura_id, c.efectivo_esperado, c.created_at
FROM cierres_caja c
ORDER BY c.created_at DESC
LIMIT 5;

-- Verificación 3: hacer el Cierre Z de ese mismo turno y confirmar que la apertura vigente queda
-- con cierre_z_id = el id de ese cierre (dejó de estar "abierta").
SELECT a.id, a.cierre_z_id
FROM aperturas_caja a
WHERE a.cierre_z_id IS NOT NULL
ORDER BY a.created_at DESC
LIMIT 5;

-- Verificación 4: intentar abrir_caja(monto) de nuevo mientras hay una apertura sin cerrar debe
-- fallar con 'Ya hay una caja abierta...'.

-- Verificación 5: toda apertura (alta) y su cierre (edición, al setear cierre_z_id) debe dejar su
-- propia fila en auditoria (tabla_afectada='aperturas_caja').
SELECT a.created_at, a.tabla_afectada, a.accion, a.registro_id
FROM auditoria a
WHERE a.tabla_afectada = 'aperturas_caja' AND a.created_at > now() - interval '5 minutes'
ORDER BY a.created_at DESC;
