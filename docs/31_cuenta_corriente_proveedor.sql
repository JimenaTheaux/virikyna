-- 31 — Cuenta corriente de proveedores: imputaciones, notas de crédito, origen del pago
--
-- Contexto (relevado contra la base real el 2026-10-05, no solo contra docs/06):
--   - Un pago se aplicaba a UNA factura o a ninguna (`pagos_proveedor.factura_compra_id`), sin
--     validar monto, proveedor ni anulación.
--   - Las notas de crédito sumaban deuda: `proveedores_saldo` sumaba `total` de todo comprobante
--     no anulado, sin mirar el tipo, y `facturas_compra_saldo` las mostraba como "a pagar".
--   - Todo pago quedaba con origen='turno' (las apps no mandan p_origen), y `cerrar_caja` sumaba
--     TODOS los egresos del día sin filtrar origen: un pago en efectivo desde Gestión (o un sueldo
--     cargado en Egresos de Gestión) bajaba el efectivo esperado del Cierre de Caja de Local.
--   - `egresos` no tenía vínculo con el pago que lo generó: `revertir_movimiento` revertía el
--     egreso con origen 'turno' fijo.
--   - Sigue viva la sobrecarga vieja de 6 parámetros de registrar_pago_proveedor (pre docs/15).
--
-- Qué hace:
--   PARTE A (correr sola, primero): enum 'presupuesto'.
--   PARTE B (una transacción):
--     1. pagos_proveedor: + fecha, + nota. factura_compra_id queda DEPRECATED (no se borra).
--     2. egresos: + pago_proveedor_id (vínculo egreso ↔ pago) + backfill 1:1.
--     3. Tabla pagos_proveedor_aplicaciones + RLS + auditoría + migración de pagos existentes.
--     4. Vistas facturas_compra_saldo / proveedores_saldo: NC restan, estado calculado.
--     5. RPC registrar_pago_proveedor_v2 (imputación múltiple, NC, origen, fecha, nota).
--     6. registrar_pago_proveedor (las 2 sobrecargas) → delegan en v2. Local sigue sin cambios.
--     7. revertir_movimiento: revierte también las aplicaciones y respeta el origen del egreso.
--     8. anular_factura_compra / editar_factura_compra: miran aplicaciones vigentes.
--     9. cerrar_caja: solo egresos origen='turno'.
--   PARTE C: tests (BEGIN … ROLLBACK, no dejan nada).
--
-- Modelo de aplicación (una fila = "este monto cancela esta factura, y sale de X"):
--   - X es un pago (pago_proveedor_id) o una nota de crédito (nota_credito_id), nunca ambos.
--   - operacion_id = el pagos_proveedor de la operación que creó la fila. Para la fuente "pago" es
--     igual a pago_proveedor_id; para la fuente "NC" es la operación en la que se usó la NC. Es lo
--     que permite que revertir el pago (Historial) deshaga también las NC aplicadas en ese acto.
--   - Nunca se borra ni se pisa el monto: revertir = marcar revertida_at/revertida_por. Las vistas
--     solo cuentan filas con revertida_at IS NULL. (No se usan contra-asientos negativos porque
--     monto > 0 es una regla de la tabla.)
--   - Toda operación v2 crea una fila en pagos_proveedor, también si p_monto = 0 (solo aplica NC):
--     esa fila es la que aparece en el Historial y desde la que se revierte. Con monto 0 no hay
--     egreso ni movimiento de cuenta.
--
-- Saldo del proveedor (identidad que verifica el test 7):
--   saldo_actual = saldo_inicial
--                + Σ saldo_pendiente (comprobantes a pagar)
--                − Σ credito_disponible (NC)
--                − Σ (monto de pagos que no quedó aplicado a ningún comprobante = "a cuenta")

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — correr SOLA y antes que la parte B
-- (un valor nuevo de enum no se puede usar en la misma transacción que lo crea)
-- ════════════════════════════════════════════════════════════════════════════════════════════
ALTER TYPE tipo_comprobante_compra ADD VALUE IF NOT EXISTS 'presupuesto';

-- Presupuesto se comporta igual que remito sin tocar ninguna función: cargar_factura_compra
-- (docs/29) actualiza costo en todo tipo salvo nota_credito/nota_debito, suma stock, y acá abajo
-- cuenta como comprobante a pagar (todo lo que no es nota_credito).


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — una sola transacción
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- Los UPDATE de backfill y la migración de aplicaciones no son acciones de un usuario: no
-- generan filas en auditoria (mismo mecanismo que fn_auditoria_generica ya soporta).
SELECT set_config('virikyna.suppress_audit', 'true', true);

-- ============================================================
-- 1. pagos_proveedor — fecha y nota; factura_compra_id deprecated
-- ============================================================
ALTER TABLE pagos_proveedor ADD COLUMN IF NOT EXISTS fecha DATE;
ALTER TABLE pagos_proveedor ADD COLUMN IF NOT EXISTS nota TEXT;

UPDATE pagos_proveedor
SET fecha = (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
WHERE fecha IS NULL;

ALTER TABLE pagos_proveedor
  ALTER COLUMN fecha SET DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date),
  ALTER COLUMN fecha SET NOT NULL;

COMMENT ON COLUMN pagos_proveedor.factura_compra_id IS
  'DEPRECATED (docs/31): la imputación vive en pagos_proveedor_aplicaciones. Se sigue completando '
  'solo cuando todo el pago cancela una única factura, para que las pantallas actuales sigan '
  'mostrando el pago en el detalle de esa factura. No usar para calcular saldos.';

-- ============================================================
-- 2. egresos.pago_proveedor_id — qué pago generó este egreso
-- ============================================================
ALTER TABLE egresos ADD COLUMN IF NOT EXISTS pago_proveedor_id UUID REFERENCES pagos_proveedor(id);

-- Backfill: el pago y su egreso se insertan en la misma transacción del RPC, así que comparten
-- created_at (now() es el instante de la transacción). Solo se vinculan pares 1:1 inequívocos.
-- Relevado antes de escribir esto: 29 pagos, 29 egresos pago_proveedor, 29 pares únicos.
WITH pares AS (
  SELECT e.id AS egreso_id, pp.id AS pago_id,
         count(*) OVER (PARTITION BY e.id)  AS n_e,
         count(*) OVER (PARTITION BY pp.id) AS n_p
  FROM egresos e
  JOIN pagos_proveedor pp
    ON pp.created_at = e.created_at
   AND pp.monto = e.monto
   AND pp.forma_pago = e.forma_pago
   AND pp.usuario_id = e.usuario_id
  WHERE e.categoria = 'pago_proveedor'
    AND e.pago_proveedor_id IS NULL
    AND e.revierte_egreso_id IS NULL
    AND e.monto > 0
)
UPDATE egresos e
SET pago_proveedor_id = p.pago_id
FROM pares p
WHERE p.egreso_id = e.id AND p.n_e = 1 AND p.n_p = 1;

-- Un pago genera a lo sumo un egreso original (las reversiones llevan revierte_egreso_id).
CREATE UNIQUE INDEX IF NOT EXISTS ux_egresos_pago_proveedor
  ON egresos(pago_proveedor_id)
  WHERE pago_proveedor_id IS NOT NULL AND revierte_egreso_id IS NULL;

-- ============================================================
-- 3. pagos_proveedor_aplicaciones
-- ============================================================
CREATE TABLE IF NOT EXISTS pagos_proveedor_aplicaciones (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factura_compra_id UUID NOT NULL REFERENCES facturas_compra(id),   -- comprobante que se cancela
  monto NUMERIC(12,2) NOT NULL CHECK (monto > 0),
  pago_proveedor_id UUID REFERENCES pagos_proveedor(id),            -- fuente: plata de un pago
  nota_credito_id UUID REFERENCES facturas_compra(id),              -- fuente: crédito de una NC
  operacion_id UUID NOT NULL REFERENCES pagos_proveedor(id),        -- operación que creó la fila
  usuario_id UUID NOT NULL REFERENCES perfiles(id),
  revertida_at TIMESTAMPTZ,                                         -- NULL = vigente
  revertida_por UUID REFERENCES perfiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_aplicacion_una_fuente CHECK ((pago_proveedor_id IS NULL) <> (nota_credito_id IS NULL)),
  CONSTRAINT chk_aplicacion_nc_distinta CHECK (nota_credito_id IS NULL OR nota_credito_id <> factura_compra_id)
);

CREATE INDEX IF NOT EXISTS idx_ppa_factura      ON pagos_proveedor_aplicaciones(factura_compra_id);
CREATE INDEX IF NOT EXISTS idx_ppa_pago         ON pagos_proveedor_aplicaciones(pago_proveedor_id);
CREATE INDEX IF NOT EXISTS idx_ppa_nota_credito ON pagos_proveedor_aplicaciones(nota_credito_id);
CREATE INDEX IF NOT EXISTS idx_ppa_operacion    ON pagos_proveedor_aplicaciones(operacion_id);

-- RLS: igual que pagos_proveedor (policy "pagos_proveedor_todos": cualquier perfil activo).
ALTER TABLE pagos_proveedor_aplicaciones ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "pagos_proveedor_aplicaciones_todos" ON pagos_proveedor_aplicaciones;
CREATE POLICY "pagos_proveedor_aplicaciones_todos" ON pagos_proveedor_aplicaciones FOR ALL USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
);

-- Auditoría universal (docs/06 sección 6): alta al aplicar, edicion al marcar revertida.
DROP TRIGGER IF EXISTS trg_auditoria_pagos_proveedor_aplicaciones ON pagos_proveedor_aplicaciones;
CREATE TRIGGER trg_auditoria_pagos_proveedor_aplicaciones AFTER INSERT OR UPDATE ON pagos_proveedor_aplicaciones
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_generica();

-- Migración: cada pago existente con factura_compra_id → una aplicación por el monto completo.
-- Si el pago fue revertido (fila con revierte_pago_proveedor_id), la aplicación nace revertida.
-- Idempotente. Relevado: 23 pagos con factura, 0 reversiones, 0 sobre anuladas, 0 cruzados
-- de proveedor, 0 facturas sobrepagadas.
INSERT INTO pagos_proveedor_aplicaciones
  (factura_compra_id, monto, pago_proveedor_id, operacion_id, usuario_id, created_at, revertida_at, revertida_por)
SELECT pp.factura_compra_id, pp.monto, pp.id, pp.id, pp.usuario_id, pp.created_at, rev.created_at, rev.usuario_id
FROM pagos_proveedor pp
LEFT JOIN LATERAL (
  SELECT r.created_at, r.usuario_id
  FROM pagos_proveedor r
  WHERE r.revierte_pago_proveedor_id = pp.id
  ORDER BY r.created_at
  LIMIT 1
) rev ON true
WHERE pp.factura_compra_id IS NOT NULL
  AND pp.monto > 0
  AND pp.revierte_pago_proveedor_id IS NULL
  AND NOT EXISTS (SELECT 1 FROM pagos_proveedor_aplicaciones a WHERE a.pago_proveedor_id = pp.id);

-- ============================================================
-- 4. Vistas de saldo
-- CREATE OR REPLACE sin DROP: mismas columnas, mismo orden (verificado con pg_get_viewdef) y las
-- nuevas al final. Ninguna vista ni función depende de estas dos (verificado en pg_depend).
-- ============================================================
CREATE OR REPLACE VIEW facturas_compra_saldo AS
SELECT
  fc.id,
  fc.proveedor_id,
  fc.tipo_comprobante,
  fc.letra,
  fc.punto_venta,
  fc.numero_comprobante,
  fc.fecha_comprobante,
  fc.fecha_fiscal,
  fc.forma_pago,
  fc.total_sin_iva,
  fc.iva,
  fc.total,
  fc.usuario_id,
  fc.created_at,
  fc.anulada,
  -- total_pagado: se mantiene por compatibilidad con las pantallas actuales = total_aplicado.
  x.aplicado AS total_pagado,
  -- saldo_pendiente: lo que falta pagar. 0 en NC (no se pagan, se aplican) y en anuladas.
  CASE WHEN fc.anulada OR fc.tipo_comprobante = 'nota_credito' THEN 0
       ELSE fc.total - x.aplicado END AS saldo_pendiente,
  -- Comprobante a pagar: lo cancelado (pagos + NC). NC: lo que ya se usó de su crédito.
  x.aplicado AS total_aplicado,
  CASE WHEN fc.tipo_comprobante = 'nota_credito' AND NOT fc.anulada
       THEN fc.total - x.aplicado ELSE 0 END AS credito_disponible,
  -- anulada | pendiente | parcial | pagada. En una NC: pendiente = sin usar, pagada = agotada.
  CASE WHEN fc.anulada THEN 'anulada'
       WHEN fc.total - x.aplicado <= 0 THEN 'pagada'
       WHEN x.aplicado > 0 THEN 'parcial'
       ELSE 'pendiente' END AS estado
FROM facturas_compra fc
CROSS JOIN LATERAL (
  SELECT CASE WHEN fc.tipo_comprobante = 'nota_credito'
    THEN (SELECT COALESCE(SUM(a.monto), 0) FROM pagos_proveedor_aplicaciones a
          WHERE a.nota_credito_id = fc.id AND a.revertida_at IS NULL)
    ELSE (SELECT COALESCE(SUM(a.monto), 0) FROM pagos_proveedor_aplicaciones a
          WHERE a.factura_compra_id = fc.id AND a.revertida_at IS NULL)
  END AS aplicado
) x;

CREATE OR REPLACE VIEW proveedores_saldo AS
SELECT
  p.id,
  p.razon_social,
  p.cuit,
  p.direccion,
  p.telefono,
  p.mail,
  p.contacto,
  p.margen_1_default,
  p.margen_2_default,
  p.saldo_inicial,
  p.created_at,
  p.saldo_inicial
    + COALESCE(facturado.total_facturado, 0)
    - COALESCE(pagado.total_pagado, 0) AS saldo_actual
FROM proveedores p
LEFT JOIN (
  -- Nota de crédito resta. Todo otro tipo (factura, remito, cupón, presupuesto, ND) suma.
  SELECT proveedor_id,
         SUM(CASE WHEN tipo_comprobante = 'nota_credito' THEN -total ELSE total END) AS total_facturado
  FROM facturas_compra WHERE anulada = false GROUP BY proveedor_id
) facturado ON facturado.proveedor_id = p.id
LEFT JOIN (
  SELECT proveedor_id, SUM(monto) AS total_pagado
  FROM pagos_proveedor GROUP BY proveedor_id
) pagado ON pagado.proveedor_id = p.id;

-- ============================================================
-- 5. registrar_pago_proveedor_v2
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
  v_restante NUMERIC;
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

  -- ── Con selección: el pago no puede superar lo que queda de esos comprobantes ──
  SELECT COALESCE(SUM(s), 0) INTO v_restante FROM unnest(v_doc_saldos) AS s;
  IF v_factura_ids IS NOT NULL AND v_monto > v_restante THEN
    RAISE EXCEPTION 'El monto a pagar ($ %) supera el saldo de los comprobantes elegidos ($ %)',
      to_char(v_monto, 'FM999G999G990D00'), to_char(v_restante, 'FM999G999G990D00');
  END IF;

  -- ── Paso 2: repartir el pago, más viejos primero. Sin selección, el sobrante queda a cuenta ──
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

-- ============================================================
-- 6. registrar_pago_proveedor — las dos sobrecargas vivas delegan en v2.
-- Firma y retorno (UUID) intactos: Local y Gestión siguen llamando igual.
-- Cambios de comportamiento (vienen de v2, a propósito):
--   - Con factura: error si está anulada, si es de otro proveedor, si es NC, o si el monto
--     supera su saldo.
--   - Sin factura ("a cuenta general"): ahora se aplica a las pendientes más viejas; solo el
--     sobrante queda a cuenta.
-- ============================================================
CREATE OR REPLACE FUNCTION registrar_pago_proveedor(
  p_proveedor_id UUID,
  p_factura_compra_id UUID,       -- NULL = sin factura puntual (se aplica a las pendientes)
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
  v_res JSONB;
BEGIN
  IF p_factura_compra_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM facturas_compra WHERE id = p_factura_compra_id AND anulada) THEN
    RAISE EXCEPTION 'Esta factura está anulada, no se le registran pagos';
  END IF;

  v_res := registrar_pago_proveedor_v2(
    p_proveedor_id := p_proveedor_id,
    p_monto := p_monto,
    p_forma_pago := p_forma_pago,
    p_factura_ids := CASE WHEN p_factura_compra_id IS NULL THEN NULL ELSE ARRAY[p_factura_compra_id] END,
    p_nota_credito_ids := NULL,
    p_origen := p_origen,
    p_cierre_caja_id := p_cierre_caja_id,
    p_fecha := NULL,
    p_nota := NULL,
    p_cheque_numero := p_cheque_numero,
    p_cheque_fecha_salida := p_cheque_fecha_salida,
    p_cheque_fecha_vencimiento := p_cheque_fecha_vencimiento
  );
  RETURN (v_res->>'pago_id')::UUID;
END;
$$;

-- Sobrecarga vieja (pre docs/15, sin campos de cheque). Ninguna app la llama, pero sigue
-- expuesta por PostgREST: se redirige a v2 en vez de dejar un camino que saltee validaciones.
CREATE OR REPLACE FUNCTION registrar_pago_proveedor(
  p_proveedor_id UUID,
  p_factura_compra_id UUID,
  p_monto NUMERIC,
  p_forma_pago forma_pago_egreso,
  p_origen origen_egreso DEFAULT 'turno',
  p_cierre_caja_id UUID DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_res JSONB;
BEGIN
  IF p_factura_compra_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM facturas_compra WHERE id = p_factura_compra_id AND anulada) THEN
    RAISE EXCEPTION 'Esta factura está anulada, no se le registran pagos';
  END IF;

  v_res := registrar_pago_proveedor_v2(
    p_proveedor_id := p_proveedor_id,
    p_monto := p_monto,
    p_forma_pago := p_forma_pago,
    p_factura_ids := CASE WHEN p_factura_compra_id IS NULL THEN NULL ELSE ARRAY[p_factura_compra_id] END,
    p_origen := p_origen,
    p_cierre_caja_id := p_cierre_caja_id
  );
  RETURN (v_res->>'pago_id')::UUID;
END;
$$;

-- ============================================================
-- 7. revertir_movimiento — cuerpo vigente (pg_get_functiondef, 2026-10-05) con cambios SOLO en
-- la rama pagos_proveedor:
--   - no se revierte una reversión (antes generaba un pago positivo "de vuelta" sin aplicaciones);
--   - el egreso se revierte con el MISMO origen del original (vía egresos.pago_proveedor_id),
--     ya no con 'turno' fijo; fallback 'turno' solo para egresos sin vínculo;
--   - con monto 0 (operación solo de NC) no hay egreso ni movimiento que revertir;
--   - marca revertidas todas las aplicaciones de la operación (pago y NC) → vuelven a pendiente.
-- ============================================================
CREATE OR REPLACE FUNCTION revertir_movimiento(p_auditoria_id UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_auditoria auditoria%ROWTYPE;
  v_row JSONB;
  v_pago_orig_id UUID;
  v_pago_rev_id UUID;
  v_monto NUMERIC;
  v_egreso egresos%ROWTYPE;
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

      -- Y si era efectivo/transferencia, había impactado en movimientos_cuenta — se revierte igual.
      IF (v_row->>'forma_pago') IN ('efectivo', 'transferencia') THEN
        INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
        SELECT cuenta_id, 'pago_proveedor', abs(v_monto), v_pago_orig_id, auth.uid()
        FROM cuenta_forma_pago WHERE forma_pago = (v_row->>'forma_pago')::forma_pago_venta;
      END IF;
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
$$;

-- ============================================================
-- 8a. anular_factura_compra — cuerpo vigente; el chequeo de pagos pasa a aplicaciones vigentes
-- (como comprobante pagado o como NC usada). Un pago ya revertido ya no bloquea la anulación.
-- ============================================================
CREATE OR REPLACE FUNCTION anular_factura_compra(p_factura_id UUID, p_motivo TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_item RECORD;
  v_ya_anulada BOOLEAN;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede anular una factura de compra';
  END IF;
  IF p_motivo IS NULL OR trim(p_motivo) = '' THEN
    RAISE EXCEPTION 'El motivo es obligatorio para anular una factura de compra';
  END IF;

  SELECT anulada INTO v_ya_anulada FROM facturas_compra WHERE id = p_factura_id;
  IF v_ya_anulada IS NULL THEN
    RAISE EXCEPTION 'Factura de compra no encontrada';
  END IF;
  IF v_ya_anulada THEN
    RAISE EXCEPTION 'Esta factura ya estaba anulada';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pagos_proveedor_aplicaciones
    WHERE (factura_compra_id = p_factura_id OR nota_credito_id = p_factura_id)
      AND revertida_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Este comprobante tiene pagos o notas de crédito aplicadas — revertí esos pagos antes de anularlo';
  END IF;

  FOR v_item IN
    SELECT producto_id, cantidad, ubicacion FROM facturas_compra_items
    WHERE factura_compra_id = p_factura_id AND producto_id IS NOT NULL
  LOOP
    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
    VALUES (v_item.producto_id, v_item.ubicacion, 'ajuste', -1 * v_item.cantidad,
            'Anulación de factura de compra: ' || p_motivo, p_factura_id, auth.uid());

    UPDATE stock_ubicaciones SET cantidad = cantidad - v_item.cantidad
    WHERE producto_id = v_item.producto_id AND ubicacion = v_item.ubicacion;
  END LOOP;

  UPDATE facturas_compra SET anulada = true WHERE id = p_factura_id;

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, nota, usuario_id)
  VALUES ('facturas_compra', p_factura_id, 'anulacion', p_motivo, auth.uid());
END;
$$;

-- ============================================================
-- 8b. editar_factura_compra — cuerpo vigente + no se puede convertir en NC (o dejar de serlo)
-- un comprobante con aplicaciones vigentes: cambiaría de "deuda" a "crédito" con plata ya imputada.
-- ============================================================
CREATE OR REPLACE FUNCTION editar_factura_compra(
  p_factura_id UUID,
  p_tipo_comprobante tipo_comprobante_compra DEFAULT NULL,
  p_letra letra_comprobante_compra DEFAULT NULL,
  p_punto_venta TEXT DEFAULT NULL,
  p_numero_comprobante TEXT DEFAULT NULL,
  p_fecha_comprobante DATE DEFAULT NULL,
  p_fecha_fiscal DATE DEFAULT NULL,
  p_forma_pago forma_pago_compra DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_tipo_actual tipo_comprobante_compra;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede editar una factura de compra ya cargada';
  END IF;
  IF EXISTS (SELECT 1 FROM facturas_compra WHERE id = p_factura_id AND anulada = true) THEN
    RAISE EXCEPTION 'Esta factura está anulada, no se edita';
  END IF;

  SELECT tipo_comprobante INTO v_tipo_actual FROM facturas_compra WHERE id = p_factura_id;
  IF p_tipo_comprobante IS NOT NULL
     AND (p_tipo_comprobante = 'nota_credito') <> (v_tipo_actual = 'nota_credito')
     AND EXISTS (
       SELECT 1 FROM pagos_proveedor_aplicaciones
       WHERE (factura_compra_id = p_factura_id OR nota_credito_id = p_factura_id)
         AND revertida_at IS NULL
     ) THEN
    RAISE EXCEPTION 'Este comprobante ya tiene pagos o créditos aplicados: no se puede cambiar de/a nota de crédito. Revertí esos pagos primero';
  END IF;

  UPDATE facturas_compra SET
    tipo_comprobante = COALESCE(p_tipo_comprobante, tipo_comprobante),
    letra = COALESCE(p_letra, letra),
    punto_venta = COALESCE(p_punto_venta, punto_venta),
    numero_comprobante = COALESCE(p_numero_comprobante, numero_comprobante),
    fecha_comprobante = COALESCE(p_fecha_comprobante, fecha_comprobante),
    fecha_fiscal = COALESCE(p_fecha_fiscal, fecha_fiscal),
    forma_pago = COALESCE(p_forma_pago, forma_pago)
  WHERE id = p_factura_id;
END;
$$;

-- ============================================================
-- 9. cerrar_caja — cuerpo vigente (pg_get_functiondef, 2026-10-05: versión docs/24 + el SET
-- timezone de docs/28). ÚNICO cambio: los dos SELECT de egresos filtran origen = 'turno'.
-- Los egresos de Gestión (origen 'general': sueldos, servicios, pagos a proveedor desde Gestión)
-- no salieron del cajón de Local y no deben bajar su efectivo esperado.
-- ⚠ Conserva SET timezone (ver advertencia de docs/28).
-- ============================================================
CREATE OR REPLACE FUNCTION cerrar_caja(p_tipo tipo_cierre, p_efectivo_contado NUMERIC DEFAULT NULL)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
SET timezone = 'America/Argentina/Buenos_Aires'
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

  -- docs/31: solo egresos de la caja de Local (origen 'turno'); los de Gestión ('general') no.
  SELECT COALESCE(SUM(monto), 0) INTO v_total_egresos
  FROM egresos WHERE created_at::date = current_date AND origen = 'turno';

  SELECT COALESCE(SUM(monto), 0) INTO v_total_egresos_efectivo
  FROM egresos WHERE created_at::date = current_date AND origen = 'turno' AND forma_pago = 'efectivo';

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

COMMIT;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- VERIFICACIONES post-migración (solo lectura)
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- V1. Todo pago con factura tiene su aplicación (esperado: 0 filas).
SELECT pp.id, pp.factura_compra_id, pp.monto
FROM pagos_proveedor pp
WHERE pp.factura_compra_id IS NOT NULL AND pp.monto > 0 AND pp.revierte_pago_proveedor_id IS NULL
  AND NOT EXISTS (SELECT 1 FROM pagos_proveedor_aplicaciones a WHERE a.pago_proveedor_id = pp.id);

-- V2. Saldos por factura iguales antes/después: total_pagado de la vista vieja = SUM por factura_compra_id
-- (esperado: 0 filas).
SELECT fcs.id, fcs.total_pagado, viejo.total
FROM facturas_compra_saldo fcs
JOIN (SELECT factura_compra_id, SUM(monto) total FROM pagos_proveedor
      WHERE factura_compra_id IS NOT NULL GROUP BY 1) viejo ON viejo.factura_compra_id = fcs.id
WHERE fcs.total_pagado <> viejo.total;

-- V3. Egresos de pago a proveedor sin vínculo a su pago (esperado: 0).
SELECT count(*) AS egresos_sin_pago
FROM egresos WHERE categoria = 'pago_proveedor' AND revierte_egreso_id IS NULL AND monto > 0 AND pago_proveedor_id IS NULL;

-- V4. cerrar_caja conserva la zona horaria (proconfig debe incluir TimeZone=America/Argentina/Buenos_Aires).
SELECT p.oid::regprocedure, p.proconfig FROM pg_proc p WHERE p.proname = 'cerrar_caja';

-- V5. Enum con presupuesto.
SELECT enum_range(NULL::tipo_comprobante_compra);

-- V6. Pagos "a cuenta" anteriores a docs/31 (sin factura): siguen restando del saldo del proveedor
-- pero no están aplicados a ningún comprobante — las facturas siguen figurando pendientes.
SELECT p.razon_social, pp.fecha, pp.monto, pp.forma_pago
FROM pagos_proveedor pp JOIN proveedores p ON p.id = pp.proveedor_id
WHERE pp.revierte_pago_proveedor_id IS NULL AND pp.monto > 0
  AND NOT EXISTS (SELECT 1 FROM pagos_proveedor_aplicaciones a WHERE a.pago_proveedor_id = pp.id)
ORDER BY pp.fecha;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — TESTS (después de A y B). Todo dentro de BEGIN … ROLLBACK: no deja datos.
-- Corren como el primer admin activo (auth.uid() vía request.jwt.claims). Si un ASSERT falla,
-- el bloque aborta con el mensaje del test.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $$
DECLARE
  v_admin UUID;
  v_hoy DATE := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  pA UUID; pB UUID; pC UUID; pD UUID; pE UUID;
  fA1 UUID; fA2 UUID; fB UUID; ncB UUID; fC UUID; fC_anulada UUID; fD UUID; fE UUID; ncE UUID; fP UUID;
  v_res JSONB;
  v_pago UUID;
  v_aud UUID;
  v_fs facturas_compra_saldo%ROWTYPE;
  v_saldo NUMERIC;
  v_identidad NUMERIC;
  v_ok BOOLEAN;
  v_cierre_id UUID; -- cerrar_caja va en una asignación aparte: en un WHERE se evaluaría una vez por fila
  v_c1 cierres_caja%ROWTYPE;
  v_c2 cierres_caja%ROWTYPE;
  v_c3 cierres_caja%ROWTYPE;
BEGIN
  SELECT id INTO v_admin FROM perfiles WHERE rol = 'admin' AND activo ORDER BY created_at LIMIT 1;
  ASSERT v_admin IS NOT NULL, 'setup: no hay admin activo';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  INSERT INTO proveedores (razon_social) VALUES ('TEST31 A') RETURNING id INTO pA;
  INSERT INTO proveedores (razon_social) VALUES ('TEST31 B') RETURNING id INTO pB;
  INSERT INTO proveedores (razon_social) VALUES ('TEST31 C') RETURNING id INTO pC;
  INSERT INTO proveedores (razon_social) VALUES ('TEST31 D') RETURNING id INTO pD;
  INSERT INTO proveedores (razon_social) VALUES ('TEST31 E') RETURNING id INTO pE;

  -- ── T1: 2 facturas de 100.000, pago 150.000 → una pagada, otra parcial con 50.000 ──
  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (pA, 'factura', 'T1-1', '2026-01-01', 'cuenta_corriente', 100000, 0, 100000, v_admin) RETURNING id INTO fA1;
  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (pA, 'factura', 'T1-2', '2026-01-02', 'cuenta_corriente', 100000, 0, 100000, v_admin) RETURNING id INTO fA2;

  v_res := registrar_pago_proveedor_v2(pA, 150000, 'transferencia', ARRAY[fA2, fA1], NULL, 'general');
  v_pago := (v_res->>'pago_id')::UUID;

  SELECT * INTO v_fs FROM facturas_compra_saldo WHERE id = fA1;
  ASSERT v_fs.estado = 'pagada' AND v_fs.saldo_pendiente = 0, 'T1: la factura más vieja debería quedar pagada';
  SELECT * INTO v_fs FROM facturas_compra_saldo WHERE id = fA2;
  ASSERT v_fs.estado = 'parcial' AND v_fs.saldo_pendiente = 50000, 'T1: la segunda debería quedar parcial con 50.000';
  ASSERT (v_res->>'a_cuenta')::NUMERIC = 0, 'T1: no debería quedar nada a cuenta';
  ASSERT (SELECT count(*) FROM egresos WHERE pago_proveedor_id = v_pago AND origen = 'general' AND monto = 150000) = 1,
    'T1: un egreso origen general por 150.000';
  ASSERT (SELECT count(*) FROM movimientos_cuenta WHERE referencia_id = v_pago AND monto = -150000) = 1,
    'T1: un movimiento de cuenta por -150.000';
  ASSERT (SELECT factura_compra_id FROM pagos_proveedor WHERE id = v_pago) IS NULL,
    'T1: pago repartido en 2 facturas → factura_compra_id (deprecated) queda NULL';

  -- ── T2: NC 30.000 + factura 100.000, pago 70.000 → factura pagada, NC agotada ──
  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (pB, 'factura', 'T2-F', '2026-01-01', 'cuenta_corriente', 100000, 0, 100000, v_admin) RETURNING id INTO fB;
  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (pB, 'nota_credito', 'T2-NC', '2026-01-05', 'cuenta_corriente', 30000, 0, 30000, v_admin) RETURNING id INTO ncB;

  ASSERT (SELECT saldo_actual FROM proveedores_saldo WHERE id = pB) = 70000, 'T2: la NC tiene que restar del saldo del proveedor';
  ASSERT (SELECT saldo_pendiente FROM facturas_compra_saldo WHERE id = ncB) = 0, 'T2: una NC nunca tiene saldo a pagar';

  v_res := registrar_pago_proveedor_v2(pB, 70000, 'efectivo', ARRAY[fB], ARRAY[ncB], 'general');
  SELECT * INTO v_fs FROM facturas_compra_saldo WHERE id = fB;
  ASSERT v_fs.estado = 'pagada' AND v_fs.saldo_pendiente = 0, 'T2: factura pagada';
  SELECT * INTO v_fs FROM facturas_compra_saldo WHERE id = ncB;
  ASSERT v_fs.estado = 'pagada' AND v_fs.credito_disponible = 0, 'T2: NC agotada';
  ASSERT (v_res->>'aplicado_nota_credito')::NUMERIC = 30000 AND (v_res->>'aplicado_pago')::NUMERIC = 70000, 'T2: 30.000 de NC + 70.000 de pago';
  ASSERT (SELECT saldo_actual FROM proveedores_saldo WHERE id = pB) = 0, 'T2: proveedor en cero';

  -- ── T3: pago mayor al saldo de lo seleccionado → error ──
  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (pC, 'factura', 'T3-F', '2026-01-01', 'cuenta_corriente', 100000, 0, 100000, v_admin) RETURNING id INTO fC;
  v_ok := false;
  BEGIN
    PERFORM registrar_pago_proveedor_v2(pC, 150000, 'efectivo', ARRAY[fC], NULL, 'general');
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM LIKE '%supera el saldo%';
  END;
  ASSERT v_ok, 'T3: debería rechazar un pago mayor al saldo seleccionado';

  -- ── T4: factura de otro proveedor → error ──
  v_ok := false;
  BEGIN
    PERFORM registrar_pago_proveedor_v2(pC, 1000, 'efectivo', ARRAY[fA2], NULL, 'general');
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM LIKE '%no es de este proveedor%';
  END;
  ASSERT v_ok, 'T4: debería rechazar una factura de otro proveedor';

  -- ── T5: factura anulada → error (v2 y wrapper viejo) ──
  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id, anulada)
  VALUES (pC, 'factura', 'T5-ANUL', '2026-01-01', 'cuenta_corriente', 5000, 0, 5000, v_admin, true) RETURNING id INTO fC_anulada;
  v_ok := false;
  BEGIN
    PERFORM registrar_pago_proveedor_v2(pC, 1000, 'efectivo', ARRAY[fC_anulada], NULL, 'general');
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM LIKE '%anulad%';
  END;
  ASSERT v_ok, 'T5: v2 debería rechazar una factura anulada';
  v_ok := false;
  BEGIN
    -- 9 argumentos: con menos, las dos sobrecargas vivas matchean y la llamada es ambigua.
    PERFORM registrar_pago_proveedor(pC, fC_anulada, 1000, 'efectivo', 'turno', NULL, NULL, NULL, NULL);
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM LIKE '%anulad%';
  END;
  ASSERT v_ok, 'T5: el RPC viejo también debería rechazar una factura anulada';

  -- ── T6: revertir el pago de T1 (Historial) → ambas facturas vuelven a pendiente ──
  SELECT id INTO v_aud FROM auditoria
  WHERE tabla_afectada = 'pagos_proveedor' AND registro_id = (SELECT id FROM pagos_proveedor WHERE proveedor_id = pA AND monto > 0)
    AND accion = 'alta';
  ASSERT v_aud IS NOT NULL, 'T6: setup — no se encontró la fila de auditoría del pago';
  PERFORM revertir_movimiento(v_aud);
  ASSERT (SELECT estado FROM facturas_compra_saldo WHERE id = fA1) = 'pendiente', 'T6: factura 1 vuelve a pendiente';
  ASSERT (SELECT estado FROM facturas_compra_saldo WHERE id = fA2) = 'pendiente', 'T6: factura 2 vuelve a pendiente';
  ASSERT (SELECT saldo_actual FROM proveedores_saldo WHERE id = pA) = 200000, 'T6: saldo del proveedor vuelve a 200.000';
  ASSERT (SELECT count(*) FROM egresos e JOIN pagos_proveedor r ON r.id = e.pago_proveedor_id
          WHERE r.revierte_pago_proveedor_id IS NOT NULL AND r.proveedor_id = pA AND e.origen = 'general' AND e.monto = -150000) = 1,
    'T6: el egreso de reversión conserva el origen general del original';
  ASSERT (SELECT count(*) FROM movimientos_cuenta WHERE referencia_id = v_pago AND monto = 150000) = 1,
    'T6: se devuelve el movimiento de cuenta';
  -- Revertir la reversión no está permitido.
  SELECT id INTO v_aud FROM auditoria
  WHERE tabla_afectada = 'pagos_proveedor' AND accion = 'alta'
    AND registro_id = (SELECT id FROM pagos_proveedor WHERE proveedor_id = pA AND revierte_pago_proveedor_id IS NOT NULL);
  v_ok := false;
  BEGIN
    PERFORM revertir_movimiento(v_aud);
  EXCEPTION WHEN raise_exception THEN v_ok := SQLERRM LIKE '%ya es la reversión%';
  END;
  ASSERT v_ok, 'T6: no se debería poder revertir una reversión';

  -- ── T7: saldo del proveedor = Σ saldos de comprobantes − NC disponibles (− pagos a cuenta) ──
  -- E: NC 50.000, factura 30.000, solo NC (monto 0) → factura pagada, NC con 20.000 disponibles.
  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (pE, 'factura', 'T7-F', '2026-01-01', 'cuenta_corriente', 30000, 0, 30000, v_admin) RETURNING id INTO fE;
  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (pE, 'nota_credito', 'T7-NC', '2026-01-02', 'cuenta_corriente', 50000, 0, 50000, v_admin) RETURNING id INTO ncE;
  v_res := registrar_pago_proveedor_v2(pE, 0, 'efectivo', NULL, ARRAY[ncE], 'general');
  ASSERT (SELECT estado FROM facturas_compra_saldo WHERE id = fE) = 'pagada', 'T7: factura cancelada con la NC';
  ASSERT (SELECT credito_disponible FROM facturas_compra_saldo WHERE id = ncE) = 20000, 'T7: NC con 20.000 disponibles';
  ASSERT (SELECT count(*) FROM egresos WHERE pago_proveedor_id = (v_res->>'pago_id')::UUID) = 0, 'T7: monto 0 no genera egreso';
  -- D: factura 100.000, pago 120.000 sin selección → pagada y 20.000 a cuenta.
  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (pD, 'factura', 'T7-D', '2026-01-01', 'cuenta_corriente', 100000, 0, 100000, v_admin) RETURNING id INTO fD;
  v_res := registrar_pago_proveedor_v2(pD, 120000, 'efectivo', NULL, NULL, 'general');
  ASSERT (v_res->>'a_cuenta')::NUMERIC = 20000, 'T7: sin selección, el excedente queda a cuenta';

  FOR v_pago IN SELECT unnest(ARRAY[pA, pB, pC, pD, pE]) LOOP
    SELECT saldo_actual INTO v_saldo FROM proveedores_saldo WHERE id = v_pago;
    SELECT (SELECT saldo_inicial FROM proveedores WHERE id = v_pago)
         + COALESCE((SELECT SUM(saldo_pendiente) - SUM(credito_disponible) FROM facturas_compra_saldo WHERE proveedor_id = v_pago), 0)
         - COALESCE((SELECT SUM(pp.monto) FROM pagos_proveedor pp WHERE pp.proveedor_id = v_pago), 0)
         + COALESCE((SELECT SUM(a.monto) FROM pagos_proveedor_aplicaciones a
                     JOIN pagos_proveedor pp ON pp.id = a.pago_proveedor_id
                     WHERE pp.proveedor_id = v_pago AND a.revertida_at IS NULL), 0)
    INTO v_identidad;
    ASSERT v_saldo = v_identidad, format('T7: identidad de saldo rota para %s (%s vs %s)', v_pago, v_saldo, v_identidad);
  END LOOP;
  ASSERT (SELECT saldo_actual FROM proveedores_saldo WHERE id = pE) = -20000, 'T7: E queda con 20.000 a favor (NC disponible)';

  -- ── T8: un egreso origen 'general' no entra en cerrar_caja; uno 'turno' sí ──
  v_cierre_id := cerrar_caja('x');
  SELECT * INTO v_c1 FROM cierres_caja WHERE id = v_cierre_id;
  INSERT INTO egresos (origen, categoria, monto, descripcion, forma_pago, usuario_id)
  VALUES ('general', 'otro', 12345, 'TEST31 general', 'efectivo', v_admin);
  v_cierre_id := cerrar_caja('x');
  SELECT * INTO v_c2 FROM cierres_caja WHERE id = v_cierre_id;
  ASSERT v_c2.total_egresos = v_c1.total_egresos AND v_c2.efectivo_esperado = v_c1.efectivo_esperado,
    'T8: un egreso general no debería cambiar el cierre de Local';
  INSERT INTO egresos (origen, categoria, monto, descripcion, forma_pago, usuario_id)
  VALUES ('turno', 'otro', 100, 'TEST31 turno', 'efectivo', v_admin);
  v_cierre_id := cerrar_caja('x');
  SELECT * INTO v_c3 FROM cierres_caja WHERE id = v_cierre_id;
  ASSERT v_c3.total_egresos = v_c1.total_egresos + 100 AND v_c3.efectivo_esperado = v_c1.efectivo_esperado - 100,
    'T8: un egreso de turno sí entra en el cierre';

  -- ── T9: presupuesto suma deuda y se paga; el RPC viejo deja factura_compra_id (compat) ──
  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, numero_comprobante, fecha_comprobante, forma_pago, total_sin_iva, iva, total, usuario_id)
  VALUES (pC, 'presupuesto', 'T9-P', '2026-02-01', 'cuenta_corriente', 8000, 0, 8000, v_admin) RETURNING id INTO fP;
  v_pago := registrar_pago_proveedor(pC, fP, 3000, 'efectivo', 'turno', NULL, NULL, NULL, NULL);
  ASSERT (SELECT estado FROM facturas_compra_saldo WHERE id = fP) = 'parcial', 'T9: presupuesto parcialmente pagado';
  ASSERT (SELECT factura_compra_id FROM pagos_proveedor WHERE id = v_pago) = fP, 'T9: compat — factura_compra_id completo';
  ASSERT (SELECT origen FROM egresos WHERE pago_proveedor_id = v_pago) = 'turno', 'T9: el RPC viejo sigue en turno por defecto';

  RAISE NOTICE 'docs/31: todos los tests pasaron';
END;
$$;

ROLLBACK;
