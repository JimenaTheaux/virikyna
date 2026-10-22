-- 57 — Pago de contado al cargar una factura de compra: factura + pago + egreso en una transacción
--
-- ✅ APLICADO en producción el 2026-10-21 (PARTE A), con backup previo virikyna_2026-10-21_pre-docs57-kogan.
-- Antes se verificó que anular_factura_compra (docs/55) y editar_factura_compra (docs/45) eran las
-- versiones de base. PARTE B ok (3 funciones, sin anon); PARTE C 17/17 (antes y después de aplicar).
-- Mismo día, aparte: corrección del pago contado de KOGAN ($ 300.000) registrado después del Cierre Z
-- (pago + egreso de Belu vinculados al Z, snapshot del Z recalculado: diferencia −298.800 → +1.200).
--
-- Correr desde la raíz del repo con
-- `supabase db query --linked -f docs/57_pago_contado.sql` (o en el SQL Editor del proyecto
-- ccpinvtleqlsukcqnili), después de 56. La PARTE A se puede re-correr (CREATE OR REPLACE); la PARTE B
-- solo lee y la PARTE C es un test (BEGIN … ROLLBACK).
--
-- Contexto (relevado contra la base real el 2026-10-21):
--   - "Contado" era solo una etiqueta (facturas_compra.forma_pago): la factura quedaba pendiente por
--     el total y el pago había que registrarlo aparte. Caso real: KOGAN NATALIA $ 300.000 del 21/10,
--     contado, pagada en efectivo del cajón y sin registrar (se corrige aparte, no en esta migración).
--   - Es la única factura "contado" de la base (1, $ 300.000, pendiente); no se toca acá.
--   - registrar_pago_proveedor_v2 (docs/52) y cargar_factura_compra (docs/55) son las versiones
--     vigentes; esta migración no las modifica.
--
-- Qué hace:
--   1. RPC nueva cargar_factura_compra_contado: mismos parámetros que cargar_factura_compra salvo
--      forma de pago (siempre contado) y devolución (no hay NC), más p_origen:
--      - 'turno' (Local, Inventario): exige una caja abierta (apertura sin Cierre Z).
--      - 'general' (Gestión): sin caja; registrar_pago_proveedor_v2 exige admin.
--      Rechaza una NC. Carga la factura y registra un pago en efectivo por el TOTAL CALCULADO POR EL
--      SERVIDOR (> 0), aplicado íntegro a esa factura (queda pagada): pago + aplicación + egreso +
--      movimiento de la cuenta Efectivo, usuario = el logueado. El borrador (p_borrador_id) se borra
--      en la misma transacción. Si algo falla, no queda nada (ni factura, ni pago; el borrador vuelve).
--   2. anular_factura_compra: mismo cuerpo (docs/55); en una factura de contado con su pago vigente,
--      el mensaje dice "Es una factura de contado: revertí su pago desde el Historial".
--   3. editar_factura_compra: mismo cuerpo (docs/45); la forma de pago no se cambia si el comprobante
--      tiene pagos o NC aplicados vigentes (es solo una etiqueta: cambiarla no crea ni borra pagos).

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ─── 1. cargar_factura_compra_contado ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.cargar_factura_compra_contado(
  p_proveedor_id uuid,
  p_tipo_comprobante tipo_comprobante_compra,
  p_letra letra_comprobante_compra,
  p_punto_venta text,
  p_numero_comprobante text,
  p_fecha_comprobante date,
  p_fecha_fiscal date,
  p_items jsonb,
  p_origen origen_egreso,                 -- sin default a propósito (mismo criterio que la UI de v2)
  p_copiada_de_id uuid DEFAULT NULL,
  p_iva_alicuota numeric DEFAULT 21,
  p_tipo_compra text DEFAULT 'articulos',
  p_borrador_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_factura_id uuid;
  v_f facturas_compra%ROWTYPE;
  v_nota text;
  v_pago jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF p_origen IS NULL THEN
    RAISE EXCEPTION 'Falta el origen del pago (caja de Local o Caja Gestión)';
  END IF;
  IF p_tipo_comprobante = 'nota_credito' THEN
    RAISE EXCEPTION 'Una nota de crédito no se paga de contado: cargala en cuenta corriente';
  END IF;
  -- Caja de Local: el egreso entra en el cierre del día; sin apertura (o ya con Cierre Z) no hay caja.
  IF p_origen = 'turno' AND NOT EXISTS (SELECT 1 FROM aperturas_caja WHERE cierre_z_id IS NULL) THEN
    RAISE EXCEPTION 'Abrí la caja para pagar de contado';
  END IF;

  v_factura_id := cargar_factura_compra(
    p_proveedor_id => p_proveedor_id, p_tipo_comprobante => p_tipo_comprobante, p_letra => p_letra,
    p_punto_venta => p_punto_venta, p_numero_comprobante => p_numero_comprobante,
    p_fecha_comprobante => p_fecha_comprobante, p_fecha_fiscal => p_fecha_fiscal,
    p_forma_pago => 'contado', p_items => p_items, p_copiada_de_id => p_copiada_de_id,
    p_iva_alicuota => p_iva_alicuota, p_tipo_compra => p_tipo_compra, p_borrador_id => p_borrador_id);

  -- El monto es el total que calculó cargar_factura_compra, no uno que mande la pantalla.
  SELECT * INTO v_f FROM facturas_compra WHERE id = v_factura_id;
  IF v_f.total IS NULL OR v_f.total <= 0 THEN
    RAISE EXCEPTION 'Para pagar de contado el total de la factura tiene que ser mayor a cero';
  END IF;

  v_nota := 'Contado: ' || concat_ws(' ',
    CASE v_f.tipo_comprobante
      WHEN 'factura' THEN 'Factura' WHEN 'remito' THEN 'Remito' WHEN 'cupon' THEN 'Cupon'
      WHEN 'presupuesto' THEN 'Presupuesto' WHEN 'nota_debito' THEN 'Nota de debito'
      ELSE v_f.tipo_comprobante::text END,
    v_f.letra::text,
    COALESCE(NULLIF(concat_ws('-', NULLIF(btrim(v_f.punto_venta), ''), NULLIF(btrim(v_f.numero_comprobante), '')), ''), 'sin numero'));

  v_pago := registrar_pago_proveedor_v2(
    p_proveedor_id => p_proveedor_id, p_monto => v_f.total, p_forma_pago => 'efectivo',
    p_factura_ids => ARRAY[v_factura_id], p_origen => p_origen, p_nota => v_nota);

  -- Defensivo: la factura recién cargada no tiene aplicaciones, así que el pago entra entero.
  IF (v_pago->>'aplicado_pago')::numeric <> v_f.total OR (v_pago->>'a_cuenta')::numeric <> 0 THEN
    RAISE EXCEPTION 'No se pudo aplicar el pago completo a la factura';
  END IF;

  RETURN jsonb_build_object('factura_id', v_factura_id, 'pago_id', v_pago->>'pago_id', 'monto', v_f.total);
END;
$$;

COMMENT ON FUNCTION public.cargar_factura_compra_contado IS
  'docs/57: carga una factura de compra de contado y registra su pago en efectivo (total del servidor) en la misma transacción. turno = caja de Local (exige caja abierta); general = Caja Gestión (admin).';

REVOKE ALL ON FUNCTION public.cargar_factura_compra_contado(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date, jsonb, origen_egreso, uuid, numeric, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cargar_factura_compra_contado(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date, jsonb, origen_egreso, uuid, numeric, text, uuid) TO authenticated, service_role;

-- ─── 2. anular_factura_compra: cuerpo vigente (docs/55) + mensaje de contado ──────────────────
CREATE OR REPLACE FUNCTION public.anular_factura_compra(p_factura_id uuid, p_motivo text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_mov RECORD;   -- docs/55
  v_ya_anulada BOOLEAN;
  v_forma_pago forma_pago_compra;  -- docs/57
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede anular una factura de compra';
  END IF;
  IF p_motivo IS NULL OR trim(p_motivo) = '' THEN
    RAISE EXCEPTION 'El motivo es obligatorio para anular una factura de compra';
  END IF;

  SELECT anulada, forma_pago INTO v_ya_anulada, v_forma_pago FROM facturas_compra WHERE id = p_factura_id FOR UPDATE;
  IF v_ya_anulada IS NULL THEN
    RAISE EXCEPTION 'Factura de compra no encontrada';
  END IF;
  IF v_ya_anulada THEN
    RAISE EXCEPTION 'Esta factura ya estaba anulada';
  END IF;
  -- docs/57: una factura de contado tiene su pago (y su egreso): se revierte desde el Historial.
  IF v_forma_pago = 'contado' AND EXISTS (
    SELECT 1 FROM pagos_proveedor_aplicaciones
    WHERE factura_compra_id = p_factura_id AND pago_proveedor_id IS NOT NULL AND revertida_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Es una factura de contado: revertí su pago desde el Historial';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pagos_proveedor_aplicaciones
    WHERE (factura_compra_id = p_factura_id OR nota_credito_id = p_factura_id)
      AND revertida_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Este comprobante tiene pagos o notas de crédito aplicadas — revertí esos pagos antes de anularlo';
  END IF;

  -- docs/55: lo que el comprobante movió de verdad (compra, ítem vinculado después, devolución de
  -- una NC), neto por producto y depósito. Antes se recorrían los ítems con producto: en una NC
  -- habría restado stock que nunca había sumado.
  FOR v_mov IN
    SELECT producto_id, ubicacion, SUM(cantidad) AS neto
    FROM movimientos_stock
    WHERE referencia_id = p_factura_id
    GROUP BY producto_id, ubicacion
    HAVING SUM(cantidad) <> 0
  LOOP
    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
    VALUES (v_mov.producto_id, v_mov.ubicacion, 'ajuste', -1 * v_mov.neto,
            'Anulación de factura de compra: ' || p_motivo, p_factura_id, auth.uid());

    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES (v_mov.producto_id, v_mov.ubicacion, -1 * v_mov.neto)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad + EXCLUDED.cantidad;
  END LOOP;

  UPDATE facturas_compra SET anulada = true WHERE id = p_factura_id;

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, nota, usuario_id)
  VALUES ('facturas_compra', p_factura_id, 'anulacion', p_motivo, auth.uid());
END;
$function$;

-- ─── 3. editar_factura_compra: cuerpo vigente (docs/45) + forma de pago fija con pagos ────────
CREATE OR REPLACE FUNCTION public.editar_factura_compra(p_factura_id uuid, p_tipo_comprobante tipo_comprobante_compra DEFAULT NULL::tipo_comprobante_compra, p_letra letra_comprobante_compra DEFAULT NULL::letra_comprobante_compra, p_punto_venta text DEFAULT NULL::text, p_numero_comprobante text DEFAULT NULL::text, p_fecha_comprobante date DEFAULT NULL::date, p_fecha_fiscal date DEFAULT NULL::date, p_forma_pago forma_pago_compra DEFAULT NULL::forma_pago_compra, p_iva_alicuota numeric DEFAULT NULL::numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tipo_actual tipo_comprobante_compra;
  v_alicuota_actual NUMERIC;    -- docs/45
  v_forma_pago_actual forma_pago_compra;  -- docs/57
  v_tipo_nuevo tipo_comprobante_compra;
  v_alicuota_nueva NUMERIC;
  v_cambia_importes BOOLEAN;
  v_tiene_aplicaciones BOOLEAN;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede editar una factura de compra ya cargada';
  END IF;
  IF EXISTS (SELECT 1 FROM facturas_compra WHERE id = p_factura_id AND anulada = true) THEN
    RAISE EXCEPTION 'Esta factura está anulada, no se edita';
  END IF;
  IF p_iva_alicuota IS NOT NULL AND p_iva_alicuota NOT IN (0, 21) THEN
    RAISE EXCEPTION 'Alícuota de IVA inválida: tiene que ser 21 %% o exento (0)';
  END IF;

  SELECT tipo_comprobante, iva_alicuota, forma_pago INTO v_tipo_actual, v_alicuota_actual, v_forma_pago_actual
  FROM facturas_compra WHERE id = p_factura_id FOR UPDATE;

  -- docs/45: tipo y alícuota definen el total (y, de/a NC, si suma o resta deuda). Con pagos o NC
  -- aplicados vigentes no se tocan: cambiaría lo que ya se imputó. Mandar el mismo valor no cuenta
  -- como cambio (la UI manda todos los campos siempre).
  v_tipo_nuevo := COALESCE(p_tipo_comprobante, v_tipo_actual);
  v_alicuota_nueva := COALESCE(p_iva_alicuota, v_alicuota_actual);
  v_cambia_importes := v_tipo_nuevo IS DISTINCT FROM v_tipo_actual
                       OR v_alicuota_nueva IS DISTINCT FROM v_alicuota_actual;
  v_tiene_aplicaciones := EXISTS (
    SELECT 1 FROM pagos_proveedor_aplicaciones
    WHERE (factura_compra_id = p_factura_id OR nota_credito_id = p_factura_id)
      AND revertida_at IS NULL);

  IF v_cambia_importes AND v_tiene_aplicaciones THEN
    RAISE EXCEPTION 'Este comprobante ya tiene pagos o notas de crédito aplicados: no se puede cambiar el tipo ni el IVA. Revertí esos pagos primero';
  END IF;
  -- docs/57: la forma de pago es una etiqueta (cambiarla no crea ni borra pagos). Con pagos aplicados
  -- queda fija, para que una factura pagada de contado no pase a figurar en cuenta corriente.
  IF p_forma_pago IS NOT NULL AND p_forma_pago IS DISTINCT FROM v_forma_pago_actual AND v_tiene_aplicaciones THEN
    RAISE EXCEPTION 'Este comprobante ya tiene pagos aplicados: no se puede cambiar la forma de pago. Revertí esos pagos primero';
  END IF;

  UPDATE facturas_compra SET
    tipo_comprobante = v_tipo_nuevo,
    letra = COALESCE(p_letra, letra),
    punto_venta = COALESCE(p_punto_venta, punto_venta),
    numero_comprobante = COALESCE(p_numero_comprobante, numero_comprobante),
    fecha_comprobante = COALESCE(p_fecha_comprobante, fecha_comprobante),
    fecha_fiscal = COALESCE(p_fecha_fiscal, fecha_fiscal),
    forma_pago = COALESCE(p_forma_pago, forma_pago),
    -- docs/45: mismo cálculo que cargar_factura_compra, sobre el total sin IVA guardado.
    iva_alicuota = v_alicuota_nueva,
    iva = CASE WHEN v_cambia_importes THEN ROUND(total_sin_iva * v_alicuota_nueva / 100, 2) ELSE iva END,
    total = CASE WHEN v_cambia_importes THEN total_sin_iva + ROUND(total_sin_iva * v_alicuota_nueva / 100, 2) ELSE total END
  WHERE id = p_factura_id;
END;
$function$;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (solo lectura)
-- Esperado: cargar_factura_compra_contado con authenticated + service_role (sin anon), una sola
-- firma de anular/editar; y la única factura contado vieja (KOGAN) tal cual.
-- ════════════════════════════════════════════════════════════════════════════════════════════
SELECT p.oid::regprocedure::text AS funcion, array_to_string(p.proacl, ',') AS permisos, p.prosecdef AS definer
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('cargar_factura_compra_contado', 'anular_factura_compra', 'editar_factura_compra')
UNION ALL
SELECT 'contado sin pago', count(*)::text || ' · $ ' || COALESCE(sum(total), 0)::text, NULL
FROM facturas_compra_saldo WHERE forma_pago = 'contado' AND NOT anulada AND total_aplicado = 0;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (no deja nada: BEGIN … ROLLBACK)
-- Corre como el primer admin y el primer cajero activos, con proveedores de prueba. Cierra a mano
-- (dentro del ROLLBACK) la caja que hubiera abierta y abre una de prueba. Resultado: una tabla, todo ok = true.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TEMP TABLE t57 (orden int, caso text, ok boolean, detalle text) ON COMMIT DROP;

DO $test$
DECLARE
  v_admin uuid := (SELECT id FROM perfiles WHERE activo AND rol = 'admin' ORDER BY created_at LIMIT 1);
  v_cajero uuid := (SELECT id FROM perfiles WHERE activo AND rol <> 'admin' ORDER BY created_at LIMIT 1);
  v_prov uuid;
  v_prov2 uuid;
  v_prod uuid := (SELECT id FROM productos WHERE estado = 'activo' ORDER BY nombre LIMIT 1);
  v_items jsonb;
  v_res jsonb;
  v_f uuid;
  v_pago uuid;
  v_b uuid;
  v_n int;
  v_id uuid;
  v_x1 cierres_caja%ROWTYPE;
  v_x2 cierres_caja%ROWTYPE;
  v_saldo0 numeric;
  v_acuenta0 numeric;
  v_ultimo_z uuid := (SELECT id FROM cierres_caja WHERE tipo = 'z' ORDER BY created_at DESC LIMIT 1);
  v_aud uuid;
  v_err text;
  v_stock0 numeric;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  INSERT INTO proveedores (razon_social) VALUES ('TEST57 A') RETURNING id INTO v_prov;
  INSERT INTO proveedores (razon_social) VALUES ('TEST57 B') RETURNING id INTO v_prov2;
  -- Producto de prueba propio: no se le cambia costo ni proveedor a uno real (igual todo vuelve con el ROLLBACK).
  v_items := jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'descripcion', 'T57', 'cantidad', 2,
               'precio_unitario_sin_iva', 1000, 'ubicacion', 'deposito'));
  SELECT COALESCE((SELECT cantidad FROM stock_ubicaciones WHERE producto_id = v_prod AND ubicacion = 'deposito'), 0) INTO v_stock0;

  -- Sin caja: se cierra la que hubiera abierta (dentro del ROLLBACK).
  UPDATE aperturas_caja SET cierre_z_id = v_ultimo_z WHERE cierre_z_id IS NULL;

  -- 1. Turno sin caja abierta: rechazada, no queda factura.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_cajero, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM cargar_factura_compra_contado(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
      p_punto_venta => '9999', p_numero_comprobante => 'T57-1', p_fecha_comprobante => current_date, p_fecha_fiscal => NULL,
      p_items => v_items, p_origen => 'turno', p_iva_alicuota => 0);
    INSERT INTO t57 VALUES (1, 'turno sin caja: rechazada', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t57 VALUES (1, 'turno sin caja: rechazada, sin factura',
      SQLERRM = 'Abrí la caja para pagar de contado' AND NOT EXISTS (SELECT 1 FROM facturas_compra WHERE numero_comprobante = 'T57-1'), SQLERRM);
  END;

  -- Caja abierta de prueba. Pago a cuenta previo de B (5.000), para ver que contado no lo toca.
  INSERT INTO aperturas_caja (monto_esperado, monto_real, diferencia, usuario_id) VALUES (0, 0, 0, v_cajero);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM registrar_pago_proveedor_v2(v_prov2, 5000, 'transferencia', NULL, NULL, 'general');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_cajero, 'role', 'authenticated')::text, true);
  v_id := cerrar_caja('x');
  SELECT * INTO v_x1 FROM cierres_caja WHERE id = v_id;
  SELECT saldo_actual INTO v_saldo0 FROM proveedores_saldo WHERE id = v_prov2;
  SELECT a_cuenta INTO v_acuenta0 FROM proveedores_a_cuenta WHERE proveedor_id = v_prov2;

  -- 2. Turno con caja, cajero: factura pagada, pago/egreso/movimiento del cajero, entra en el cierre.
  v_res := cargar_factura_compra_contado(p_proveedor_id => v_prov2, p_tipo_comprobante => 'factura', p_letra => 'A',
    p_punto_venta => '9999', p_numero_comprobante => 'T57-2', p_fecha_comprobante => current_date, p_fecha_fiscal => NULL,
    p_items => v_items, p_origen => 'turno', p_iva_alicuota => 21);
  v_f := (v_res->>'factura_id')::uuid;
  v_pago := (v_res->>'pago_id')::uuid;
  INSERT INTO t57 SELECT 2, 'turno: factura contado pagada por el total del servidor',
    s.estado = 'pagada' AND s.saldo_pendiente = 0 AND s.forma_pago = 'contado' AND s.total = 2420 AND (v_res->>'monto')::numeric = 2420,
    format('%s saldo %s total %s', s.estado, s.saldo_pendiente, s.total)
  FROM facturas_compra_saldo s WHERE s.id = v_f;
  INSERT INTO t57 SELECT 3, 'turno: pago efectivo del cajero, egreso turno de hoy, movimiento Efectivo',
    pp.usuario_id = v_cajero AND pp.forma_pago = 'efectivo' AND pp.monto = 2420 AND pp.factura_compra_id = v_f
      AND pp.nota = 'Contado: Factura A 9999-T57-2'
      AND (SELECT count(*) FROM egresos e WHERE e.pago_proveedor_id = v_pago AND e.origen = 'turno' AND e.monto = 2420
           AND e.forma_pago = 'efectivo' AND e.usuario_id = v_cajero AND e.categoria = 'pago_proveedor') = 1
      AND (SELECT count(*) FROM movimientos_cuenta m JOIN cuenta_forma_pago c ON c.cuenta_id = m.cuenta_id AND c.forma_pago = 'efectivo'
           WHERE m.referencia_id = v_pago AND m.monto = -2420) = 1,
    (SELECT descripcion FROM egresos WHERE pago_proveedor_id = v_pago)
  FROM pagos_proveedor pp WHERE pp.id = v_pago;
  v_id := cerrar_caja('x');
  SELECT * INTO v_x2 FROM cierres_caja WHERE id = v_id;
  INSERT INTO t57 VALUES (4, 'turno: entra en el cierre (egresos +2420, esperado −2420)',
    v_x2.total_egresos - v_x1.total_egresos = 2420 AND v_x1.efectivo_esperado - v_x2.efectivo_esperado = 2420,
    format('egresos %s → %s', v_x1.total_egresos, v_x2.total_egresos));
  INSERT INTO t57 SELECT 5, 'saldo del proveedor sin cambio neto y lo a cuenta intacto',
    saldo_actual = v_saldo0 AND (SELECT a_cuenta FROM proveedores_a_cuenta WHERE proveedor_id = v_prov2) = v_acuenta0,
    format('saldo %s → %s, a cuenta %s', v_saldo0, saldo_actual, v_acuenta0)
  FROM proveedores_saldo WHERE id = v_prov2;
  INSERT INTO t57 VALUES (6, 'stock: suma igual que una factura común',
    (SELECT cantidad FROM stock_ubicaciones WHERE producto_id = v_prod AND ubicacion = 'deposito') = v_stock0 + 2, NULL);

  -- 7. General como cajero: rechazada (v2 exige admin) y no queda factura.
  BEGIN
    PERFORM cargar_factura_compra_contado(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
      p_punto_venta => '9999', p_numero_comprobante => 'T57-7', p_fecha_comprobante => current_date, p_fecha_fiscal => NULL,
      p_items => v_items, p_origen => 'general', p_iva_alicuota => 0);
    INSERT INTO t57 VALUES (7, 'general como cajero: rechazada', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t57 VALUES (7, 'general como cajero: rechazada, sin factura',
      SQLERRM LIKE 'Solo un administrador%' AND NOT EXISTS (SELECT 1 FROM facturas_compra WHERE numero_comprobante = 'T57-7'), SQLERRM);
  END;

  -- 8. General como admin (servicios): egreso general, no entra en el cierre de Local; sin stock.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  v_id := cerrar_caja('x');
  SELECT * INTO v_x1 FROM cierres_caja WHERE id = v_id;
  v_res := cargar_factura_compra_contado(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => NULL,
    p_punto_venta => NULL, p_numero_comprobante => NULL, p_fecha_comprobante => current_date, p_fecha_fiscal => NULL,
    p_items => '[{"producto_id": null, "descripcion": "Flete", "cantidad": 1, "precio_unitario_sin_iva": 500}]',
    p_origen => 'general', p_iva_alicuota => 0, p_tipo_compra => 'servicios');
  v_id := cerrar_caja('x');
  SELECT * INTO v_x2 FROM cierres_caja WHERE id = v_id;
  INSERT INTO t57 SELECT 8, 'general (servicios): pagada, egreso general del admin, fuera del cierre, sin stock',
    s.estado = 'pagada' AND s.tipo_compra = 'servicios'
      AND (SELECT count(*) FROM egresos e WHERE e.pago_proveedor_id = (v_res->>'pago_id')::uuid AND e.origen = 'general' AND e.usuario_id = v_admin) = 1
      AND v_x2.total_egresos = v_x1.total_egresos
      AND NOT EXISTS (SELECT 1 FROM movimientos_stock WHERE referencia_id = s.id)
      AND (SELECT nota FROM pagos_proveedor WHERE id = (v_res->>'pago_id')::uuid) = 'Contado: Factura sin numero',
    format('%s, cierre %s → %s', s.estado, v_x1.total_egresos, v_x2.total_egresos)
  FROM facturas_compra_saldo s WHERE s.id = (v_res->>'factura_id')::uuid;

  -- 9. NC: rechazada.
  BEGIN
    PERFORM cargar_factura_compra_contado(p_proveedor_id => v_prov, p_tipo_comprobante => 'nota_credito', p_letra => 'A',
      p_punto_venta => '9999', p_numero_comprobante => 'T57-9', p_fecha_comprobante => current_date, p_fecha_fiscal => NULL,
      p_items => v_items, p_origen => 'general', p_iva_alicuota => 0);
    INSERT INTO t57 VALUES (9, 'NC: rechazada', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t57 VALUES (9, 'NC: rechazada', SQLERRM LIKE 'Una nota de crédito no se paga de contado%', SQLERRM);
  END;

  -- 10. Falla del pago (total 0) con borrador: no queda factura y el borrador vuelve.
  PERFORM set_config('request.headers', '{"x-virikyna-app": "gestion"}', true);
  INSERT INTO borradores (tipo, sistema, payload) VALUES ('factura_compra', 'gestion', '{}') RETURNING id INTO v_b;
  BEGIN
    PERFORM cargar_factura_compra_contado(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
      p_punto_venta => '9999', p_numero_comprobante => 'T57-10', p_fecha_comprobante => current_date, p_fecha_fiscal => NULL,
      p_items => '[{"producto_id": null, "descripcion": "Gratis", "cantidad": 1, "precio_unitario_sin_iva": 0}]',
      p_origen => 'general', p_iva_alicuota => 0, p_borrador_id => v_b);
    INSERT INTO t57 VALUES (10, 'total 0: rechazada', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t57 VALUES (10, 'falla del pago (total 0): sin factura, el borrador vuelve',
      SQLERRM LIKE 'Para pagar de contado%' AND NOT EXISTS (SELECT 1 FROM facturas_compra WHERE numero_comprobante = 'T57-10')
        AND EXISTS (SELECT 1 FROM borradores WHERE id = v_b), SQLERRM);
  END;

  -- 11. Con borrador y todo bien: el borrador se borra.
  v_res := cargar_factura_compra_contado(p_proveedor_id => v_prov, p_tipo_comprobante => 'remito', p_letra => 'R',
    p_punto_venta => '9999', p_numero_comprobante => 'T57-11', p_fecha_comprobante => current_date, p_fecha_fiscal => NULL,
    p_items => '[{"producto_id": null, "descripcion": "Varios", "cantidad": 1, "precio_unitario_sin_iva": 100}]',
    p_origen => 'general', p_iva_alicuota => 0, p_borrador_id => v_b);
  INSERT INTO t57 VALUES (11, 'con borrador: factura y pago, borrador eliminado',
    NOT EXISTS (SELECT 1 FROM borradores WHERE id = v_b)
      AND (SELECT estado FROM facturas_compra_saldo WHERE id = (v_res->>'factura_id')::uuid) = 'pagada', NULL);

  -- 12. Editar la forma de pago de una factura con pagos: rechazado; mismo valor + otro campo: ok.
  BEGIN
    PERFORM editar_factura_compra(p_factura_id => v_f, p_forma_pago => 'cuenta_corriente');
    INSERT INTO t57 VALUES (12, 'editar forma de pago con pagos: rechazado', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t57 VALUES (12, 'editar forma de pago con pagos: rechazado', SQLERRM LIKE '%no se puede cambiar la forma de pago%', SQLERRM);
  END;
  PERFORM editar_factura_compra(p_factura_id => v_f, p_forma_pago => 'contado', p_numero_comprobante => 'T57-2B');
  INSERT INTO t57 SELECT 13, 'editar otro campo con la misma forma de pago: ok',
    numero_comprobante = 'T57-2B' AND forma_pago = 'contado', numero_comprobante FROM facturas_compra WHERE id = v_f;

  -- 14. Anular la factura contado: rechazada con el mensaje nuevo.
  BEGIN
    PERFORM anular_factura_compra(v_f, 'test 57');
    INSERT INTO t57 VALUES (14, 'anular contado con pago: rechazada', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t57 VALUES (14, 'anular contado con pago: mensaje de contado',
      SQLERRM = 'Es una factura de contado: revertí su pago desde el Historial', SQLERRM);
  END;

  -- 15. Revertir el pago desde el Historial y anular: ok; stock vuelve.
  SELECT id INTO v_aud FROM auditoria WHERE tabla_afectada = 'pagos_proveedor' AND registro_id = v_pago AND accion = 'alta';
  PERFORM revertir_movimiento(v_aud);
  PERFORM anular_factura_compra(v_f, 'test 57');
  INSERT INTO t57 SELECT 15, 'revertir pago y anular: ok, stock y saldo vuelven',
    s.estado = 'anulada'
      AND (SELECT cantidad FROM stock_ubicaciones WHERE producto_id = v_prod AND ubicacion = 'deposito') = v_stock0
      AND (SELECT saldo_actual FROM proveedores_saldo WHERE id = v_prov2) = v_saldo0,
    s.estado
  FROM facturas_compra_saldo s WHERE s.id = v_f;

  -- 16. Forma de pago editable sin pagos (cuenta corriente → contado): ok, sin pago nuevo.
  v_f := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
           p_punto_venta => '9999', p_numero_comprobante => 'T57-16', p_fecha_comprobante => current_date,
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente',
           p_items => '[{"producto_id": null, "descripcion": "x", "cantidad": 1, "precio_unitario_sin_iva": 10}]', p_iva_alicuota => 0);
  PERFORM editar_factura_compra(p_factura_id => v_f, p_forma_pago => 'contado');
  INSERT INTO t57 SELECT 16, 'sin pagos: la forma de pago se edita (solo etiqueta, sin pago)',
    forma_pago = 'contado' AND estado = 'pendiente', estado FROM facturas_compra_saldo WHERE id = v_f;

  -- 17. Regresión: cargar_factura_compra con contado (apps viejas) sigue sin registrar pago.
  v_f := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
           p_punto_venta => '9999', p_numero_comprobante => 'T57-17', p_fecha_comprobante => current_date,
           p_fecha_fiscal => NULL, p_forma_pago => 'contado',
           p_items => '[{"producto_id": null, "descripcion": "x", "cantidad": 1, "precio_unitario_sin_iva": 10}]', p_iva_alicuota => 0);
  INSERT INTO t57 SELECT 17, 'cargar_factura_compra viejo con contado: sin pago, pendiente',
    estado = 'pendiente' AND NOT EXISTS (SELECT 1 FROM pagos_proveedor_aplicaciones WHERE factura_compra_id = v_f), estado
  FROM facturas_compra_saldo WHERE id = v_f;
END
$test$;

SELECT * FROM t57 ORDER BY orden;

ROLLBACK;
