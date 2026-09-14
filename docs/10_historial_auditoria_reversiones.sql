-- 10 — Historial y Auditoría — RPCs de reversión reales para Virikyna Gestión (módulo 10)
--
-- docs/06_estructura_de_datos.md, sección 7, dejó estas funciones como pseudo-código a propósito
-- ("Cada revertir_* hace su propia validación de negocio... queda fuera de este pseudo-código").
-- Este archivo es esa implementación real, para ejecutar en el SQL Editor de Supabase DESPUÉS
-- de 06 y 09. Correr todo de una vez, en orden, una sola vez.
--
-- Decisión de schema tomada en esta fase (Fase 8, Parte B): `egresos`, `pagos_proveedor` y
-- `pagos_cliente` no tenían una columna de auto-referencia para el contra-asiento, a diferencia
-- de `movimientos_cuenta` (que ya tiene `revierte_movimiento_id`). Se agregan acá para el mismo
-- principio: el saldo/monto nunca se pisa, la reversión es siempre una fila nueva vinculada a
-- la original — nunca un UPDATE/DELETE real sobre el movimiento de negocio.
--
-- También se agrega un trigger de auditoría sobre `movimientos_stock` (el doc original decía que
-- no hacía falta, "es en sí misma un log, ya inmutable" — cierto para trazabilidad, pero sin este
-- trigger un ajuste manual de stock nunca aparecía como fila propia en `auditoria`, y no había forma
-- determinística de identificar "este ajuste es reversible" sin adivinar. Con el trigger, cada
-- ajuste manual entra a auditoria con accion='alta'; el Historial solo ofrece "Revertir" cuando
-- tipo='ajuste' Y referencia_id IS NULL — así se excluyen los movimientos de stock que son
-- efecto automático de una venta o de una anulación de venta (que tienen su propio camino de
-- reversión: anular_venta), evitando que alguien "revierta" sin querer un movimiento que no es
-- un ajuste manual.

-- ============================================================
-- 1. Columnas nuevas — mismo patrón que movimientos_cuenta.revierte_movimiento_id
-- ============================================================
ALTER TABLE egresos ADD COLUMN IF NOT EXISTS revierte_egreso_id UUID REFERENCES egresos(id);
ALTER TABLE pagos_proveedor ADD COLUMN IF NOT EXISTS revierte_pago_proveedor_id UUID REFERENCES pagos_proveedor(id);
ALTER TABLE pagos_cliente ADD COLUMN IF NOT EXISTS revierte_pago_cliente_id UUID REFERENCES pagos_cliente(id);

-- ============================================================
-- 2. Trigger de auditoría sobre movimientos_stock (solo INSERT — la tabla es append-only)
-- ============================================================
CREATE TRIGGER trg_auditoria_movimientos_stock AFTER INSERT ON movimientos_stock
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_generica();

-- ============================================================
-- 3. fn_auditoria_generica — se le agrega una válvula de escape para que los revertir_* de acá
--    abajo puedan hacer su propio UPDATE/DELETE controlado sin que el trigger genérico lo vuelva
--    a loggear como 'edicion'/'eliminacion' (el revertir_* inserta su propia fila, con accion =
--    'reversion' y el detalle correcto). CREATE OR REPLACE no rompe los triggers ya colgados.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_auditoria_generica() RETURNS TRIGGER AS $$
BEGIN
  IF current_setting('virikyna.suppress_audit', true) = 'true' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF TG_OP = 'INSERT' THEN
    INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_nuevos, usuario_id)
    VALUES (TG_TABLE_NAME, NEW.id, 'alta', to_jsonb(NEW), auth.uid());
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, valores_nuevos, usuario_id)
    VALUES (TG_TABLE_NAME, NEW.id, 'edicion', to_jsonb(OLD), to_jsonb(NEW), auth.uid());
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, usuario_id)
    VALUES (TG_TABLE_NAME, OLD.id, 'eliminacion', to_jsonb(OLD), auth.uid());
    RETURN OLD;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 4. revertir_edicion — cambio de campo simple (productos, proveedores, clientes)
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
  WHERE kv.key NOT IN ('id', 'created_at', 'updated_at', 'precio_venta');

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
-- 5. revertir_alta — alta de un registro nuevo: inactivar/eliminar según la regla de esa entidad
-- ============================================================
CREATE OR REPLACE FUNCTION revertir_alta(p_auditoria_id UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_auditoria auditoria%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede revertir acciones';
  END IF;

  SELECT * INTO v_auditoria FROM auditoria WHERE id = p_auditoria_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Acción no encontrada'; END IF;
  IF v_auditoria.accion <> 'alta' THEN RAISE EXCEPTION 'Esta acción no es un alta reversible'; END IF;
  IF v_auditoria.tabla_afectada NOT IN ('productos', 'clientes', 'proveedores') THEN
    RAISE EXCEPTION 'Este tipo de alta no se revierte automáticamente';
  END IF;
  IF EXISTS (SELECT 1 FROM auditoria WHERE revierte_auditoria_id = p_auditoria_id) THEN
    RAISE EXCEPTION 'Esta acción ya fue revertida';
  END IF;

  PERFORM set_config('virikyna.suppress_audit', 'true', true);

  IF v_auditoria.tabla_afectada = 'productos' THEN
    UPDATE productos SET estado = 'inactivo', updated_at = now() WHERE id = v_auditoria.registro_id;
  ELSIF v_auditoria.tabla_afectada = 'clientes' THEN
    UPDATE clientes SET activo = false WHERE id = v_auditoria.registro_id;
  ELSIF v_auditoria.tabla_afectada = 'proveedores' THEN
    DELETE FROM proveedores WHERE id = v_auditoria.registro_id;
  END IF;

  PERFORM set_config('virikyna.suppress_audit', 'false', true);

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, usuario_id, revierte_auditoria_id)
  VALUES (v_auditoria.tabla_afectada, v_auditoria.registro_id, 'reversion', v_auditoria.valores_nuevos, auth.uid(), p_auditoria_id);
END;
$$;
-- Nota: si DELETE FROM proveedores choca con una FK (ya tiene productos o facturas asociadas),
-- la función aborta con el error de Postgres tal cual — el cliente lo muestra vía friendlyError
-- ("hay datos relacionados que lo impiden"), consistente con el botón Eliminar de Proveedores.

-- ============================================================
-- 6. anular_venta — venta SIN facturar: repone stock, marca la venta como anulada
-- ============================================================
CREATE OR REPLACE FUNCTION anular_venta(p_venta_id UUID, p_motivo TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_venta ventas%ROWTYPE;
  v_item RECORD;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede anular una venta';
  END IF;
  IF p_motivo IS NULL OR trim(p_motivo) = '' THEN
    RAISE EXCEPTION 'El motivo es obligatorio para anular una venta';
  END IF;

  SELECT * INTO v_venta FROM ventas WHERE id = p_venta_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Venta no encontrada'; END IF;
  IF v_venta.estado = 'anulada' THEN RAISE EXCEPTION 'Esta venta ya está anulada'; END IF;
  IF EXISTS (SELECT 1 FROM facturas_c WHERE venta_id = p_venta_id) THEN
    RAISE EXCEPTION 'Esta venta ya tiene Factura C emitida — no es reversible desde el sistema (límite conocido de Fase 1, ver docs)';
  END IF;

  FOR v_item IN SELECT * FROM venta_items WHERE venta_id = p_venta_id LOOP
    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
    VALUES (v_item.producto_id, 'local', 'ajuste', v_item.cantidad,
            'Reposición por anulación de venta: ' || p_motivo, p_venta_id, auth.uid());

    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES (v_item.producto_id, 'local', v_item.cantidad)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad + v_item.cantidad;
  END LOOP;

  UPDATE ventas SET estado = 'anulada' WHERE id = p_venta_id;

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, valores_nuevos, usuario_id, nota)
  VALUES ('ventas', p_venta_id, 'anulacion', to_jsonb(v_venta),
          jsonb_set(to_jsonb(v_venta), '{estado}', '"anulada"'), auth.uid(), p_motivo);
END;
$$;
-- Nota: la reposición de stock (tipo='ajuste', referencia_id=venta_id) queda visible en Historial
-- pero SIN botón de revertir individual — el Historial solo ofrece "Revertir ajuste" cuando
-- referencia_id IS NULL (ver punto 2 más arriba). Tiene sentido: deshacer la reposición de una
-- venta anulada no es un caso real, y el motivo ya dice de dónde vino.

-- ============================================================
-- 7. revertir_movimiento — ajuste de stock, egreso, pago (proveedor/cliente), movimiento de cuenta
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
    INSERT INTO pagos_proveedor (proveedor_id, factura_compra_id, monto, forma_pago, usuario_id, revierte_pago_proveedor_id)
    VALUES ((v_row->>'proveedor_id')::UUID, NULLIF(v_row->>'factura_compra_id','')::UUID,
            -1 * (v_row->>'monto')::NUMERIC, (v_row->>'forma_pago')::forma_pago_egreso, auth.uid(), (v_row->>'id')::UUID);

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

-- ============================================================
-- 8. agregar_nota_correccion — Cierre Z ya validado: no se reabre, solo se anota
-- ============================================================
CREATE OR REPLACE FUNCTION agregar_nota_correccion(p_cierre_id UUID, p_nota TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede agregar una nota de corrección';
  END IF;
  IF p_nota IS NULL OR trim(p_nota) = '' THEN
    RAISE EXCEPTION 'La nota no puede estar vacía';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cierres_caja WHERE id = p_cierre_id AND tipo = 'z') THEN
    RAISE EXCEPTION 'Cierre Z no encontrado';
  END IF;

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, nota, usuario_id)
  VALUES ('cierres_caja', p_cierre_id, 'nota_correccion', trim(p_nota), auth.uid());
END;
$$;

-- ============================================================
-- Venta ya facturada (con CAE): sin RPC, por diseño y por decisión confirmada con la clienta.
-- No existe revertir_venta_facturada — anular_venta ya rechaza explícitamente cualquier venta
-- con factura_c asociada (ver punto 6). El Historial no debe ofrecer ese botón nunca; no es un
-- bug si no aparece.
-- ============================================================
