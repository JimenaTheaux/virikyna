-- 58 — El efectivo de Local no sale de la cuenta Efectivo de Caja Gestión
--
-- ✅ APLICADO en producción el 2026-10-26 (PARTE A + PARTE D en una transacción), con backup previo
-- virikyna_2026-10-26_pre-docs58. PARTE B ok (4 funciones, sin anon); Efectivo −122.930,72 → 627.385,48.
-- PARTE C 10/10 contra la base real (BEGIN … ROLLBACK);
-- sin la PARTE A fallan los casos 1, 5, 7 y 10.
--
-- Correr desde la raíz del repo, por partes, con `supabase db query --linked -f <archivo>` (o en el SQL
-- Editor del proyecto ccpinvtleqlsukcqnili), después de 57. La PARTE A se puede re-correr (CREATE OR
-- REPLACE); la PARTE B solo lee; la PARTE C es un test (termina en error a propósito: la transacción
-- aborta y el mensaje trae "RESULTADO"); la PARTE D es una corrección de datos de una sola vez.
--
-- Regla (definida con Jimena el 2026-10-26):
--   - Lo que se cobra y se paga en Local queda en el cajón de Local y se controla en el Cierre Z.
--   - El efectivo entra a Caja Gestión solo por retiros (registrar_retiro_caja).
--   - De la cuenta Efectivo de Caja Gestión solo sale lo que se paga desde Gestión (origen 'general').
--   - Transferencias: siguen bajando la cuenta del banco desde cualquier app (la cuenta es una sola).
--
-- Contexto (relevado contra la base real el 2026-10-26): la card Efectivo de Caja Gestión daba
-- −122.930,72 con un retiro de 1.160.000 del 25/10. registrar_pago_proveedor_v2 y registrar_egreso_general
-- descontaban de Efectivo todo pago/egreso en efectivo sin mirar el origen, así que los 4 pagos hechos
-- desde el cajón de Local (750.316,20) quedaban descontados dos veces: en el Z y en Efectivo.
-- FAYDI (453.550,71) y ANKAH (79.063,81) del 23/10, cargados desde Gestión, quedan como están.
--
-- Qué hace:
--   1. registrar_pago_proveedor_v2 y registrar_egreso_general (las dos firmas): el movimiento de cuenta
--      se crea para transferencia (siempre) y para efectivo solo con origen 'general'. El egreso se
--      registra igual que antes, así que cerrar_caja no cambia. cargar_factura_compra_contado llama a v2.
--   2. revertir_movimiento (rama pagos_proveedor): la reversión espeja lo que el pago movió en cuentas
--      (neto por cuenta), en vez de recalcularlo por forma de pago. Un pago de Local en efectivo no movió
--      Efectivo y su reversión tampoco lo mueve. La rama egresos ya espejaba (docs/38).
--   3. PARTE D: contra-asiento (revierte_movimiento_id + referencia_id = pago) de los 4 pagos de Local,
--      como Jimena. Re-verifica que sean exactamente esos 4 antes de tocar nada.
--      Efectivo: −122.930,72 → 627.385,48 (= retiro 1.160.000 − FAYDI − ANKAH; falta el saldo inicial).
--
-- Pendiente (no se resuelve acá): registrar_pago_cliente no tiene origen y siempre suma a la cuenta
-- de la forma de pago; un cobro de cuenta corriente en efectivo hecho en Local sumaría a Efectivo y
-- el Cierre Z no lo cuenta. Al 2026-10-26 no hay ningún pagos_cliente.
--
-- Ojo: la PARTE C de docs/57 (caso 3) esperaba movimiento en Efectivo para un pago contado de turno;
-- con esta migración ese caso ya no aplica.

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.registrar_pago_proveedor_v2(p_proveedor_id uuid, p_monto numeric, p_forma_pago forma_pago_egreso, p_factura_ids uuid[] DEFAULT NULL::uuid[], p_nota_credito_ids uuid[] DEFAULT NULL::uuid[], p_origen origen_egreso DEFAULT 'turno'::origen_egreso, p_cierre_caja_id uuid DEFAULT NULL::uuid, p_fecha date DEFAULT NULL::date, p_nota text DEFAULT NULL::text, p_cheque_numero text DEFAULT NULL::text, p_cheque_fecha_salida date DEFAULT NULL::date, p_cheque_fecha_vencimiento date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_monto NUMERIC := round(p_monto, 2);
  v_fecha DATE := COALESCE(p_fecha, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);
  v_nota TEXT := NULLIF(trim(p_nota), '');
  v_es_cheque BOOLEAN := p_forma_pago IN ('cheque', 'echeq');
  v_factura_ids UUID[];
  v_nc_ids UUID[];
  v_mal facturas_compra%ROWTYPE;
  -- Comprobantes a cancelar (ordenados) y su saldo, que se va descontando en memoria.
  v_doc_ids UUID[] := '{}';
  v_doc_saldos NUMERIC[] := '{}';
  -- NC a usar (ordenadas) y su crédito disponible.
  v_nc_orden UUID[] := '{}';
  v_nc_disp NUMERIC[] := '{}';
  -- Plan de aplicaciones: (comprobante, monto, NC o NULL si sale del pago).
  v_plan_doc UUID[] := '{}';
  v_plan_monto NUMERIC[] := '{}';
  v_plan_nc UUID[] := '{}';
  v_pago_docs UUID[] := '{}';
  v_n INT;
  v_m INT;
  i INT;
  j INT;
  v_aplicar NUMERIC;
  v_total_nc NUMERIC := 0;
  v_rest NUMERIC;
  v_pago_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  -- Mismo criterio que registrar_egreso_general: origen 'general' (Gestión) es solo admin.
  IF p_origen = 'general' AND NOT EXISTS (
    SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true
  ) THEN
    RAISE EXCEPTION 'Solo un administrador puede registrar un pago de origen general';
  END IF;
  IF p_forma_pago IS NULL THEN
    RAISE EXCEPTION 'La forma de pago es obligatoria';
  END IF;

  SELECT array_agg(DISTINCT x) INTO v_factura_ids FROM unnest(p_factura_ids) AS x WHERE x IS NOT NULL;
  SELECT array_agg(DISTINCT x) INTO v_nc_ids FROM unnest(p_nota_credito_ids) AS x WHERE x IS NOT NULL;

  IF v_monto IS NULL OR v_monto < 0 THEN
    RAISE EXCEPTION 'El monto no puede ser negativo';
  END IF;
  IF v_monto = 0 AND v_nc_ids IS NULL THEN
    RAISE EXCEPTION 'Ingresá un monto mayor a cero o elegí una nota de crédito para aplicar';
  END IF;
  IF v_monto = 0 AND v_es_cheque THEN
    RAISE EXCEPTION 'Un pago sin monto (solo aplicación de notas de crédito) no puede ser con cheque';
  END IF;
  IF v_es_cheque THEN
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

  -- Serializa los pagos de un mismo proveedor: dos cajas pagando la misma factura a la vez no
  -- pueden leer el mismo saldo y sobrepagarla.
  PERFORM 1 FROM proveedores WHERE id = p_proveedor_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Proveedor no encontrado';
  END IF;

  -- ── Validación de comprobantes a pagar ──
  IF v_factura_ids IS NOT NULL THEN
    IF (SELECT count(*) FROM facturas_compra WHERE id = ANY(v_factura_ids)) <> cardinality(v_factura_ids) THEN
      RAISE EXCEPTION 'Alguno de los comprobantes elegidos no existe';
    END IF;
    SELECT * INTO v_mal FROM facturas_compra WHERE id = ANY(v_factura_ids) AND proveedor_id <> p_proveedor_id LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El comprobante % no es de este proveedor', COALESCE(v_mal.numero_comprobante, 'sin número');
    END IF;
    SELECT * INTO v_mal FROM facturas_compra WHERE id = ANY(v_factura_ids) AND anulada LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El comprobante % está anulado, no se le registran pagos', COALESCE(v_mal.numero_comprobante, 'sin número');
    END IF;
    SELECT * INTO v_mal FROM facturas_compra WHERE id = ANY(v_factura_ids) AND tipo_comprobante = 'nota_credito' LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El comprobante % es una nota de crédito: se aplica como crédito, no se paga', COALESCE(v_mal.numero_comprobante, 'sin número');
    END IF;
  END IF;

  -- ── Validación de notas de crédito ──
  IF v_nc_ids IS NOT NULL THEN
    IF (SELECT count(*) FROM facturas_compra WHERE id = ANY(v_nc_ids)) <> cardinality(v_nc_ids) THEN
      RAISE EXCEPTION 'Alguna de las notas de crédito elegidas no existe';
    END IF;
    SELECT * INTO v_mal FROM facturas_compra WHERE id = ANY(v_nc_ids) AND proveedor_id <> p_proveedor_id LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'La nota de crédito % no es de este proveedor', COALESCE(v_mal.numero_comprobante, 'sin número');
    END IF;
    SELECT * INTO v_mal FROM facturas_compra WHERE id = ANY(v_nc_ids) AND anulada LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'La nota de crédito % está anulada', COALESCE(v_mal.numero_comprobante, 'sin número');
    END IF;
    SELECT * INTO v_mal FROM facturas_compra WHERE id = ANY(v_nc_ids) AND tipo_comprobante <> 'nota_credito' LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El comprobante % no es una nota de crédito', COALESCE(v_mal.numero_comprobante, 'sin número');
    END IF;
  END IF;

  -- ── Comprobantes a cancelar: los elegidos, o todos los pendientes; más viejos primero ──
  SELECT COALESCE(array_agg(d.id ORDER BY d.fecha_comprobante, d.created_at, d.id), '{}'),
         COALESCE(array_agg(d.saldo ORDER BY d.fecha_comprobante, d.created_at, d.id), '{}')
  INTO v_doc_ids, v_doc_saldos
  FROM (
    SELECT fc.id, fc.fecha_comprobante, fc.created_at,
           fc.total - COALESCE((SELECT SUM(a.monto) FROM pagos_proveedor_aplicaciones a
                                WHERE a.factura_compra_id = fc.id AND a.revertida_at IS NULL), 0) AS saldo
    FROM facturas_compra fc
    WHERE fc.proveedor_id = p_proveedor_id
      AND NOT fc.anulada
      AND fc.tipo_comprobante <> 'nota_credito'
      AND (v_factura_ids IS NULL OR fc.id = ANY(v_factura_ids))
  ) d
  WHERE d.saldo > 0;
  v_n := cardinality(v_doc_ids);

  -- ── NC con crédito disponible, más viejas primero ──
  IF v_nc_ids IS NOT NULL THEN
    SELECT COALESCE(array_agg(d.id ORDER BY d.fecha_comprobante, d.created_at, d.id), '{}'),
           COALESCE(array_agg(d.disp ORDER BY d.fecha_comprobante, d.created_at, d.id), '{}')
    INTO v_nc_orden, v_nc_disp
    FROM (
      SELECT fc.id, fc.fecha_comprobante, fc.created_at,
             fc.total - COALESCE((SELECT SUM(a.monto) FROM pagos_proveedor_aplicaciones a
                                  WHERE a.nota_credito_id = fc.id AND a.revertida_at IS NULL), 0) AS disp
      FROM facturas_compra fc
      WHERE fc.id = ANY(v_nc_ids)
    ) d
    WHERE d.disp > 0;
  END IF;
  v_m := cardinality(v_nc_orden);

  -- ── Paso 1: crédito de NC contra los comprobantes ──
  i := 1;
  j := 1;
  WHILE i <= v_n AND j <= v_m LOOP
    v_aplicar := LEAST(v_doc_saldos[i], v_nc_disp[j]);
    v_plan_doc := array_append(v_plan_doc, v_doc_ids[i]);
    v_plan_monto := array_append(v_plan_monto, v_aplicar);
    v_plan_nc := array_append(v_plan_nc, v_nc_orden[j]);
    v_doc_saldos[i] := v_doc_saldos[i] - v_aplicar;
    v_nc_disp[j] := v_nc_disp[j] - v_aplicar;
    v_total_nc := v_total_nc + v_aplicar;
    IF v_doc_saldos[i] <= 0 THEN i := i + 1; END IF;
    IF v_nc_disp[j] <= 0 THEN j := j + 1; END IF;
  END LOOP;

  IF v_monto = 0 AND v_total_nc = 0 THEN
    RAISE EXCEPTION 'No hay saldo pendiente al que aplicar la nota de crédito';
  END IF;

  -- docs/52: con selección, un monto mayor a lo que queda de esos comprobantes ya no se rechaza.
  -- El paso 2 solo recorre los elegidos: lo que sobra queda a cuenta (v_rest).

  -- ── Paso 2: repartir el pago, más viejos primero. Lo que sobra queda a cuenta ──
  v_rest := v_monto;
  i := 1;
  WHILE i <= v_n AND v_rest > 0 LOOP
    v_aplicar := LEAST(v_doc_saldos[i], v_rest);
    IF v_aplicar > 0 THEN
      v_plan_doc := array_append(v_plan_doc, v_doc_ids[i]);
      v_plan_monto := array_append(v_plan_monto, v_aplicar);
      v_plan_nc := array_append(v_plan_nc, NULL::UUID);
      v_pago_docs := array_append(v_pago_docs, v_doc_ids[i]);
      v_doc_saldos[i] := v_doc_saldos[i] - v_aplicar;
      v_rest := v_rest - v_aplicar;
    END IF;
    i := i + 1;
  END LOOP;

  -- ── Escritura ──
  INSERT INTO pagos_proveedor (
    proveedor_id, factura_compra_id, monto, forma_pago, usuario_id, fecha, nota,
    cheque_numero, cheque_fecha_salida, cheque_fecha_vencimiento
  )
  VALUES (
    p_proveedor_id,
    -- deprecated: solo si todo el pago cancela una única factura (compatibilidad con las pantallas actuales)
    CASE WHEN cardinality(v_pago_docs) = 1 AND v_rest = 0 THEN v_pago_docs[1] END,
    v_monto, p_forma_pago, auth.uid(), v_fecha, v_nota,
    CASE WHEN v_es_cheque THEN trim(p_cheque_numero) END,
    CASE WHEN v_es_cheque THEN p_cheque_fecha_salida END,
    CASE WHEN v_es_cheque THEN p_cheque_fecha_vencimiento END
  )
  RETURNING id INTO v_pago_id;

  INSERT INTO pagos_proveedor_aplicaciones
    (factura_compra_id, monto, pago_proveedor_id, nota_credito_id, operacion_id, usuario_id)
  SELECT t.doc, t.monto, CASE WHEN t.nc IS NULL THEN v_pago_id END, t.nc, v_pago_id, auth.uid()
  FROM unnest(v_plan_doc, v_plan_monto, v_plan_nc) AS t(doc, monto, nc);

  IF v_monto > 0 THEN
    INSERT INTO egresos (cierre_caja_id, origen, categoria, monto, descripcion, forma_pago, usuario_id, fecha, pago_proveedor_id)
    VALUES (p_cierre_caja_id, p_origen, 'pago_proveedor', v_monto,
            'Pago a proveedor' || COALESCE(' — ' || v_nota, ''),
            p_forma_pago, auth.uid(), v_fecha, v_pago_id);

    -- Cheque y echeq no impactan cuentas (no son plata líquida al registrarse — docs/15).
    -- docs/58: el efectivo de Local (origen 'turno') sale del cajón y queda en el Cierre Z; la cuenta
    -- Efectivo (Caja Gestión) solo baja con lo que paga Gestión. La transferencia sale del banco igual.
    IF p_forma_pago = 'transferencia' OR (p_forma_pago = 'efectivo' AND p_origen = 'general') THEN
      INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
      SELECT cuenta_id, 'pago_proveedor', -abs(v_monto), v_pago_id, auth.uid()
      FROM cuenta_forma_pago WHERE forma_pago = p_forma_pago::text::forma_pago_venta;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'pago_id', v_pago_id,
    'monto', v_monto,
    'aplicado_pago', v_monto - v_rest,
    'aplicado_nota_credito', v_total_nc,
    'a_cuenta', v_rest,
    'aplicaciones', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', a.id,
               'factura_compra_id', a.factura_compra_id,
               'monto', a.monto,
               'fuente', CASE WHEN a.nota_credito_id IS NULL THEN 'pago' ELSE 'nota_credito' END,
               'nota_credito_id', a.nota_credito_id
             ) ORDER BY a.created_at, a.id)
      FROM pagos_proveedor_aplicaciones a
      WHERE a.operacion_id = v_pago_id
    ), '[]'::jsonb)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_egreso_general(p_categoria categoria_egreso, p_monto numeric, p_descripcion text, p_forma_pago forma_pago_egreso, p_origen origen_egreso DEFAULT 'general'::origen_egreso, p_cierre_caja_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_egreso_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF p_origen = 'general' AND NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede registrar un egreso de origen general';
  END IF;
  IF p_categoria = 'pago_proveedor' THEN
    RAISE EXCEPTION 'Para pagos a proveedor usá registrar_pago_proveedor, no esta función';
  END IF;
  IF p_descripcion IS NULL OR trim(p_descripcion) = '' THEN
    RAISE EXCEPTION 'La descripción es obligatoria';
  END IF;

  INSERT INTO egresos (cierre_caja_id, origen, categoria, monto, descripcion, forma_pago, usuario_id)
  VALUES (p_cierre_caja_id, p_origen, p_categoria, p_monto, p_descripcion, p_forma_pago, auth.uid())
  RETURNING id INTO v_egreso_id;

  -- docs/58: el efectivo de Local (origen 'turno') no sale de la cuenta Efectivo de Caja Gestión.
  IF p_forma_pago = 'transferencia' OR (p_forma_pago = 'efectivo' AND p_origen = 'general') THEN
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
    SELECT cuenta_id, 'egreso', -abs(p_monto), v_egreso_id, auth.uid()
    FROM cuenta_forma_pago WHERE forma_pago = p_forma_pago::text::forma_pago_venta;
  END IF;

  RETURN v_egreso_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_egreso_general(p_categoria categoria_egreso, p_monto numeric, p_descripcion text, p_forma_pago forma_pago_egreso, p_origen origen_egreso DEFAULT 'general'::origen_egreso, p_cierre_caja_id uuid DEFAULT NULL::uuid, p_fecha date DEFAULT CURRENT_DATE)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_egreso_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF p_origen = 'general' AND NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede registrar un egreso de origen general';
  END IF;
  IF p_categoria = 'pago_proveedor' THEN
    RAISE EXCEPTION 'Para pagos a proveedor usá registrar_pago_proveedor, no esta función';
  END IF;
  IF p_descripcion IS NULL OR trim(p_descripcion) = '' THEN
    RAISE EXCEPTION 'La descripción es obligatoria';
  END IF;
  IF p_fecha IS NULL THEN
    RAISE EXCEPTION 'La fecha del egreso es obligatoria';
  END IF;

  INSERT INTO egresos (cierre_caja_id, origen, categoria, monto, descripcion, forma_pago, usuario_id, fecha)
  VALUES (p_cierre_caja_id, p_origen, p_categoria, p_monto, p_descripcion, p_forma_pago, auth.uid(), p_fecha)
  RETURNING id INTO v_egreso_id;

  -- docs/58: el efectivo de Local (origen 'turno') no sale de la cuenta Efectivo de Caja Gestión.
  IF p_forma_pago = 'transferencia' OR (p_forma_pago = 'efectivo' AND p_origen = 'general') THEN
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
    SELECT cuenta_id, 'egreso', -abs(p_monto), v_egreso_id, auth.uid()
    FROM cuenta_forma_pago WHERE forma_pago = p_forma_pago::text::forma_pago_venta;
  END IF;

  RETURN v_egreso_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.revertir_movimiento(p_auditoria_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_auditoria auditoria%ROWTYPE;
  v_row JSONB;
  v_pago_orig_id UUID;
  v_pago_rev_id UUID;
  v_monto NUMERIC;
  v_egreso egresos%ROWTYPE;
  v_egreso_rev_id UUID;  -- docs/38
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
            (v_row->>'forma_pago')::forma_pago_egreso, auth.uid(), (v_row->>'id')::UUID)
    RETURNING id INTO v_egreso_rev_id;

    -- docs/38: contra-movimiento de cuenta, espejo de lo que movió el egreso original.
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, referencia_id, usuario_id)
    SELECT mc.cuenta_id, mc.tipo, -1 * mc.monto, 'Reversión de egreso', v_egreso_rev_id, auth.uid()
    FROM movimientos_cuenta mc
    WHERE mc.referencia_id = (v_row->>'id')::UUID;

  ELSIF v_auditoria.tabla_afectada = 'pagos_proveedor' THEN
    v_pago_orig_id := (v_row->>'id')::UUID;
    v_monto := (v_row->>'monto')::NUMERIC;

    IF v_row->>'revierte_pago_proveedor_id' IS NOT NULL OR v_monto < 0 THEN
      RAISE EXCEPTION 'Esto ya es la reversión de un pago — no se revierte de nuevo';
    END IF;

    INSERT INTO pagos_proveedor (
      proveedor_id, factura_compra_id, monto, forma_pago, usuario_id, revierte_pago_proveedor_id,
      cheque_numero, cheque_fecha_salida, cheque_fecha_vencimiento, nota
    )
    VALUES (
      (v_row->>'proveedor_id')::UUID, NULLIF(v_row->>'factura_compra_id','')::UUID,
      -1 * v_monto, (v_row->>'forma_pago')::forma_pago_egreso, auth.uid(), v_pago_orig_id,
      v_row->>'cheque_numero', NULLIF(v_row->>'cheque_fecha_salida','')::DATE, NULLIF(v_row->>'cheque_fecha_vencimiento','')::DATE,
      'Reversión desde Historial'
    )
    RETURNING id INTO v_pago_rev_id;

    IF v_monto <> 0 THEN
      -- El egreso original, con su origen real (turno = caja de Local, general = Gestión).
      SELECT * INTO v_egreso FROM egresos
      WHERE pago_proveedor_id = v_pago_orig_id AND revierte_egreso_id IS NULL
      LIMIT 1;

      IF FOUND THEN
        INSERT INTO egresos (origen, categoria, monto, descripcion, forma_pago, usuario_id, revierte_egreso_id, pago_proveedor_id)
        VALUES (v_egreso.origen, 'pago_proveedor', -1 * v_monto, 'Reversión de pago a proveedor',
                v_egreso.forma_pago, auth.uid(), v_egreso.id, v_pago_rev_id);
      ELSE
        -- Pago anterior a docs/31 sin egreso vinculado (el backfill vinculó todos los que había).
        INSERT INTO egresos (origen, categoria, monto, descripcion, forma_pago, usuario_id, pago_proveedor_id)
        VALUES ('turno', 'pago_proveedor', -1 * v_monto, 'Reversión de pago a proveedor',
                (v_row->>'forma_pago')::forma_pago_egreso, auth.uid(), v_pago_rev_id);
      END IF;

      -- docs/58: espejo de lo que el pago movió en cuentas (neto de correcciones). Un pago en
      -- efectivo de Local no movió la cuenta Efectivo, así que su reversión tampoco la mueve.
      INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
      SELECT mc.cuenta_id, 'pago_proveedor', -1 * sum(mc.monto), v_pago_orig_id, auth.uid()
      FROM movimientos_cuenta mc
      WHERE mc.referencia_id = v_pago_orig_id AND mc.tipo = 'pago_proveedor'
      GROUP BY mc.cuenta_id
      HAVING sum(mc.monto) <> 0;
    END IF;

    -- Las aplicaciones de la operación (plata del pago y NC usadas en ese acto) dejan de contar:
    -- los comprobantes vuelven a su saldo anterior y la NC recupera su crédito.
    UPDATE pagos_proveedor_aplicaciones
    SET revertida_at = now(), revertida_por = auth.uid()
    WHERE operacion_id = v_pago_orig_id AND revertida_at IS NULL;

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
$function$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (solo lectura)
-- Esperado: las 4 funciones con la marca docs/58.
-- ════════════════════════════════════════════════════════════════════════════════════════════
SELECT p.oid::regprocedure::text AS funcion, pg_get_functiondef(p.oid) LIKE '%docs/58%' AS con_docs58,
       array_to_string(p.proacl, ',') AS permisos
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('registrar_pago_proveedor_v2', 'registrar_egreso_general', 'revertir_movimiento');

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (no deja nada: termina en RAISE EXCEPTION 'RESULTADO: …')
-- Corre como el primer admin y el primer cajero activos, con un proveedor de prueba.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $test$
DECLARE
  v_admin uuid := (SELECT id FROM perfiles WHERE activo AND rol = 'admin' ORDER BY created_at LIMIT 1);
  v_cajero uuid := (SELECT id FROM perfiles WHERE activo AND rol <> 'admin' ORDER BY created_at LIMIT 1);
  v_ef uuid := (SELECT cuenta_id FROM cuenta_forma_pago WHERE forma_pago = 'efectivo');
  v_tr uuid := (SELECT cuenta_id FROM cuenta_forma_pago WHERE forma_pago = 'transferencia');
  v_prov uuid;
  v_p1 uuid; v_p2 uuid; v_p3 uuid;
  v_e1 uuid; v_e2 uuid;
  v_aud uuid;
  v_n int;
  v_x0 numeric; v_x1 numeric;
  v_ef0 numeric; v_tr0 numeric;
  v_ok text := '';
  v_mal text := '';
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  INSERT INTO proveedores (razon_social) VALUES ('TEST58') RETURNING id INTO v_prov;
  SELECT saldo_actual INTO v_ef0 FROM cuentas_saldo WHERE id = v_ef;
  SELECT saldo_actual INTO v_tr0 FROM cuentas_saldo WHERE id = v_tr;

  -- Caja abierta (si no hay, una de prueba) para medir el X.
  IF NOT EXISTS (SELECT 1 FROM aperturas_caja WHERE cierre_z_id IS NULL) THEN
    INSERT INTO aperturas_caja (monto_esperado, monto_real, diferencia, usuario_id) VALUES (0, 0, 0, v_cajero);
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_cajero, 'role', 'authenticated')::text, true);
  v_aud := cerrar_caja('x');
  SELECT efectivo_esperado INTO v_x0 FROM cierres_caja WHERE id = v_aud;

  -- 1. Pago efectivo desde Local (turno): egreso turno, sin movimiento de cuenta.
  v_p1 := (registrar_pago_proveedor_v2(p_proveedor_id => v_prov, p_monto => 1000, p_forma_pago => 'efectivo', p_origen => 'turno')->>'pago_id')::uuid;
  IF EXISTS (SELECT 1 FROM egresos WHERE pago_proveedor_id = v_p1 AND origen = 'turno' AND monto = 1000)
     AND NOT EXISTS (SELECT 1 FROM movimientos_cuenta WHERE referencia_id = v_p1)
  THEN v_ok := v_ok || ' 1'; ELSE v_mal := v_mal || ' 1'; END IF;

  -- 2. El X de Local sigue restando ese pago del cajón.
  v_aud := cerrar_caja('x');
  SELECT efectivo_esperado INTO v_x1 FROM cierres_caja WHERE id = v_aud;
  IF v_x1 = v_x0 - 1000 THEN v_ok := v_ok || ' 2'; ELSE v_mal := v_mal || format(' 2(%s→%s)', v_x0, v_x1); END IF;

  -- 3. Pago transferencia desde Local: sí baja la cuenta del banco.
  v_p2 := (registrar_pago_proveedor_v2(p_proveedor_id => v_prov, p_monto => 700, p_forma_pago => 'transferencia', p_origen => 'turno')->>'pago_id')::uuid;
  IF EXISTS (SELECT 1 FROM movimientos_cuenta WHERE referencia_id = v_p2 AND cuenta_id = v_tr AND monto = -700)
  THEN v_ok := v_ok || ' 3'; ELSE v_mal := v_mal || ' 3'; END IF;

  -- 4. Pago efectivo desde Gestión (general, admin): baja Efectivo.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  v_p3 := (registrar_pago_proveedor_v2(p_proveedor_id => v_prov, p_monto => 500, p_forma_pago => 'efectivo', p_origen => 'general')->>'pago_id')::uuid;
  IF EXISTS (SELECT 1 FROM movimientos_cuenta WHERE referencia_id = v_p3 AND cuenta_id = v_ef AND monto = -500)
  THEN v_ok := v_ok || ' 4'; ELSE v_mal := v_mal || ' 4'; END IF;

  -- 5. Egreso efectivo de Local (turno, cajero): sin movimiento. 6. De Gestión: con movimiento.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_cajero, 'role', 'authenticated')::text, true);
  v_e1 := registrar_egreso_general(p_categoria => 'otro', p_monto => 300, p_descripcion => 'T58', p_forma_pago => 'efectivo', p_origen => 'turno', p_cierre_caja_id => NULL, p_fecha => current_date);
  IF NOT EXISTS (SELECT 1 FROM movimientos_cuenta WHERE referencia_id = v_e1) THEN v_ok := v_ok || ' 5'; ELSE v_mal := v_mal || ' 5'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  v_e2 := registrar_egreso_general(p_categoria => 'otro', p_monto => 200, p_descripcion => 'T58', p_forma_pago => 'efectivo', p_origen => 'general', p_cierre_caja_id => NULL, p_fecha => current_date);
  IF EXISTS (SELECT 1 FROM movimientos_cuenta WHERE referencia_id = v_e2 AND cuenta_id = v_ef AND monto = -200) THEN v_ok := v_ok || ' 6'; ELSE v_mal := v_mal || ' 6'; END IF;

  -- 7. Revertir el pago de Local: egreso contrario turno, ningún movimiento de cuenta.
  SELECT id INTO v_aud FROM auditoria WHERE tabla_afectada = 'pagos_proveedor' AND registro_id = v_p1 AND accion = 'alta';
  PERFORM revertir_movimiento(v_aud);
  IF NOT EXISTS (SELECT 1 FROM movimientos_cuenta WHERE referencia_id = v_p1)
     AND EXISTS (SELECT 1 FROM egresos WHERE revierte_egreso_id IS NOT NULL AND origen = 'turno' AND monto = -1000
                 AND pago_proveedor_id IN (SELECT id FROM pagos_proveedor WHERE revierte_pago_proveedor_id = v_p1))
  THEN v_ok := v_ok || ' 7'; ELSE v_mal := v_mal || ' 7'; END IF;

  -- 8. Revertir el pago de Gestión: devuelve 500 a Efectivo (neto 0). 9. El de transferencia: neto 0 en banco.
  SELECT id INTO v_aud FROM auditoria WHERE tabla_afectada = 'pagos_proveedor' AND registro_id = v_p3 AND accion = 'alta';
  PERFORM revertir_movimiento(v_aud);
  SELECT count(*) INTO v_n FROM movimientos_cuenta WHERE referencia_id = v_p3;
  IF v_n = 2 AND (SELECT sum(monto) FROM movimientos_cuenta WHERE referencia_id = v_p3) = 0 THEN v_ok := v_ok || ' 8'; ELSE v_mal := v_mal || ' 8'; END IF;
  SELECT id INTO v_aud FROM auditoria WHERE tabla_afectada = 'pagos_proveedor' AND registro_id = v_p2 AND accion = 'alta';
  PERFORM revertir_movimiento(v_aud);
  IF (SELECT sum(monto) FROM movimientos_cuenta WHERE referencia_id = v_p2 AND cuenta_id = v_tr) = 0 THEN v_ok := v_ok || ' 9'; ELSE v_mal := v_mal || ' 9'; END IF;

  -- 10. Saldos: Efectivo solo movió el egreso de Gestión (−200); banco neto 0.
  IF (SELECT saldo_actual FROM cuentas_saldo WHERE id = v_ef) = v_ef0 - 200
     AND (SELECT saldo_actual FROM cuentas_saldo WHERE id = v_tr) = v_tr0
  THEN v_ok := v_ok || ' 10'; ELSE v_mal := v_mal || ' 10'; END IF;

  RAISE EXCEPTION 'RESULTADO: ok[%] mal[%]', v_ok, v_mal;
END
$test$;

ROLLBACK;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE D — corrección de datos (una sola vez, después de la PARTE A)
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $fix$
DECLARE
  v_ef uuid := 'cc43498c-0924-4ba8-9ec3-0a2d95b58ee7';
  v_saldo0 numeric;
  v_esperados jsonb := '[
    {"mov": "2cd3e9b0-0269-4c26-917d-fdf2b370384b", "pago": "938f100c-d9a0-457a-adb0-3e33bc4d7f46", "monto": -61300},
    {"mov": "e0a2cf75-abca-47c4-b909-702f1f5e26a2", "pago": "de045d5b-43fa-4fb4-ae65-f0fd4a7ba640", "monto": -195600},
    {"mov": "cfcb9315-a042-451b-9738-69595c68e963", "pago": "a2191ee0-63e6-489a-b35a-0636efdec031", "monto": -300000},
    {"mov": "0ca008af-d678-474a-81f8-90aba7b6fc6a", "pago": "42d4ef65-15e7-4306-b05b-d5ab8a32919c", "monto": -193416.20}
  ]';
  v_encontrados text;
  v_x jsonb;
BEGIN
  -- Re-verificación: los movimientos de Efectivo de pagos con egreso de Local, sin corregir, son
  -- exactamente los 4 relevados el 2026-10-26 (si apareció otro o cambió uno, no se toca nada).
  SELECT string_agg(mc.id::text || '|' || mc.referencia_id::text || '|' || round(mc.monto, 2)::text, ',' ORDER BY mc.id::text)
  INTO v_encontrados
  FROM movimientos_cuenta mc
  JOIN egresos e ON e.pago_proveedor_id = mc.referencia_id AND e.revierte_egreso_id IS NULL
  WHERE mc.cuenta_id = v_ef AND mc.tipo = 'pago_proveedor' AND mc.revierte_movimiento_id IS NULL
    AND e.origen = 'turno' AND e.forma_pago = 'efectivo'
    AND NOT EXISTS (SELECT 1 FROM movimientos_cuenta c WHERE c.revierte_movimiento_id = mc.id)
    AND NOT EXISTS (SELECT 1 FROM pagos_proveedor r WHERE r.revierte_pago_proveedor_id = mc.referencia_id);

  IF v_encontrados IS DISTINCT FROM (
    SELECT string_agg((x->>'mov') || '|' || (x->>'pago') || '|' || round((x->>'monto')::numeric, 2)::text, ',' ORDER BY x->>'mov')
    FROM jsonb_array_elements(v_esperados) x
  ) THEN
    RAISE EXCEPTION 'Los datos cambiaron desde el relevamiento, no se corrige nada: %', v_encontrados;
  END IF;

  SELECT saldo_actual INTO v_saldo0 FROM cuentas_saldo WHERE id = v_ef;

  -- Como Jimena (admin): la auditoría 'alta' de cada contra-asiento queda a su nombre.
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', '4b6fc500-fa5f-4512-84b8-13345382b761', 'role', 'authenticated')::text, true);

  FOR v_x IN SELECT * FROM jsonb_array_elements(v_esperados) LOOP
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, referencia_id, revierte_movimiento_id, usuario_id)
    VALUES (v_ef, 'pago_proveedor', -1 * (v_x->>'monto')::numeric,
            'Corrección docs/58: pago en efectivo desde la caja de Local (ya descontado en el Cierre Z), no sale del Efectivo de Gestión',
            (v_x->>'pago')::uuid, (v_x->>'mov')::uuid, '4b6fc500-fa5f-4512-84b8-13345382b761');
  END LOOP;

  IF (SELECT saldo_actual FROM cuentas_saldo WHERE id = v_ef) <> v_saldo0 + 750316.20 THEN
    RAISE EXCEPTION 'El saldo de Efectivo no quedó como se esperaba';
  END IF;
  RAISE NOTICE 'Efectivo: % → %', v_saldo0, v_saldo0 + 750316.20;
END
$fix$;

COMMIT;
