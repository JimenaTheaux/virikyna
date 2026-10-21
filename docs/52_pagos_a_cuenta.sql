-- 52 — Pagos "a cuenta" de proveedores: aplicarlos después a comprobantes, y quitar una aplicación
--
-- ✅ APLICADO el 2026-10-21 (archivo completo), con backup previo virikyna_2026-10-21_pre-pagos-a-cuenta.
-- La primera corrida commiteó la PARTE A y falló en la PARTE C (T3): el detalle que devuelve
-- aplicar_pagos_a_cuenta se ordenaba por created_at, que es el mismo para toda la transacción, y
-- quedaba al azar. El reparto en sí estaba bien. Se corrigió el ORDER BY (orden de aplicación), la
-- PARTE A pasó a CREATE OR REPLACE y se volvió a correr el archivo entero: PARTE C sin errores. Las
-- vistas nacieron con todos los privilegios para authenticated (default privileges de Supabase): se
-- revocó a mano y el REVOKE de abajo ya lo incluye. Verificación PARTE B: identidad de saldo 0 filas,
-- 0 pagos sobreaplicados, EXPRESO JESUS MARIA $ 256.900 a cuenta en 2 pagos.
--
-- Contexto (relevado contra la base real el 2026-10-20):
--   - Un pago solo se reparte al registrarlo (registrar_pago_proveedor_v2, docs/31). Si en ese
--     momento el proveedor no tiene comprobantes pendientes, la plata queda "a cuenta" y no había
--     forma de aplicarla a una factura cargada después. Caso real: EXPRESO JESUS MARIA S.R.L., dos
--     pagos desde Local ($ 195.600 y $ 61.300) enteros a cuenta, sin comprobantes. Al cargar su
--     factura iba a figurar pendiente por el total (y se podía pagar dos veces).
--   - Lo "a cuenta" de un pago no se guardaba en ningún lado: lo calculaba la pantalla.
--   - Una aplicación no se podía deshacer sola: solo revirtiendo el pago entero desde el Historial
--     (contra-egreso + contra-movimiento de hoy, que pesan en el cierre del día).
--   - registrar_pago_proveedor_v2 con comprobantes elegidos rechazaba un monto mayor a su saldo.
--
-- Qué hace (una transacción; no toca tablas ni vistas existentes):
--   1. Vista nueva pagos_proveedor_a_cuenta (por pago) y proveedores_a_cuenta (total por proveedor).
--   2. RPC aplicar_pagos_a_cuenta: reparte lo a cuenta de los pagos (más viejos primero) en los
--      comprobantes elegidos o en los pendientes más viejos. Sin egreso, sin movimiento de cuenta,
--      no toca la caja.
--   3. RPC desaplicar_pago (solo admin): marca una aplicación como revertida; la plata (o el crédito
--      de la NC) vuelve a estar disponible. Sin egreso ni movimiento.
--   4. registrar_pago_proveedor_v2: con comprobantes elegidos y un monto mayor a su saldo, ya no
--      rechaza: aplica hasta el saldo y el sobrante queda a cuenta. Cuerpo vigente (igual a docs/31,
--      verificado con pg_get_functiondef el 2026-10-20) con ese único cambio.
--
-- Modelo (igual que docs/31): una aplicación nueva lleva operacion_id = pago_proveedor_id, así
-- revertir el pago original desde el Historial (revertir_movimiento) también la deshace.
--
-- Saldo del proveedor: proveedores_saldo no mira aplicaciones, así que aplicar o quitar no lo cambia.
-- Identidad (test T8):
--   saldo_actual = saldo_inicial + Σ saldo_pendiente − Σ credito_disponible (NC) − Σ a_cuenta (pagos)

BEGIN;

-- ============================================================
-- 1. Vistas de lo "a cuenta"
-- Pago vigente = monto > 0, no es una reversión y no fue revertido. Lo de un pago revertido no
-- está a cuenta: su reversión ya lo descontó del saldo del proveedor.
-- ============================================================
CREATE OR REPLACE VIEW pagos_proveedor_a_cuenta WITH (security_invoker = on) AS
SELECT
  pp.id,
  pp.proveedor_id,
  pp.fecha,
  pp.created_at,
  pp.monto,
  ap.aplicado,                                         -- de la plata de este pago, lo aplicado vigente
  v.vigente,
  CASE WHEN v.vigente THEN pp.monto - ap.aplicado ELSE 0 END AS a_cuenta
FROM pagos_proveedor pp
CROSS JOIN LATERAL (
  SELECT COALESCE(SUM(a.monto), 0) AS aplicado
  FROM pagos_proveedor_aplicaciones a
  WHERE a.pago_proveedor_id = pp.id AND a.revertida_at IS NULL
) ap
CROSS JOIN LATERAL (
  SELECT pp.monto > 0
         AND pp.revierte_pago_proveedor_id IS NULL
         AND NOT EXISTS (SELECT 1 FROM pagos_proveedor r WHERE r.revierte_pago_proveedor_id = pp.id) AS vigente
) v;

COMMENT ON VIEW pagos_proveedor_a_cuenta IS
  'docs/52: por pago, lo aplicado vigente y lo que queda a cuenta (0 en reversiones, revertidos y operaciones solo de NC).';

CREATE OR REPLACE VIEW proveedores_a_cuenta WITH (security_invoker = on) AS
SELECT proveedor_id,
       SUM(a_cuenta) AS a_cuenta,
       count(*) FILTER (WHERE a_cuenta > 0) AS pagos_con_saldo
FROM pagos_proveedor_a_cuenta
GROUP BY proveedor_id;

COMMENT ON VIEW proveedores_a_cuenta IS 'docs/52: total a cuenta (pagos sin aplicar) por proveedor.';

-- Mismo criterio que docs/38: sin anon; authenticated solo lee (la RLS de pagos_proveedor aplica
-- por security_invoker). Se revoca también authenticated: los default privileges de Supabase le
-- dan todo (arwdDxtm) a cada objeto nuevo.
REVOKE ALL ON pagos_proveedor_a_cuenta, proveedores_a_cuenta FROM PUBLIC, anon, authenticated;
GRANT SELECT ON pagos_proveedor_a_cuenta, proveedores_a_cuenta TO authenticated, service_role;

-- ============================================================
-- 2. aplicar_pagos_a_cuenta
-- ============================================================
CREATE OR REPLACE FUNCTION aplicar_pagos_a_cuenta(
  p_proveedor_id UUID,
  p_factura_ids UUID[] DEFAULT NULL,   -- NULL/vacío = todos los pendientes, más viejos primero
  p_pago_ids UUID[] DEFAULT NULL       -- NULL/vacío = todos los pagos con saldo a cuenta, más viejos primero
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_factura_ids UUID[];
  v_pago_ids UUID[];
  v_mal facturas_compra%ROWTYPE;
  v_pago_mal RECORD;
  v_doc_ids UUID[] := '{}';
  v_doc_saldos NUMERIC[] := '{}';
  v_pag_ids UUID[] := '{}';
  v_pag_disp NUMERIC[] := '{}';
  v_n INT;
  v_m INT;
  i INT := 1;
  j INT := 1;
  v_aplicar NUMERIC;
  v_total NUMERIC := 0;
  v_ids UUID[] := '{}';
  v_id UUID;
BEGIN
  -- Mismo permiso que registrar_pago_proveedor_v2: cualquier perfil activo. No mueve plata.
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  SELECT array_agg(DISTINCT x) INTO v_factura_ids FROM unnest(p_factura_ids) AS x WHERE x IS NOT NULL;
  SELECT array_agg(DISTINCT x) INTO v_pago_ids FROM unnest(p_pago_ids) AS x WHERE x IS NOT NULL;

  -- Mismo lock que v2: serializa pagos, aplicaciones y quitas del mismo proveedor.
  PERFORM 1 FROM proveedores WHERE id = p_proveedor_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Proveedor no encontrado';
  END IF;

  -- ── Comprobantes elegidos: mismas reglas que v2 ──
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
      RAISE EXCEPTION 'El comprobante % está anulado, no se le aplican pagos', COALESCE(v_mal.numero_comprobante, 'sin número');
    END IF;
    SELECT * INTO v_mal FROM facturas_compra WHERE id = ANY(v_factura_ids) AND tipo_comprobante = 'nota_credito' LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El comprobante % es una nota de crédito: no se le aplican pagos', COALESCE(v_mal.numero_comprobante, 'sin número');
    END IF;
  END IF;

  -- ── Pagos elegidos: del proveedor y vigentes ──
  IF v_pago_ids IS NOT NULL THEN
    IF (SELECT count(*) FROM pagos_proveedor WHERE id = ANY(v_pago_ids)) <> cardinality(v_pago_ids) THEN
      RAISE EXCEPTION 'Alguno de los pagos elegidos no existe';
    END IF;
    SELECT * INTO v_pago_mal FROM pagos_proveedor_a_cuenta WHERE id = ANY(v_pago_ids) AND proveedor_id <> p_proveedor_id LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El pago del % no es de este proveedor', to_char(v_pago_mal.fecha, 'DD/MM/YYYY');
    END IF;
    SELECT * INTO v_pago_mal FROM pagos_proveedor_a_cuenta WHERE id = ANY(v_pago_ids) AND NOT vigente LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El pago del % no está vigente (fue revertido o es una reversión)', to_char(v_pago_mal.fecha, 'DD/MM/YYYY');
    END IF;
  END IF;

  -- ── Comprobantes a cancelar, más viejos primero (mismo orden y saldo que v2) ──
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

  IF v_n = 0 THEN
    RAISE EXCEPTION 'No hay saldo pendiente en los comprobantes al que aplicar el pago a cuenta';
  END IF;

  -- ── Pagos con saldo a cuenta, más viejos primero ──
  SELECT COALESCE(array_agg(p.id ORDER BY p.fecha, p.created_at, p.id), '{}'),
         COALESCE(array_agg(p.a_cuenta ORDER BY p.fecha, p.created_at, p.id), '{}')
  INTO v_pag_ids, v_pag_disp
  FROM pagos_proveedor_a_cuenta p
  WHERE p.proveedor_id = p_proveedor_id
    AND p.a_cuenta > 0
    AND (v_pago_ids IS NULL OR p.id = ANY(v_pago_ids));
  v_m := cardinality(v_pag_ids);

  IF v_m = 0 THEN
    RAISE EXCEPTION 'Este proveedor no tiene pagos a cuenta para aplicar';
  END IF;

  -- ── Reparto: pago más viejo contra comprobante más viejo ──
  WHILE i <= v_n AND j <= v_m LOOP
    v_aplicar := LEAST(v_doc_saldos[i], v_pag_disp[j]);
    INSERT INTO pagos_proveedor_aplicaciones
      (factura_compra_id, monto, pago_proveedor_id, nota_credito_id, operacion_id, usuario_id)
    VALUES (v_doc_ids[i], v_aplicar, v_pag_ids[j], NULL, v_pag_ids[j], auth.uid())
    RETURNING id INTO v_id;
    v_ids := array_append(v_ids, v_id);
    v_total := v_total + v_aplicar;
    v_doc_saldos[i] := v_doc_saldos[i] - v_aplicar;
    v_pag_disp[j] := v_pag_disp[j] - v_aplicar;
    IF v_doc_saldos[i] <= 0 THEN i := i + 1; END IF;
    IF v_pag_disp[j] <= 0 THEN j := j + 1; END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'aplicado', v_total,
    'a_cuenta_restante', (SELECT COALESCE(SUM(a_cuenta), 0) FROM pagos_proveedor_a_cuenta WHERE proveedor_id = p_proveedor_id),
    'aplicaciones', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', a.id,
               'pago_proveedor_id', a.pago_proveedor_id,
               'factura_compra_id', a.factura_compra_id,
               'monto', a.monto
             -- En el orden en que se aplicaron: created_at es el mismo para toda la transacción.
             ) ORDER BY array_position(v_ids, a.id))
      FROM pagos_proveedor_aplicaciones a
      WHERE a.id = ANY(v_ids)
    ), '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION aplicar_pagos_a_cuenta(UUID, UUID[], UUID[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION aplicar_pagos_a_cuenta(UUID, UUID[], UUID[]) TO authenticated, service_role;

-- ============================================================
-- 3. desaplicar_pago — solo admin
-- Sirve para una aplicación de plata (vuelve a cuenta del pago) o de NC (la NC recupera crédito).
-- No toca egresos, cuentas ni pagos_proveedor: el saldo del proveedor no cambia.
-- ============================================================
CREATE OR REPLACE FUNCTION desaplicar_pago(p_aplicacion_id UUID) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_apl pagos_proveedor_aplicaciones%ROWTYPE;
  v_proveedor_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede quitar una aplicación de pago';
  END IF;

  SELECT fc.proveedor_id INTO v_proveedor_id
  FROM pagos_proveedor_aplicaciones a JOIN facturas_compra fc ON fc.id = a.factura_compra_id
  WHERE a.id = p_aplicacion_id;
  IF v_proveedor_id IS NULL THEN
    RAISE EXCEPTION 'Aplicación no encontrada';
  END IF;

  -- Mismo lock que v2 y aplicar_pagos_a_cuenta.
  PERFORM 1 FROM proveedores WHERE id = v_proveedor_id FOR UPDATE;

  SELECT * INTO v_apl FROM pagos_proveedor_aplicaciones WHERE id = p_aplicacion_id FOR UPDATE;
  IF v_apl.revertida_at IS NOT NULL THEN
    RAISE EXCEPTION 'Esta aplicación ya se había quitado';
  END IF;

  UPDATE pagos_proveedor_aplicaciones
  SET revertida_at = now(), revertida_por = auth.uid()
  WHERE id = p_aplicacion_id AND revertida_at IS NULL;

  RETURN jsonb_build_object(
    'id', v_apl.id,
    'factura_compra_id', v_apl.factura_compra_id,
    'monto', v_apl.monto,
    'fuente', CASE WHEN v_apl.nota_credito_id IS NULL THEN 'pago' ELSE 'nota_credito' END,
    'pago_proveedor_id', v_apl.pago_proveedor_id,
    'nota_credito_id', v_apl.nota_credito_id
  );
END;
$$;

REVOKE ALL ON FUNCTION desaplicar_pago(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION desaplicar_pago(UUID) TO authenticated, service_role;

-- ============================================================
-- 4. registrar_pago_proveedor_v2 — cuerpo vigente (= docs/31). Único cambio: con comprobantes
-- elegidos, un monto mayor a su saldo ya no se rechaza; el paso 2 solo recorre los elegidos, así
-- que el sobrante queda a cuenta (no se va a otros pendientes). CREATE OR REPLACE conserva grants.
-- ============================================================
CREATE OR REPLACE FUNCTION registrar_pago_proveedor_v2(
  p_proveedor_id UUID,
  p_monto NUMERIC,                         -- 0 = solo aplicar notas de crédito (sin egreso)
  p_forma_pago forma_pago_egreso,
  p_factura_ids UUID[] DEFAULT NULL,       -- NULL/vacío = todas las pendientes, más viejas primero
  p_nota_credito_ids UUID[] DEFAULT NULL,
  p_origen origen_egreso DEFAULT 'turno',  -- 'turno' = caja de Local · 'general' = Gestión (solo admin)
  p_cierre_caja_id UUID DEFAULT NULL,
  p_fecha DATE DEFAULT NULL,               -- NULL = hoy (día AR)
  p_nota TEXT DEFAULT NULL,
  p_cheque_numero TEXT DEFAULT NULL,
  p_cheque_fecha_salida DATE DEFAULT NULL,
  p_cheque_fecha_vencimiento DATE DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
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
    IF p_forma_pago IN ('efectivo', 'transferencia') THEN
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
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación post-migración (solo lectura)
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- B1. Vistas con security_invoker y sin anon; funciones sin anon (esperado: 2 vistas con
-- {security_invoker=on}, 2 funciones con authenticated + service_role).
SELECT c.relname, c.reloptions, c.relacl FROM pg_class c
WHERE c.relname IN ('pagos_proveedor_a_cuenta', 'proveedores_a_cuenta');
SELECT p.oid::regprocedure, p.prosecdef, p.proacl FROM pg_proc p
WHERE p.proname IN ('aplicar_pagos_a_cuenta', 'desaplicar_pago', 'registrar_pago_proveedor_v2');

-- B2. Identidad de saldo para todos los proveedores (esperado: 0 filas).
SELECT ps.id, ps.razon_social, ps.saldo_actual,
       ps.saldo_inicial
       + COALESCE((SELECT SUM(saldo_pendiente) - SUM(credito_disponible) FROM facturas_compra_saldo f WHERE f.proveedor_id = ps.id), 0)
       - COALESCE((SELECT a_cuenta FROM proveedores_a_cuenta pc WHERE pc.proveedor_id = ps.id), 0) AS identidad
FROM proveedores_saldo ps
WHERE ps.saldo_actual <> ps.saldo_inicial
       + COALESCE((SELECT SUM(saldo_pendiente) - SUM(credito_disponible) FROM facturas_compra_saldo f WHERE f.proveedor_id = ps.id), 0)
       - COALESCE((SELECT a_cuenta FROM proveedores_a_cuenta pc WHERE pc.proveedor_id = ps.id), 0);

-- B3. Lo que hoy está a cuenta (esperado al 2026-10-20: EXPRESO JESUS MARIA $ 256.900 en 2 pagos).
SELECT p.razon_social, pc.a_cuenta, pc.pagos_con_saldo
FROM proveedores_a_cuenta pc JOIN proveedores p ON p.id = pc.proveedor_id
WHERE pc.a_cuenta <> 0 ORDER BY 1;

-- B4. Ningún pago con más aplicado que su monto (esperado: 0 filas).
SELECT * FROM pagos_proveedor_a_cuenta WHERE vigente AND a_cuenta < 0;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — TESTS (después de la parte A). Todo dentro de BEGIN … ROLLBACK: no deja datos.
-- Corren como el primer admin activo. Si un ASSERT falla, el bloque aborta con el mensaje.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $$
DECLARE
  v_admin UUID;
  v_cajero UUID;
  pA UUID; pB UUID; pC UUID; pD UUID; pX UUID;
  fA UUID; fB UUID; fC1 UUID; fC2 UUID; fD UUID; fD2 UUID; fX UUID; ncC UUID; fAnul UUID;
  pagoA UUID; pagoB1 UUID; pagoB2 UUID; pagoC UUID; pagoD UUID; pagoX UUID;
  v_res JSONB;
  v_apl UUID;
  v_aud UUID;
  v_saldo_antes NUMERIC;
  v_ok BOOLEAN;
  v_prov UUID;
  v_identidad NUMERIC;
  v_saldo NUMERIC;
  v_cierre_id UUID;
  v_c1 cierres_caja%ROWTYPE;
  v_c2 cierres_caja%ROWTYPE;
  v_egresos BIGINT;
  v_movs BIGINT;
  -- Caso real
  pExpreso UUID;
  v_expreso_a_cuenta NUMERIC;
  fE1 UUID; fE2 UUID;
  v_t11 TEXT := 'salteado';
BEGIN
  SELECT id INTO v_admin FROM perfiles WHERE rol = 'admin' AND activo ORDER BY created_at LIMIT 1;
  ASSERT v_admin IS NOT NULL, 'setup: no hay admin activo';
  SELECT id INTO v_cajero FROM perfiles WHERE rol <> 'admin' AND activo ORDER BY created_at LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  INSERT INTO proveedores (razon_social) VALUES ('TEST52 A') RETURNING id INTO pA;
  INSERT INTO proveedores (razon_social) VALUES ('TEST52 B') RETURNING id INTO pB;
  INSERT INTO proveedores (razon_social) VALUES ('TEST52 C') RETURNING id INTO pC;
  INSERT INTO proveedores (razon_social) VALUES ('TEST52 D') RETURNING id INTO pD;
  INSERT INTO proveedores (razon_social) VALUES ('TEST52 X') RETURNING id INTO pX;

  -- Caja antes de todo lo que no mueve plata (T7).
  v_cierre_id := cerrar_caja('x');
  SELECT * INTO v_c1 FROM cierres_caja WHERE id = v_cierre_id;

  -- ── T1: pago a cuenta 150.000 > factura 100.000 → factura pagada, 50.000 siguen a cuenta ──
  v_res := registrar_pago_proveedor_v2(pA, 150000, 'transferencia', NULL, NULL, 'general');
  pagoA := (v_res->>'pago_id')::UUID;
  ASSERT (v_res->>'a_cuenta')::NUMERIC = 150000, 'T1: sin comprobantes, el pago queda entero a cuenta';
  ASSERT (SELECT a_cuenta FROM proveedores_a_cuenta WHERE proveedor_id = pA) = 150000, 'T1: vista por proveedor = 150.000';
  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (pA, 'factura', 'T1', '2026-02-01', 'cuenta_corriente', 100000, 0, 100000, v_admin) RETURNING id INTO fA;
  SELECT saldo_actual INTO v_saldo_antes FROM proveedores_saldo WHERE id = pA;
  SELECT count(*) INTO v_egresos FROM egresos;
  SELECT count(*) INTO v_movs FROM movimientos_cuenta;

  v_res := aplicar_pagos_a_cuenta(pA, ARRAY[fA]);
  ASSERT (v_res->>'aplicado')::NUMERIC = 100000, 'T1: aplica 100.000';
  ASSERT (v_res->>'a_cuenta_restante')::NUMERIC = 50000, 'T1: quedan 50.000 a cuenta';
  ASSERT jsonb_array_length(v_res->'aplicaciones') = 1, 'T1: una aplicación';
  ASSERT (SELECT estado FROM facturas_compra_saldo WHERE id = fA) = 'pagada', 'T1: factura pagada';
  ASSERT (SELECT a_cuenta FROM pagos_proveedor_a_cuenta WHERE id = pagoA) = 50000, 'T1: el pago muestra 50.000 a cuenta';
  ASSERT (SELECT saldo_actual FROM proveedores_saldo WHERE id = pA) = v_saldo_antes, 'T1: saldo del proveedor sin cambios';
  ASSERT (SELECT count(*) FROM egresos) = v_egresos AND (SELECT count(*) FROM movimientos_cuenta) = v_movs,
    'T1: aplicar no crea egresos ni movimientos de cuenta';
  ASSERT (SELECT operacion_id FROM pagos_proveedor_aplicaciones WHERE id = (v_res->'aplicaciones'->0->>'id')::UUID) = pagoA,
    'T1: operacion_id = el pago original';

  -- Sin pendientes ya no hay a qué aplicar.
  v_ok := false;
  BEGIN
    PERFORM aplicar_pagos_a_cuenta(pA);
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM LIKE '%No hay saldo pendiente%';
  END;
  ASSERT v_ok, 'T1: sin pendientes → error';

  -- ── T2: pago a cuenta 40.000 < factura 100.000 → factura parcial con 60.000 ──
  v_res := registrar_pago_proveedor_v2(pB, 40000, 'efectivo', NULL, NULL, 'general');
  pagoB1 := (v_res->>'pago_id')::UUID;
  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (pB, 'factura', 'T2', '2026-02-01', 'cuenta_corriente', 100000, 0, 100000, v_admin) RETURNING id INTO fB;
  v_res := aplicar_pagos_a_cuenta(pB);
  ASSERT (SELECT estado FROM facturas_compra_saldo WHERE id = fB) = 'parcial', 'T2: factura parcial';
  ASSERT (SELECT saldo_pendiente FROM facturas_compra_saldo WHERE id = fB) = 60000, 'T2: saldo 60.000';
  ASSERT (v_res->>'a_cuenta_restante')::NUMERIC = 0, 'T2: nada a cuenta';

  -- Sin pagos a cuenta → error.
  v_ok := false;
  BEGIN
    PERFORM aplicar_pagos_a_cuenta(pB);
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM LIKE '%no tiene pagos a cuenta%';
  END;
  ASSERT v_ok, 'T2: sin pagos a cuenta → error';

  -- Con una pendiente, v2 sin selección sigue aplicando ahí (no queda a cuenta).
  v_res := registrar_pago_proveedor_v2(pB, 25000, 'efectivo', NULL, NULL, 'general');
  ASSERT (SELECT saldo_pendiente FROM facturas_compra_saldo WHERE id = fB) = 35000, 'T2: v2 sin selección sigue aplicando a pendientes';

  -- ── T3: dos pagos a cuenta (los montos de EXPRESO) a una factura, con una NC que no se toca ──
  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (pC, 'nota_credito', 'T3-NC', '2026-01-01', 'cuenta_corriente', 1000, 0, 1000, v_admin) RETURNING id INTO ncC;
  v_res := registrar_pago_proveedor_v2(pC, 195600, 'efectivo', NULL, NULL, 'turno', NULL, '2026-10-01');
  pagoC := (v_res->>'pago_id')::UUID;
  v_res := registrar_pago_proveedor_v2(pC, 61300, 'transferencia', NULL, NULL, 'turno', NULL, '2026-10-02');
  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (pC, 'factura', 'T3-F', '2026-10-15', 'cuenta_corriente', 256900, 0, 256900, v_admin) RETURNING id INTO fC1;
  SELECT saldo_actual INTO v_saldo_antes FROM proveedores_saldo WHERE id = pC;
  v_res := aplicar_pagos_a_cuenta(pC, ARRAY[fC1]);
  ASSERT jsonb_array_length(v_res->'aplicaciones') = 2, 'T3: dos aplicaciones (una por pago)';
  ASSERT (v_res->'aplicaciones'->0->>'pago_proveedor_id')::UUID = pagoC, 'T3: el detalle viene en orden de aplicación';
  ASSERT (SELECT monto FROM pagos_proveedor_aplicaciones WHERE pago_proveedor_id = pagoC AND factura_compra_id = fC1) = 195600,
    'T3: el pago más viejo (195.600) se aplica entero';
  ASSERT (SELECT estado FROM facturas_compra_saldo WHERE id = fC1) = 'pagada', 'T3: factura pagada con los dos pagos';
  ASSERT (SELECT saldo_actual FROM proveedores_saldo WHERE id = pC) = v_saldo_antes, 'T3: saldo del proveedor sin cambios';
  ASSERT (SELECT credito_disponible FROM facturas_compra_saldo WHERE id = ncC) = 1000, 'T3: la NC no se toca';

  -- ── T4: un pago a dos facturas (más viejas primero) ──
  v_res := registrar_pago_proveedor_v2(pD, 150000, 'efectivo', NULL, NULL, 'general');
  pagoD := (v_res->>'pago_id')::UUID;
  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (pD, 'factura', 'T4-2', '2026-03-02', 'cuenta_corriente', 100000, 0, 100000, v_admin) RETURNING id INTO fD2;
  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (pD, 'factura', 'T4-1', '2026-03-01', 'cuenta_corriente', 100000, 0, 100000, v_admin) RETURNING id INTO fD;
  v_res := aplicar_pagos_a_cuenta(pD, NULL, ARRAY[pagoD]);
  ASSERT (SELECT estado FROM facturas_compra_saldo WHERE id = fD) = 'pagada', 'T4: la más vieja pagada';
  ASSERT (SELECT saldo_pendiente FROM facturas_compra_saldo WHERE id = fD2) = 50000, 'T4: la otra parcial con 50.000';
  ASSERT (SELECT a_cuenta FROM pagos_proveedor_a_cuenta WHERE id = pagoD) = 0, 'T4: el pago queda sin saldo a cuenta';

  -- ── T5: desaplicar → vuelve a cuenta, saldo del proveedor sin cambios ──
  SELECT saldo_actual INTO v_saldo_antes FROM proveedores_saldo WHERE id = pD;
  SELECT id INTO v_apl FROM pagos_proveedor_aplicaciones WHERE factura_compra_id = fD2 AND revertida_at IS NULL;
  SELECT count(*) INTO v_egresos FROM egresos;
  SELECT count(*) INTO v_movs FROM movimientos_cuenta;
  v_res := desaplicar_pago(v_apl);
  ASSERT (v_res->>'monto')::NUMERIC = 50000, 'T5: devuelve el monto quitado';
  ASSERT (SELECT estado FROM facturas_compra_saldo WHERE id = fD2) = 'pendiente', 'T5: la factura vuelve a pendiente';
  ASSERT (SELECT a_cuenta FROM pagos_proveedor_a_cuenta WHERE id = pagoD) = 50000, 'T5: 50.000 vuelven a cuenta';
  ASSERT (SELECT saldo_actual FROM proveedores_saldo WHERE id = pD) = v_saldo_antes, 'T5: saldo del proveedor sin cambios';
  ASSERT (SELECT count(*) FROM egresos) = v_egresos AND (SELECT count(*) FROM movimientos_cuenta) = v_movs,
    'T5: desaplicar no crea egresos ni movimientos';
  ASSERT (SELECT revertida_por FROM pagos_proveedor_aplicaciones WHERE id = v_apl) = v_admin, 'T5: queda quién la quitó';
  v_ok := false;
  BEGIN
    PERFORM desaplicar_pago(v_apl);
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM LIKE '%ya se había quitado%';
  END;
  ASSERT v_ok, 'T5: quitar dos veces → error';
  -- Se puede volver a aplicar.
  v_res := aplicar_pagos_a_cuenta(pD, ARRAY[fD2]);
  ASSERT (SELECT saldo_pendiente FROM facturas_compra_saldo WHERE id = fD2) = 50000, 'T5: reaplicado';
  -- Un no-admin no puede quitar.
  IF v_cajero IS NOT NULL THEN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_cajero, 'role', 'authenticated')::text, true);
    v_ok := false;
    BEGIN
      PERFORM desaplicar_pago((v_res->'aplicaciones'->0->>'id')::UUID);
    EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM LIKE '%Solo un administrador%';
    END;
    ASSERT v_ok, 'T5: un cajero no puede quitar una aplicación';
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  ELSE
    RAISE NOTICE 'T5: no hay perfil no-admin activo, se saltea la prueba de permiso';
  END IF;

  -- ── T6: revertir el pago original (Historial) deshace también lo aplicado después ──
  SELECT id INTO v_aud FROM auditoria WHERE tabla_afectada = 'pagos_proveedor' AND registro_id = pagoD AND accion = 'alta';
  ASSERT v_aud IS NOT NULL, 'T6: setup — falta la auditoría del pago';
  PERFORM revertir_movimiento(v_aud);
  ASSERT (SELECT estado FROM facturas_compra_saldo WHERE id = fD) = 'pendiente', 'T6: factura 1 vuelve a pendiente';
  ASSERT (SELECT estado FROM facturas_compra_saldo WHERE id = fD2) = 'pendiente', 'T6: factura 2 vuelve a pendiente';
  ASSERT (SELECT count(*) FROM pagos_proveedor_aplicaciones WHERE pago_proveedor_id = pagoD AND revertida_at IS NULL) = 0,
    'T6: ninguna aplicación del pago queda vigente';
  ASSERT (SELECT a_cuenta FROM pagos_proveedor_a_cuenta WHERE id = pagoD) = 0 AND NOT (SELECT vigente FROM pagos_proveedor_a_cuenta WHERE id = pagoD),
    'T6: un pago revertido no queda a cuenta';
  ASSERT COALESCE((SELECT a_cuenta FROM proveedores_a_cuenta WHERE proveedor_id = pD), 0) = 0, 'T6: proveedor sin nada a cuenta';
  v_ok := false;
  BEGIN
    PERFORM aplicar_pagos_a_cuenta(pD, NULL, ARRAY[pagoD]);
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM LIKE '%no está vigente%';
  END;
  ASSERT v_ok, 'T6: un pago revertido no se puede aplicar';

  -- ── T9: v2 con selección y monto mayor al saldo → aplica hasta el saldo, sobrante a cuenta ──
  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (pX, 'factura', 'T9-VIEJA', '2026-01-01', 'cuenta_corriente', 5000, 0, 5000, v_admin) RETURNING id INTO fC2;
  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (pX, 'factura', 'T9', '2026-02-01', 'cuenta_corriente', 100000, 0, 100000, v_admin) RETURNING id INTO fX;
  v_res := registrar_pago_proveedor_v2(pX, 150000, 'efectivo', ARRAY[fX], NULL, 'general');
  pagoX := (v_res->>'pago_id')::UUID;
  ASSERT (v_res->>'aplicado_pago')::NUMERIC = 100000 AND (v_res->>'a_cuenta')::NUMERIC = 50000, 'T9: 100.000 aplicados, 50.000 a cuenta';
  ASSERT (SELECT estado FROM facturas_compra_saldo WHERE id = fX) = 'pagada', 'T9: la elegida pagada';
  ASSERT (SELECT estado FROM facturas_compra_saldo WHERE id = fC2) = 'pendiente', 'T9: el sobrante no va a otra pendiente';
  ASSERT (SELECT count(*) FROM egresos WHERE pago_proveedor_id = pagoX AND monto = 150000) = 1, 'T9: el egreso es por el total';
  ASSERT (SELECT factura_compra_id FROM pagos_proveedor WHERE id = pagoX) IS NULL, 'T9: con sobrante, factura_compra_id (deprecated) NULL';
  -- El wrapper viejo tampoco rechaza (Local, detalle de factura).
  v_res := jsonb_build_object('pago', registrar_pago_proveedor(pX, fC2, 8000, 'efectivo', 'turno', NULL, NULL, NULL, NULL));
  ASSERT (SELECT estado FROM facturas_compra_saldo WHERE id = fC2) = 'pagada', 'T9: wrapper viejo paga la factura';
  ASSERT (SELECT a_cuenta FROM proveedores_a_cuenta WHERE proveedor_id = pX) = 53000, 'T9: 50.000 + 3.000 a cuenta';

  -- ── T10: validaciones ──
  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id, anulada)
  VALUES (pX, 'factura', 'T10-ANUL', '2026-01-01', 'cuenta_corriente', 100, 0, 100, v_admin, true) RETURNING id INTO fAnul;
  v_ok := false;
  BEGIN PERFORM aplicar_pagos_a_cuenta(pX, ARRAY[fA]);
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM LIKE '%no es de este proveedor%'; END;
  ASSERT v_ok, 'T10: comprobante de otro proveedor';
  v_ok := false;
  BEGIN PERFORM aplicar_pagos_a_cuenta(pX, ARRAY[fAnul]);
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM LIKE '%anulado%'; END;
  ASSERT v_ok, 'T10: comprobante anulado';
  v_ok := false;
  BEGIN PERFORM aplicar_pagos_a_cuenta(pC, ARRAY[ncC]);
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM LIKE '%nota de crédito%'; END;
  ASSERT v_ok, 'T10: nota de crédito';
  v_ok := false;
  BEGIN PERFORM aplicar_pagos_a_cuenta(pX, NULL, ARRAY[pagoA]);
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM LIKE '%no es de este proveedor%'; END;
  ASSERT v_ok, 'T10: pago de otro proveedor';

  -- ── T7: nada de lo anterior que no mueve plata cambia la caja ──
  -- (los pagos de v2 sí: se descuentan de la foto para comparar solo aplicar/quitar)
  v_cierre_id := cerrar_caja('x');
  SELECT * INTO v_c2 FROM cierres_caja WHERE id = v_cierre_id;
  ASSERT v_c2.total_egresos = v_c1.total_egresos
           + (SELECT COALESCE(SUM(e.monto), 0) FROM egresos e JOIN pagos_proveedor pp ON pp.id = e.pago_proveedor_id
              WHERE pp.proveedor_id IN (pA, pB, pC, pD, pX) AND e.origen = 'turno'),
    format('T7: el cierre solo cambia por los pagos de turno (%s → %s)', v_c1.total_egresos, v_c2.total_egresos);

  -- ── T8: identidad de saldo en todos los proveedores de prueba ──
  FOR v_prov IN SELECT unnest(ARRAY[pA, pB, pC, pD, pX]) LOOP
    SELECT saldo_actual INTO v_saldo FROM proveedores_saldo WHERE id = v_prov;
    SELECT (SELECT saldo_inicial FROM proveedores WHERE id = v_prov)
         + COALESCE((SELECT SUM(saldo_pendiente) - SUM(credito_disponible) FROM facturas_compra_saldo WHERE proveedor_id = v_prov), 0)
         - COALESCE((SELECT a_cuenta FROM proveedores_a_cuenta WHERE proveedor_id = v_prov), 0)
    INTO v_identidad;
    ASSERT v_saldo = v_identidad, format('T8: identidad de saldo rota para %s (%s vs %s)', v_prov, v_saldo, v_identidad);
  END LOOP;

  -- ── T11: caso real EXPRESO JESUS MARIA (si sigue igual que el 20/10) ──
  SELECT id INTO pExpreso FROM proveedores WHERE razon_social ILIKE 'EXPRESO JESUS MARIA%';
  SELECT COALESCE(a_cuenta, 0) INTO v_expreso_a_cuenta FROM proveedores_a_cuenta WHERE proveedor_id = pExpreso;
  IF pExpreso IS NULL OR v_expreso_a_cuenta IS DISTINCT FROM 256900 THEN
    RAISE NOTICE 'T11: EXPRESO cambió desde el 20/10 (a cuenta = %), se saltea', v_expreso_a_cuenta;
  ELSE
    SELECT saldo_actual INTO v_saldo_antes FROM proveedores_saldo WHERE id = pExpreso;
    -- Factura de 200.000: pagada, quedan 56.900. Después otra de 100.000: parcial con 43.100.
    INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id)
    VALUES (pExpreso, 'factura', 'TEST52-1', '2026-10-20', 'cuenta_corriente', 200000, 0, 200000, v_admin) RETURNING id INTO fE1;
    v_res := aplicar_pagos_a_cuenta(pExpreso, ARRAY[fE1]);
    ASSERT (SELECT estado FROM facturas_compra_saldo WHERE id = fE1) = 'pagada', 'T11: factura de 200.000 pagada';
    ASSERT (v_res->>'a_cuenta_restante')::NUMERIC = 56900, 'T11: quedan 56.900 a cuenta';
    INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id)
    VALUES (pExpreso, 'factura', 'TEST52-2', '2026-10-20', 'cuenta_corriente', 100000, 0, 100000, v_admin) RETURNING id INTO fE2;
    v_res := aplicar_pagos_a_cuenta(pExpreso, ARRAY[fE2]);
    ASSERT (SELECT estado FROM facturas_compra_saldo WHERE id = fE2) = 'parcial'
       AND (SELECT saldo_pendiente FROM facturas_compra_saldo WHERE id = fE2) = 43100, 'T11: segunda factura parcial con 43.100';
    ASSERT COALESCE((SELECT a_cuenta FROM proveedores_a_cuenta WHERE proveedor_id = pExpreso), 0) = 0, 'T11: nada a cuenta';
    ASSERT (SELECT saldo_actual FROM proveedores_saldo WHERE id = pExpreso) = v_saldo_antes + 300000,
      'T11: el saldo solo cambia por las facturas cargadas, no por aplicar';
    v_t11 := format('ok, saldo %s → %s', v_saldo_antes, v_saldo_antes + 300000);
  END IF;

  RAISE NOTICE 'docs/52: todos los tests pasaron (T11 EXPRESO: %)', v_t11;
END;
$$;

ROLLBACK;
