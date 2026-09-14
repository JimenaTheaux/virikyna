-- 17 — Los retiros de efectivo impactan el Cierre X / Cierre Z
--
-- Bug reportado: se registró una venta de 15000 en efectivo y un retiro de 10000 (docs/14). El
-- retiro impactó bien en Resumen de Cuentas (Caja Gestión), pero el Cierre X seguía mostrando
-- "efectivo esperado" = 15000 (no 5000) y el retiro no aparecía en el detalle del cierre.
--
-- Causa: `cerrar_caja` (docs/06) calcula `efectivo_esperado` a partir de `ventas` y `egresos`
-- únicamente — nunca consultó `retiros_caja` (docs/14), porque esa tabla se creó después y nadie
-- conectó las dos cosas.
--
-- Ejemplo numérico (el mismo que reportó el usuario):
--   Venta en efectivo:     15000
--   Retiro de caja:       -10000  (entregado en mano a un admin, ya no está en el cajón)
--   Egresos en efectivo:       0
--   Efectivo esperado (cajón físico) = 15000 - 0 - 10000 = 5000  ← lo que este fix corrige
--
-- El Cierre Z no cambia de comportamiento respecto a docs/14: sigue sin volcar efectivo a
-- `movimientos_cuenta` (esa plata ya entró a Caja Gestión vía el retiro, no vía el cierre) —
-- por eso "en cierre z nunca suma el efectivo, ya que eso lo valida la acción retiros" ya está
-- garantizado por `validar_cierre_z` desde docs/14 y no se toca acá.

-- ============================================================
-- 1. Nueva columna para poder mostrar el retiro en el detalle del cierre (Cierre X y Z)
-- ============================================================
ALTER TABLE cierres_caja ADD COLUMN IF NOT EXISTS total_retiros NUMERIC(12,2) NOT NULL DEFAULT 0;

-- ============================================================
-- 2. cerrar_caja — ahora resta los retiros de efectivo del día del efectivo esperado
-- Único cambio real vs. docs/06: se suma v_total_retiros (desde retiros_caja, filtrando por su
-- columna `fecha`, igual criterio que turno_fecha) y se resta en el cálculo de efectivo_esperado,
-- igual que ya se restaban los egresos en efectivo.
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
  v_total_egresos_efectivo NUMERIC; -- corregido en QA: solo esto resta del cajón físico
  v_total_retiros NUMERIC;          -- docs/17: retiros de efectivo del día — también salen del cajón físico
  v_efectivo_esperado NUMERIC;
  v_diferencia NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

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
-- Verificación: repetir el ejemplo del bug — hacer una venta en efectivo, un retiro, y un Cierre X,
-- y confirmar que efectivo_esperado y total_retiros del cierre más reciente coinciden con lo esperado.
-- ============================================================
SELECT tipo, turno_fecha, total_efectivo, total_egresos, total_retiros, efectivo_esperado, created_at
FROM cierres_caja
ORDER BY created_at DESC
LIMIT 5;
