-- 65 — Pago a proveedor con varios medios (efectivo, transferencia, eCheq, cheque físico)
--
-- ✅ APLICADO en producción el 2026-10-27 (A0 y A, en llamadas separadas), con backup previo
-- virikyna_2026-10-27_pre-docs65-aplicar. Antes se re-verificó (diff) que v2, el contado y
-- revertir_movimiento seguían iguales a lo probado. PARTE B ok: mixto en el enum, RLS, vista
-- invoker, v3 sin anon, 6 pagos con 1 medio cada uno, ninguno con suma distinta.
-- Probada el 2026-10-27 sobre una restauración local del backup virikyna_2026-10-27_pre-docs65-test
-- (restaurar-prueba.ps1, docs/44): docs/64 + esta completa, PARTE B ok y PARTE C 12/12, dos veces
-- seguidas (re-corrible). No se puede probar en BEGIN … ROLLBACK contra producción: 'mixto' (A0)
-- recién se puede usar después del COMMIT.
-- Correr desde la raíz del repo con
-- `supabase db query --linked -f docs/65_pago_proveedor_varios_medios.sql` (o en el SQL Editor del
-- proyecto ccpinvtleqlsukcqnili), después de 64. La PARTE A0 y la A se pueden re-correr (IF NOT
-- EXISTS / CREATE OR REPLACE / backfill solo de lo que falta); la PARTE B solo lee y la PARTE C es
-- un test (BEGIN … ROLLBACK, termina con RAISE EXCEPTION 'RESULTADO: …' para que nada quede escrito).
--
-- Contexto (relevado contra la base real el 2026-10-27):
--   - pagos_proveedor tiene UN medio por pago (forma_pago) y los datos de un solo cheque en columnas
--     (cheque_numero, cheque_fecha_salida, cheque_fecha_vencimiento, docs/15). No hay tabla de cheques.
--   - registrar_pago_proveedor_v2 (docs/31, docs/52, docs/58) crea: el pago, sus aplicaciones, UN
--     egreso y, si es transferencia o efectivo de Gestión, UN movimiento de cuenta.
--   - registrar_pago_proveedor (v1, las dos firmas) y cargar_factura_compra_contado (docs/57)
--     delegan en v2. revertir_movimiento revierte UN egreso del pago (LIMIT 1).
--   - Hay 6 pagos, todos en efectivo, cada uno con un egreso; ninguno revertido.
--   - Caso real a cubrir: un pago = transferencia + eCheq + cheques físicos a 30/60/90 días, o
--     efectivo + transferencia; hoy cada medio es un pago aparte.
--
-- Decisiones (2026-10-27): 1 pago = cabecera + N medios, sin límite y con tipos repetidos; solo
-- cheques propios (el campo `propio` queda preparado); el estado "debitado" queda afuera; el contado
-- sigue solo en efectivo; Local no cambia de UI (sus RPCs siguen andando con 1 medio).
--
-- Qué hace:
--   0. forma_pago_egreso + 'mixto' (cabecera de un pago con más de un medio). Va en su propia
--      transacción: un valor nuevo de enum no se puede usar antes del COMMIT.
--   1. Tabla pagos_proveedor_medios: pago, medio, monto y, para cheques, número, banco, fecha de
--      salida, fecha de pago, propio. Una reversión agrega filas espejo (monto negativo,
--      revierte_medio_id) en el pago de reversión, igual que pagos_proveedor. RLS: misma lectura que
--      pagos_proveedor; se escribe solo por RPC (SECURITY DEFINER).
--   2. egresos.pago_proveedor_medio_id: de qué medio salió cada egreso (NULL en los anteriores).
--      El índice único de docs/31 (un egreso original por pago) pasa a ser uno por medio; los
--      egresos anteriores, sin medio, siguen con uno por pago.
--   3. Backfill: cada pago existente con monto <> 0 pasa a tener 1 medio (su forma de pago y, si
--      era cheque, sus datos). No toca egresos (el UPDATE dejaría ediciones en la auditoría).
--   4. registrar_pago_proveedor_v3(proveedor, medios jsonb, facturas, NC, origen, cierre, fecha,
--      nota, monto): mismo reparto que v2 (NC primero, después el pago, más viejos primero,
--      sobrante a cuenta) sobre el total = suma de los medios. Por medio: un egreso (el cierre de
--      Local sigue contando solo efectivo de turno) y, si es transferencia o efectivo de Gestión,
--      un movimiento de cuenta (docs/58). Los cheques no mueven cuentas: quedan en la cartera.
--      Cabecera: forma_pago = el medio si hay uno, 'mixto' si hay más; con un solo cheque también
--      completa las columnas cheque_* (lo leen las apps instaladas).
--   5. registrar_pago_proveedor_v2: misma firma y mismas validaciones, ahora arma 1 medio y llama a
--      v3. v1 y cargar_factura_compra_contado no cambian (llaman a v2).
--   6. revertir_movimiento (pagos_proveedor): revierte TODOS los egresos del pago y espeja todos sus
--      medios. El resto de la función queda igual.
--   7. Vista cartera_cheques_emitidos (security_invoker): un renglón por cheque/eCheq, con
--      proveedor, vencimiento y si está revertido.

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A0 — valor nuevo del enum (transacción propia)
-- ════════════════════════════════════════════════════════════════════════════════════════════
ALTER TYPE public.forma_pago_egreso ADD VALUE IF NOT EXISTS 'mixto';

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ─── 1. pagos_proveedor_medios ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.pagos_proveedor_medios (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pago_proveedor_id uuid NOT NULL REFERENCES public.pagos_proveedor(id),
  medio public.forma_pago_egreso NOT NULL,
  monto numeric(12,2) NOT NULL,              -- > 0; negativo solo en la fila espejo de una reversión
  numero text,                               -- cheque / eCheq
  banco text,
  fecha_salida date,
  fecha_pago date,                           -- vencimiento (cuándo se cobra)
  propio boolean NOT NULL DEFAULT true,      -- por ahora solo propios; terceros queda preparado
  orden integer NOT NULL,
  revierte_medio_id uuid REFERENCES public.pagos_proveedor_medios(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pagos_proveedor_medios_no_mixto CHECK (medio <> 'mixto'),
  CONSTRAINT pagos_proveedor_medios_monto CHECK (monto <> 0),
  CONSTRAINT pagos_proveedor_medios_cheque CHECK (
    CASE WHEN medio IN ('cheque', 'echeq')
      THEN numero IS NOT NULL AND btrim(numero) <> '' AND fecha_pago IS NOT NULL
      ELSE numero IS NULL AND banco IS NULL AND fecha_salida IS NULL AND fecha_pago IS NULL
    END),
  CONSTRAINT pagos_proveedor_medios_orden UNIQUE (pago_proveedor_id, orden)
);

CREATE INDEX IF NOT EXISTS idx_pagos_proveedor_medios_pago ON public.pagos_proveedor_medios(pago_proveedor_id);
CREATE INDEX IF NOT EXISTS idx_pagos_proveedor_medios_cheques ON public.pagos_proveedor_medios(fecha_pago)
  WHERE medio IN ('cheque', 'echeq');

ALTER TABLE public.pagos_proveedor_medios ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pagos_proveedor_medios_select ON public.pagos_proveedor_medios;
CREATE POLICY pagos_proveedor_medios_select ON public.pagos_proveedor_medios FOR SELECT
  USING (EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));
REVOKE ALL ON public.pagos_proveedor_medios FROM anon;

-- Banco sin acentos, como el resto de los textos (docs/51).
DROP TRIGGER IF EXISTS trg_sin_acentos ON public.pagos_proveedor_medios;
CREATE TRIGGER trg_sin_acentos BEFORE INSERT OR UPDATE ON public.pagos_proveedor_medios
  FOR EACH ROW EXECUTE FUNCTION fn_sin_acentos('banco');

-- ─── 2. egresos.pago_proveedor_medio_id ──────────────────────────────────────────────────────
ALTER TABLE public.egresos ADD COLUMN IF NOT EXISTS pago_proveedor_medio_id uuid REFERENCES public.pagos_proveedor_medios(id);

-- docs/31 garantizaba "un pago genera a lo sumo un egreso original" (ux_egresos_pago_proveedor).
-- Ahora es uno por medio; para los egresos anteriores (sin medio) se mantiene uno por pago.
DROP INDEX IF EXISTS public.ux_egresos_pago_proveedor;
CREATE UNIQUE INDEX IF NOT EXISTS ux_egresos_pago_proveedor_medio
  ON public.egresos(pago_proveedor_medio_id)
  WHERE pago_proveedor_medio_id IS NOT NULL AND revierte_egreso_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_egresos_pago_proveedor_sin_medio
  ON public.egresos(pago_proveedor_id)
  WHERE pago_proveedor_id IS NOT NULL AND pago_proveedor_medio_id IS NULL AND revierte_egreso_id IS NULL;
-- Los egresos de un pago se buscan por pago (reversión, Egresos, cierre).
CREATE INDEX IF NOT EXISTS idx_egresos_pago_proveedor ON public.egresos(pago_proveedor_id)
  WHERE pago_proveedor_id IS NOT NULL;

-- ─── 3. Backfill: 1 medio por pago existente ─────────────────────────────────────────────────
-- Primero los pagos originales, después las reversiones (que apuntan al medio del original).
INSERT INTO public.pagos_proveedor_medios (pago_proveedor_id, medio, monto, numero, fecha_salida, fecha_pago, orden, created_at)
SELECT p.id, p.forma_pago, p.monto,
       CASE WHEN p.forma_pago IN ('cheque', 'echeq') THEN COALESCE(NULLIF(btrim(p.cheque_numero), ''), 'S/N') END,
       CASE WHEN p.forma_pago IN ('cheque', 'echeq') THEN p.cheque_fecha_salida END,
       CASE WHEN p.forma_pago IN ('cheque', 'echeq') THEN COALESCE(p.cheque_fecha_vencimiento, p.cheque_fecha_salida, p.fecha) END,
       1, p.created_at
FROM public.pagos_proveedor p
WHERE p.monto <> 0 AND p.revierte_pago_proveedor_id IS NULL
  AND NOT EXISTS (SELECT 1 FROM public.pagos_proveedor_medios m WHERE m.pago_proveedor_id = p.id);

INSERT INTO public.pagos_proveedor_medios (pago_proveedor_id, medio, monto, numero, fecha_salida, fecha_pago, orden, revierte_medio_id, created_at)
SELECT p.id, p.forma_pago, p.monto,
       CASE WHEN p.forma_pago IN ('cheque', 'echeq') THEN COALESCE(NULLIF(btrim(p.cheque_numero), ''), 'S/N') END,
       CASE WHEN p.forma_pago IN ('cheque', 'echeq') THEN p.cheque_fecha_salida END,
       CASE WHEN p.forma_pago IN ('cheque', 'echeq') THEN COALESCE(p.cheque_fecha_vencimiento, p.cheque_fecha_salida, p.fecha) END,
       1, (SELECT m.id FROM public.pagos_proveedor_medios m WHERE m.pago_proveedor_id = p.revierte_pago_proveedor_id ORDER BY m.orden LIMIT 1),
       p.created_at
FROM public.pagos_proveedor p
WHERE p.monto <> 0 AND p.revierte_pago_proveedor_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.pagos_proveedor_medios m WHERE m.pago_proveedor_id = p.id);

-- ─── 4. registrar_pago_proveedor_v3 ──────────────────────────────────────────────────────────
-- p_medios: [{"medio": "efectivo|transferencia|cheque|echeq", "monto": 1000, "numero": "…",
--             "banco": "…", "fecha_salida": "AAAA-MM-DD", "fecha_pago": "AAAA-MM-DD", "propio": true}]
-- Vacío o NULL = pago de monto 0 que solo aplica notas de crédito (igual que v2 con monto 0).
-- p_monto (opcional): total que la pantalla quiere pagar; si viene, tiene que ser igual a la suma.
CREATE OR REPLACE FUNCTION public.registrar_pago_proveedor_v3(
  p_proveedor_id uuid,
  p_medios jsonb,
  p_factura_ids uuid[] DEFAULT NULL,
  p_nota_credito_ids uuid[] DEFAULT NULL,
  p_origen origen_egreso DEFAULT 'turno',
  p_cierre_caja_id uuid DEFAULT NULL,
  p_fecha date DEFAULT NULL,
  p_nota text DEFAULT NULL,
  p_monto numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_fecha DATE := COALESCE(p_fecha, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);
  v_nota TEXT := NULLIF(trim(p_nota), '');
  -- Medios ya validados (en orden).
  v_m_medio forma_pago_egreso[] := '{}';
  v_m_monto NUMERIC[] := '{}';
  v_m_numero TEXT[] := '{}';
  v_m_banco TEXT[] := '{}';
  v_m_salida DATE[] := '{}';
  v_m_pago DATE[] := '{}';
  v_m_ids UUID[] := '{}';
  v_elem jsonb;
  v_medio_txt text;
  v_medio forma_pago_egreso;
  v_m_val NUMERIC;
  v_es_cheque BOOLEAN;
  v_num TEXT;
  v_sal DATE;
  v_pag DATE;
  v_cant INT := 0;
  v_monto NUMERIC := 0;
  v_forma_cabecera forma_pago_egreso;
  v_medio_id UUID;
  v_desc TEXT;
  v_factura_ids UUID[];
  v_nc_ids UUID[];
  v_mal facturas_compra%ROWTYPE;
  v_doc_ids UUID[] := '{}';
  v_doc_saldos NUMERIC[] := '{}';
  v_nc_orden UUID[] := '{}';
  v_nc_disp NUMERIC[] := '{}';
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

  -- ── Medios ──
  IF p_medios IS NOT NULL AND jsonb_typeof(p_medios) <> 'array' THEN
    RAISE EXCEPTION 'Los medios de pago tienen que venir como lista';
  END IF;
  FOR v_elem IN SELECT e FROM jsonb_array_elements(COALESCE(p_medios, '[]'::jsonb)) AS e LOOP
    v_cant := v_cant + 1;
    v_medio_txt := v_elem->>'medio';
    IF v_medio_txt IS NULL OR v_medio_txt NOT IN ('efectivo', 'transferencia', 'cheque', 'echeq') THEN
      RAISE EXCEPTION 'Medio de pago % no válido (efectivo, transferencia, cheque o echeq)', COALESCE(v_medio_txt, 'vacío');
    END IF;
    v_medio := v_medio_txt::forma_pago_egreso;
    BEGIN
      v_m_val := round((v_elem->>'monto')::numeric, 2);
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'El monto del medio % no es un número', v_cant;
    END;
    IF v_m_val IS NULL OR v_m_val <= 0 THEN
      RAISE EXCEPTION 'Cada medio tiene que tener un monto mayor a cero (medio %)', v_cant;
    END IF;
    v_es_cheque := v_medio IN ('cheque', 'echeq');
    v_num := NULL; v_sal := NULL; v_pag := NULL;
    IF v_es_cheque THEN
      v_num := NULLIF(trim(v_elem->>'numero'), '');
      IF v_num IS NULL THEN
        RAISE EXCEPTION 'El número de cheque es obligatorio';
      END IF;
      v_pag := NULLIF(v_elem->>'fecha_pago', '')::date;
      IF v_pag IS NULL THEN
        RAISE EXCEPTION 'La fecha de pago del cheque % es obligatoria', v_num;
      END IF;
      v_sal := COALESCE(NULLIF(v_elem->>'fecha_salida', '')::date, v_fecha);
      IF v_pag < v_sal THEN
        RAISE EXCEPTION 'El cheque % se cobra antes de la fecha de salida', v_num;
      END IF;
      IF COALESCE((v_elem->>'propio')::boolean, true) = false THEN
        RAISE EXCEPTION 'Por ahora solo se registran cheques propios';
      END IF;
    END IF;
    v_m_medio := array_append(v_m_medio, v_medio);
    v_m_monto := array_append(v_m_monto, v_m_val);
    v_m_numero := array_append(v_m_numero, v_num);
    v_m_banco := array_append(v_m_banco, CASE WHEN v_es_cheque THEN NULLIF(trim(v_elem->>'banco'), '') END);
    v_m_salida := array_append(v_m_salida, v_sal);
    v_m_pago := array_append(v_m_pago, v_pag);
    v_monto := v_monto + v_m_val;
  END LOOP;

  IF p_monto IS NOT NULL AND round(p_monto, 2) <> v_monto THEN
    RAISE EXCEPTION 'La suma de los medios (%) no coincide con el total del pago (%)', v_monto, round(p_monto, 2);
  END IF;

  SELECT array_agg(DISTINCT x) INTO v_factura_ids FROM unnest(p_factura_ids) AS x WHERE x IS NOT NULL;
  SELECT array_agg(DISTINCT x) INTO v_nc_ids FROM unnest(p_nota_credito_ids) AS x WHERE x IS NOT NULL;

  IF v_monto = 0 AND v_nc_ids IS NULL THEN
    RAISE EXCEPTION 'Ingresá un monto mayor a cero o elegí una nota de crédito para aplicar';
  END IF;

  -- Serializa los pagos de un mismo proveedor: dos cajas pagando la misma factura a la vez no
  -- pueden leer el mismo saldo y sobrepagarla.
  PERFORM 1 FROM proveedores WHERE id = p_proveedor_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Proveedor no encontrado';
  END IF;

  -- ── Validación de comprobantes a pagar (igual que v2) ──
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

  -- ── Validación de notas de crédito (igual que v2) ──
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

  -- ── Paso 2: repartir el pago (suma de los medios), más viejos primero. Lo que sobra queda a cuenta ──
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
  -- Sin medios (solo NC) la cabecera queda en efectivo, como hacía v2 con monto 0.
  v_forma_cabecera := CASE WHEN v_cant = 0 THEN 'efectivo'::forma_pago_egreso
                           WHEN v_cant = 1 THEN v_m_medio[1]
                           ELSE 'mixto'::forma_pago_egreso END;

  INSERT INTO pagos_proveedor (
    proveedor_id, factura_compra_id, monto, forma_pago, usuario_id, fecha, nota,
    cheque_numero, cheque_fecha_salida, cheque_fecha_vencimiento
  )
  VALUES (
    p_proveedor_id,
    -- deprecated: solo si todo el pago cancela una única factura (compatibilidad con las pantallas actuales)
    CASE WHEN cardinality(v_pago_docs) = 1 AND v_rest = 0 THEN v_pago_docs[1] END,
    v_monto, v_forma_cabecera, auth.uid(), v_fecha, v_nota,
    -- Con un solo cheque, también en la cabecera: lo leen las apps que no conocen los medios.
    CASE WHEN v_cant = 1 AND v_m_medio[1] IN ('cheque', 'echeq') THEN v_m_numero[1] END,
    CASE WHEN v_cant = 1 AND v_m_medio[1] IN ('cheque', 'echeq') THEN v_m_salida[1] END,
    CASE WHEN v_cant = 1 AND v_m_medio[1] IN ('cheque', 'echeq') THEN v_m_pago[1] END
  )
  RETURNING id INTO v_pago_id;

  INSERT INTO pagos_proveedor_aplicaciones
    (factura_compra_id, monto, pago_proveedor_id, nota_credito_id, operacion_id, usuario_id)
  SELECT t.doc, t.monto, CASE WHEN t.nc IS NULL THEN v_pago_id END, t.nc, v_pago_id, auth.uid()
  FROM unnest(v_plan_doc, v_plan_monto, v_plan_nc) AS t(doc, monto, nc);

  FOR i IN 1 .. v_cant LOOP
    INSERT INTO pagos_proveedor_medios (pago_proveedor_id, medio, monto, numero, banco, fecha_salida, fecha_pago, orden)
    VALUES (v_pago_id, v_m_medio[i], v_m_monto[i], v_m_numero[i], v_m_banco[i], v_m_salida[i], v_m_pago[i], i)
    RETURNING id INTO v_medio_id;
    v_m_ids := array_append(v_m_ids, v_medio_id);

    -- Con varios medios, el egreso dice cuál es (Egresos y el cierre lo listan por renglón).
    v_desc := 'Pago a proveedor' || COALESCE(' — ' || v_nota, '') ||
      CASE WHEN v_cant > 1 THEN ' (' ||
        CASE v_m_medio[i] WHEN 'efectivo' THEN 'efectivo' WHEN 'transferencia' THEN 'transferencia'
          WHEN 'cheque' THEN 'cheque N° ' || v_m_numero[i] ELSE 'echeq N° ' || v_m_numero[i] END || ')'
      ELSE '' END;

    INSERT INTO egresos (cierre_caja_id, origen, categoria, monto, descripcion, forma_pago, usuario_id, fecha,
                         pago_proveedor_id, pago_proveedor_medio_id)
    VALUES (p_cierre_caja_id, p_origen, 'pago_proveedor', v_m_monto[i], v_desc,
            v_m_medio[i], auth.uid(), v_fecha, v_pago_id, v_medio_id);

    -- Cheque y echeq no impactan cuentas (no son plata líquida al registrarse — docs/15).
    -- docs/58: el efectivo de Local (origen 'turno') sale del cajón y queda en el Cierre Z; la cuenta
    -- Efectivo (Caja Gestión) solo baja con lo que paga Gestión. La transferencia sale del banco igual.
    IF v_m_medio[i] = 'transferencia' OR (v_m_medio[i] = 'efectivo' AND p_origen = 'general') THEN
      INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
      SELECT cuenta_id, 'pago_proveedor', -abs(v_m_monto[i]), v_pago_id, auth.uid()
      FROM cuenta_forma_pago WHERE forma_pago = v_m_medio[i]::text::forma_pago_venta;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'pago_id', v_pago_id,
    'monto', v_monto,
    'aplicado_pago', v_monto - v_rest,
    'aplicado_nota_credito', v_total_nc,
    'a_cuenta', v_rest,
    'medios', to_jsonb(v_m_ids),
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

REVOKE ALL ON FUNCTION public.registrar_pago_proveedor_v3(uuid, jsonb, uuid[], uuid[], origen_egreso, uuid, date, text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_pago_proveedor_v3(uuid, jsonb, uuid[], uuid[], origen_egreso, uuid, date, text, numeric) TO authenticated, service_role;

-- ─── 5. registrar_pago_proveedor_v2: 1 medio sobre v3 ────────────────────────────────────────
-- Misma firma y mismas validaciones (y mensajes) que antes; lo usan Local v0.9.0, v1 y el contado.
CREATE OR REPLACE FUNCTION public.registrar_pago_proveedor_v2(
  p_proveedor_id uuid, p_monto numeric, p_forma_pago forma_pago_egreso,
  p_factura_ids uuid[] DEFAULT NULL::uuid[], p_nota_credito_ids uuid[] DEFAULT NULL::uuid[],
  p_origen origen_egreso DEFAULT 'turno'::origen_egreso, p_cierre_caja_id uuid DEFAULT NULL::uuid,
  p_fecha date DEFAULT NULL::date, p_nota text DEFAULT NULL::text,
  p_cheque_numero text DEFAULT NULL::text, p_cheque_fecha_salida date DEFAULT NULL::date,
  p_cheque_fecha_vencimiento date DEFAULT NULL::date
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_monto NUMERIC := round(p_monto, 2);
  v_es_cheque BOOLEAN := p_forma_pago IN ('cheque', 'echeq');
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF p_forma_pago IS NULL THEN
    RAISE EXCEPTION 'La forma de pago es obligatoria';
  END IF;
  IF p_forma_pago = 'mixto' THEN
    RAISE EXCEPTION 'Un pago con varios medios se registra con registrar_pago_proveedor_v3';
  END IF;
  IF v_monto IS NULL OR v_monto < 0 THEN
    RAISE EXCEPTION 'El monto no puede ser negativo';
  END IF;
  IF v_monto = 0 AND v_es_cheque THEN
    RAISE EXCEPTION 'Un pago sin monto (solo aplicación de notas de crédito) no puede ser con cheque';
  END IF;
  IF v_es_cheque AND v_monto > 0 THEN
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

  RETURN registrar_pago_proveedor_v3(
    p_proveedor_id => p_proveedor_id,
    p_medios => CASE WHEN v_monto > 0 THEN jsonb_build_array(jsonb_build_object(
                  'medio', p_forma_pago, 'monto', v_monto,
                  'numero', CASE WHEN v_es_cheque THEN p_cheque_numero END,
                  'fecha_salida', CASE WHEN v_es_cheque THEN p_cheque_fecha_salida END,
                  'fecha_pago', CASE WHEN v_es_cheque THEN p_cheque_fecha_vencimiento END))
                ELSE '[]'::jsonb END,
    p_factura_ids => p_factura_ids,
    p_nota_credito_ids => p_nota_credito_ids,
    p_origen => p_origen,
    p_cierre_caja_id => p_cierre_caja_id,
    p_fecha => p_fecha,
    p_nota => p_nota,
    p_monto => v_monto);
END;
$function$;

-- ─── 6. revertir_movimiento: todos los egresos y medios del pago ─────────────────────────────
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
  v_medio pagos_proveedor_medios%ROWTYPE;  -- docs/65
  v_medio_rev_id UUID;
  v_mapa_medios JSONB := '{}'::jsonb;  -- medio original → medio espejo
  v_egresos_revertidos INT := 0;
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

    -- docs/65: cada medio del pago tiene su espejo negativo en la reversión (los cheques salen de
    -- la cartera vigente).
    FOR v_medio IN
      SELECT * FROM pagos_proveedor_medios WHERE pago_proveedor_id = v_pago_orig_id ORDER BY orden
    LOOP
      INSERT INTO pagos_proveedor_medios (pago_proveedor_id, medio, monto, numero, banco, fecha_salida, fecha_pago, propio, orden, revierte_medio_id)
      VALUES (v_pago_rev_id, v_medio.medio, -1 * v_medio.monto, v_medio.numero, v_medio.banco, v_medio.fecha_salida,
              v_medio.fecha_pago, v_medio.propio, v_medio.orden, v_medio.id)
      RETURNING id INTO v_medio_rev_id;
      v_mapa_medios := v_mapa_medios || jsonb_build_object(v_medio.id::text, v_medio_rev_id);
    END LOOP;

    IF v_monto <> 0 THEN
      -- docs/65: todos los egresos del pago (uno por medio), con su origen real (turno = caja de
      -- Local, general = Gestión). Antes se tomaba uno solo (LIMIT 1).
      FOR v_egreso IN
        SELECT * FROM egresos
        WHERE pago_proveedor_id = v_pago_orig_id AND revierte_egreso_id IS NULL
        ORDER BY created_at, id
      LOOP
        INSERT INTO egresos (origen, categoria, monto, descripcion, forma_pago, usuario_id, revierte_egreso_id,
                             pago_proveedor_id, pago_proveedor_medio_id)
        VALUES (v_egreso.origen, 'pago_proveedor', -1 * v_egreso.monto, 'Reversión de pago a proveedor',
                v_egreso.forma_pago, auth.uid(), v_egreso.id, v_pago_rev_id,
                (v_mapa_medios->>(v_egreso.pago_proveedor_medio_id::text))::UUID);
        v_egresos_revertidos := v_egresos_revertidos + 1;
      END LOOP;

      IF v_egresos_revertidos = 0 THEN
        -- Pago anterior a docs/31 sin egreso vinculado (el backfill vinculó todos los que había).
        INSERT INTO egresos (origen, categoria, monto, descripcion, forma_pago, usuario_id, pago_proveedor_id)
        VALUES ('turno', 'pago_proveedor', -1 * v_monto, 'Reversión de pago a proveedor',
                (v_row->>'forma_pago')::forma_pago_egreso, auth.uid(), v_pago_rev_id);
      END IF;

      -- docs/58: espejo de lo que el pago movió en cuentas (neto de correcciones). Un pago en
      -- efectivo de Local no movió la cuenta Efectivo, así que su reversión tampoco la mueve.
      -- Con varios medios suma todos los movimientos del pago, por cuenta.
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

-- ─── 7. Vista cartera_cheques_emitidos ───────────────────────────────────────────────────────
-- Un renglón por cheque/eCheq. Vigente = ni es la fila espejo de una reversión ni fue revertido.
-- La suma de `monto` de todas las filas da lo vigente (las reversiones restan).
DROP VIEW IF EXISTS public.cartera_cheques_emitidos;
CREATE VIEW public.cartera_cheques_emitidos WITH (security_invoker = true) AS
SELECT m.id,
       m.pago_proveedor_id,
       pp.proveedor_id,
       pr.razon_social AS proveedor,
       m.medio,
       m.monto,
       m.numero,
       m.banco,
       m.fecha_salida,
       m.fecha_pago,
       m.propio,
       pp.fecha AS fecha_pago_proveedor,
       m.revierte_medio_id IS NOT NULL AS es_reversion,
       EXISTS (SELECT 1 FROM public.pagos_proveedor_medios r WHERE r.revierte_medio_id = m.id) AS revertido
FROM public.pagos_proveedor_medios m
JOIN public.pagos_proveedor pp ON pp.id = m.pago_proveedor_id
JOIN public.proveedores pr ON pr.id = pp.proveedor_id
WHERE m.medio IN ('cheque', 'echeq');

REVOKE ALL ON public.cartera_cheques_emitidos FROM anon;
GRANT SELECT ON public.cartera_cheques_emitidos TO authenticated, service_role;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (solo lectura)
-- ════════════════════════════════════════════════════════════════════════════════════════════
SELECT json_build_object(
  'mixto_en_enum', EXISTS (SELECT 1 FROM pg_enum WHERE enumtypid = 'forma_pago_egreso'::regtype AND enumlabel = 'mixto'),
  'rls_medios', (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.pagos_proveedor_medios'::regclass),
  'policies_medios', (SELECT string_agg(policyname || ':' || cmd, ', ') FROM pg_policies WHERE tablename = 'pagos_proveedor_medios'),
  'vista_invoker', (SELECT reloptions::text FROM pg_class WHERE oid = 'public.cartera_cheques_emitidos'::regclass),
  'v3_sin_anon', NOT has_function_privilege('anon', 'public.registrar_pago_proveedor_v3(uuid,jsonb,uuid[],uuid[],origen_egreso,uuid,date,text,numeric)', 'EXECUTE'),
  'pagos_sin_medios', (SELECT count(*) FROM pagos_proveedor p WHERE p.monto <> 0
                         AND NOT EXISTS (SELECT 1 FROM pagos_proveedor_medios m WHERE m.pago_proveedor_id = p.id)),
  'pagos_suma_distinta', (SELECT count(*) FROM pagos_proveedor p
                            WHERE p.monto <> COALESCE((SELECT sum(m.monto) FROM pagos_proveedor_medios m WHERE m.pago_proveedor_id = p.id), 0))
) AS verificacion;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (BEGIN … ROLLBACK). Como admin, contra un proveedor real y sus facturas reales
-- dentro de la transacción. Siempre aborta.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

SELECT set_config('request.jwt.claims',
  json_build_object('sub', (SELECT id FROM perfiles WHERE rol = 'admin' AND activo ORDER BY created_at LIMIT 1), 'role', 'authenticated')::text,
  true);

DO $$
DECLARE
  v_ok int := 0;
  v_total int := 0;
  v_fallas text := '';
  v_prov uuid;
  v_saldo_antes numeric;
  v_saldo_despues numeric;
  v_res jsonb;
  v_pago uuid;
  v_n int;
  v_x numeric;
  v_aud uuid;
  v_ef uuid := (SELECT cuenta_id FROM cuenta_forma_pago WHERE forma_pago = 'efectivo');
  v_tr uuid := (SELECT cuenta_id FROM cuenta_forma_pago WHERE forma_pago = 'transferencia');
  v_hoy date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_seis jsonb;
  v_diez jsonb := '[]'::jsonb;
  v_err text;
BEGIN
  -- Proveedor con más deuda pendiente (para que el pago se aplique a facturas reales).
  SELECT fc.proveedor_id INTO v_prov
  FROM facturas_compra fc
  WHERE NOT fc.anulada AND fc.tipo_comprobante <> 'nota_credito'
  GROUP BY fc.proveedor_id
  ORDER BY sum(fc.total) - COALESCE(sum((SELECT sum(a.monto) FROM pagos_proveedor_aplicaciones a WHERE a.factura_compra_id = fc.id AND a.revertida_at IS NULL)), 0) DESC
  LIMIT 1;
  SELECT COALESCE(sum(fc.total - COALESCE((SELECT sum(a.monto) FROM pagos_proveedor_aplicaciones a WHERE a.factura_compra_id = fc.id AND a.revertida_at IS NULL), 0)), 0)
  INTO v_saldo_antes
  FROM facturas_compra fc WHERE fc.proveedor_id = v_prov AND NOT fc.anulada AND fc.tipo_comprobante <> 'nota_credito';

  -- 1. Pago de 6 medios desde Gestión: 1 eCheq + 3 cheques 30/60/90 + transferencia + efectivo.
  v_seis := jsonb_build_array(
    jsonb_build_object('medio', 'echeq', 'monto', 1000, 'numero', 'E-1', 'banco', 'Galicia', 'fecha_pago', v_hoy + 15),
    jsonb_build_object('medio', 'cheque', 'monto', 1000, 'numero', 'C-30', 'banco', 'Nación', 'fecha_pago', v_hoy + 30),
    jsonb_build_object('medio', 'cheque', 'monto', 1000, 'numero', 'C-60', 'banco', 'Nación', 'fecha_pago', v_hoy + 60),
    jsonb_build_object('medio', 'cheque', 'monto', 1000, 'numero', 'C-90', 'banco', 'Nación', 'fecha_pago', v_hoy + 90),
    jsonb_build_object('medio', 'transferencia', 'monto', 2500.50),
    jsonb_build_object('medio', 'efectivo', 'monto', 499.50));
  v_res := registrar_pago_proveedor_v3(v_prov, v_seis, p_origen => 'general', p_nota => 'prueba 65', p_monto => 7000);
  v_pago := (v_res->>'pago_id')::uuid;

  v_total := v_total + 1;
  IF (SELECT forma_pago FROM pagos_proveedor WHERE id = v_pago) = 'mixto'
     AND (SELECT monto FROM pagos_proveedor WHERE id = v_pago) = 7000
     AND (SELECT count(*) FROM pagos_proveedor_medios WHERE pago_proveedor_id = v_pago) = 6
     AND (SELECT cheque_numero FROM pagos_proveedor WHERE id = v_pago) IS NULL THEN v_ok := v_ok + 1;
  ELSE v_fallas := v_fallas || ' [1 cabecera/medios]'; END IF;

  v_total := v_total + 1;
  IF (SELECT count(*) FROM egresos WHERE pago_proveedor_id = v_pago AND pago_proveedor_medio_id IS NOT NULL AND origen = 'general') = 6
     AND (SELECT sum(monto) FROM egresos WHERE pago_proveedor_id = v_pago) = 7000
     AND (SELECT sum(monto) FROM egresos WHERE pago_proveedor_id = v_pago AND forma_pago = 'efectivo') = 499.50 THEN v_ok := v_ok + 1;
  ELSE v_fallas := v_fallas || ' [2 egresos por medio]'; END IF;

  -- 3. Cuentas: efectivo de Gestión baja Efectivo, transferencia baja su cuenta, cheques nada.
  v_total := v_total + 1;
  IF (SELECT sum(monto) FROM movimientos_cuenta WHERE referencia_id = v_pago AND cuenta_id = v_ef) = -499.50
     AND (SELECT sum(monto) FROM movimientos_cuenta WHERE referencia_id = v_pago AND cuenta_id = v_tr) = -2500.50
     AND (SELECT count(*) FROM movimientos_cuenta WHERE referencia_id = v_pago) = 2 THEN v_ok := v_ok + 1;
  ELSE v_fallas := v_fallas || ' [3 cuentas]'; END IF;

  -- 4. Cartera: 4 cheques vigentes de este pago, con vencimiento.
  v_total := v_total + 1;
  IF (SELECT count(*) FROM cartera_cheques_emitidos WHERE pago_proveedor_id = v_pago AND NOT revertido AND NOT es_reversion AND fecha_pago IS NOT NULL) = 4
     AND (SELECT sum(monto) FROM cartera_cheques_emitidos WHERE pago_proveedor_id = v_pago) = 4000 THEN v_ok := v_ok + 1;
  ELSE v_fallas := v_fallas || ' [4 cartera]'; END IF;

  -- 5. Aplicación igual que hoy: lo aplicado + a cuenta = total; aplicado = min(total, saldo).
  v_total := v_total + 1;
  IF (v_res->>'aplicado_pago')::numeric + (v_res->>'a_cuenta')::numeric = 7000
     AND (v_res->>'aplicado_pago')::numeric = LEAST(7000, v_saldo_antes)
     AND (SELECT COALESCE(sum(monto), 0) FROM pagos_proveedor_aplicaciones WHERE operacion_id = v_pago) = LEAST(7000, v_saldo_antes) THEN v_ok := v_ok + 1;
  ELSE v_fallas := v_fallas || format(' [5 aplicación: %s, saldo %s]', v_res, v_saldo_antes); END IF;

  -- 6. Revertir el pago mixto desde Historial deshace todo.
  SELECT id INTO v_aud FROM auditoria WHERE tabla_afectada = 'pagos_proveedor' AND registro_id = v_pago AND accion = 'alta';
  PERFORM revertir_movimiento(v_aud);
  v_total := v_total + 1;
  IF (SELECT sum(e.monto) FROM egresos e JOIN pagos_proveedor p ON p.id = e.pago_proveedor_id WHERE p.id = v_pago OR p.revierte_pago_proveedor_id = v_pago) = 0
     AND (SELECT count(*) FROM egresos e JOIN pagos_proveedor p ON p.id = e.pago_proveedor_id WHERE p.revierte_pago_proveedor_id = v_pago AND e.pago_proveedor_medio_id IS NOT NULL) = 6
     AND (SELECT COALESCE(sum(monto), 0) FROM movimientos_cuenta WHERE referencia_id = v_pago) = 0
     AND NOT EXISTS (SELECT 1 FROM pagos_proveedor_aplicaciones WHERE operacion_id = v_pago AND revertida_at IS NULL)
     AND (SELECT count(*) FROM cartera_cheques_emitidos c WHERE c.pago_proveedor_id = v_pago AND NOT c.revertido) = 0
     AND (SELECT COALESCE(sum(c.monto), 0) FROM cartera_cheques_emitidos c JOIN pagos_proveedor p ON p.id = c.pago_proveedor_id WHERE p.id = v_pago OR p.revierte_pago_proveedor_id = v_pago) = 0
     AND (SELECT forma_pago FROM pagos_proveedor WHERE revierte_pago_proveedor_id = v_pago) = 'mixto' THEN v_ok := v_ok + 1;
  ELSE v_fallas := v_fallas || ' [6 reversión]'; END IF;

  -- 7. El saldo del proveedor vuelve a ser el de antes.
  SELECT COALESCE(sum(fc.total - COALESCE((SELECT sum(a.monto) FROM pagos_proveedor_aplicaciones a WHERE a.factura_compra_id = fc.id AND a.revertida_at IS NULL), 0)), 0)
  INTO v_saldo_despues
  FROM facturas_compra fc WHERE fc.proveedor_id = v_prov AND NOT fc.anulada AND fc.tipo_comprobante <> 'nota_credito';
  v_total := v_total + 1;
  IF v_saldo_despues = v_saldo_antes THEN v_ok := v_ok + 1; ELSE v_fallas := v_fallas || ' [7 saldo]'; END IF;

  -- 8. 10 medios (tipos repetidos) en un solo pago.
  FOR v_n IN 1 .. 10 LOOP
    v_diez := v_diez || jsonb_build_array(CASE WHEN v_n % 2 = 0
      THEN jsonb_build_object('medio', 'cheque', 'monto', 100, 'numero', 'D-' || v_n, 'fecha_pago', v_hoy + v_n * 10)
      ELSE jsonb_build_object('medio', 'transferencia', 'monto', 100) END);
  END LOOP;
  v_res := registrar_pago_proveedor_v3(v_prov, v_diez, p_origen => 'general');
  v_total := v_total + 1;
  IF (SELECT count(*) FROM pagos_proveedor_medios WHERE pago_proveedor_id = (v_res->>'pago_id')::uuid) = 10
     AND (v_res->>'monto')::numeric = 1000 THEN v_ok := v_ok + 1;
  ELSE v_fallas := v_fallas || ' [8 diez medios]'; END IF;

  -- 9. v2 (Local v0.9.0, egreso de caja): efectivo de turno → 1 medio, 1 egreso turno, SIN movimiento (docs/58).
  v_res := registrar_pago_proveedor_v2(v_prov, 300, 'efectivo', p_origen => 'turno');
  v_pago := (v_res->>'pago_id')::uuid;
  v_total := v_total + 1;
  IF (SELECT forma_pago FROM pagos_proveedor WHERE id = v_pago) = 'efectivo'
     AND (SELECT count(*) FROM pagos_proveedor_medios WHERE pago_proveedor_id = v_pago AND medio = 'efectivo' AND monto = 300) = 1
     AND (SELECT count(*) FROM egresos WHERE pago_proveedor_id = v_pago AND origen = 'turno' AND forma_pago = 'efectivo' AND monto = 300) = 1
     AND NOT EXISTS (SELECT 1 FROM movimientos_cuenta WHERE referencia_id = v_pago) THEN v_ok := v_ok + 1;
  ELSE v_fallas := v_fallas || ' [9 v2 efectivo turno]'; END IF;

  -- 10. v2 con cheque: cabecera con columnas cheque_* (apps viejas) + 1 medio cheque en la cartera.
  v_res := registrar_pago_proveedor_v2(v_prov, 800, 'cheque', p_origen => 'general',
             p_cheque_numero => 'V2-1', p_cheque_fecha_salida => v_hoy, p_cheque_fecha_vencimiento => v_hoy + 45);
  v_pago := (v_res->>'pago_id')::uuid;
  v_total := v_total + 1;
  IF (SELECT cheque_numero FROM pagos_proveedor WHERE id = v_pago) = 'V2-1'
     AND (SELECT cheque_fecha_vencimiento FROM pagos_proveedor WHERE id = v_pago) = v_hoy + 45
     AND (SELECT count(*) FROM cartera_cheques_emitidos WHERE pago_proveedor_id = v_pago AND numero = 'V2-1') = 1
     AND NOT EXISTS (SELECT 1 FROM movimientos_cuenta WHERE referencia_id = v_pago) THEN v_ok := v_ok + 1;
  ELSE v_fallas := v_fallas || ' [10 v2 cheque]'; END IF;

  -- 11. Validaciones: suma distinta del total, cheque sin número, sin fecha de pago, terceros, monto 0, mixto en v2.
  v_n := 0;
  BEGIN PERFORM registrar_pago_proveedor_v3(v_prov, '[{"medio":"efectivo","monto":100}]', p_origen => 'general', p_monto => 150);
  EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT; IF v_err LIKE 'La suma de los medios%' THEN v_n := v_n + 1; END IF; END;
  BEGIN PERFORM registrar_pago_proveedor_v3(v_prov, jsonb_build_array(jsonb_build_object('medio', 'cheque', 'monto', 100, 'fecha_pago', v_hoy)), p_origen => 'general');
  EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT; IF v_err = 'El número de cheque es obligatorio' THEN v_n := v_n + 1; END IF; END;
  BEGIN PERFORM registrar_pago_proveedor_v3(v_prov, '[{"medio":"echeq","monto":100,"numero":"X"}]', p_origen => 'general');
  EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT; IF v_err LIKE 'La fecha de pago del cheque%' THEN v_n := v_n + 1; END IF; END;
  BEGIN PERFORM registrar_pago_proveedor_v3(v_prov, jsonb_build_array(jsonb_build_object('medio', 'cheque', 'monto', 100, 'numero', 'T', 'fecha_pago', v_hoy, 'propio', false)), p_origen => 'general');
  EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT; IF v_err LIKE 'Por ahora solo%' THEN v_n := v_n + 1; END IF; END;
  BEGIN PERFORM registrar_pago_proveedor_v3(v_prov, '[{"medio":"transferencia","monto":0}]', p_origen => 'general');
  EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT; IF v_err LIKE 'Cada medio tiene que tener%' THEN v_n := v_n + 1; END IF; END;
  BEGIN PERFORM registrar_pago_proveedor_v3(v_prov, '[{"medio":"mixto","monto":10}]', p_origen => 'general');
  EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT; IF v_err LIKE 'Medio de pago mixto no válido%' THEN v_n := v_n + 1; END IF; END;
  BEGIN PERFORM registrar_pago_proveedor_v2(v_prov, 10, 'mixto', p_origen => 'general');
  EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT; IF v_err LIKE 'Un pago con varios medios%' THEN v_n := v_n + 1; END IF; END;
  v_total := v_total + 1;
  IF v_n = 7 THEN v_ok := v_ok + 1; ELSE v_fallas := v_fallas || format(' [11 validaciones %s/7]', v_n); END IF;

  -- 12. Backfill: todo pago con monto tiene medios que suman lo mismo.
  v_total := v_total + 1;
  IF NOT EXISTS (SELECT 1 FROM pagos_proveedor p
                 WHERE p.monto <> COALESCE((SELECT sum(m.monto) FROM pagos_proveedor_medios m WHERE m.pago_proveedor_id = p.id), 0)) THEN
    v_ok := v_ok + 1;
  ELSE v_fallas := v_fallas || ' [12 backfill]'; END IF;

  RAISE EXCEPTION 'RESULTADO: % de % ok%', v_ok, v_total, CASE WHEN v_fallas = '' THEN '' ELSE ' — FALLAS:' || v_fallas END;
END;
$$;

ROLLBACK;
