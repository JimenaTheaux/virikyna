-- 74 — Devolución con 1 a 3 tickets (modelo A: cabecera + tabla puente + detalle por línea de venta)
--
-- Estado: ver los bloques "PROBADO" y "APLICADO" al final del encabezado.
--
-- Correr desde la raíz del repo, después de 72 (el 73 es la bandeja de documentos: sin SQL). La PARTE A es re-corrible (IF NOT EXISTS, CREATE OR
-- REPLACE, rellenos que solo tocan filas sin completar). La PARTE B solo lee. La PARTE C es un test
-- (BEGIN … ROLLBACK) que llama a confirmar_venta / crear_devolucion*: consume numeración aunque haga
-- ROLLBACK → SOLO en la restauración local (restaurar-prueba.ps1), nunca en producción.
--
-- Pedido (2026-11-11): el cliente trae 2 o 3 tickets (típico: regalos), devuelve productos de todos,
-- junta el monto y se lleva otra cosa. Se eligió el modelo A del diagnóstico (cabecera + tabla puente
-- devolucion_tickets + detalle con venta_id y venta_item_id).
--
-- DECISIONES VALIDADAS CON LA DUEÑA (2026-11-11)
--   1. Diferencia a favor del cliente: "Devolver la plata" (resolución 'reintegro', con medio de pago,
--      como hasta ahora) o "Queda a favor" ('a_favor': sin pagos, con nota obligatoria). El vale se
--      hace a mano, en papel: sin numeración, sin vencimiento, sin cuenta corriente, no se usa después
--      en el sistema.
--   2. Ticket de más de 15 días: se rechaza ese ticket, con el motivo. Sin excepción.
--   3. Lo devuelto vale lo que se pagó (prorrateado), ahora POR LÍNEA de venta; lo nuevo, precio de
--      lista actual.
--   4. Defectuoso es por línea (devolucion_items.defectuoso), no por devolución.
--   5–6, 8–9. Fuera de alcance: ticket de regalo sin precio, nota de crédito / facturar lo que se
--      lleva, comprobante impreso de la devolución, escanear el ticket.
--   7. Un ticket a cuenta corriente solo se devuelve solo (D12 de docs/68 se mantiene tal cual).
--  10. Saldos a favor del día: línea informativa en el cierre (cantidad_saldos_a_favor /
--      total_saldos_a_favor). NO suman a la caja ni descuentan de la venta neta.
--
-- QUÉ HACE
--   1. Enum resolucion_devolucion (sin_diferencia | cobro | reintegro | a_favor | cuenta_corriente).
--   2. devoluciones: venta_id pasa a admitir NULL (se completa solo con 1 ticket), + resolucion,
--      cantidad_tickets (1..3), total_devuelto, total_nuevo, nota_a_favor. El CHECK de forma de pago se
--      reemplaza por uno por resolución. nota_a_favor entra al trigger sin acentos (docs/51).
--   3. devolucion_tickets (tabla puente): UNIQUE (devolucion_id, venta_id) → ticket repetido imposible;
--      orden 1..3 único → máximo 3; total_devuelto por ticket. Solo lectura (RLS); se escribe por las
--      funciones.
--   4. devolucion_items: + venta_id (ticket de la línea, solo en 'devuelto'), + venta_item_id (línea de
--      venta original), + defectuoso. FKs compuestas: la línea es de ese ticket y el ticket es de esa
--      devolución. CHECK reingresa_stock = NOT defectuoso.
--   5. Relleno de lo existente (al 2026-11-11: 1 devolución, 0 ítems ambiguos — paso 0).
--   6. crear_devolucion_tickets (NUEVA, único camino de la app nueva) — 1 a 3 tickets, todo o nada.
--   7. crear_devolucion (vieja, MISMA FIRMA: la usan las versiones de Local ya instaladas): reparte cada
--      producto entre las líneas del ticket con unidades disponibles (en orden de id) y llama a
--      crear_devolucion_tickets. Deja tabla puente, línea, resolución y totales. Con motivo
--      'defectuoso', todas sus líneas quedan defectuosas (comportamiento de siempre).
--      Diferencia con la versión anterior: si el mismo producto está en 2 líneas con precios distintos,
--      cada unidad vale el precio de SU línea (antes: el promedio de las líneas).
--   8. anular_venta: bloquea la venta (FOR UPDATE, serializa con crear_devolucion*) y rechaza si el
--      ticket está en una devolución activa. Arregla el doble reingreso de stock (la anulación de venta
--      reponía todo lo vendido aunque una devolución ya hubiera reingresado parte).
--   9. cerrar_caja: misma lógica + cantidad_saldos_a_favor / total_saldos_a_favor (informativo: no
--      entra en efectivo_esperado). Los saldos a favor no tienen devolucion_pagos, así que los netos de
--      devoluciones por medio ya los dejaban afuera.
--  10. dashboard_ventas_por_producto: lo devuelto se filtra por el ticket de cada línea; lo nuevo se
--      excluye si algún ticket de la devolución es interno (docs/68 D8).
--
-- VERIFICADO SIN CAMBIOS
--   - anular_devolucion: recorre todos los ítems de la devolución (sirve igual para 3 tickets); los
--     defectuosos tienen reingresa_stock = false y se saltean. La caja: una devolución anulada sale de
--     los cierres no emitidos (cerrar_caja filtra estado = 'activa').
--   - validar_cierre_z: usa los totales de devoluciones del cierre; un saldo a favor no tiene pagos.
--   - credito_devoluciones_venta / ventas_cuenta_corriente_saldo y dashboard_consumo_interno: leen
--     devoluciones.venta_id, que en ventas a cta. cte. e internas siempre está (esas devoluciones son de
--     un solo ticket).
--   - historial_producto / resumen_historial_producto / clasificar_movimiento_stock: van por
--     movimientos_stock.referencia_id = devolución; los textos de motivo conservan los prefijos
--     "Devolución de venta #" / "Cambio sobre venta" / "Anulación de devolución".
--
-- Orden de despliegue: esta migración ANTES de las apps (la app nueva llama a crear_devolucion_tickets
-- y lee devolucion_tickets). Las apps viejas siguen andando contra la base nueva (crear_devolucion
-- mantiene firma y resultado). En la app vieja, "Ya devuelta" de un ticket que esté en una devolución
-- múltiple se ve de menos (lee devoluciones.venta_id), pero la función igual rechaza el exceso.
--
-- PROBADO: 2026-11-11 sobre la restauración local de virikyna_2026-11-11_pre-docs73-test (:54329), el
-- archivo entero dos veces seguidas (versión final, con devolucion_tickets.id como PK, sobre una
-- restauración limpia). PARTE B: 1 devolución histórica, todo en 0 (sin ítems ambiguos), anon sin
-- EXECUTE, RLS activa, authenticated solo SELECT. PARTE C: OK T1–T13 en las dos corridas. Además: los
-- payloads que mandó la pantalla de Local (Playwright, 1366×768 y 1024×700) corridos como cajero con
-- ROLLBACK dieron lo mismo que la vista previa; docs/37 V5–V12: 0 filas.
-- PENDIENTE AL APLICAR EN PROD: verificar que la API sigue aceptando el embed sin aclarar
-- `devoluciones?select=*,venta:ventas(numero)` (lo usa la versión instalada de Local).
-- APLICADO: 2026-11-12 08:52 en producción (backup previo virikyna_2026-11-12_pre-docs74-aplicar; antes
-- se verificó que las funciones reemplazadas seguían idénticas a las del 11/11). Solo PARTE A, con
-- lock_timeout 5s; caja cerrada. PARTE B: todo en 0, anon sin EXECUTE, RLS activa. docs/37 V5–V12: 0
-- filas. La API acepta `devoluciones?select=*,venta:ventas(numero)` y las consultas de Local v0.13.0.
-- Junto al backup: aplicar-docs74.sql y revert-docs74.sql (revert probado en restauración: schema
-- idéntico al original).

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios
-- ════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 1. Enum ────────────────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'resolucion_devolucion') THEN
    CREATE TYPE public.resolucion_devolucion AS ENUM ('sin_diferencia', 'cobro', 'reintegro', 'a_favor', 'cuenta_corriente');
  END IF;
END $$;

-- ── 2. devoluciones ────────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.devoluciones ALTER COLUMN venta_id DROP NOT NULL;
ALTER TABLE public.devoluciones ADD COLUMN IF NOT EXISTS resolucion public.resolucion_devolucion;
ALTER TABLE public.devoluciones ADD COLUMN IF NOT EXISTS cantidad_tickets smallint NOT NULL DEFAULT 1;
ALTER TABLE public.devoluciones ADD COLUMN IF NOT EXISTS total_devuelto numeric(12,2);
ALTER TABLE public.devoluciones ADD COLUMN IF NOT EXISTS total_nuevo numeric(12,2);
ALTER TABLE public.devoluciones ADD COLUMN IF NOT EXISTS nota_a_favor text;

COMMENT ON COLUMN public.devoluciones.venta_id IS 'Ticket de la devolución cuando es UNO solo (todas las anteriores a docs/74 y las de 1 ticket). Con 2–3 tickets queda NULL: los tickets están en devolucion_tickets.';
COMMENT ON COLUMN public.devoluciones.resolucion IS 'docs/74: cómo se resolvió la diferencia. sin_diferencia | cobro (paga el cliente) | reintegro (se le devuelve plata) | a_favor (queda a favor, vale manual, sin pagos ni caja) | cuenta_corriente (docs/68 D12).';
COMMENT ON COLUMN public.devoluciones.cantidad_tickets IS 'docs/74: cantidad de tickets (filas de devolucion_tickets), 1 a 3.';
COMMENT ON COLUMN public.devoluciones.total_devuelto IS 'docs/74: suma de lo devuelto (cantidad × precio pagado) de todos los tickets.';
COMMENT ON COLUMN public.devoluciones.total_nuevo IS 'docs/74: suma de lo que se lleva (precio de lista al momento).';
COMMENT ON COLUMN public.devoluciones.nota_a_favor IS 'docs/74: nota obligatoria con resolución a_favor (ej. vale manual a nombre de…). Registro interno.';

-- ── 3. devolucion_tickets ──────────────────────────────────────────────────────────────────────────
-- PK propia (id) y NO (devolucion_id, venta_id) a propósito: PostgREST toma como tabla intermedia
-- (muchos-a-muchos) a la que tiene las dos FKs dentro de la PK. Si devolucion_tickets lo fuera, entre
-- devoluciones y ventas habría DOS relaciones (devoluciones.venta_id y esta) y los embeds sin aclarar
-- de las apps ya instaladas (`venta:ventas(numero)`, `ventas!inner(...)`) fallarían por ambigüedad.
-- El UNIQUE da la misma garantía (ticket repetido imposible) y sirve a la FK compuesta de los ítems.
CREATE TABLE IF NOT EXISTS public.devolucion_tickets (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  devolucion_id uuid NOT NULL REFERENCES public.devoluciones(id) ON DELETE CASCADE,
  venta_id uuid NOT NULL REFERENCES public.ventas(id),
  orden smallint NOT NULL,
  total_devuelto numeric(12,2) NOT NULL DEFAULT 0,
  CONSTRAINT devolucion_tickets_pkey PRIMARY KEY (id),
  CONSTRAINT devolucion_tickets_unico UNIQUE (devolucion_id, venta_id),
  CONSTRAINT devolucion_tickets_orden_unico UNIQUE (devolucion_id, orden),
  CONSTRAINT chk_devolucion_tickets_orden CHECK (orden BETWEEN 1 AND 3),
  CONSTRAINT chk_devolucion_tickets_total CHECK (total_devuelto >= 0)
);
CREATE INDEX IF NOT EXISTS idx_devolucion_tickets_venta ON public.devolucion_tickets(venta_id);
COMMENT ON TABLE public.devolucion_tickets IS 'docs/74: tickets (ventas) de una devolución, 1 a 3, en el orden en que se agregaron, con el total devuelto de cada uno.';

ALTER TABLE public.devolucion_tickets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS devolucion_tickets_ver_todos ON public.devolucion_tickets;
CREATE POLICY devolucion_tickets_ver_todos ON public.devolucion_tickets FOR SELECT
  USING (EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true));
REVOKE ALL ON public.devolucion_tickets FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.devolucion_tickets TO authenticated;
GRANT ALL ON public.devolucion_tickets TO service_role;

-- ── 4. devolucion_items ────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.devolucion_items ADD COLUMN IF NOT EXISTS venta_id uuid;
ALTER TABLE public.devolucion_items ADD COLUMN IF NOT EXISTS venta_item_id uuid;
ALTER TABLE public.devolucion_items ADD COLUMN IF NOT EXISTS defectuoso boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.devolucion_items.venta_id IS 'docs/74: ticket de la línea devuelta (solo tipo devuelto).';
COMMENT ON COLUMN public.devolucion_items.venta_item_id IS 'docs/74: línea de venta original de lo devuelto. NULL solo en devoluciones anteriores a docs/74 cuyo producto estaba en 2+ líneas del ticket.';
COMMENT ON COLUMN public.devolucion_items.defectuoso IS 'docs/74: la línea devuelta es defectuosa → no reingresa al stock (reingresa_stock = NOT defectuoso).';

CREATE INDEX IF NOT EXISTS idx_devolucion_items_venta_item ON public.devolucion_items(venta_item_id);
CREATE INDEX IF NOT EXISTS idx_devolucion_items_venta ON public.devolucion_items(venta_id);

-- ── 5. Relleno (todos con WHERE: safeupdate) ───────────────────────────────────────────────────────
INSERT INTO public.devolucion_tickets (devolucion_id, venta_id, orden, total_devuelto)
SELECT d.id, d.venta_id, 1,
       COALESCE((SELECT SUM(ROUND(di.cantidad * di.precio_unitario, 2)) FROM public.devolucion_items di
                 WHERE di.devolucion_id = d.id AND di.tipo = 'devuelto'), 0)
FROM public.devoluciones d
WHERE d.venta_id IS NOT NULL
ON CONFLICT DO NOTHING;

UPDATE public.devolucion_items di SET venta_id = d.venta_id
FROM public.devoluciones d
WHERE d.id = di.devolucion_id AND di.tipo = 'devuelto' AND di.venta_id IS NULL AND d.venta_id IS NOT NULL;

-- La línea solo cuando no es ambigua (el producto está en UNA línea de ese ticket).
UPDATE public.devolucion_items di SET venta_item_id = u.id
FROM (SELECT venta_id, producto_id, (array_agg(id))[1] AS id
      FROM public.venta_items GROUP BY 1, 2 HAVING count(*) = 1) u
WHERE di.tipo = 'devuelto' AND di.venta_item_id IS NULL
  AND u.venta_id = di.venta_id AND u.producto_id = di.producto_id;

UPDATE public.devolucion_items SET defectuoso = true
WHERE tipo = 'devuelto' AND NOT reingresa_stock AND NOT defectuoso;

UPDATE public.devoluciones d SET
  total_devuelto = COALESCE((SELECT SUM(ROUND(cantidad * precio_unitario, 2)) FROM public.devolucion_items
                             WHERE devolucion_id = d.id AND tipo = 'devuelto'), 0),
  total_nuevo    = COALESCE((SELECT SUM(ROUND(cantidad * precio_unitario, 2)) FROM public.devolucion_items
                             WHERE devolucion_id = d.id AND tipo = 'nuevo'), 0),
  resolucion = CASE WHEN d.a_cuenta_corriente THEN 'cuenta_corriente'
                    WHEN d.diferencia_monto = 0 THEN 'sin_diferencia'
                    WHEN d.diferencia_monto > 0 THEN 'cobro'
                    ELSE 'reintegro' END::public.resolucion_devolucion
WHERE d.resolucion IS NULL OR d.total_devuelto IS NULL OR d.total_nuevo IS NULL;

ALTER TABLE public.devoluciones ALTER COLUMN resolucion SET NOT NULL;
ALTER TABLE public.devoluciones ALTER COLUMN total_devuelto SET NOT NULL;
ALTER TABLE public.devoluciones ALTER COLUMN total_nuevo SET NOT NULL;

-- ── 6. Restricciones ───────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_venta_items_id_venta') THEN
    ALTER TABLE public.venta_items ADD CONSTRAINT uq_venta_items_id_venta UNIQUE (id, venta_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_devolucion_items_ticket') THEN
    ALTER TABLE public.devolucion_items ADD CONSTRAINT fk_devolucion_items_ticket
      FOREIGN KEY (devolucion_id, venta_id) REFERENCES public.devolucion_tickets(devolucion_id, venta_id) ON DELETE CASCADE;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_devolucion_items_linea') THEN
    ALTER TABLE public.devolucion_items ADD CONSTRAINT fk_devolucion_items_linea
      FOREIGN KEY (venta_item_id, venta_id) REFERENCES public.venta_items(id, venta_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_devolucion_items_ticket') THEN
    ALTER TABLE public.devolucion_items ADD CONSTRAINT chk_devolucion_items_ticket
      CHECK ((tipo = 'devuelto') = (venta_id IS NOT NULL));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_devolucion_items_linea') THEN
    ALTER TABLE public.devolucion_items ADD CONSTRAINT chk_devolucion_items_linea
      CHECK (venta_item_id IS NULL OR tipo = 'devuelto');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_devolucion_items_defectuoso') THEN
    ALTER TABLE public.devolucion_items ADD CONSTRAINT chk_devolucion_items_defectuoso
      CHECK ((NOT defectuoso OR tipo = 'devuelto') AND reingresa_stock = NOT defectuoso);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_devoluciones_cantidad_tickets') THEN
    ALTER TABLE public.devoluciones ADD CONSTRAINT chk_devoluciones_cantidad_tickets
      CHECK (cantidad_tickets BETWEEN 1 AND 3 AND (venta_id IS NULL) = (cantidad_tickets > 1));
  END IF;
END $$;

ALTER TABLE public.devoluciones DROP CONSTRAINT IF EXISTS chk_devolucion_forma_pago_coherente;
ALTER TABLE public.devoluciones DROP CONSTRAINT IF EXISTS chk_devolucion_resolucion;
ALTER TABLE public.devoluciones ADD CONSTRAINT chk_devolucion_resolucion CHECK (
     (resolucion = 'sin_diferencia'   AND diferencia_monto = 0 AND diferencia_forma_pago IS NULL AND NOT a_cuenta_corriente)
  OR (resolucion = 'cobro'            AND diferencia_monto > 0 AND diferencia_forma_pago IS NOT NULL AND NOT a_cuenta_corriente)
  OR (resolucion = 'reintegro'        AND diferencia_monto < 0 AND diferencia_forma_pago IS NOT NULL AND NOT a_cuenta_corriente)
  OR (resolucion = 'a_favor'          AND diferencia_monto < 0 AND diferencia_forma_pago IS NULL AND NOT a_cuenta_corriente
                                      AND btrim(COALESCE(nota_a_favor, '')) <> '')
  OR (resolucion = 'cuenta_corriente' AND a_cuenta_corriente AND diferencia_forma_pago IS NULL AND venta_id IS NOT NULL));

-- nota_a_favor también se guarda sin acentos (docs/51), como observaciones.
DROP TRIGGER IF EXISTS trg_sin_acentos ON public.devoluciones;
CREATE TRIGGER trg_sin_acentos BEFORE INSERT OR UPDATE ON public.devoluciones
  FOR EACH ROW EXECUTE FUNCTION fn_sin_acentos('motivo_detalle', 'observaciones', 'motivo_anulacion', 'nota_a_favor');

-- ── 7. cierres_caja: saldos a favor del día (informativo) ──────────────────────────────────────────
ALTER TABLE public.cierres_caja ADD COLUMN IF NOT EXISTS cantidad_saldos_a_favor integer NOT NULL DEFAULT 0;
ALTER TABLE public.cierres_caja ADD COLUMN IF NOT EXISTS total_saldos_a_favor numeric(12,2) NOT NULL DEFAULT 0;
COMMENT ON COLUMN public.cierres_caja.total_saldos_a_favor IS 'docs/74: devoluciones del día que quedaron "a favor" del cliente (vale manual). Informativo: NO entra en efectivo_esperado ni en los netos de devoluciones.';

-- ── 8. crear_devolucion_tickets ────────────────────────────────────────────────────────────────────
-- p_tickets:         1 a 3 ventas, en el orden en que se agregaron.
-- p_items_devueltos: [{"venta_item_id":"…","cantidad":1,"defectuoso":false}, …] (al menos 1 por ticket)
-- p_items_nuevos:    [{"producto_id":"…","cantidad":1}, …] (opcional)
-- p_resolucion:      con diferencia < 0, 'reintegro' (default) o 'a_favor' (pide p_nota_a_favor). Si
--                    viene y no coincide con la diferencia real, rechaza: la pantalla mostró otra cosa.
-- p_forma_pago / p_pagos: como siempre (cobro o reintegro; hasta 2 medios). Ticket único a cta. cte.:
--                    p_forma_pago = 'cuenta_corriente' carga a la cuenta lo que el cliente lleva de más.
-- Precios: NO vienen del cliente. Devuelto = importe de la línea ÷ cantidad × total/subtotal de esa
-- venta; nuevo = precio de lista actual.
CREATE OR REPLACE FUNCTION public.crear_devolucion_tickets(
  p_tickets uuid[],
  p_motivo motivo_devolucion,
  p_motivo_detalle text,
  p_observaciones text,
  p_items_devueltos jsonb,
  p_items_nuevos jsonb DEFAULT NULL,
  p_resolucion resolucion_devolucion DEFAULT NULL,
  p_forma_pago forma_pago_venta DEFAULT NULL,
  p_pagos jsonb DEFAULT NULL,
  p_nota_a_favor text DEFAULT NULL
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'America/Argentina/Buenos_Aires'
AS $$
DECLARE
  v_n int;
  v_venta ventas%ROWTYPE;
  v_unica ventas%ROWTYPE;
  v_row RECORD;
  v_item jsonb;
  v_venta_id uuid;
  v_numero bigint;
  v_ya numeric;
  v_vendida numeric;
  v_devuelta numeric;
  v_precio numeric;
  v_total_devuelto numeric := 0;
  v_total_nuevo numeric := 0;
  v_diferencia numeric;
  v_resolucion resolucion_devolucion;
  v_forma_final forma_pago_venta;
  v_suma_pagos numeric;
  v_suma_asignada numeric := 0;
  v_monto numeric;
  v_pago jsonb;
  v_idx int := 0;
  v_a_cuenta boolean := false;
  v_dev_id uuid;
  v_dev_numero bigint;
  v_nombre text;
  v_marca text;
  v_tickets_txt text;
  v_lineas jsonb := '[]'::jsonb;
  v_nuevos jsonb := '[]'::jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  -- ---- Tickets ----
  IF p_tickets IS NULL OR cardinality(p_tickets) = 0 THEN
    RAISE EXCEPTION 'Agregá al menos un ticket';
  END IF;
  IF cardinality(p_tickets) > 3 THEN
    RAISE EXCEPTION 'Una devolución admite hasta 3 tickets';
  END IF;
  IF array_position(p_tickets, NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'Hay un ticket vacío';
  END IF;
  IF (SELECT count(DISTINCT t) FROM unnest(p_tickets) AS t) <> cardinality(p_tickets) THEN
    RAISE EXCEPTION 'Un ticket está repetido';
  END IF;
  v_n := cardinality(p_tickets);

  -- Bloquea los tickets en orden de id: dos devoluciones (o una anulación) sobre el mismo ticket se
  -- serializan sin trabarse entre sí; la validación de cantidades no se puede saltear con una carrera.
  PERFORM 1 FROM ventas WHERE id = ANY(p_tickets) ORDER BY id FOR UPDATE;
  IF (SELECT count(*) FROM ventas WHERE id = ANY(p_tickets)) <> v_n THEN
    RAISE EXCEPTION 'Ticket no encontrado';
  END IF;

  FOR v_venta IN
    SELECT v.* FROM unnest(p_tickets) WITH ORDINALITY AS t(id, ord) JOIN ventas v ON v.id = t.id ORDER BY t.ord
  LOOP
    IF v_venta.estado = 'anulada' THEN
      RAISE EXCEPTION 'El ticket N° % está anulado', v_venta.numero;
    END IF;
    IF v_venta.estado_interno IS NOT NULL AND v_n > 1 THEN
      RAISE EXCEPTION 'El ticket N° % es un consumo interno: se devuelve solo, sin otros tickets', v_venta.numero;
    END IF;
    IF v_venta.estado_interno = 'finalizado' THEN
      RAISE EXCEPTION 'Es un consumo interno ya finalizado: pedile a un administrador que lo reabra antes de la devolución';
    END IF;
    IF v_venta.forma_pago = 'cuenta_corriente' AND v_n > 1 THEN
      RAISE EXCEPTION 'El ticket N° % es a cuenta corriente: se devuelve solo, sin otros tickets', v_venta.numero;
    END IF;
    IF v_venta.created_at::date < current_date - 15 THEN
      RAISE EXCEPTION 'El ticket N° % supera los 15 días permitidos para devolución/cambio', v_venta.numero;
    END IF;
  END LOOP;

  IF p_motivo IS NULL THEN RAISE EXCEPTION 'El motivo es obligatorio'; END IF;
  IF p_motivo = 'otro' AND (p_motivo_detalle IS NULL OR btrim(p_motivo_detalle) = '') THEN
    RAISE EXCEPTION 'Con motivo "otro" el detalle es obligatorio';
  END IF;

  IF p_items_devueltos IS NULL OR jsonb_typeof(p_items_devueltos) <> 'array' OR jsonb_array_length(p_items_devueltos) = 0 THEN
    RAISE EXCEPTION 'Elegí al menos un producto para devolver';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items_devueltos) AS i
             WHERE (i->>'venta_item_id') IS NULL OR (i->>'cantidad') IS NULL OR (i->>'cantidad')::numeric <= 0) THEN
    RAISE EXCEPTION 'La cantidad a devolver debe ser mayor a 0';
  END IF;

  -- ---- Lo devuelto: cada línea es de un ticket agregado y no supera lo disponible ----
  FOR v_row IN
    SELECT (i->>'venta_item_id')::uuid AS venta_item_id, SUM((i->>'cantidad')::numeric) AS cantidad
    FROM jsonb_array_elements(p_items_devueltos) AS i GROUP BY 1
  LOOP
    SELECT vi.venta_id, vi.cantidad, v.numero, COALESCE(vi.producto_nombre, p.nombre)
    INTO v_venta_id, v_vendida, v_numero, v_nombre
    FROM venta_items vi JOIN ventas v ON v.id = vi.venta_id LEFT JOIN productos p ON p.id = vi.producto_id
    WHERE vi.id = v_row.venta_item_id;
    IF NOT FOUND OR NOT (v_venta_id = ANY(p_tickets)) THEN
      RAISE EXCEPTION 'Un producto a devolver no es de los tickets agregados';
    END IF;

    SELECT COALESCE(SUM(di.cantidad), 0) INTO v_ya
    FROM devolucion_items di JOIN devoluciones d ON d.id = di.devolucion_id
    WHERE di.venta_item_id = v_row.venta_item_id AND d.estado = 'activa';

    IF v_row.cantidad > v_vendida - v_ya THEN
      RAISE EXCEPTION 'No se puede devolver % de "%" del ticket N° %: solo quedan % disponibles (vendidas %, ya devueltas %)',
        v_row.cantidad, v_nombre, v_numero, v_vendida - v_ya, v_vendida, v_ya;
    END IF;
  END LOOP;

  -- Además por producto dentro de cada ticket: cubre devoluciones anteriores a docs/74 sin línea.
  FOR v_row IN
    SELECT vi.venta_id, vi.producto_id, SUM((i->>'cantidad')::numeric) AS cantidad
    FROM jsonb_array_elements(p_items_devueltos) AS i
    JOIN venta_items vi ON vi.id = (i->>'venta_item_id')::uuid
    GROUP BY 1, 2
  LOOP
    SELECT COALESCE(SUM(cantidad), 0) INTO v_vendida
    FROM venta_items WHERE venta_id = v_row.venta_id AND producto_id = v_row.producto_id;
    SELECT COALESCE(SUM(di.cantidad), 0) INTO v_devuelta
    FROM devolucion_items di JOIN devoluciones d ON d.id = di.devolucion_id
    WHERE di.venta_id = v_row.venta_id AND di.producto_id = v_row.producto_id
      AND di.tipo = 'devuelto' AND d.estado = 'activa';
    IF v_row.cantidad > v_vendida - v_devuelta THEN
      SELECT numero INTO v_numero FROM ventas WHERE id = v_row.venta_id;
      SELECT nombre INTO v_nombre FROM productos WHERE id = v_row.producto_id;
      RAISE EXCEPTION 'No se puede devolver % de "%" del ticket N° %: solo quedan % disponibles (vendidas %, ya devueltas %)',
        v_row.cantidad, v_nombre, v_numero, v_vendida - v_devuelta, v_vendida, v_devuelta;
    END IF;
  END LOOP;

  -- Cada ticket agregado aporta al menos una línea.
  SELECT v.numero INTO v_numero
  FROM unnest(p_tickets) WITH ORDINALITY AS t(id, ord) JOIN ventas v ON v.id = t.id
  WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_items_devueltos) AS i
                    JOIN venta_items vi ON vi.id = (i->>'venta_item_id')::uuid
                    WHERE vi.venta_id = t.id)
  ORDER BY t.ord LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'El ticket N° % no tiene productos para devolver: quitalo o elegí qué se devuelve', v_numero;
  END IF;

  -- Precio pagado por línea (prorrateado por total/subtotal de SU venta).
  FOR v_row IN
    SELECT vi.id AS venta_item_id, vi.venta_id, v.numero, vi.producto_id,
           COALESCE((i->>'defectuoso')::boolean, false) AS defectuoso,
           SUM((i->>'cantidad')::numeric) AS cantidad,
           ROUND((vi.importe / NULLIF(vi.cantidad, 0))
                 * (CASE WHEN v.subtotal > 0 THEN v.total / v.subtotal ELSE 1 END), 2) AS precio,
           t.ord
    FROM jsonb_array_elements(p_items_devueltos) AS i
    JOIN venta_items vi ON vi.id = (i->>'venta_item_id')::uuid
    JOIN ventas v ON v.id = vi.venta_id
    JOIN unnest(p_tickets) WITH ORDINALITY AS t(id, ord) ON t.id = vi.venta_id
    GROUP BY vi.id, vi.venta_id, v.numero, vi.producto_id, 5, vi.importe, vi.cantidad, v.subtotal, v.total, t.ord
    ORDER BY t.ord, vi.id, 5
  LOOP
    v_total_devuelto := v_total_devuelto + ROUND(v_row.cantidad * COALESCE(v_row.precio, 0), 2);
    v_lineas := v_lineas || jsonb_build_object(
      'venta_item_id', v_row.venta_item_id, 'venta_id', v_row.venta_id, 'numero', v_row.numero,
      'producto_id', v_row.producto_id, 'defectuoso', v_row.defectuoso, 'cantidad', v_row.cantidad,
      'precio_unitario', COALESCE(v_row.precio, 0));
  END LOOP;

  -- ---- Lo que se lleva, a precio de lista actual ----
  IF p_items_nuevos IS NOT NULL AND jsonb_typeof(p_items_nuevos) = 'array' AND jsonb_array_length(p_items_nuevos) > 0 THEN
    FOR v_row IN
      SELECT (i->>'producto_id')::uuid AS producto_id, SUM((i->>'cantidad')::numeric) AS cantidad
      FROM jsonb_array_elements(p_items_nuevos) AS i GROUP BY 1
    LOOP
      IF v_row.cantidad IS NULL OR v_row.cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad del producto nuevo debe ser mayor a 0';
      END IF;
      SELECT precio_venta INTO v_precio FROM productos WHERE id = v_row.producto_id AND estado = 'activo';
      IF NOT FOUND THEN RAISE EXCEPTION 'Producto nuevo no encontrado o inactivo'; END IF;
      v_total_nuevo := v_total_nuevo + ROUND(v_row.cantidad * v_precio, 2);
      v_nuevos := v_nuevos || jsonb_build_object(
        'producto_id', v_row.producto_id, 'cantidad', v_row.cantidad, 'precio_unitario', v_precio);
    END LOOP;
  END IF;

  v_diferencia := ROUND(v_total_nuevo - v_total_devuelto, 2);

  -- ---- Resolución ----
  IF v_n = 1 THEN
    SELECT * INTO v_unica FROM ventas WHERE id = p_tickets[1];
  END IF;

  IF v_n = 1 AND v_unica.forma_pago = 'cuenta_corriente'
     AND (v_diferencia <= 0 OR p_forma_pago = 'cuenta_corriente') THEN
    -- docs/68 (D12): la diferencia va a la cuenta del cliente, sin plata.
    v_resolucion := 'cuenta_corriente';
    v_a_cuenta := true;
  ELSIF v_diferencia = 0 THEN
    v_resolucion := 'sin_diferencia';
  ELSIF v_diferencia > 0 THEN
    v_resolucion := 'cobro';
  ELSIF p_resolucion = 'a_favor' THEN
    IF p_nota_a_favor IS NULL OR btrim(p_nota_a_favor) = '' THEN
      RAISE EXCEPTION 'Con "Queda a favor" la nota es obligatoria';
    END IF;
    v_resolucion := 'a_favor';
  ELSE
    v_resolucion := 'reintegro';
  END IF;

  IF p_resolucion IS NOT NULL AND p_resolucion <> v_resolucion THEN
    RAISE EXCEPTION 'La diferencia cambió (ahora %): revisá el resumen y volvé a confirmar',
      CASE WHEN v_diferencia > 0 THEN 'el cliente paga ' || v_diferencia
           WHEN v_diferencia < 0 THEN 'a favor del cliente ' || -v_diferencia
           ELSE 'sin diferencia' END;
  END IF;

  -- ---- Forma de pago (solo cobro / reintegro) ----
  IF v_resolucion IN ('cobro', 'reintegro') THEN
    IF p_pagos IS NOT NULL AND jsonb_typeof(p_pagos) = 'array' AND jsonb_array_length(p_pagos) > 0 THEN
      IF jsonb_array_length(p_pagos) > 2 THEN
        RAISE EXCEPTION 'Un pago combinado admite hasta 2 medios de pago';
      END IF;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_pagos) AS p
                 WHERE (p->>'forma_pago') IN ('cuenta_corriente', 'combinado')) THEN
        RAISE EXCEPTION 'La diferencia no se puede saldar con cuenta corriente';
      END IF;
      SELECT COALESCE(SUM((p->>'monto')::numeric), 0) INTO v_suma_pagos FROM jsonb_array_elements(p_pagos) AS p;
      IF ABS(v_suma_pagos - ABS(v_diferencia)) > 0.01 THEN
        RAISE EXCEPTION 'La suma de los pagos (%) no coincide con la diferencia (%)', v_suma_pagos, ABS(v_diferencia);
      END IF;
      v_forma_final := CASE WHEN jsonb_array_length(p_pagos) = 1
        THEN (p_pagos->0->>'forma_pago')::forma_pago_venta ELSE 'combinado'::forma_pago_venta END;
    ELSE
      IF p_forma_pago IS NULL THEN
        RAISE EXCEPTION 'Elegí la forma de pago para saldar la diferencia';
      END IF;
      IF p_forma_pago IN ('cuenta_corriente', 'combinado') THEN
        RAISE EXCEPTION 'Forma de pago inválida para saldar la diferencia';
      END IF;
      v_forma_final := p_forma_pago;
    END IF;
  END IF;

  -- ---- Cabecera ----
  INSERT INTO devoluciones (venta_id, usuario_id, motivo, motivo_detalle, observaciones,
                            diferencia_monto, diferencia_forma_pago, a_cuenta_corriente,
                            resolucion, cantidad_tickets, total_devuelto, total_nuevo, nota_a_favor)
  VALUES (CASE WHEN v_n = 1 THEN p_tickets[1] END, auth.uid(), p_motivo,
          NULLIF(btrim(p_motivo_detalle), ''), NULLIF(btrim(p_observaciones), ''),
          v_diferencia, v_forma_final, v_a_cuenta,
          v_resolucion, v_n, v_total_devuelto, v_total_nuevo,
          CASE WHEN v_resolucion = 'a_favor' THEN btrim(p_nota_a_favor) END)
  RETURNING id, numero INTO v_dev_id, v_dev_numero;

  INSERT INTO devolucion_tickets (devolucion_id, venta_id, orden, total_devuelto)
  SELECT v_dev_id, t.id, t.ord,
         COALESCE((SELECT SUM(ROUND((l->>'cantidad')::numeric * (l->>'precio_unitario')::numeric, 2))
                   FROM jsonb_array_elements(v_lineas) AS l WHERE (l->>'venta_id')::uuid = t.id), 0)
  FROM unnest(p_tickets) WITH ORDINALITY AS t(id, ord);

  SELECT string_agg('#' || v.numero, ', ' ORDER BY t.ord) INTO v_tickets_txt
  FROM unnest(p_tickets) WITH ORDINALITY AS t(id, ord) JOIN ventas v ON v.id = t.id;

  -- ---- Pagos (monto siempre positivo; el sentido lo da el signo de diferencia_monto) ----
  IF v_resolucion IN ('cobro', 'reintegro') THEN
    IF p_pagos IS NOT NULL AND jsonb_typeof(p_pagos) = 'array' AND jsonb_array_length(p_pagos) > 0 THEN
      FOR v_pago IN SELECT * FROM jsonb_array_elements(p_pagos) LOOP
        v_idx := v_idx + 1;
        IF v_idx = jsonb_array_length(p_pagos) THEN
          v_monto := ABS(v_diferencia) - v_suma_asignada;   -- la última parte absorbe el centavo
        ELSE
          v_monto := ROUND((v_pago->>'monto')::numeric, 2);
          v_suma_asignada := v_suma_asignada + v_monto;
        END IF;
        INSERT INTO devolucion_pagos (devolucion_id, forma_pago, monto)
        VALUES (v_dev_id, (v_pago->>'forma_pago')::forma_pago_venta, v_monto);
      END LOOP;
    ELSE
      INSERT INTO devolucion_pagos (devolucion_id, forma_pago, monto)
      VALUES (v_dev_id, v_forma_final, ABS(v_diferencia));
    END IF;
  END IF;

  -- ---- Ítems devueltos: + stock local salvo defectuoso ----
  FOR v_item IN SELECT * FROM jsonb_array_elements(v_lineas) LOOP
    SELECT nombre, marca INTO v_nombre, v_marca FROM productos WHERE id = (v_item->>'producto_id')::uuid;  -- docs/42
    INSERT INTO devolucion_items (devolucion_id, tipo, producto_id, cantidad, precio_unitario, reingresa_stock,
                                  defectuoso, producto_nombre, producto_marca, venta_id, venta_item_id)
    VALUES (v_dev_id, 'devuelto', (v_item->>'producto_id')::uuid, (v_item->>'cantidad')::numeric,
            (v_item->>'precio_unitario')::numeric, NOT (v_item->>'defectuoso')::boolean,
            (v_item->>'defectuoso')::boolean, v_nombre, v_marca,
            (v_item->>'venta_id')::uuid, (v_item->>'venta_item_id')::uuid);

    IF NOT (v_item->>'defectuoso')::boolean THEN
      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id, origen)
      VALUES ((v_item->>'producto_id')::uuid, 'local', 'ajuste', (v_item->>'cantidad')::numeric,
              'Devolución de venta #' || (v_item->>'numero') || ' (' || p_motivo::text || ')'
                || CASE WHEN v_n > 1 THEN ' · devolución #' || v_dev_numero ELSE '' END,
              v_dev_id, auth.uid(), 'devolucion_cliente');
      INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
      VALUES ((v_item->>'producto_id')::uuid, 'local', (v_item->>'cantidad')::numeric)
      ON CONFLICT (producto_id, ubicacion)
      DO UPDATE SET cantidad = stock_ubicaciones.cantidad + EXCLUDED.cantidad;
    END IF;
  END LOOP;

  -- ---- Lo que se lleva: − stock local ----
  FOR v_item IN SELECT * FROM jsonb_array_elements(v_nuevos) LOOP
    SELECT nombre, marca INTO v_nombre, v_marca FROM productos WHERE id = (v_item->>'producto_id')::uuid;
    INSERT INTO devolucion_items (devolucion_id, tipo, producto_id, cantidad, precio_unitario, reingresa_stock,
                                  defectuoso, producto_nombre, producto_marca)
    VALUES (v_dev_id, 'nuevo', (v_item->>'producto_id')::uuid, (v_item->>'cantidad')::numeric,
            (v_item->>'precio_unitario')::numeric, true, false, v_nombre, v_marca);

    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id, origen)
    VALUES ((v_item->>'producto_id')::uuid, 'local', 'ajuste', -1 * (v_item->>'cantidad')::numeric,
            CASE WHEN v_n = 1 THEN 'Cambio sobre venta ' || v_tickets_txt
                 ELSE 'Cambio sobre ventas ' || v_tickets_txt || ' · devolución #' || v_dev_numero END,
            v_dev_id, auth.uid(), 'cambio_entrega');
    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES ((v_item->>'producto_id')::uuid, 'local', -1 * (v_item->>'cantidad')::numeric)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad + EXCLUDED.cantidad;
  END LOOP;

  RETURN jsonb_build_object(
    'devolucion_id', v_dev_id,
    'numero', v_dev_numero,
    'total_devuelto', v_total_devuelto,
    'total_nuevo', v_total_nuevo,
    'diferencia', v_diferencia,
    'resolucion', v_resolucion,
    'tickets', (SELECT jsonb_agg(jsonb_build_object('venta_id', dt.venta_id, 'numero', v.numero,
                                                    'orden', dt.orden, 'total_devuelto', dt.total_devuelto)
                                 ORDER BY dt.orden)
                FROM devolucion_tickets dt JOIN ventas v ON v.id = dt.venta_id WHERE dt.devolucion_id = v_dev_id));
END;
$$;
REVOKE ALL ON FUNCTION public.crear_devolucion_tickets(uuid[], motivo_devolucion, text, text, jsonb, jsonb, resolucion_devolucion, forma_pago_venta, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crear_devolucion_tickets(uuid[], motivo_devolucion, text, text, jsonb, jsonb, resolucion_devolucion, forma_pago_venta, jsonb, text) TO authenticated, service_role;
COMMENT ON FUNCTION public.crear_devolucion_tickets(uuid[], motivo_devolucion, text, text, jsonb, jsonb, resolucion_devolucion, forma_pago_venta, jsonb, text) IS
  'docs/74: devolución/cambio sobre 1 a 3 tickets, por línea de venta, todo o nada. Devuelve {devolucion_id, numero, total_devuelto, total_nuevo, diferencia, resolucion, tickets[]}.';

-- ── 9. crear_devolucion (vieja): misma firma, por producto → reparte en líneas y delega ─────────────
CREATE OR REPLACE FUNCTION public.crear_devolucion(p_venta_id uuid, p_motivo motivo_devolucion, p_motivo_detalle text, p_observaciones text, p_items_devueltos jsonb, p_items_nuevos jsonb DEFAULT NULL::jsonb, p_forma_pago forma_pago_venta DEFAULT NULL::forma_pago_venta, p_pagos jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'America/Argentina/Buenos_Aires'
AS $$
DECLARE
  v_row RECORD;
  v_linea RECORD;
  v_resto numeric;
  v_toma numeric;
  v_vendida numeric;
  v_devuelta numeric;
  v_nombre text;
  v_items jsonb := '[]'::jsonb;
  v_res jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  -- El reparto lee lo disponible: se bloquea la venta antes (crear_devolucion_tickets la vuelve a
  -- bloquear en la misma transacción, sin efecto).
  PERFORM 1 FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Venta no encontrada'; END IF;

  IF p_items_devueltos IS NULL OR jsonb_typeof(p_items_devueltos) <> 'array' OR jsonb_array_length(p_items_devueltos) = 0 THEN
    RAISE EXCEPTION 'Elegí al menos un producto para devolver';
  END IF;

  FOR v_row IN
    SELECT (i->>'producto_id')::uuid AS producto_id, SUM((i->>'cantidad')::numeric) AS cantidad
    FROM jsonb_array_elements(p_items_devueltos) AS i GROUP BY 1
  LOOP
    IF v_row.cantidad IS NULL OR v_row.cantidad <= 0 THEN
      RAISE EXCEPTION 'La cantidad a devolver debe ser mayor a 0';
    END IF;
    SELECT nombre INTO v_nombre FROM productos WHERE id = v_row.producto_id;
    SELECT COALESCE(SUM(cantidad), 0) INTO v_vendida
    FROM venta_items WHERE venta_id = p_venta_id AND producto_id = v_row.producto_id;
    IF v_vendida = 0 THEN
      RAISE EXCEPTION 'El producto "%" no forma parte de esta venta', COALESCE(v_nombre, v_row.producto_id::text);
    END IF;
    SELECT COALESCE(SUM(di.cantidad), 0) INTO v_devuelta
    FROM devolucion_items di JOIN devoluciones d ON d.id = di.devolucion_id
    WHERE di.venta_id = p_venta_id AND di.producto_id = v_row.producto_id
      AND di.tipo = 'devuelto' AND d.estado = 'activa';
    IF v_row.cantidad > v_vendida - v_devuelta THEN
      RAISE EXCEPTION 'No se puede devolver % de "%": solo quedan % disponibles (vendidas %, ya devueltas %)',
        v_row.cantidad, v_nombre, v_vendida - v_devuelta, v_vendida, v_devuelta;
    END IF;

    -- Reparto entre las líneas del producto con unidades disponibles (orden de id: determinístico).
    v_resto := v_row.cantidad;
    FOR v_linea IN
      SELECT vi.id, vi.cantidad - COALESCE((SELECT SUM(di.cantidad) FROM devolucion_items di
                                            JOIN devoluciones d ON d.id = di.devolucion_id
                                            WHERE di.venta_item_id = vi.id AND d.estado = 'activa'), 0) AS disponible
      FROM venta_items vi
      WHERE vi.venta_id = p_venta_id AND vi.producto_id = v_row.producto_id
      ORDER BY vi.id
    LOOP
      EXIT WHEN v_resto <= 0;
      CONTINUE WHEN v_linea.disponible <= 0;
      v_toma := LEAST(v_resto, v_linea.disponible);
      v_items := v_items || jsonb_build_object('venta_item_id', v_linea.id, 'cantidad', v_toma,
                                               'defectuoso', p_motivo = 'defectuoso');
      v_resto := v_resto - v_toma;
    END LOOP;
    IF v_resto > 0 THEN
      RAISE EXCEPTION 'No se puede devolver % de "%": solo quedan % disponibles',
        v_row.cantidad, v_nombre, v_row.cantidad - v_resto;
    END IF;
  END LOOP;

  v_res := crear_devolucion_tickets(ARRAY[p_venta_id], p_motivo, p_motivo_detalle, p_observaciones,
                                    v_items, p_items_nuevos, NULL, p_forma_pago, p_pagos, NULL);
  RETURN (v_res->>'devolucion_id')::uuid;
END;
$$;

-- ── 10. anular_venta: no con devoluciones activas ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.anular_venta(p_venta_id uuid, p_motivo text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_venta ventas%ROWTYPE;
  v_item RECORD;
  v_devs text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede anular una venta';
  END IF;
  IF p_motivo IS NULL OR trim(p_motivo) = '' THEN
    RAISE EXCEPTION 'El motivo es obligatorio para anular una venta';
  END IF;

  -- docs/74: FOR UPDATE serializa con crear_devolucion*, que bloquea el mismo ticket.
  SELECT * INTO v_venta FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Venta no encontrada'; END IF;
  IF v_venta.estado = 'anulada' THEN RAISE EXCEPTION 'Esta venta ya está anulada'; END IF;
  IF EXISTS (SELECT 1 FROM facturas_c WHERE venta_id = p_venta_id) THEN
    RAISE EXCEPTION 'Esta venta ya tiene Factura C emitida — no es reversible desde el sistema (límite conocido de Fase 1, ver docs)';
  END IF;
  -- docs/74: con una devolución activa, reponer todo lo vendido duplicaría el stock que la devolución ya
  -- reingresó. Primero se anula la devolución (revierte su stock), después la venta.
  SELECT string_agg('N° ' || d.numero, ', ' ORDER BY d.numero) INTO v_devs
  FROM devolucion_tickets dt JOIN devoluciones d ON d.id = dt.devolucion_id
  WHERE dt.venta_id = p_venta_id AND d.estado = 'activa';
  IF v_devs IS NOT NULL THEN
    RAISE EXCEPTION 'Este ticket está en una devolución activa (%): anulá la devolución antes de anular la venta', v_devs;
  END IF;

  FOR v_item IN SELECT * FROM venta_items WHERE venta_id = p_venta_id LOOP
    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id, origen)  -- docs/70: origen
    VALUES (v_item.producto_id, 'local', 'ajuste', v_item.cantidad,
            'Reposición por anulación de venta: ' || p_motivo, p_venta_id, auth.uid(), 'anulacion_venta');

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

-- ── 11. cerrar_caja: + saldos a favor del día (informativo) ────────────────────────────────────────
-- Copia de la versión vigente (docs/68) + v_cant_a_favor / v_total_a_favor. efectivo_esperado no cambia.
CREATE OR REPLACE FUNCTION public.cerrar_caja(p_tipo tipo_cierre, p_efectivo_contado numeric DEFAULT NULL::numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'America/Argentina/Buenos_Aires'
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
  v_cob_efectivo NUMERIC;       -- docs/68
  v_cob_transferencia NUMERIC;  -- docs/68
  v_cob_qr NUMERIC;             -- docs/68
  v_cob_tarjeta NUMERIC;        -- docs/68
  v_cant_cobros INT;            -- docs/68
  v_cant_a_favor INT;           -- docs/74
  v_total_a_favor NUMERIC;      -- docs/74
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

  -- docs/74: saldos a favor (vale manual). Informativo: no tienen pagos y no tocan efectivo_esperado.
  SELECT COUNT(*), COALESCE(SUM(-diferencia_monto), 0) INTO v_cant_a_favor, v_total_a_favor
  FROM devoluciones WHERE fecha = current_date AND estado = 'activa' AND resolucion = 'a_favor';

  -- docs/68 (D13): cobros de cuenta corriente hechos en la caja de Local hoy (las reversiones,
  -- con medios negativos, restan el día en que se hacen, igual que los egresos).
  SELECT COALESCE(SUM(m.monto) FILTER (WHERE m.forma_pago = 'efectivo'), 0),
         COALESCE(SUM(m.monto) FILTER (WHERE m.forma_pago = 'transferencia'), 0),
         COALESCE(SUM(m.monto) FILTER (WHERE m.forma_pago = 'qr'), 0),
         COALESCE(SUM(m.monto) FILTER (WHERE m.forma_pago IN ('tarjeta_debito','tarjeta_credito')), 0),
         COUNT(DISTINCT pc.id) FILTER (WHERE pc.revierte_pago_cliente_id IS NULL)
  INTO v_cob_efectivo, v_cob_transferencia, v_cob_qr, v_cob_tarjeta, v_cant_cobros
  FROM pagos_cliente pc
  JOIN pagos_cliente_medios m ON m.pago_cliente_id = pc.id
  WHERE pc.origen = 'turno' AND pc.created_at::date = current_date;

  -- docs/31: solo egresos de la caja de Local (origen 'turno'); los de Gestión ('general') no.
  SELECT COALESCE(SUM(monto), 0) INTO v_total_egresos
  FROM egresos WHERE created_at::date = current_date AND origen = 'turno';

  SELECT COALESCE(SUM(monto), 0) INTO v_total_egresos_efectivo
  FROM egresos WHERE created_at::date = current_date AND origen = 'turno' AND forma_pago = 'efectivo';

  SELECT COALESCE(SUM(monto), 0) INTO v_total_retiros
  FROM retiros_caja WHERE fecha = current_date;

  v_efectivo_esperado := v_monto_base + v_total_efectivo + v_dev_efectivo + v_cob_efectivo
                         - v_total_egresos_efectivo - v_total_retiros;
  v_diferencia := CASE WHEN p_efectivo_contado IS NOT NULL THEN p_efectivo_contado - v_efectivo_esperado ELSE NULL END;

  INSERT INTO cierres_caja (tipo, turno_fecha, total_efectivo, total_transferencia, total_qr, total_tarjeta,
         total_cuenta_corriente, total_egresos, total_retiros, efectivo_esperado, efectivo_contado, diferencia,
         estado_validacion, usuario_id, apertura_id,
         cantidad_devoluciones, total_devoluciones_efectivo, total_devoluciones_transferencia,
         total_devoluciones_qr, total_devoluciones_tarjeta,
         cantidad_cobros, total_cobros_efectivo, total_cobros_transferencia, total_cobros_qr, total_cobros_tarjeta,
         cantidad_saldos_a_favor, total_saldos_a_favor)
  VALUES (p_tipo, current_date, v_total_efectivo, v_total_transferencia, v_total_qr, v_total_tarjeta,
         v_total_cuenta_corriente, v_total_egresos, v_total_retiros, v_efectivo_esperado, p_efectivo_contado, v_diferencia,
         CASE WHEN p_tipo = 'z' THEN 'pendiente_validacion'::estado_cierre_z ELSE NULL END, auth.uid(), v_apertura.id,
         v_cant_devoluciones, v_dev_efectivo, v_dev_transferencia, v_dev_qr, v_dev_tarjeta,
         v_cant_cobros, v_cob_efectivo, v_cob_transferencia, v_cob_qr, v_cob_tarjeta,
         v_cant_a_favor, v_total_a_favor)
  RETURNING id INTO v_cierre_id;

  IF p_tipo = 'z' AND v_apertura.id IS NOT NULL THEN
    UPDATE aperturas_caja SET cierre_z_id = v_cierre_id WHERE id = v_apertura.id;
  END IF;

  RETURN v_cierre_id;
END;
$$;

-- ── 12. dashboard_ventas_por_producto: internas por el ticket de cada línea ────────────────────────
CREATE OR REPLACE FUNCTION public.dashboard_ventas_por_producto(p_desde date, p_hasta date, p_ant_desde date DEFAULT NULL::date, p_ant_hasta date DEFAULT NULL::date)
 RETURNS TABLE(producto_id uuid, nombre text, marca text, unidades numeric, importe numeric, stock_actual numeric, stock_minimo numeric, unidades_periodo_anterior numeric, importe_periodo_anterior numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  WITH lim AS (
    SELECT p_desde AS d1, p_hasta AS h1,
           COALESCE(p_ant_desde, p_desde - (p_hasta - p_desde + 1)) AS d0,
           COALESCE(p_ant_hasta, p_desde - 1) AS h0
  ),
  rango AS (SELECT LEAST(d0, d1) AS desde, GREATEST(h0, h1) AS hasta FROM lim),
  vendidos AS (
    SELECT vi.producto_id,
           (v.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS dia,
           vi.cantidad,
           -- Prorrateo: la venta se cobró precio_cobrado (con descuento/recargo); cada ítem se lleva
           -- su parte según su importe de lista.
           COALESCE(vi.importe * v.precio_cobrado / NULLIF(SUM(vi.importe) OVER (PARTITION BY v.id), 0), 0) AS importe
    FROM ventas v
    JOIN venta_items vi ON vi.venta_id = v.id
    CROSS JOIN rango r
    WHERE v.estado <> 'anulada'
      AND v.estado_interno IS NULL  -- docs/68 (D8)
      AND v.created_at >= (r.desde::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires')
      AND v.created_at <  ((r.hasta + 1)::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires')
  ),
  devueltos AS (
    SELECT di.producto_id,
           d.fecha AS dia,
           CASE WHEN di.tipo = 'devuelto' THEN -di.cantidad ELSE di.cantidad END AS cantidad,
           CASE WHEN di.tipo = 'devuelto' THEN -1 ELSE 1 END * di.cantidad * di.precio_unitario AS importe
    FROM devoluciones d
    JOIN devolucion_items di ON di.devolucion_id = d.id
    CROSS JOIN rango r
    WHERE d.estado = 'activa' AND d.fecha BETWEEN r.desde AND r.hasta
      -- docs/68 (D8) + docs/74: lo devuelto, por el ticket de su línea; lo nuevo, fuera si algún ticket
      -- de la devolución es interno.
      AND NOT EXISTS (
        SELECT 1 FROM devolucion_tickets dt JOIN ventas vd ON vd.id = dt.venta_id
        WHERE dt.devolucion_id = d.id AND vd.estado_interno IS NOT NULL
          AND (di.tipo = 'nuevo' OR dt.venta_id = di.venta_id))
  ),
  movs AS (SELECT * FROM vendidos UNION ALL SELECT * FROM devueltos),
  por_producto AS (
    SELECT m.producto_id,
           SUM(m.cantidad) FILTER (WHERE m.dia BETWEEN l.d1 AND l.h1) AS unidades,
           SUM(m.importe)  FILTER (WHERE m.dia BETWEEN l.d1 AND l.h1) AS importe,
           SUM(m.cantidad) FILTER (WHERE m.dia BETWEEN l.d0 AND l.h0) AS unidades_ant,
           SUM(m.importe)  FILTER (WHERE m.dia BETWEEN l.d0 AND l.h0) AS importe_ant,
           bool_or(m.dia BETWEEN l.d1 AND l.h1) AS en_periodo
    FROM movs m CROSS JOIN lim l
    GROUP BY m.producto_id
  )
  SELECT pp.producto_id, p.nombre, p.marca,
         COALESCE(pp.unidades, 0), round(COALESCE(pp.importe, 0), 2),
         COALESCE((SELECT SUM(s.cantidad) FROM stock_ubicaciones s WHERE s.producto_id = pp.producto_id), 0),
         p.stock_minimo,
         COALESCE(pp.unidades_ant, 0), round(COALESCE(pp.importe_ant, 0), 2)
  FROM por_producto pp
  JOIN productos p ON p.id = pp.producto_id
  WHERE pp.en_periodo
  ORDER BY 5 DESC, 4 DESC, p.nombre;
$$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (solo lee). Todo en una fila: los contadores deben dar 0 y los booleanos true.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
SELECT jsonb_build_object(
  'devoluciones', (SELECT count(*) FROM devoluciones),
  'sin_tickets', (SELECT count(*) FROM devoluciones d WHERE NOT EXISTS (SELECT 1 FROM devolucion_tickets dt WHERE dt.devolucion_id = d.id)),
  'cantidad_tickets_distinta', (SELECT count(*) FROM devoluciones d
      WHERE d.cantidad_tickets <> (SELECT count(*) FROM devolucion_tickets dt WHERE dt.devolucion_id = d.id)),
  'ticket_sin_lineas', (SELECT count(*) FROM devolucion_tickets dt
      WHERE NOT EXISTS (SELECT 1 FROM devolucion_items di WHERE di.devolucion_id = dt.devolucion_id AND di.venta_id = dt.venta_id)),
  'total_tickets_distinto', (SELECT count(*) FROM devoluciones d
      WHERE d.total_devuelto <> (SELECT COALESCE(SUM(dt.total_devuelto), 0) FROM devolucion_tickets dt WHERE dt.devolucion_id = d.id)),
  'devueltos_sin_ticket', (SELECT count(*) FROM devolucion_items WHERE tipo = 'devuelto' AND venta_id IS NULL),
  'devueltos_sin_linea', (SELECT count(*) FROM devolucion_items WHERE tipo = 'devuelto' AND venta_item_id IS NULL),
  'defectuoso_incoherente', (SELECT count(*) FROM devolucion_items WHERE reingresa_stock = defectuoso),
  'diferencia_incoherente', (SELECT count(*) FROM devoluciones WHERE diferencia_monto <> total_nuevo - total_devuelto),
  'anon_sin_execute', NOT has_function_privilege('anon', 'public.crear_devolucion_tickets(uuid[], motivo_devolucion, text, text, jsonb, jsonb, resolucion_devolucion, forma_pago_venta, jsonb, text)', 'EXECUTE'),
  'tickets_rls', (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.devolucion_tickets'::regclass),
  'tickets_acl', (SELECT relacl::text FROM pg_class WHERE oid = 'public.devolucion_tickets'::regclass)
) AS r;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (BEGIN … ROLLBACK). SOLO en la restauración local (restaurar-prueba.ps1): llama a
-- confirmar_venta / crear_devolucion*, que consumen numeración aunque se haga ROLLBACK. Nunca en prod.
-- psql -v ON_ERROR_STOP=1: cualquier ASSERT que falle corta. Cada test imprime "OK Tn".
-- ════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- La restauración no trae privilegios: se replican los de Supabase para `authenticated` (la RLS decide),
-- solo dentro de esta transacción.
GRANT USAGE ON SCHEMA public, auth TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public, auth TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON devolucion_tickets FROM authenticated;

-- Productos con precio y stock para armar ventas; un cliente externo para la venta a cta. cte.
CREATE TEMP TABLE t_ctx ON COMMIT DROP AS
SELECT (SELECT id FROM perfiles WHERE rol = 'admin' AND activo ORDER BY created_at LIMIT 1) AS admin_id,
       (SELECT id FROM perfiles WHERE rol = 'cajero' AND activo ORDER BY created_at LIMIT 1) AS cajero_id,
       (SELECT array_agg(id ORDER BY id) FROM (SELECT id FROM productos WHERE estado = 'activo' AND precio_venta > 0
                                              ORDER BY id LIMIT 4) x) AS prods,
       (SELECT id FROM clientes WHERE tipo = 'externo' ORDER BY created_at LIMIT 1) AS cliente_id;
CREATE TEMP TABLE t_ids (k text PRIMARY KEY, v uuid) ON COMMIT DROP;
GRANT SELECT ON t_ctx TO authenticated;
GRANT SELECT, INSERT, UPDATE ON t_ids TO authenticated;

-- Helpers (pg_temp: desaparecen con la sesión).
CREATE FUNCTION pg_temp.stock(p uuid) RETURNS numeric LANGUAGE sql AS
  $f$ SELECT COALESCE(SUM(cantidad), 0) FROM stock_ubicaciones WHERE producto_id = p AND ubicacion = 'local' $f$;
-- Venta de 1 o 2 productos, 2 unidades c/u, al precio de lista.
CREATE FUNCTION pg_temp.venta(p1 uuid, p2 uuid DEFAULT NULL, p_forma forma_pago_venta DEFAULT 'efectivo', p_cliente uuid DEFAULT NULL) RETURNS uuid LANGUAGE sql AS $f$
  SELECT confirmar_venta(p_cliente, p_forma,
    (SELECT jsonb_agg(jsonb_build_object('producto_id', p.id, 'cantidad', 2, 'precio_unitario', p.precio_venta))
     FROM productos p WHERE p.id IN (p1, p2)))
$f$;
CREATE FUNCTION pg_temp.linea(v uuid, p uuid) RETURNS uuid LANGUAGE sql AS
  $f$ SELECT id FROM venta_items WHERE venta_id = v AND producto_id = p ORDER BY id LIMIT 1 $f$;
-- Espera un error que contenga `esperado`.
CREATE FUNCTION pg_temp.falla(sql text, esperado text) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  EXECUTE sql;
  RAISE EXCEPTION 'NO FALLO (esperaba "%")', esperado;
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM LIKE 'NO FALLO%' OR SQLERRM NOT ILIKE '%' || esperado || '%' THEN
    RAISE EXCEPTION 'Error inesperado: % (esperaba "%")', SQLERRM, esperado;
  END IF;
END $f$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', cajero_id, 'role', 'authenticated')::text, true) FROM t_ctx;

-- T1: 1 ticket, cambio justo (devuelve 1 de A, se lleva 1 de A) → sin_diferencia, sin pagos.
DO $$
DECLARE c t_ctx; v uuid; r jsonb; d devoluciones;
BEGIN
  SELECT * INTO c FROM t_ctx;
  v := pg_temp.venta(c.prods[1]);
  r := crear_devolucion_tickets(ARRAY[v], 'arrepentimiento', NULL, NULL,
         jsonb_build_array(jsonb_build_object('venta_item_id', pg_temp.linea(v, c.prods[1]), 'cantidad', 1)),
         jsonb_build_array(jsonb_build_object('producto_id', c.prods[1], 'cantidad', 1)));
  SELECT * INTO d FROM devoluciones WHERE id = (r->>'devolucion_id')::uuid;
  ASSERT d.resolucion = 'sin_diferencia' AND d.diferencia_monto = 0 AND d.venta_id = v AND d.cantidad_tickets = 1,
    'T1 ' || row_to_json(d)::text;
  ASSERT NOT EXISTS (SELECT 1 FROM devolucion_pagos WHERE devolucion_id = d.id), 'T1 pagos';
  RAISE NOTICE 'OK T1 1 ticket, cambio justo → sin_diferencia';
END $$;

-- T2: 3 tickets → se lleva algo más caro → cobro (efectivo). Totales por ticket y stock.
DO $$
DECLARE c t_ctx; v1 uuid; v2 uuid; v3 uuid; r jsonb; d devoluciones; s0 numeric; p4 numeric;
BEGIN
  SELECT * INTO c FROM t_ctx;
  v1 := pg_temp.venta(c.prods[1]); v2 := pg_temp.venta(c.prods[2]); v3 := pg_temp.venta(c.prods[3]);
  s0 := pg_temp.stock(c.prods[1]);
  SELECT precio_venta INTO p4 FROM productos WHERE id = c.prods[4];
  r := crear_devolucion_tickets(ARRAY[v1, v2, v3], 'regalo', NULL, NULL,
         jsonb_build_array(
           jsonb_build_object('venta_item_id', pg_temp.linea(v1, c.prods[1]), 'cantidad', 1),
           jsonb_build_object('venta_item_id', pg_temp.linea(v2, c.prods[2]), 'cantidad', 1),
           jsonb_build_object('venta_item_id', pg_temp.linea(v3, c.prods[3]), 'cantidad', 1)),
         jsonb_build_array(jsonb_build_object('producto_id', c.prods[4],
           'cantidad', ceil(((SELECT sum(precio_venta) FROM productos WHERE id = ANY(c.prods[1:3])) + 1) / p4))),
         'cobro', 'efectivo');
  SELECT * INTO d FROM devoluciones WHERE id = (r->>'devolucion_id')::uuid;
  ASSERT d.resolucion = 'cobro' AND d.diferencia_monto > 0 AND d.venta_id IS NULL AND d.cantidad_tickets = 3, 'T2 cabecera';
  ASSERT (SELECT count(*) FROM devolucion_tickets WHERE devolucion_id = d.id) = 3, 'T2 puente';
  ASSERT (SELECT array_agg(orden ORDER BY orden) FROM devolucion_tickets WHERE devolucion_id = d.id) = ARRAY[1,2,3]::smallint[], 'T2 orden';
  ASSERT d.total_devuelto = (SELECT sum(total_devuelto) FROM devolucion_tickets WHERE devolucion_id = d.id), 'T2 totales';
  ASSERT (SELECT sum(monto) FROM devolucion_pagos WHERE devolucion_id = d.id) = d.diferencia_monto, 'T2 pago';
  ASSERT pg_temp.stock(c.prods[1]) = s0 + 1, 'T2 stock devuelto';
  ASSERT (SELECT count(*) FROM devolucion_items WHERE devolucion_id = d.id AND tipo = 'devuelto' AND venta_item_id IS NOT NULL) = 3, 'T2 líneas';
  INSERT INTO t_ids VALUES ('t2', d.id), ('t2v2', v2);
  RAISE NOTICE 'OK T2 3 tickets → cobro % (tickets %)', d.diferencia_monto, r->'tickets';
END $$;

-- T3: 2 tickets → se lleva menos → "Queda a favor" con nota → sin pagos; cierre X: línea informativa,
-- netos de devoluciones y efectivo esperado sin ese monto.
DO $$
DECLARE c t_ctx; v1 uuid; v2 uuid; r jsonb; d devoluciones; x cierres_caja; x0 cierres_caja; cid uuid;
BEGIN
  SELECT * INTO c FROM t_ctx;
  cid := cerrar_caja('x'); SELECT * INTO x0 FROM cierres_caja WHERE id = cid;
  v1 := pg_temp.venta(c.prods[1]); v2 := pg_temp.venta(c.prods[2]);
  PERFORM pg_temp.falla(format($s$SELECT crear_devolucion_tickets(ARRAY[%L,%L]::uuid[], 'regalo', NULL, NULL,
      jsonb_build_array(jsonb_build_object('venta_item_id', %L, 'cantidad', 1), jsonb_build_object('venta_item_id', %L, 'cantidad', 1)),
      NULL, 'a_favor', NULL, NULL, '  ')$s$, v1, v2, pg_temp.linea(v1, c.prods[1]), pg_temp.linea(v2, c.prods[2])),
    'la nota es obligatoria');
  r := crear_devolucion_tickets(ARRAY[v1, v2], 'regalo', NULL, NULL,
         jsonb_build_array(
           jsonb_build_object('venta_item_id', pg_temp.linea(v1, c.prods[1]), 'cantidad', 1),
           jsonb_build_object('venta_item_id', pg_temp.linea(v2, c.prods[2]), 'cantidad', 1)),
         NULL, 'a_favor', NULL, NULL, 'Vale manual a nombre de Pérez');
  SELECT * INTO d FROM devoluciones WHERE id = (r->>'devolucion_id')::uuid;
  ASSERT d.resolucion = 'a_favor' AND d.diferencia_monto < 0 AND d.diferencia_forma_pago IS NULL, 'T3 cabecera';
  ASSERT d.nota_a_favor = 'Vale manual a nombre de Perez', 'T3 nota sin acentos: ' || d.nota_a_favor;
  ASSERT NOT EXISTS (SELECT 1 FROM devolucion_pagos WHERE devolucion_id = d.id), 'T3 pagos';
  cid := cerrar_caja('x'); SELECT * INTO x FROM cierres_caja WHERE id = cid;
  ASSERT x.cantidad_saldos_a_favor = x0.cantidad_saldos_a_favor + 1
     AND x.total_saldos_a_favor = x0.total_saldos_a_favor - d.diferencia_monto, 'T3 cierre a favor';
  ASSERT x.total_devoluciones_efectivo = x0.total_devoluciones_efectivo, 'T3 netos de devoluciones';
  ASSERT x.efectivo_esperado - x0.efectivo_esperado = x.total_efectivo - x0.total_efectivo, 'T3 efectivo esperado';
  RAISE NOTICE 'OK T3 a favor %, cierre X con línea informativa (% / %)', -d.diferencia_monto, x.cantidad_saldos_a_favor, x.total_saldos_a_favor;
END $$;

-- T4: igual con "Devolver la plata" → reintegro; el cierre resta el efectivo.
DO $$
DECLARE c t_ctx; v1 uuid; v2 uuid; r jsonb; d devoluciones; x cierres_caja; x0 cierres_caja; cid uuid;
BEGIN
  SELECT * INTO c FROM t_ctx;
  v1 := pg_temp.venta(c.prods[1]); v2 := pg_temp.venta(c.prods[2]);
  cid := cerrar_caja('x'); SELECT * INTO x0 FROM cierres_caja WHERE id = cid;
  r := crear_devolucion_tickets(ARRAY[v1, v2], 'regalo', NULL, NULL,
         jsonb_build_array(
           jsonb_build_object('venta_item_id', pg_temp.linea(v1, c.prods[1]), 'cantidad', 1),
           jsonb_build_object('venta_item_id', pg_temp.linea(v2, c.prods[2]), 'cantidad', 1)),
         NULL, 'reintegro', 'efectivo');
  SELECT * INTO d FROM devoluciones WHERE id = (r->>'devolucion_id')::uuid;
  ASSERT d.resolucion = 'reintegro' AND d.diferencia_forma_pago = 'efectivo', 'T4 cabecera';
  cid := cerrar_caja('x'); SELECT * INTO x FROM cierres_caja WHERE id = cid;
  ASSERT x.total_devoluciones_efectivo = x0.total_devoluciones_efectivo + d.diferencia_monto, 'T4 neto efectivo';
  ASSERT x.efectivo_esperado = x0.efectivo_esperado + d.diferencia_monto, 'T4 efectivo esperado';
  ASSERT x.cantidad_saldos_a_favor = x0.cantidad_saldos_a_favor, 'T4 no es a favor';
  RAISE NOTICE 'OK T4 reintegro %', d.diferencia_monto;
END $$;

-- T5: repetido, vencido, anulado, ya devuelto completo, 4 tickets, ticket sin líneas → rechazados.
DO $$
DECLARE c t_ctx; v1 uuid; v2 uuid; v3 uuid; l1 uuid;
BEGIN
  SELECT * INTO c FROM t_ctx;
  v1 := pg_temp.venta(c.prods[1]); l1 := pg_temp.linea(v1, c.prods[1]);
  PERFORM pg_temp.falla(format($s$SELECT crear_devolucion_tickets(ARRAY[%L,%L]::uuid[], 'regalo', NULL, NULL,
      jsonb_build_array(jsonb_build_object('venta_item_id', %L, 'cantidad', 1)))$s$, v1, v1, l1), 'repetido');
  v2 := pg_temp.venta(c.prods[2]);
  INSERT INTO t_ids VALUES ('vencida', v2);
  v3 := pg_temp.venta(c.prods[3]);
  INSERT INTO t_ids VALUES ('anulada', v3);
  PERFORM crear_devolucion_tickets(ARRAY[v1], 'regalo', NULL, NULL,
      jsonb_build_array(jsonb_build_object('venta_item_id', l1, 'cantidad', 2)), NULL, 'reintegro', 'efectivo');
  PERFORM pg_temp.falla(format($s$SELECT crear_devolucion_tickets(ARRAY[%L]::uuid[], 'regalo', NULL, NULL,
      jsonb_build_array(jsonb_build_object('venta_item_id', %L, 'cantidad', 1)))$s$, v1, l1), 'solo quedan 0');
  PERFORM pg_temp.falla(format($s$SELECT crear_devolucion_tickets(ARRAY[%L,%L,%L,%L]::uuid[], 'regalo', NULL, NULL, '[]')$s$,
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid()), 'hasta 3 tickets');
  PERFORM pg_temp.falla(format($s$SELECT crear_devolucion_tickets(ARRAY[%L,%L]::uuid[], 'regalo', NULL, NULL,
      jsonb_build_array(jsonb_build_object('venta_item_id', %L, 'cantidad', 1)))$s$,
      v2, v3, pg_temp.linea(v2, c.prods[2])), 'no tiene productos para devolver');
  RAISE NOTICE 'OK T5a repetido, devuelto completo, 4 tickets, ticket sin líneas';
END $$;
-- vencido / anulado: se tocan las ventas como superusuario (simula el paso del tiempo / una anulación).
RESET ROLE;
UPDATE ventas SET created_at = now() - interval '20 days' WHERE id = (SELECT v FROM t_ids WHERE k = 'vencida');
UPDATE ventas SET estado = 'anulada' WHERE id = (SELECT v FROM t_ids WHERE k = 'anulada');
SET LOCAL ROLE authenticated;
DO $$
DECLARE c t_ctx; v2 uuid := (SELECT v FROM t_ids WHERE k = 'vencida'); v3 uuid := (SELECT v FROM t_ids WHERE k = 'anulada');
BEGIN
  SELECT * INTO c FROM t_ctx;
  PERFORM pg_temp.falla(format($s$SELECT crear_devolucion_tickets(ARRAY[%L]::uuid[], 'regalo', NULL, NULL,
      jsonb_build_array(jsonb_build_object('venta_item_id', %L, 'cantidad', 1)))$s$, v2, pg_temp.linea(v2, c.prods[2])), '15 días');
  PERFORM pg_temp.falla(format($s$SELECT crear_devolucion_tickets(ARRAY[%L]::uuid[], 'regalo', NULL, NULL,
      jsonb_build_array(jsonb_build_object('venta_item_id', %L, 'cantidad', 1)))$s$, v3, pg_temp.linea(v3, c.prods[3])), 'anulado');
  RAISE NOTICE 'OK T5b vencido y anulado';
END $$;

-- T6: ticket a cta. cte. + otro → rechazado; solo → anda (D12: a la cuenta).
DO $$
DECLARE c t_ctx; vc uuid; v2 uuid; r jsonb;
BEGIN
  SELECT * INTO c FROM t_ctx;
  ASSERT c.cliente_id IS NOT NULL, 'T6 sin cliente externo en la restauración';
  vc := pg_temp.venta(c.prods[1], NULL, 'cuenta_corriente', c.cliente_id);
  v2 := pg_temp.venta(c.prods[2]);
  PERFORM pg_temp.falla(format($s$SELECT crear_devolucion_tickets(ARRAY[%L,%L]::uuid[], 'regalo', NULL, NULL,
      jsonb_build_array(jsonb_build_object('venta_item_id', %L, 'cantidad', 1), jsonb_build_object('venta_item_id', %L, 'cantidad', 1)))$s$,
      vc, v2, pg_temp.linea(vc, c.prods[1]), pg_temp.linea(v2, c.prods[2])), 'cuenta corriente');
  r := crear_devolucion_tickets(ARRAY[vc], 'regalo', NULL, NULL,
      jsonb_build_array(jsonb_build_object('venta_item_id', pg_temp.linea(vc, c.prods[1]), 'cantidad', 1)));
  ASSERT r->>'resolucion' = 'cuenta_corriente', 'T6 ' || r::text;
  ASSERT (SELECT a_cuenta_corriente FROM devoluciones WHERE id = (r->>'devolucion_id')::uuid), 'T6 a cuenta';
  RAISE NOTICE 'OK T6 cta. cte. sola sí, mezclada no';
END $$;

-- T7: un defectuoso y uno sano en la misma devolución → solo reingresa el sano.
DO $$
DECLARE c t_ctx; v uuid; r jsonb; s1 numeric; s2 numeric;
BEGIN
  SELECT * INTO c FROM t_ctx;
  v := pg_temp.venta(c.prods[1], c.prods[2]);
  s1 := pg_temp.stock(c.prods[1]); s2 := pg_temp.stock(c.prods[2]);
  r := crear_devolucion_tickets(ARRAY[v], 'otro', 'prueba', NULL,
      jsonb_build_array(jsonb_build_object('venta_item_id', pg_temp.linea(v, c.prods[1]), 'cantidad', 1, 'defectuoso', true),
                        jsonb_build_object('venta_item_id', pg_temp.linea(v, c.prods[2]), 'cantidad', 1)),
      NULL, 'reintegro', 'efectivo');
  ASSERT pg_temp.stock(c.prods[1]) = s1 AND pg_temp.stock(c.prods[2]) = s2 + 1, 'T7 stock';
  ASSERT (SELECT bool_and(defectuoso = (producto_id = c.prods[1]) AND reingresa_stock = (producto_id <> c.prods[1]))
          FROM devolucion_items WHERE devolucion_id = (r->>'devolucion_id')::uuid), 'T7 flags';
  RAISE NOTICE 'OK T7 defectuoso por línea';
END $$;

-- T8: devolver de más en el ticket 2 de una devolución múltiple → rechazado (nada queda guardado).
DO $$
DECLARE c t_ctx; v1 uuid; v2 uuid; n0 bigint;
BEGIN
  SELECT * INTO c FROM t_ctx;
  v1 := pg_temp.venta(c.prods[1]); v2 := pg_temp.venta(c.prods[2]);
  SELECT count(*) INTO n0 FROM devoluciones;
  PERFORM pg_temp.falla(format($s$SELECT crear_devolucion_tickets(ARRAY[%L,%L]::uuid[], 'regalo', NULL, NULL,
      jsonb_build_array(jsonb_build_object('venta_item_id', %L, 'cantidad', 1), jsonb_build_object('venta_item_id', %L, 'cantidad', 3)),
      NULL, 'reintegro', 'efectivo')$s$, v1, v2, pg_temp.linea(v1, c.prods[1]), pg_temp.linea(v2, c.prods[2])), 'solo quedan 2');
  PERFORM pg_temp.falla(format($s$SELECT crear_devolucion_tickets(ARRAY[%L]::uuid[], 'regalo', NULL, NULL,
      jsonb_build_array(jsonb_build_object('venta_item_id', %L, 'cantidad', 1)))$s$, v1, pg_temp.linea(v2, c.prods[2])), 'no es de los tickets');
  ASSERT (SELECT count(*) FROM devoluciones) = n0, 'T8 quedó algo guardado';
  RAISE NOTICE 'OK T8 exceso en ticket 2 y línea ajena rechazados';
END $$;

-- T9: anular una venta con devolución activa → rechazado (admin).
SELECT set_config('request.jwt.claims', json_build_object('sub', admin_id, 'role', 'authenticated')::text, true) FROM t_ctx;
DO $$
BEGIN
  PERFORM pg_temp.falla(format('SELECT anular_venta(%L, %L)', (SELECT v FROM t_ids WHERE k = 't2v2'), 'prueba'), 'devolución activa');
  RAISE NOTICE 'OK T9 anular venta con devolución activa';
END $$;

-- T10: anular la devolución de 3 tickets → stock revertido, sale de la caja; después la venta sí se anula.
DO $$
DECLARE c t_ctx; d uuid; s1 numeric; s4 numeric; x0 cierres_caja; x cierres_caja; cid uuid; dif numeric;
BEGIN
  SELECT * INTO c FROM t_ctx;
  d := (SELECT v FROM t_ids WHERE k = 't2');
  SELECT diferencia_monto INTO dif FROM devoluciones WHERE id = d;
  s1 := pg_temp.stock(c.prods[1]); s4 := pg_temp.stock(c.prods[4]);
  cid := cerrar_caja('x'); SELECT * INTO x0 FROM cierres_caja WHERE id = cid;
  PERFORM anular_devolucion(d, 'prueba docs73');
  ASSERT pg_temp.stock(c.prods[1]) = s1 - 1, 'T10 stock devuelto';
  ASSERT pg_temp.stock(c.prods[4]) = s4 + (SELECT cantidad FROM devolucion_items WHERE devolucion_id = d AND tipo = 'nuevo'), 'T10 stock nuevo';
  cid := cerrar_caja('x'); SELECT * INTO x FROM cierres_caja WHERE id = cid;
  ASSERT x.total_devoluciones_efectivo = x0.total_devoluciones_efectivo - dif, 'T10 caja';
  ASSERT x.cantidad_devoluciones = x0.cantidad_devoluciones - 1, 'T10 cantidad';
  PERFORM anular_venta((SELECT v FROM t_ids WHERE k = 't2v2'), 'prueba docs73');
  RAISE NOTICE 'OK T10 anulación de 3 tickets';
END $$;

-- T11: crear_devolucion (vieja) sigue andando: puente, línea, resolución, totales; producto en 2 líneas
-- se reparte; motivo defectuoso → líneas defectuosas.
DO $$
DECLARE c t_ctx; v uuid; d uuid; dv devoluciones; p numeric;
BEGIN
  SELECT * INTO c FROM t_ctx;
  SELECT precio_venta INTO p FROM productos WHERE id = c.prods[1];
  v := confirmar_venta(NULL, 'efectivo', jsonb_build_array(
         jsonb_build_object('producto_id', c.prods[1], 'cantidad', 1, 'precio_unitario', p),
         jsonb_build_object('producto_id', c.prods[1], 'cantidad', 1, 'precio_unitario', p),
         jsonb_build_object('producto_id', c.prods[2], 'cantidad', 1, 'precio_unitario', (SELECT precio_venta FROM productos WHERE id = c.prods[2]))));
  d := crear_devolucion(v, 'arrepentimiento', NULL, NULL,
         jsonb_build_array(jsonb_build_object('producto_id', c.prods[1], 'cantidad', (SELECT sum(cantidad) FROM venta_items WHERE venta_id = v AND producto_id = c.prods[1]))),
         NULL, 'efectivo');
  SELECT * INTO dv FROM devoluciones WHERE id = d;
  ASSERT dv.venta_id = v AND dv.resolucion = 'reintegro' AND dv.cantidad_tickets = 1, 'T11 cabecera';
  ASSERT (SELECT count(*) FROM devolucion_tickets WHERE devolucion_id = d AND venta_id = v) = 1, 'T11 puente';
  ASSERT NOT EXISTS (SELECT 1 FROM devolucion_items WHERE devolucion_id = d AND (venta_id IS NULL OR venta_item_id IS NULL)), 'T11 líneas';
  ASSERT dv.total_devuelto = (SELECT total_devuelto FROM devolucion_tickets WHERE devolucion_id = d), 'T11 totales';
  PERFORM pg_temp.falla(format($s$SELECT crear_devolucion(%L, 'regalo', NULL, NULL, jsonb_build_array(jsonb_build_object('producto_id', %L, 'cantidad', 1)), NULL, 'efectivo')$s$, v, c.prods[1]), 'solo quedan 0');
  d := crear_devolucion(v, 'defectuoso', NULL, NULL, jsonb_build_array(jsonb_build_object('producto_id', c.prods[2], 'cantidad', 1)), NULL, 'efectivo');
  ASSERT (SELECT bool_and(defectuoso AND NOT reingresa_stock) FROM devolucion_items WHERE devolucion_id = d), 'T11 defectuoso';
  RAISE NOTICE 'OK T11 crear_devolucion vieja (líneas del producto: %)', (SELECT count(*) FROM venta_items WHERE venta_id = v AND producto_id = c.prods[1]);
END $$;

-- T12: la pantalla mostró "a favor" pero la diferencia real es cobro → rechazo.
DO $$
DECLARE c t_ctx; v uuid;
BEGIN
  SELECT * INTO c FROM t_ctx;
  v := pg_temp.venta(c.prods[1]);
  PERFORM pg_temp.falla(format($s$SELECT crear_devolucion_tickets(ARRAY[%L]::uuid[], 'regalo', NULL, NULL,
      jsonb_build_array(jsonb_build_object('venta_item_id', %L, 'cantidad', 1)),
      jsonb_build_array(jsonb_build_object('producto_id', %L, 'cantidad', 5)), 'a_favor', NULL, NULL, 'x')$s$,
      v, pg_temp.linea(v, c.prods[1]), c.prods[1]), 'La diferencia cambió');
  RAISE NOTICE 'OK T12 resolución que no coincide';
END $$;

-- T13: chequeos de salud de docs/37 (devoluciones) en verde con todo lo de arriba.
RESET ROLE;
DO $$
DECLARE v jsonb;
BEGIN
  SELECT jsonb_build_object(
    'V5', (SELECT count(*) FROM devoluciones d JOIN devolucion_tickets dt ON dt.devolucion_id = d.id
           JOIN ventas v ON v.id = dt.venta_id WHERE d.estado = 'activa' AND v.estado = 'anulada'
             AND v.id NOT IN (SELECT t.v FROM t_ids t WHERE t.k = 'anulada')),
    'V6', (SELECT count(*) FROM (
             SELECT di.venta_id, di.producto_id, SUM(di.cantidad) AS dev
             FROM devolucion_items di JOIN devoluciones d ON d.id = di.devolucion_id
             WHERE d.estado = 'activa' AND di.tipo = 'devuelto' GROUP BY 1, 2) x
           WHERE x.dev > (SELECT COALESCE(SUM(vi.cantidad), 0) FROM venta_items vi
                          WHERE vi.venta_id = x.venta_id AND vi.producto_id = x.producto_id)),
    'V7', (SELECT count(*) FROM devoluciones d WHERE d.resolucion IN ('cobro', 'reintegro')
           AND ABS(d.diferencia_monto) <> (SELECT COALESCE(SUM(monto), 0) FROM devolucion_pagos WHERE devolucion_id = d.id)),
    'V9', (SELECT count(*) FROM devoluciones d
           WHERE d.cantidad_tickets <> (SELECT count(*) FROM devolucion_tickets dt WHERE dt.devolucion_id = d.id)),
    'V10', (SELECT count(*) FROM devolucion_tickets dt
            WHERE NOT EXISTS (SELECT 1 FROM devolucion_items di WHERE di.devolucion_id = dt.devolucion_id AND di.venta_id = dt.venta_id)),
    'V11', (SELECT count(*) FROM devoluciones d
            WHERE d.total_devuelto <> (SELECT COALESCE(SUM(total_devuelto), 0) FROM devolucion_tickets dt WHERE dt.devolucion_id = d.id)),
    'V12', (SELECT count(*) FROM devoluciones d WHERE d.resolucion = 'a_favor' AND EXISTS (SELECT 1 FROM devolucion_pagos p WHERE p.devolucion_id = d.id))
  ) INTO v;
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_each(v) WHERE value::text <> '0'), 'T13 chequeos ' || v::text;
  RAISE NOTICE 'OK T13 chequeos de salud %', v;
END $$;

ROLLBACK;
