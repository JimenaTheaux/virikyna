-- 14 — Retiro de efectivo: único camino por el que la plata física del turno llega a Caja Gestión
--
-- Contexto: hasta ahora, `validar_cierre_z` volcaba el efectivo del día a `movimientos_cuenta`
-- junto con transferencia/QR/tarjeta. Eso ya no es correcto: el Cierre Z debe quedar como una
-- FOTO de cuánto efectivo hay físicamente en el cajón (efectivo_esperado / efectivo_contado /
-- diferencia, calculados en `cerrar_caja` — sin cambios ahí), nunca un movimiento real de cuentas.
-- El efectivo entra a Caja Gestión únicamente cuando un cajero se lo entrega en mano a un admin,
-- registrado acá con `registrar_retiro_caja`. Transferencia, QR y tarjeta siguen sin cambios:
-- esas sí son plata que ya "entró" a una cuenta real (Mercado Pago / Galicia) al momento de la venta.
--
-- Ejecutar la Parte 1 sola primero, esperar a que confirme, y recién después correr la Parte 2 —
-- Postgres no permite usar un valor de enum nuevo en la misma transacción/lote en que se agregó.

-- ============================================================
-- Parte 1 — nuevo valor del enum (correr esto solo, primero)
-- ============================================================
ALTER TYPE tipo_movimiento_cuenta ADD VALUE IF NOT EXISTS 'retiro';

-- ============================================================
-- Parte 2 — tabla, RLS y funciones (correr después de confirmar la Parte 1)
-- ============================================================

-- Detalle de cada retiro — 1 fila acá + 1 fila en movimientos_cuenta (tipo='retiro', ingreso a
-- la cuenta Efectivo), vinculadas por movimiento_cuenta_id. Igual principio que cierres_caja/egresos:
-- la tabla de detalle nunca se edita/borra directo, y el ledger (movimientos_cuenta) es la fuente
-- de verdad del saldo.
CREATE TABLE IF NOT EXISTS retiros_caja (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  fecha DATE NOT NULL DEFAULT current_date,
  monto NUMERIC(12,2) NOT NULL CHECK (monto > 0),
  admin_receptor_id UUID NOT NULL REFERENCES perfiles(id),  -- quien recibe el efectivo (debe ser rol='admin')
  cajero_id UUID NOT NULL REFERENCES perfiles(id),          -- quien lo entrega — autocompleta con el usuario logueado, editable
  movimiento_cuenta_id UUID NOT NULL REFERENCES movimientos_cuenta(id),
  usuario_id UUID NOT NULL REFERENCES perfiles(id),         -- quien registró la acción (auth.uid())
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_retiros_caja_fecha ON retiros_caja(fecha);

-- Mismo patrón "_todos" que egresos/cierres_caja: cajero y admin acceden por igual — el cajero
-- necesita ver/registrar sus propios retiros desde el Cierre de Caja de Local.
ALTER TABLE retiros_caja ENABLE ROW LEVEL SECURITY;
CREATE POLICY "retiros_caja_todos" ON retiros_caja FOR ALL USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
);
-- Aun con esta policy, el INSERT real de la app siempre pasa por registrar_retiro_caja (nunca un
-- insert libre del cliente) para poder validar admin/cajero y mantener la fila de movimientos_cuenta
-- sincronizada — mismo criterio que ventas/egresos con sus RPCs.

-- El insert en movimientos_cuenta (tipo='retiro') ya queda auditado por trg_auditoria_movimientos_cuenta
-- (docs/06), pero esa fila no lleva admin_receptor_id/cajero_id — sin este trigger, "quién entregó y
-- quién recibió" cada retiro no aparecería nunca como fila propia en `auditoria`. Mismo criterio que
-- trg_auditoria_movimientos_stock en docs/10.
CREATE TRIGGER trg_auditoria_retiros_caja AFTER INSERT ON retiros_caja
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_generica();

-- ============================================================
-- registrar_retiro_caja — único punto de entrada para registrar un retiro
-- ============================================================
CREATE OR REPLACE FUNCTION registrar_retiro_caja(
  p_monto NUMERIC,
  p_admin_id UUID,
  p_cajero_id UUID,
  p_fecha DATE DEFAULT CURRENT_DATE
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_cuenta_id UUID;
  v_movimiento_id UUID;
  v_retiro_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF p_monto IS NULL OR p_monto <= 0 THEN
    RAISE EXCEPTION 'El importe del retiro debe ser mayor a 0';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = p_admin_id AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'El admin receptor seleccionado no es válido';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = p_cajero_id AND activo = true) THEN
    RAISE EXCEPTION 'El cajero seleccionado no es válido';
  END IF;

  SELECT id INTO v_cuenta_id FROM cuentas WHERE nombre = 'Efectivo';
  IF v_cuenta_id IS NULL THEN
    RAISE EXCEPTION 'No existe la cuenta Efectivo';
  END IF;

  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, usuario_id)
  VALUES (v_cuenta_id, 'retiro', abs(p_monto), 'Retiro de efectivo recibido por admin', auth.uid())
  RETURNING id INTO v_movimiento_id;

  INSERT INTO retiros_caja (fecha, monto, admin_receptor_id, cajero_id, movimiento_cuenta_id, usuario_id)
  VALUES (p_fecha, abs(p_monto), p_admin_id, p_cajero_id, v_movimiento_id, auth.uid())
  RETURNING id INTO v_retiro_id;

  RETURN v_retiro_id;
END;
$$;

-- ============================================================
-- listar_admins — selector de "admin que recibe" en el modal de Retiro
-- `perfiles` solo expone la fila propia por RLS (regla de oro, sin recursión — docs/06 sección 5),
-- así que un cajero no puede filtrar por rol='admin' directo. perfiles_publico tampoco sirve:
-- no expone rol. Esta función SECURITY DEFINER es el único punto para listar admins.
-- ============================================================
CREATE OR REPLACE FUNCTION listar_admins()
RETURNS TABLE(id UUID, nombre TEXT)
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT id, nombre FROM perfiles WHERE rol = 'admin' AND activo = true ORDER BY nombre;
$$;

-- ============================================================
-- Patch a validar_cierre_z — saca el efectivo del volcado a movimientos_cuenta
-- Único cambio real vs. la versión de docs/06: se elimina la fila ('efectivo', total_efectivo)
-- del VALUES. Transferencia, QR y tarjeta quedan intactos.
-- ============================================================
CREATE OR REPLACE FUNCTION validar_cierre_z(p_cierre_id UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_cierre cierres_caja%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede validar un Cierre Z';
  END IF;

  SELECT * INTO v_cierre FROM cierres_caja WHERE id = p_cierre_id AND tipo = 'z';
  IF NOT FOUND THEN RAISE EXCEPTION 'Cierre Z no encontrado'; END IF;
  IF v_cierre.estado_validacion = 'validado' THEN RAISE EXCEPTION 'Este Cierre Z ya fue validado'; END IF;

  UPDATE cierres_caja SET estado_validacion = 'validado', validado_por = auth.uid(), validado_at = now()
  WHERE id = p_cierre_id;

  -- Efectivo YA NO se vuelca acá (docs/14) — el Cierre Z solo informa cuánto efectivo hay
  -- físicamente (efectivo_esperado/efectivo_contado/diferencia, ver cerrar_caja en docs/06).
  -- Ese efectivo entra a Caja Gestión únicamente cuando lo recibe un admin vía registrar_retiro_caja.
  -- Transferencia y QR se mapean 1 a 1 vía cuenta_forma_pago, sin cambios.
  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
  SELECT cfp.cuenta_id, 'cierre_z', v.monto, p_cierre_id, auth.uid()
  FROM (VALUES
    ('transferencia'::forma_pago_venta, v_cierre.total_transferencia),
    ('qr'::forma_pago_venta, v_cierre.total_qr)
  ) AS v(forma_pago, monto)
  JOIN cuenta_forma_pago cfp ON cfp.forma_pago = v.forma_pago
  WHERE v.monto > 0;

  -- Tarjeta (débito+crédito, un solo total combinado hoy) va a la misma cuenta que QR (Galicia) — sin cambios
  IF v_cierre.total_tarjeta > 0 THEN
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
    SELECT cuenta_id, 'cierre_z', v_cierre.total_tarjeta, p_cierre_id, auth.uid()
    FROM cuenta_forma_pago WHERE forma_pago = 'qr';
  END IF;

  -- Los egresos del día NO se tocan acá — ya impactaron su cuenta en el momento de registrarse
  -- (vía registrar_pago_proveedor / registrar_egreso_general). Volver a restarlos acá los contaría dos veces.
END;
$$;

-- ============================================================
-- Auditoría de la validación en sí (independiente de si hubo o no movimientos_cuenta)
-- Antes del patch de este archivo, el UPDATE de acá arriba solo quedaba "auditado" de rebote,
-- vía los inserts en movimientos_cuenta que generaba el mismo validar_cierre_z. Ahora que el
-- efectivo ya no genera esa fila, un Cierre Z 100% en efectivo (sin transferencia/QR/tarjeta)
-- podía validarse sin dejar NINGUNA fila en `auditoria` — el evento de validación desaparecía
-- del Historial. Este trigger audita el UPDATE de cierres_caja siempre, sin depender del mix de
-- medios de pago del día.
-- ============================================================
CREATE TRIGGER trg_auditoria_cierres_caja AFTER UPDATE ON cierres_caja
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_generica();

-- Verificación 1: a partir de ahora, ningún movimiento nuevo de tipo 'cierre_z' debería tener
-- monto asociado a la cuenta Efectivo — solo Mercado Pago/Galicia.
SELECT mc.created_at, c.nombre AS cuenta, mc.monto
FROM movimientos_cuenta mc
JOIN cuentas c ON c.id = mc.cuenta_id
WHERE mc.tipo = 'cierre_z' AND mc.created_at > now() - interval '1 minute'
ORDER BY mc.created_at DESC;

-- Verificación 2: toda validación de Cierre Z reciente debe tener su propia fila en auditoria
-- (tabla_afectada='cierres_caja', accion='edicion'), incluso los días 100% efectivo.
SELECT a.created_at, a.tabla_afectada, a.accion, a.registro_id
FROM auditoria a
WHERE a.tabla_afectada = 'cierres_caja' AND a.created_at > now() - interval '1 minute'
ORDER BY a.created_at DESC;

-- Verificación 3: todo retiro reciente debe tener su propia fila en auditoria (tabla_afectada='retiros_caja').
SELECT a.created_at, a.tabla_afectada, a.accion, a.registro_id
FROM auditoria a
WHERE a.tabla_afectada = 'retiros_caja' AND a.created_at > now() - interval '1 minute'
ORDER BY a.created_at DESC;
