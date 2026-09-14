-- 15 — Cheque / eCheq de proveedores: número, fecha de salida y fecha de vencimiento
--
-- Contexto: `pagos_proveedor` ya distingue forma_pago = 'cheque' | 'echeq' (docs/06), pero no
-- guardaba ningún dato del cheque en sí. Esto agrega las 3 columnas, las suma a
-- `registrar_pago_proveedor` (obligatorias solo cuando la forma de pago es cheque/echeq) y
-- actualiza `revertir_movimiento` (docs/10) para que una reversión de un pago con cheque
-- conserve esos datos en la fila de reversión — si no, el listado de "Cheques emitidos"
-- mostraría una fila con importe negativo pero sin número/vencimiento.
--
-- Cheque y echeq siguen sin impactar en `movimientos_cuenta` (docs/06, RPC 5) — no son plata
-- líquida al momento de registrarse. Esto no cambia acá.
--
-- Ejecutar todo de una vez en el SQL Editor de Supabase.

-- ============================================================
-- 1. Columnas nuevas en pagos_proveedor
-- ============================================================
ALTER TABLE pagos_proveedor ADD COLUMN IF NOT EXISTS cheque_numero TEXT;
ALTER TABLE pagos_proveedor ADD COLUMN IF NOT EXISTS cheque_fecha_salida DATE;
ALTER TABLE pagos_proveedor ADD COLUMN IF NOT EXISTS cheque_fecha_vencimiento DATE;

-- Para ordenar por vencimiento en el detalle de la card "Cheques emitidos" (Resumen Cuentas).
CREATE INDEX IF NOT EXISTS idx_pagos_proveedor_cheque_vencimiento
  ON pagos_proveedor(cheque_fecha_vencimiento)
  WHERE forma_pago IN ('cheque', 'echeq');

-- ============================================================
-- 2. registrar_pago_proveedor — se agregan los 3 parámetros de cheque (opcionales, NULL para
-- efectivo/transferencia). Mismo cuerpo que docs/06 RPC 5 más la validación y el INSERT de estas
-- columnas.
-- ============================================================
CREATE OR REPLACE FUNCTION registrar_pago_proveedor(
  p_proveedor_id UUID,
  p_factura_compra_id UUID,       -- NULL = pago a cuenta general, sin factura puntual
  p_monto NUMERIC,
  p_forma_pago forma_pago_egreso,
  p_origen origen_egreso DEFAULT 'turno',
  p_cierre_caja_id UUID DEFAULT NULL,
  p_cheque_numero TEXT DEFAULT NULL,
  p_cheque_fecha_salida DATE DEFAULT NULL,
  p_cheque_fecha_vencimiento DATE DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_pago_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  IF p_forma_pago IN ('cheque', 'echeq') THEN
    IF p_cheque_numero IS NULL OR trim(p_cheque_numero) = '' THEN
      RAISE EXCEPTION 'El número de cheque es obligatorio';
    END IF;
    IF p_cheque_fecha_salida IS NULL THEN
      RAISE EXCEPTION 'La fecha de salida del cheque es obligatoria';
    END IF;
    IF p_cheque_fecha_vencimiento IS NULL THEN
      RAISE EXCEPTION 'La fecha de vencimiento del cheque es obligatoria';
    END IF;
  END IF;

  INSERT INTO pagos_proveedor (
    proveedor_id, factura_compra_id, monto, forma_pago, usuario_id,
    cheque_numero, cheque_fecha_salida, cheque_fecha_vencimiento
  )
  VALUES (
    p_proveedor_id, p_factura_compra_id, p_monto, p_forma_pago, auth.uid(),
    CASE WHEN p_forma_pago IN ('cheque', 'echeq') THEN trim(p_cheque_numero) END,
    CASE WHEN p_forma_pago IN ('cheque', 'echeq') THEN p_cheque_fecha_salida END,
    CASE WHEN p_forma_pago IN ('cheque', 'echeq') THEN p_cheque_fecha_vencimiento END
  )
  RETURNING id INTO v_pago_id;

  INSERT INTO egresos (cierre_caja_id, origen, categoria, monto, descripcion, forma_pago, usuario_id)
  VALUES (p_cierre_caja_id, p_origen, 'pago_proveedor', p_monto, 'Pago a proveedor', p_forma_pago, auth.uid());

  IF p_forma_pago IN ('efectivo', 'transferencia') THEN
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
    SELECT cuenta_id, 'pago_proveedor', -abs(p_monto), v_pago_id, auth.uid()
    FROM cuenta_forma_pago WHERE forma_pago = p_forma_pago::text::forma_pago_venta;
  END IF;

  RETURN v_pago_id;
END;
$$;

-- ============================================================
-- 3. revertir_movimiento (docs/10, punto 7) — mismo cuerpo, solo se le agrega que la reversión
-- de un pagos_proveedor copie los campos de cheque de la fila original (v_row), para que la fila
-- de reversión no quede con número/vencimiento en blanco.
-- ============================================================
CREATE OR REPLACE FUNCTION revertir_movimiento(p_auditoria_id UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_auditoria auditoria%ROWTYPE;
  v_row JSONB;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede revertir movimientos';
  END IF;

  SELECT * INTO v_auditoria FROM auditoria WHERE id = p_auditoria_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Acción no encontrada'; END IF;
  IF EXISTS (SELECT 1 FROM auditoria WHERE revierte_auditoria_id = p_auditoria_id) THEN
    RAISE EXCEPTION 'Esta acción ya fue revertida';
  END IF;

  v_row := v_auditoria.valores_nuevos;

  IF v_auditoria.tabla_afectada = 'movimientos_stock' THEN
    IF (v_row->>'tipo') <> 'ajuste' OR v_row->>'referencia_id' IS NOT NULL THEN
      RAISE EXCEPTION 'Solo se puede revertir un ajuste de stock manual (no una venta, compra, ni una reposición automática)';
    END IF;

    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, usuario_id)
    VALUES ((v_row->>'producto_id')::UUID, (v_row->>'ubicacion')::ubicacion_stock, 'ajuste',
            -1 * (v_row->>'cantidad')::NUMERIC, 'Reversión de ajuste (auditoría)', auth.uid());

    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES ((v_row->>'producto_id')::UUID, (v_row->>'ubicacion')::ubicacion_stock, -1 * (v_row->>'cantidad')::NUMERIC)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad - (v_row->>'cantidad')::NUMERIC;

  ELSIF v_auditoria.tabla_afectada = 'egresos' THEN
    INSERT INTO egresos (cierre_caja_id, origen, categoria, monto, descripcion, forma_pago, usuario_id, revierte_egreso_id)
    VALUES (NULLIF(v_row->>'cierre_caja_id','')::UUID, (v_row->>'origen')::origen_egreso, (v_row->>'categoria')::categoria_egreso,
            -1 * (v_row->>'monto')::NUMERIC, 'Reversión: ' || COALESCE(v_row->>'descripcion', ''),
            (v_row->>'forma_pago')::forma_pago_egreso, auth.uid(), (v_row->>'id')::UUID);

  ELSIF v_auditoria.tabla_afectada = 'pagos_proveedor' THEN
    INSERT INTO pagos_proveedor (
      proveedor_id, factura_compra_id, monto, forma_pago, usuario_id, revierte_pago_proveedor_id,
      cheque_numero, cheque_fecha_salida, cheque_fecha_vencimiento
    )
    VALUES (
      (v_row->>'proveedor_id')::UUID, NULLIF(v_row->>'factura_compra_id','')::UUID,
      -1 * (v_row->>'monto')::NUMERIC, (v_row->>'forma_pago')::forma_pago_egreso, auth.uid(), (v_row->>'id')::UUID,
      v_row->>'cheque_numero', NULLIF(v_row->>'cheque_fecha_salida','')::DATE, NULLIF(v_row->>'cheque_fecha_vencimiento','')::DATE
    );

    -- El pago original generó un egreso (registrar_pago_proveedor, docs/06 RPC 5) — se revierte también.
    INSERT INTO egresos (origen, categoria, monto, descripcion, forma_pago, usuario_id)
    VALUES ('turno', 'pago_proveedor', -1 * (v_row->>'monto')::NUMERIC, 'Reversión de pago a proveedor',
            (v_row->>'forma_pago')::forma_pago_egreso, auth.uid());

    -- Y si era efectivo/transferencia, había impactado en movimientos_cuenta — se revierte igual.
    IF (v_row->>'forma_pago') IN ('efectivo', 'transferencia') THEN
      INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
      SELECT cuenta_id, 'pago_proveedor', abs((v_row->>'monto')::NUMERIC), (v_row->>'id')::UUID, auth.uid()
      FROM cuenta_forma_pago WHERE forma_pago = (v_row->>'forma_pago')::forma_pago_venta;
    END IF;

  ELSIF v_auditoria.tabla_afectada = 'pagos_cliente' THEN
    INSERT INTO pagos_cliente (cliente_id, venta_id, monto, forma_pago, usuario_id, revierte_pago_cliente_id)
    VALUES ((v_row->>'cliente_id')::UUID, NULLIF(v_row->>'venta_id','')::UUID,
            -1 * (v_row->>'monto')::NUMERIC, (v_row->>'forma_pago')::forma_pago_venta, auth.uid(), (v_row->>'id')::UUID);

    -- El pago original siempre impacta en movimientos_cuenta (registrar_pago_cliente, docs/06 RPC 10).
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
    SELECT cuenta_id, 'pago_cliente', -abs((v_row->>'monto')::NUMERIC), (v_row->>'id')::UUID, auth.uid()
    FROM cuenta_forma_pago WHERE forma_pago = (v_row->>'forma_pago')::forma_pago_venta;

  ELSIF v_auditoria.tabla_afectada = 'movimientos_cuenta' THEN
    -- Mismo efecto que eliminar_movimiento_cuenta (docs/06 RPC 13), disparado desde el Historial.
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, revierte_movimiento_id, usuario_id)
    VALUES ((v_row->>'cuenta_id')::UUID, (v_row->>'tipo')::tipo_movimiento_cuenta,
            -1 * (v_row->>'monto')::NUMERIC, 'Reversión desde Historial', (v_row->>'id')::UUID, auth.uid());

  ELSE
    RAISE EXCEPTION 'Este tipo de movimiento no se revierte desde acá';
  END IF;

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, usuario_id, revierte_auditoria_id, nota)
  VALUES (v_auditoria.tabla_afectada, v_auditoria.registro_id, 'reversion', v_auditoria.valores_nuevos, auth.uid(),
          p_auditoria_id, 'Reversión de movimiento (' || v_auditoria.tabla_afectada || ')');
END;
$$;

-- Verificación: últimos pagos con cheque/echeq cargados, con sus 3 campos nuevos.
SELECT pp.created_at, p.razon_social, pp.forma_pago, pp.monto,
       pp.cheque_numero, pp.cheque_fecha_salida, pp.cheque_fecha_vencimiento
FROM pagos_proveedor pp
JOIN proveedores p ON p.id = pp.proveedor_id
WHERE pp.forma_pago IN ('cheque', 'echeq') AND pp.created_at > now() - interval '1 minute'
ORDER BY pp.created_at DESC;
