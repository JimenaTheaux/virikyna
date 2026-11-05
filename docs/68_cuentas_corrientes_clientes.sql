-- 68 — Cuentas corrientes de clientes (cobros con imputación y varios medios) + cuentas internas
--
-- ✅ APLICADO en producción el 2026-11-05 ~18:55 (PARTE A sola, con `supabase db query --linked -f`),
-- con backup previo virikyna_2026-11-05_pre-docs68-aplicar. Antes se comparó contra el backup de
-- prueba: schema idéntico y sin cambios en clientes/ventas/venta_items/pagos_cliente/devoluciones.
-- PARTE B ok en producción (5 internos con perfil, 388 pendiente con importes intactos, vistas
-- invoker, nada para anon, RLS en tablas nuevas). Prueba sin efectos en producción (BEGIN + RAISE):
-- editar/finalizar/reabrir la 388, Factura C rechazada, cobro viejo desde Local = turno sin
-- movimiento; la 388 quedó con version 0.
-- Probada antes sobre una restauración local de virikyna_2026-11-05_pre-docs68-test: PARTE A dos
-- veces seguidas (re-corrible), PARTE B ok, PARTE C 15/15.
-- Base: docs/DIAGNOSTICO_CUENTAS_CORRIENTES.md (2026-11-05) + decisiones D1–D13 cerradas con la
-- clienta el 2026-11-05. Schema relevado sobre el backup virikyna_2026-11-05_pre-docs68-test.
--
-- Correr desde la raíz del repo, después de 67. La PARTE A es re-corrible (IF NOT EXISTS / CREATE
-- OR REPLACE / datos con WHERE). La PARTE B solo lee. La PARTE C es un test (BEGIN … ROLLBACK):
-- llama a confirmar_venta, que consume ventas.numero aunque haga ROLLBACK → correrla SOLO en la
-- restauración local (restaurar-prueba.ps1, puerto 54329), nunca en producción.
--
-- Qué hace (sin UI):
--   1. clientes.tipo (externo/interno) + perfil_id. Solo un admin cambia tipo/perfil (trigger), las
--      apps siguen escribiendo clientes directo para el resto de los datos.
--   2. ventas: estado_interno (pendiente/finalizado; null = no es interna), total_original,
--      descuento_global_original, finalizada_*, editada_*, reabierta_*, version (control de edición
--      concurrente). Una venta es interna si al venderla el cliente es interno y va a cta. cte.
--   3. venta_items: costo_unitario (snapshot, sin IVA), producto_con_iva (snapshot del check),
--      precio_unitario_original y descuento_porcentaje_original (antes de la primera edición).
--      Auditoría en UPDATE/DELETE (el alta ya queda en la de ventas; auditar cada ítem vendido
--      llenaría el Historial con una fila por producto de cada venta).
--   4. pagos_cliente: origen (turno = caja de Local / general = Gestión), fecha, nota. venta_id
--      DEPRECATED. forma_pago 'combinado' permitido en la cabecera (cobro con varios medios).
--      Tablas nuevas pagos_cliente_aplicaciones (cobro → venta) y pagos_cliente_medios.
--   5. devoluciones.a_cuenta_corriente (D12): la devolución de una venta a cta. cte. baja la deuda,
--      no devuelve plata. Su crédito se calcula con el precio vigente de la venta (si la dueña edita
--      una interna pendiente, la devolución se reprecia sola).
--   6. Vistas: ventas_cuenta_corriente_saldo, pagos_cliente_a_cuenta, clientes_saldo (recalculada),
--      consumo_interno_mensual (D11, por fecha de finalización).
--   7. RPCs nuevas: registrar_cobro_cliente, aplicar_cobros_a_cuenta, desaplicar_cobro,
--      editar_venta_interna, finalizar_venta_interna, reabrir_venta_interna, dashboard_consumo_interno.
--   8. RPCs modificadas (misma firma): confirmar_venta (costo snapshot + marca interna),
--      registrar_pago_cliente (vieja: sigue andando, ahora con origen por app, medio e imputación),
--      crear_devolucion (D12), cerrar_caja y validar_cierre_z (cobros de turno, D13),
--      reservar_emision_factura_c (D5), dashboard_ventas_por_dia / _por_producto (D8),
--      revertir_movimiento (rama pagos_cliente con medios, aplicaciones y origen).
--   9. Datos: los 5 clientes actuales → internos con su perfil; venta N° 388 → interna pendiente
--      (sin tocar importes, ítems ni stock).
--
-- Reglas de caja (D13 + docs/58):
--   - Cobro origen 'turno' (Local): no crea movimientos_cuenta. Entra al Cierre X/Z del día
--     (efectivo al efectivo esperado; transferencia/QR/tarjeta discriminados) y validar_cierre_z
--     lleva lo no-efectivo a su cuenta, igual que las ventas de Local. Exige caja abierta.
--   - Cobro origen 'general' (Gestión, solo admin): movimiento en la cuenta mapeada de cada medio.

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios
-- ════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ─── 1. Tipos ────────────────────────────────────────────────────────────────────────────────
DO $$ BEGIN
  CREATE TYPE public.tipo_cliente AS ENUM ('externo', 'interno');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE TYPE public.estado_venta_interna AS ENUM ('pendiente', 'finalizado');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ─── 2. clientes ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS tipo public.tipo_cliente NOT NULL DEFAULT 'externo';
ALTER TABLE public.clientes ADD COLUMN IF NOT EXISTS perfil_id uuid REFERENCES public.perfiles(id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_clientes_perfil ON public.clientes(perfil_id) WHERE perfil_id IS NOT NULL;
ALTER TABLE public.clientes DROP CONSTRAINT IF EXISTS chk_cliente_perfil_solo_interno;
ALTER TABLE public.clientes ADD CONSTRAINT chk_cliente_perfil_solo_interno
  CHECK (perfil_id IS NULL OR tipo = 'interno');
COMMENT ON COLUMN public.clientes.tipo IS 'docs/68: interno = dueña o empleado (sus ventas a cta. cte. las edita y finaliza un admin, sin cobro). Solo un admin lo cambia.';
COMMENT ON COLUMN public.clientes.perfil_id IS 'docs/68: usuario del sistema que es este cliente interno (opcional).';

-- Solo un admin marca/desmarca internos. Las apps escriben clientes directo (RLS clientes_todos):
-- sin esto un cajero podría pasarse a sí mismo a externo/interno. Sin sesión (SQL de
-- mantenimiento, auth.uid() null) se permite.
CREATE OR REPLACE FUNCTION public.fn_proteger_tipo_cliente() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF auth.uid() IS NULL OR EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.tipo <> 'externo' OR NEW.perfil_id IS NOT NULL THEN
      RAISE EXCEPTION 'Solo un administrador puede dar de alta un cliente interno';
    END IF;
  ELSIF NEW.tipo IS DISTINCT FROM OLD.tipo OR NEW.perfil_id IS DISTINCT FROM OLD.perfil_id THEN
    RAISE EXCEPTION 'Solo un administrador puede cambiar si un cliente es interno';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.fn_proteger_tipo_cliente() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_proteger_tipo_cliente ON public.clientes;
CREATE TRIGGER trg_proteger_tipo_cliente BEFORE INSERT OR UPDATE ON public.clientes
  FOR EACH ROW EXECUTE FUNCTION public.fn_proteger_tipo_cliente();

-- ─── 3. ventas ───────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.ventas ADD COLUMN IF NOT EXISTS estado_interno public.estado_venta_interna;
ALTER TABLE public.ventas ADD COLUMN IF NOT EXISTS total_original numeric(12,2);
ALTER TABLE public.ventas ADD COLUMN IF NOT EXISTS descuento_global_original numeric(5,2);
ALTER TABLE public.ventas ADD COLUMN IF NOT EXISTS finalizada_at timestamptz;
ALTER TABLE public.ventas ADD COLUMN IF NOT EXISTS finalizada_por uuid REFERENCES public.perfiles(id);
ALTER TABLE public.ventas ADD COLUMN IF NOT EXISTS editada_at timestamptz;
ALTER TABLE public.ventas ADD COLUMN IF NOT EXISTS editada_por uuid REFERENCES public.perfiles(id);
ALTER TABLE public.ventas ADD COLUMN IF NOT EXISTS reabierta_at timestamptz;
ALTER TABLE public.ventas ADD COLUMN IF NOT EXISTS reabierta_por uuid REFERENCES public.perfiles(id);
ALTER TABLE public.ventas ADD COLUMN IF NOT EXISTS reabierta_motivo text;
ALTER TABLE public.ventas ADD COLUMN IF NOT EXISTS version integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN public.ventas.estado_interno IS 'docs/68: venta a cta. cte. de un cliente interno. pendiente = la dueña la revisa/edita; finalizado = cerrada sin cobro (se descuenta del sueldo fuera del sistema). null = no es interna.';
COMMENT ON COLUMN public.ventas.total_original IS 'docs/68: precio_cobrado que registró el cajero (solo ventas internas).';
COMMENT ON COLUMN public.ventas.descuento_global_original IS 'docs/68: descuento global que registró el cajero (solo ventas internas). Al editar, el global queda en 0.';
COMMENT ON COLUMN public.ventas.version IS 'docs/68: sube con cada edición/finalización/reapertura de una venta interna (control de edición concurrente).';

ALTER TABLE public.ventas DROP CONSTRAINT IF EXISTS chk_ventas_interna_cta_cte;
ALTER TABLE public.ventas ADD CONSTRAINT chk_ventas_interna_cta_cte
  CHECK (estado_interno IS NULL OR forma_pago = 'cuenta_corriente');
-- Una interna puede quedar en $0 (100 % de descuento por ítem); el resto sigue exigiendo > 0.
ALTER TABLE public.ventas DROP CONSTRAINT IF EXISTS chk_ventas_precio_cobrado_positivo;
ALTER TABLE public.ventas ADD CONSTRAINT chk_ventas_precio_cobrado_positivo
  CHECK (precio_cobrado > 0 OR (estado_interno IS NOT NULL AND precio_cobrado >= 0));
CREATE INDEX IF NOT EXISTS idx_ventas_estado_interno ON public.ventas(estado_interno) WHERE estado_interno IS NOT NULL;
DROP TRIGGER IF EXISTS trg_sin_acentos ON public.ventas;
CREATE TRIGGER trg_sin_acentos BEFORE INSERT OR UPDATE ON public.ventas
  FOR EACH ROW EXECUTE FUNCTION fn_sin_acentos('nota', 'reabierta_motivo');

-- ─── 4. venta_items ──────────────────────────────────────────────────────────────────────────
ALTER TABLE public.venta_items ADD COLUMN IF NOT EXISTS costo_unitario numeric(12,2);
ALTER TABLE public.venta_items ADD COLUMN IF NOT EXISTS producto_con_iva boolean;
ALTER TABLE public.venta_items ADD COLUMN IF NOT EXISTS precio_unitario_original numeric(12,2);
ALTER TABLE public.venta_items ADD COLUMN IF NOT EXISTS descuento_porcentaje_original numeric(5,2);
COMMENT ON COLUMN public.venta_items.costo_unitario IS 'docs/68: productos.costo al vender (sin IVA). null = venta anterior a docs/68 o producto con precio manual sin costo.';
COMMENT ON COLUMN public.venta_items.producto_con_iva IS 'docs/68: check "lleva IVA" del producto al vender (iva_porcentaje > 0). Costo comparable = costo × 1,21 si true.';
COMMENT ON COLUMN public.venta_items.precio_unitario_original IS 'docs/68: precio unitario antes de la primera edición de la dueña (null = nunca se editó).';
COMMENT ON COLUMN public.venta_items.descuento_porcentaje_original IS 'docs/68: descuento del ítem antes de la primera edición (null = nunca se editó).';
ALTER TABLE public.venta_items DROP CONSTRAINT IF EXISTS chk_venta_items_descuento_rango;
ALTER TABLE public.venta_items ADD CONSTRAINT chk_venta_items_descuento_rango
  CHECK (descuento_porcentaje >= 0 AND descuento_porcentaje <= 100);
DROP TRIGGER IF EXISTS trg_auditoria_venta_items ON public.venta_items;
CREATE TRIGGER trg_auditoria_venta_items AFTER UPDATE OR DELETE ON public.venta_items
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_generica();

-- ─── 5. pagos_cliente + tablas nuevas ────────────────────────────────────────────────────────
ALTER TABLE public.pagos_cliente ADD COLUMN IF NOT EXISTS origen public.origen_egreso NOT NULL DEFAULT 'general';
ALTER TABLE public.pagos_cliente ADD COLUMN IF NOT EXISTS fecha date NOT NULL
  DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'))::date;
ALTER TABLE public.pagos_cliente ADD COLUMN IF NOT EXISTS nota text;
COMMENT ON COLUMN public.pagos_cliente.venta_id IS 'DEPRECATED (docs/68): la imputación vive en pagos_cliente_aplicaciones. Se completa solo cuando todo el cobro cancela una única venta. No usar para calcular saldos.';
COMMENT ON COLUMN public.pagos_cliente.origen IS 'docs/68: turno = cobrado en la caja de Local (entra al Cierre); general = Gestión (impacta la cuenta mapeada).';
COMMENT ON COLUMN public.pagos_cliente.forma_pago IS 'docs/68: medio del cobro, o combinado si tiene varios (detalle en pagos_cliente_medios).';
ALTER TABLE public.pagos_cliente DROP CONSTRAINT IF EXISTS chk_pago_cliente_forma_pago;
ALTER TABLE public.pagos_cliente ADD CONSTRAINT chk_pago_cliente_forma_pago CHECK (forma_pago <> 'cuenta_corriente');
CREATE INDEX IF NOT EXISTS idx_pagos_cliente_cliente ON public.pagos_cliente(cliente_id);
DROP TRIGGER IF EXISTS trg_sin_acentos ON public.pagos_cliente;
CREATE TRIGGER trg_sin_acentos BEFORE INSERT OR UPDATE ON public.pagos_cliente
  FOR EACH ROW EXECUTE FUNCTION fn_sin_acentos('nota');

CREATE TABLE IF NOT EXISTS public.pagos_cliente_medios (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pago_cliente_id uuid NOT NULL REFERENCES public.pagos_cliente(id),
  forma_pago public.forma_pago_venta NOT NULL,
  monto numeric(12,2) NOT NULL,              -- > 0; negativo solo en la fila espejo de una reversión
  orden integer NOT NULL,
  revierte_medio_id uuid REFERENCES public.pagos_cliente_medios(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pagos_cliente_medios_forma CHECK (forma_pago NOT IN ('cuenta_corriente', 'combinado')),
  CONSTRAINT pagos_cliente_medios_monto CHECK (monto <> 0),
  CONSTRAINT pagos_cliente_medios_orden UNIQUE (pago_cliente_id, orden)
);
CREATE INDEX IF NOT EXISTS idx_pagos_cliente_medios_pago ON public.pagos_cliente_medios(pago_cliente_id);

CREATE TABLE IF NOT EXISTS public.pagos_cliente_aplicaciones (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pago_cliente_id uuid NOT NULL REFERENCES public.pagos_cliente(id),
  venta_id uuid NOT NULL REFERENCES public.ventas(id),
  monto numeric(12,2) NOT NULL CHECK (monto > 0),
  operacion_id uuid NOT NULL,                -- el cobro (o el cobro a cuenta) que la originó
  usuario_id uuid NOT NULL REFERENCES public.perfiles(id),
  revertida_at timestamptz,
  revertida_por uuid REFERENCES public.perfiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_pagos_cliente_aplicaciones_venta ON public.pagos_cliente_aplicaciones(venta_id);
CREATE INDEX IF NOT EXISTS idx_pagos_cliente_aplicaciones_pago ON public.pagos_cliente_aplicaciones(pago_cliente_id);
DROP TRIGGER IF EXISTS trg_auditoria_pagos_cliente_aplicaciones ON public.pagos_cliente_aplicaciones;
CREATE TRIGGER trg_auditoria_pagos_cliente_aplicaciones AFTER INSERT OR UPDATE ON public.pagos_cliente_aplicaciones
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_generica();

ALTER TABLE public.pagos_cliente_medios ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pagos_cliente_medios_select ON public.pagos_cliente_medios;
CREATE POLICY pagos_cliente_medios_select ON public.pagos_cliente_medios FOR SELECT
  USING (EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));
ALTER TABLE public.pagos_cliente_aplicaciones ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pagos_cliente_aplicaciones_select ON public.pagos_cliente_aplicaciones;
CREATE POLICY pagos_cliente_aplicaciones_select ON public.pagos_cliente_aplicaciones FOR SELECT
  USING (EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));
REVOKE ALL ON public.pagos_cliente_medios, public.pagos_cliente_aplicaciones FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.pagos_cliente_medios, public.pagos_cliente_aplicaciones TO authenticated;
GRANT ALL ON public.pagos_cliente_medios, public.pagos_cliente_aplicaciones TO service_role;

-- ─── 6. devoluciones (D12) ───────────────────────────────────────────────────────────────────
ALTER TABLE public.devoluciones ADD COLUMN IF NOT EXISTS a_cuenta_corriente boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.devoluciones.a_cuenta_corriente IS 'docs/68 (D12): la diferencia va a la cuenta corriente del cliente (baja o sube la deuda), sin plata. Solo en ventas a cta. cte.';
ALTER TABLE public.devoluciones DROP CONSTRAINT IF EXISTS chk_devolucion_forma_pago_coherente;
ALTER TABLE public.devoluciones ADD CONSTRAINT chk_devolucion_forma_pago_coherente CHECK (
  ((diferencia_monto = 0 OR a_cuenta_corriente) AND diferencia_forma_pago IS NULL)
  OR (diferencia_monto <> 0 AND NOT a_cuenta_corriente AND diferencia_forma_pago IS NOT NULL));

-- ─── 7. cierres_caja: cobros de clientes del turno (D13) ─────────────────────────────────────
ALTER TABLE public.cierres_caja ADD COLUMN IF NOT EXISTS cantidad_cobros integer NOT NULL DEFAULT 0;
ALTER TABLE public.cierres_caja ADD COLUMN IF NOT EXISTS total_cobros_efectivo numeric(12,2) NOT NULL DEFAULT 0;
ALTER TABLE public.cierres_caja ADD COLUMN IF NOT EXISTS total_cobros_transferencia numeric(12,2) NOT NULL DEFAULT 0;
ALTER TABLE public.cierres_caja ADD COLUMN IF NOT EXISTS total_cobros_qr numeric(12,2) NOT NULL DEFAULT 0;
ALTER TABLE public.cierres_caja ADD COLUMN IF NOT EXISTS total_cobros_tarjeta numeric(12,2) NOT NULL DEFAULT 0;
COMMENT ON COLUMN public.cierres_caja.total_cobros_efectivo IS 'docs/68: cobros de cuenta corriente en efectivo hechos en la caja de Local ese día (ya incluidos en efectivo_esperado).';

-- ─── 8. Crédito de devoluciones imputadas a la cuenta (D12) ──────────────────────────────────
-- Devueltos al precio efectivo VIGENTE de la venta (mismo cálculo que crear_devolucion: importe
-- promedio del producto × total/subtotal) − nuevos a su precio de lista. En una venta que nunca se
-- editó da exactamente −diferencia_monto; en una interna editada se reprecia sola.
CREATE OR REPLACE FUNCTION public.credito_devoluciones_venta(p_venta_id uuid) RETURNS numeric
  LANGUAGE sql STABLE SET search_path TO 'public' AS $$
  SELECT COALESCE(SUM(
           CASE WHEN di.tipo = 'devuelto' THEN ROUND(di.cantidad * COALESCE(pu.precio, di.precio_unitario), 2)
                ELSE -ROUND(di.cantidad * di.precio_unitario, 2) END), 0)
  FROM devoluciones d
  JOIN devolucion_items di ON di.devolucion_id = d.id
  JOIN ventas v ON v.id = d.venta_id
  LEFT JOIN LATERAL (
    SELECT ROUND((SUM(vi.importe) / NULLIF(SUM(vi.cantidad), 0))
                 * (CASE WHEN v.subtotal > 0 THEN v.total / v.subtotal ELSE 1 END), 2) AS precio
    FROM venta_items vi
    WHERE vi.venta_id = d.venta_id AND vi.producto_id = di.producto_id
  ) pu ON di.tipo = 'devuelto'
  WHERE d.venta_id = p_venta_id AND d.estado = 'activa' AND d.a_cuenta_corriente;
$$;
REVOKE ALL ON FUNCTION public.credito_devoluciones_venta(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.credito_devoluciones_venta(uuid) TO authenticated, service_role;

-- ─── 9. Vistas ───────────────────────────────────────────────────────────────────────────────
-- Saldo por comprobante (espejo de facturas_compra_saldo).
CREATE OR REPLACE VIEW public.ventas_cuenta_corriente_saldo WITH (security_invoker = on) AS
SELECT v.id, v.numero, v.cliente_id, v.created_at, v.usuario_id, v.estado, v.estado_interno, v.nota,
       v.subtotal, v.descuento_porcentaje, v.recargo_porcentaje, v.total,
       v.total_original, v.descuento_global_original,
       v.finalizada_at, v.finalizada_por, v.editada_at, v.editada_por,
       v.reabierta_at, v.reabierta_por, v.reabierta_motivo, v.version,
       x.aplicado AS total_aplicado,
       x.devuelto AS total_devuelto,
       CASE WHEN v.estado = 'anulada' THEN 0 ELSE GREATEST(v.total - x.aplicado - x.devuelto, 0) END AS saldo_pendiente,
       CASE WHEN v.estado = 'anulada' THEN 0 ELSE GREATEST(x.aplicado + x.devuelto - v.total, 0) END AS credito,
       CASE
         WHEN v.estado = 'anulada' THEN 'anulada'
         WHEN v.estado_interno = 'pendiente' THEN 'a_revisar'
         WHEN v.estado_interno = 'finalizado' THEN 'finalizado'
         WHEN v.total - x.aplicado - x.devuelto <= 0 THEN 'pagada'
         WHEN x.aplicado + x.devuelto > 0 THEN 'parcial'
         ELSE 'pendiente'
       END AS estado_cuenta
FROM ventas v
CROSS JOIN LATERAL (
  SELECT COALESCE((SELECT SUM(a.monto) FROM pagos_cliente_aplicaciones a
                   WHERE a.venta_id = v.id AND a.revertida_at IS NULL), 0) AS aplicado,
         credito_devoluciones_venta(v.id) AS devuelto
) x
WHERE v.forma_pago = 'cuenta_corriente';
COMMENT ON VIEW public.ventas_cuenta_corriente_saldo IS 'docs/68: saldo por venta a cta. cte. (cobros aplicados vigentes, devoluciones imputadas). estado_cuenta: a_revisar | finalizado | pendiente | parcial | pagada | anulada.';

-- Por cobro, lo aplicado vigente y lo que queda a cuenta (espejo de pagos_proveedor_a_cuenta).
CREATE OR REPLACE VIEW public.pagos_cliente_a_cuenta WITH (security_invoker = on) AS
SELECT pc.id, pc.cliente_id, pc.fecha, pc.created_at, pc.monto, pc.origen,
       ap.aplicado, v.vigente,
       CASE WHEN v.vigente THEN pc.monto - ap.aplicado ELSE 0 END AS a_cuenta
FROM pagos_cliente pc
CROSS JOIN LATERAL (
  SELECT COALESCE(SUM(a.monto), 0) AS aplicado FROM pagos_cliente_aplicaciones a
  WHERE a.pago_cliente_id = pc.id AND a.revertida_at IS NULL
) ap
CROSS JOIN LATERAL (
  SELECT pc.monto > 0 AND pc.revierte_pago_cliente_id IS NULL
         AND NOT EXISTS (SELECT 1 FROM pagos_cliente r WHERE r.revierte_pago_cliente_id = pc.id) AS vigente
) v;
COMMENT ON VIEW public.pagos_cliente_a_cuenta IS 'docs/68: por cobro, lo aplicado vigente y lo que queda a cuenta (0 en reversiones y revertidos).';

-- clientes_saldo: mismas columnas que antes (en el mismo orden) + las nuevas al final.
-- saldo_actual = saldo inicial + ventas a cta. cte. no anuladas y no finalizadas internas
--                − devoluciones imputadas − cobros (las reversiones restan solas, monto negativo).
CREATE OR REPLACE VIEW public.clientes_saldo WITH (security_invoker = on) AS
SELECT c.id, c.razon_social, c.nombre_fantasia, c.cuit, c.domicilio, c.mail, c.celular, c.activo,
       c.saldo_inicial, c.created_at,
       c.saldo_inicial + COALESCE(vt.neto, 0) - COALESCE(pg.total_pagado, 0) AS saldo_actual,
       c.condicion_iva, c.tipo, c.perfil_id,
       COALESCE(vt.deuda_comprobantes, 0) AS deuda_comprobantes,
       COALESCE(vt.interno_pendiente, 0) AS consumo_interno_pendiente,
       COALESCE(ac.a_cuenta, 0) AS a_cuenta,
       c.saldo_inicial + COALESCE(vt.neto, 0) - COALESCE(vt.interno_pendiente, 0) - COALESCE(pg.total_pagado, 0) AS saldo_cobrable,
       COALESCE(vt.comprobantes_abiertos, 0) AS comprobantes_abiertos
FROM clientes c
LEFT JOIN (
  SELECT s.cliente_id,
         SUM(s.total - s.total_devuelto) FILTER (WHERE s.estado_interno IS DISTINCT FROM 'finalizado') AS neto,
         SUM(s.saldo_pendiente) FILTER (WHERE s.estado_interno IS NULL) AS deuda_comprobantes,
         SUM(s.total - s.total_devuelto) FILTER (WHERE s.estado_interno = 'pendiente') AS interno_pendiente,
         COUNT(*) FILTER (WHERE s.estado_cuenta IN ('pendiente', 'parcial', 'a_revisar')) AS comprobantes_abiertos
  FROM ventas_cuenta_corriente_saldo s
  WHERE s.estado <> 'anulada'
  GROUP BY s.cliente_id
) vt ON vt.cliente_id = c.id
LEFT JOIN (SELECT cliente_id, SUM(monto) AS total_pagado FROM pagos_cliente GROUP BY cliente_id) pg ON pg.cliente_id = c.id
LEFT JOIN (SELECT cliente_id, SUM(a_cuenta) AS a_cuenta FROM pagos_cliente_a_cuenta GROUP BY cliente_id) ac ON ac.cliente_id = c.id;
COMMENT ON VIEW public.clientes_saldo IS 'docs/68: saldo de cuenta corriente por cliente. saldo_actual excluye internas finalizadas y descuenta devoluciones imputadas; saldo_cobrable además excluye internas pendientes (no se cobran, se finalizan).';

-- D11: total mensual por cliente interno, por fecha de finalización (hora AR).
CREATE OR REPLACE VIEW public.consumo_interno_mensual WITH (security_invoker = on) AS
SELECT s.cliente_id,
       COALESCE(c.razon_social, c.nombre_fantasia) AS cliente_nombre,
       date_trunc('month', s.finalizada_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS mes,
       COUNT(*)::int AS cantidad_comprobantes,
       SUM(s.total - s.total_devuelto) AS total,
       SUM(COALESCE(s.total_original, s.total)) AS total_original
FROM ventas_cuenta_corriente_saldo s
JOIN clientes c ON c.id = s.cliente_id
WHERE s.estado_interno = 'finalizado' AND s.estado <> 'anulada'
GROUP BY s.cliente_id, COALESCE(c.razon_social, c.nombre_fantasia),
         date_trunc('month', s.finalizada_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
COMMENT ON VIEW public.consumo_interno_mensual IS 'docs/68 (D11): consumo interno finalizado por cliente y mes de finalización (total neto de devoluciones).';

REVOKE ALL ON public.ventas_cuenta_corriente_saldo, public.pagos_cliente_a_cuenta, public.consumo_interno_mensual
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.ventas_cuenta_corriente_saldo, public.pagos_cliente_a_cuenta, public.consumo_interno_mensual
  TO authenticated, service_role;
REVOKE ALL ON public.clientes_saldo FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.clientes_saldo TO authenticated, service_role;

-- ─── 10. confirmar_venta: costo snapshot + marca interna (misma firma, D2 sin restricciones) ──
CREATE OR REPLACE FUNCTION public.confirmar_venta(p_cliente_id uuid, p_forma_pago forma_pago_venta, p_items jsonb, p_descuento_porcentaje numeric DEFAULT 0, p_nota text DEFAULT NULL::text, p_recargo_porcentaje numeric DEFAULT 0, p_pagos jsonb DEFAULT NULL::jsonb, p_precio_cobrado numeric DEFAULT NULL::numeric, p_client_id text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_venta_id UUID;
  v_item JSONB;
  v_pago JSONB;
  v_subtotal NUMERIC := 0;
  v_precio_oficial NUMERIC;
  v_precio_cobrado NUMERIC;
  v_ratio NUMERIC;
  v_importe NUMERIC;
  v_forma_pago_final forma_pago_venta;
  v_suma_pagos NUMERIC;
  v_suma_ajustada NUMERIC := 0;
  v_monto_ajustado NUMERIC;
  v_idx INT := 0;
  v_nombre TEXT;  -- docs/42
  v_marca TEXT;   -- docs/42
  v_costo NUMERIC;       -- docs/68
  v_con_iva BOOLEAN;     -- docs/68
  v_interna BOOLEAN := false;  -- docs/68
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  -- docs/43: reintento de un cobro que ya se grabó → la misma venta, sin volver a mover nada.
  IF p_client_id IS NOT NULL THEN
    SELECT id INTO v_venta_id FROM ventas WHERE client_id = p_client_id;
    IF FOUND THEN
      RETURN v_venta_id;
    END IF;
  END IF;

  SELECT COALESCE(SUM((i->>'cantidad')::NUMERIC * (i->>'precio_unitario')::NUMERIC
           * (1 - COALESCE((i->>'descuento_porcentaje')::NUMERIC,0)/100.0)), 0)
  INTO v_subtotal
  FROM jsonb_array_elements(p_items) AS i;

  v_precio_oficial := ROUND(v_subtotal * (1 - COALESCE(p_descuento_porcentaje,0)/100.0)
                    * (1 + COALESCE(p_recargo_porcentaje,0)/100.0), 2);

  IF p_pagos IS NOT NULL AND jsonb_array_length(p_pagos) > 0 THEN
    IF jsonb_array_length(p_pagos) > 2 THEN
      RAISE EXCEPTION 'Un pago combinado admite hasta 2 medios de pago';
    END IF;
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_pagos) AS p
      WHERE (p->>'forma_pago') IN ('cuenta_corriente', 'combinado')
    ) THEN
      RAISE EXCEPTION 'La cuenta corriente no puede combinarse con otro medio de pago';
    END IF;
    -- La validación de la suma se hace contra el precio OFICIAL: es el monto con el que se armó
    -- el reparto en PagoCombinadoModal, antes de que el cajero edite el precio final a cobrar.
    SELECT COALESCE(SUM((p->>'monto')::NUMERIC), 0) INTO v_suma_pagos FROM jsonb_array_elements(p_pagos) AS p;
    IF ROUND(v_suma_pagos, 2) <> v_precio_oficial THEN
      RAISE EXCEPTION 'La suma de los pagos (%) no coincide con el total de la venta (%)', v_suma_pagos, v_precio_oficial;
    END IF;
    v_forma_pago_final := CASE WHEN jsonb_array_length(p_pagos) = 1
      THEN (p_pagos->0->>'forma_pago')::forma_pago_venta
      ELSE 'combinado'::forma_pago_venta END;
  ELSE
    v_forma_pago_final := p_forma_pago;
  END IF;

  -- Corregido en QA: mensaje claro antes de chocar con el CHECK del schema
  IF v_forma_pago_final = 'cuenta_corriente' AND p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'Una venta a cuenta corriente necesita un cliente asignado';
  END IF;

  v_precio_cobrado := COALESCE(p_precio_cobrado, v_precio_oficial);
  IF v_precio_cobrado <= 0 THEN
    RAISE EXCEPTION 'El precio final a cobrar debe ser mayor a 0';
  END IF;

  -- docs/68: cliente interno + cuenta corriente → venta interna pendiente (la revisa la dueña).
  IF v_forma_pago_final = 'cuenta_corriente' THEN
    SELECT tipo = 'interno' INTO v_interna FROM clientes WHERE id = p_cliente_id;
    v_interna := COALESCE(v_interna, false);
  END IF;

  INSERT INTO ventas (cliente_id, forma_pago, subtotal, descuento_porcentaje, recargo_porcentaje, total,
         precio_oficial, precio_cobrado, nota, usuario_id, client_id,
         estado_interno, total_original, descuento_global_original)
  VALUES (p_cliente_id, v_forma_pago_final, v_subtotal, COALESCE(p_descuento_porcentaje,0),
          COALESCE(p_recargo_porcentaje,0), v_precio_cobrado, v_precio_oficial, v_precio_cobrado, p_nota, auth.uid(),
          p_client_id,
          CASE WHEN v_interna THEN 'pendiente'::estado_venta_interna END,
          CASE WHEN v_interna THEN v_precio_cobrado END,
          CASE WHEN v_interna THEN COALESCE(p_descuento_porcentaje,0) END)
  ON CONFLICT (client_id) WHERE client_id IS NOT NULL DO NOTHING
  RETURNING id INTO v_venta_id;

  -- docs/43: otra llamada con el mismo client_id la grabó mientras esta esperaba el índice único.
  IF v_venta_id IS NULL THEN
    SELECT id INTO v_venta_id FROM ventas WHERE client_id = p_client_id;
    RETURN v_venta_id;
  END IF;

  IF v_forma_pago_final <> 'cuenta_corriente' THEN
    IF p_pagos IS NOT NULL AND jsonb_array_length(p_pagos) > 0 THEN
      -- Reescala cada parte al precio cobrado, manteniendo la proporción del reparto original —
      -- la última parte absorbe el centavo de redondeo para que la suma dé exacta.
      v_ratio := CASE WHEN v_precio_oficial = 0 THEN 1 ELSE v_precio_cobrado / v_precio_oficial END;
      FOR v_pago IN SELECT * FROM jsonb_array_elements(p_pagos)
      LOOP
        v_idx := v_idx + 1;
        IF v_idx = jsonb_array_length(p_pagos) THEN
          v_monto_ajustado := v_precio_cobrado - v_suma_ajustada;
        ELSE
          v_monto_ajustado := ROUND((v_pago->>'monto')::NUMERIC * v_ratio, 2);
          v_suma_ajustada := v_suma_ajustada + v_monto_ajustado;
        END IF;
        INSERT INTO venta_pagos (venta_id, forma_pago, monto, usuario_id)
        VALUES (v_venta_id, (v_pago->>'forma_pago')::forma_pago_venta, v_monto_ajustado, auth.uid());
      END LOOP;
    ELSE
      INSERT INTO venta_pagos (venta_id, forma_pago, monto, usuario_id)
      VALUES (v_venta_id, v_forma_pago_final, v_precio_cobrado, auth.uid());
    END IF;
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_importe := ROUND((v_item->>'cantidad')::NUMERIC * (v_item->>'precio_unitario')::NUMERIC
                 * (1 - COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0)/100.0), 2);

    -- docs/42: snapshot de nombre y marca. docs/68: + costo (sin IVA) y check de IVA.
    -- Si el producto no existe, la FK del INSERT lo frena igual.
    SELECT nombre, marca, costo, iva_porcentaje > 0 INTO v_nombre, v_marca, v_costo, v_con_iva
    FROM productos WHERE id = (v_item->>'producto_id')::UUID;

    INSERT INTO venta_items (venta_id, producto_id, cantidad, precio_unitario, descuento_porcentaje, importe,
                             producto_nombre, producto_marca, costo_unitario, producto_con_iva)
    VALUES (v_venta_id, (v_item->>'producto_id')::UUID, (v_item->>'cantidad')::NUMERIC,
            (v_item->>'precio_unitario')::NUMERIC, COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0), v_importe,
            v_nombre, v_marca, v_costo, v_con_iva);

    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, referencia_id, usuario_id)
    VALUES ((v_item->>'producto_id')::UUID, 'local', 'venta', -1 * (v_item->>'cantidad')::NUMERIC, v_venta_id, auth.uid());

    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES ((v_item->>'producto_id')::UUID, 'local', -1 * (v_item->>'cantidad')::NUMERIC)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad - (v_item->>'cantidad')::NUMERIC;
  END LOOP;

  RETURN v_venta_id;
END;
$$;

-- ─── 11. registrar_cobro_cliente (espejo de registrar_pago_proveedor_v3, sin cheques ni NC) ───
CREATE OR REPLACE FUNCTION public.registrar_cobro_cliente(
  p_cliente_id uuid,
  p_medios jsonb,
  p_venta_ids uuid[] DEFAULT NULL,
  p_origen origen_egreso DEFAULT 'turno',
  p_fecha date DEFAULT NULL,
  p_nota text DEFAULT NULL,
  p_monto numeric DEFAULT NULL
) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_hoy DATE := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_fecha DATE;
  v_nota TEXT := NULLIF(btrim(p_nota), '');
  v_elem jsonb;
  v_txt text;
  v_val NUMERIC;
  v_m_forma forma_pago_venta[] := '{}';
  v_m_monto NUMERIC[] := '{}';
  v_cant INT := 0;
  v_monto NUMERIC := 0;
  v_venta_ids UUID[];
  v_mal RECORD;
  v_cobrable NUMERIC;
  v_doc_ids UUID[] := '{}';
  v_doc_saldos NUMERIC[] := '{}';
  v_plan_doc UUID[] := '{}';
  v_plan_monto NUMERIC[] := '{}';
  v_rest NUMERIC;
  v_aplicar NUMERIC;
  v_pago_id UUID;
  i INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF p_origen IS NULL THEN
    RAISE EXCEPTION 'Falta el origen del cobro';
  END IF;
  IF p_origen = 'general' AND NOT EXISTS (
    SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true
  ) THEN
    RAISE EXCEPTION 'Solo un administrador puede registrar un cobro desde Gestión';
  END IF;

  IF p_origen = 'turno' THEN
    -- El cobro de Local entra al Cierre del día: tiene que haber caja abierta y es de hoy.
    IF NOT EXISTS (SELECT 1 FROM aperturas_caja WHERE cierre_z_id IS NULL) THEN
      RAISE EXCEPTION 'Abrí la caja para registrar un cobro';
    END IF;
    IF p_fecha IS NOT NULL AND p_fecha <> v_hoy THEN
      RAISE EXCEPTION 'Un cobro en la caja de Local es siempre de hoy';
    END IF;
    v_fecha := v_hoy;
  ELSE
    v_fecha := COALESCE(p_fecha, v_hoy);
    IF v_fecha > v_hoy THEN
      RAISE EXCEPTION 'La fecha del cobro no puede ser futura';
    END IF;
  END IF;

  -- ── Medios ──
  IF p_medios IS NULL OR jsonb_typeof(p_medios) <> 'array' OR jsonb_array_length(p_medios) = 0 THEN
    RAISE EXCEPTION 'Agregá al menos un medio de cobro';
  END IF;
  FOR v_elem IN SELECT e FROM jsonb_array_elements(p_medios) AS e LOOP
    v_cant := v_cant + 1;
    v_txt := v_elem->>'forma_pago';
    IF v_txt IS NULL OR v_txt NOT IN ('efectivo', 'transferencia', 'qr', 'tarjeta_debito', 'tarjeta_credito') THEN
      RAISE EXCEPTION 'Medio de cobro % no válido (efectivo, transferencia, QR, débito o crédito)', COALESCE(v_txt, 'vacío');
    END IF;
    BEGIN
      v_val := round((v_elem->>'monto')::numeric, 2);
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'El monto del medio % no es un número', v_cant;
    END;
    IF v_val IS NULL OR v_val <= 0 THEN
      RAISE EXCEPTION 'Cada medio tiene que tener un monto mayor a cero (medio %)', v_cant;
    END IF;
    v_m_forma := array_append(v_m_forma, v_txt::forma_pago_venta);
    v_m_monto := array_append(v_m_monto, v_val);
    v_monto := v_monto + v_val;
  END LOOP;
  IF p_monto IS NOT NULL AND round(p_monto, 2) <> v_monto THEN
    RAISE EXCEPTION 'La suma de los medios (%) no coincide con el total del cobro (%)', v_monto, round(p_monto, 2);
  END IF;

  SELECT array_agg(DISTINCT x) INTO v_venta_ids FROM unnest(p_venta_ids) AS x WHERE x IS NOT NULL;

  -- Serializa los cobros de un mismo cliente (dos cajas cobrando la misma venta a la vez).
  PERFORM 1 FROM clientes WHERE id = p_cliente_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cliente no encontrado';
  END IF;

  -- ── Ventas elegidas ──
  IF v_venta_ids IS NOT NULL THEN
    IF (SELECT count(*) FROM ventas WHERE id = ANY(v_venta_ids)) <> cardinality(v_venta_ids) THEN
      RAISE EXCEPTION 'Alguna de las ventas elegidas no existe';
    END IF;
    SELECT numero INTO v_mal FROM ventas WHERE id = ANY(v_venta_ids) AND cliente_id IS DISTINCT FROM p_cliente_id LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'La venta N° % no es de este cliente', v_mal.numero; END IF;
    SELECT numero INTO v_mal FROM ventas WHERE id = ANY(v_venta_ids) AND forma_pago <> 'cuenta_corriente' LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'La venta N° % no es a cuenta corriente', v_mal.numero; END IF;
    SELECT numero INTO v_mal FROM ventas WHERE id = ANY(v_venta_ids) AND estado = 'anulada' LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'La venta N° % está anulada', v_mal.numero; END IF;
    SELECT numero INTO v_mal FROM ventas WHERE id = ANY(v_venta_ids) AND estado_interno IS NOT NULL LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'La venta N° % es de consumo interno: no se cobra, se finaliza', v_mal.numero; END IF;
    SELECT numero INTO v_mal FROM ventas_cuenta_corriente_saldo WHERE id = ANY(v_venta_ids) AND saldo_pendiente <= 0 LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'La venta N° % ya está saldada', v_mal.numero; END IF;
  END IF;

  -- No se cobra más de lo que el cliente debe (sin contar consumo interno pendiente).
  SELECT saldo_cobrable INTO v_cobrable FROM clientes_saldo WHERE id = p_cliente_id;
  IF COALESCE(v_cobrable, 0) <= 0 THEN
    RAISE EXCEPTION 'Este cliente no tiene saldo a cobrar';
  END IF;
  IF v_monto > v_cobrable THEN
    RAISE EXCEPTION 'El cobro (%) supera lo que debe el cliente (%)', v_monto, v_cobrable;
  END IF;

  -- ── Ventas a cancelar: las elegidas, o todas las pendientes; más viejas primero ──
  SELECT COALESCE(array_agg(s.id ORDER BY s.created_at, s.id), '{}'),
         COALESCE(array_agg(s.saldo_pendiente ORDER BY s.created_at, s.id), '{}')
  INTO v_doc_ids, v_doc_saldos
  FROM ventas_cuenta_corriente_saldo s
  WHERE s.cliente_id = p_cliente_id
    AND s.estado <> 'anulada' AND s.estado_interno IS NULL
    AND s.saldo_pendiente > 0
    AND (v_venta_ids IS NULL OR s.id = ANY(v_venta_ids));

  v_rest := v_monto;
  i := 1;
  WHILE i <= cardinality(v_doc_ids) AND v_rest > 0 LOOP
    v_aplicar := LEAST(v_doc_saldos[i], v_rest);
    v_plan_doc := array_append(v_plan_doc, v_doc_ids[i]);
    v_plan_monto := array_append(v_plan_monto, v_aplicar);
    v_rest := v_rest - v_aplicar;
    i := i + 1;
  END LOOP;

  -- ── Escritura ──
  INSERT INTO pagos_cliente (cliente_id, venta_id, monto, forma_pago, usuario_id, origen, fecha, nota)
  VALUES (p_cliente_id,
          CASE WHEN cardinality(v_plan_doc) = 1 AND v_rest = 0 THEN v_plan_doc[1] END,  -- deprecated
          v_monto,
          CASE WHEN v_cant = 1 THEN v_m_forma[1] ELSE 'combinado'::forma_pago_venta END,
          auth.uid(), p_origen, v_fecha, v_nota)
  RETURNING id INTO v_pago_id;

  INSERT INTO pagos_cliente_aplicaciones (pago_cliente_id, venta_id, monto, operacion_id, usuario_id)
  SELECT v_pago_id, t.doc, t.monto, v_pago_id, auth.uid()
  FROM unnest(v_plan_doc, v_plan_monto) AS t(doc, monto);

  FOR i IN 1 .. v_cant LOOP
    INSERT INTO pagos_cliente_medios (pago_cliente_id, forma_pago, monto, orden)
    VALUES (v_pago_id, v_m_forma[i], v_m_monto[i], i);
    -- docs/58 + D13: lo cobrado en la caja de Local no toca cuentas acá (efectivo queda en el cajón;
    -- el resto entra a su cuenta al validar el Z, como las ventas). Gestión: directo a la cuenta.
    IF p_origen = 'general' THEN
      INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
      SELECT cuenta_id, 'pago_cliente', v_m_monto[i], v_pago_id, auth.uid()
      FROM cuenta_forma_pago WHERE forma_pago = v_m_forma[i];
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'pago_id', v_pago_id,
    'monto', v_monto,
    'aplicado', v_monto - v_rest,
    'a_cuenta', v_rest,
    'aplicaciones', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', a.id, 'venta_id', a.venta_id, 'monto', a.monto)
                       ORDER BY array_position(v_plan_doc, a.venta_id))
      FROM pagos_cliente_aplicaciones a WHERE a.operacion_id = v_pago_id
    ), '[]'::jsonb)
  );
END;
$$;
REVOKE ALL ON FUNCTION public.registrar_cobro_cliente(uuid, jsonb, uuid[], origen_egreso, date, text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_cobro_cliente(uuid, jsonb, uuid[], origen_egreso, date, text, numeric) TO authenticated, service_role;

-- ─── 12. registrar_pago_cliente (vieja): misma firma, sigue andando para el Local instalado ───
-- Un solo medio. Origen según la app (header x-virikyna-app, docs/54): Local → turno (entra al
-- Cierre, sin movimiento de cuenta, docs/58); Gestión o sin header → general (cuenta mapeada).
-- No exige caja abierta ni valida contra el saldo (como antes). Si se eligió una venta cobrable
-- con saldo, se imputa hasta su saldo; el resto queda a cuenta.
CREATE OR REPLACE FUNCTION public.registrar_pago_cliente(p_cliente_id uuid, p_venta_id uuid, p_monto numeric, p_forma_pago forma_pago_venta)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_pago_id UUID;
  v_origen origen_egreso := CASE WHEN app_cliente() = 'local' THEN 'turno'::origen_egreso ELSE 'general'::origen_egreso END;
  v_saldo NUMERIC;
  v_monto NUMERIC := round(p_monto, 2);
BEGIN
  IF p_forma_pago = 'cuenta_corriente' THEN
    RAISE EXCEPTION 'La forma de pago no puede ser cuenta_corriente para saldar una cuenta corriente';
  END IF;
  IF p_forma_pago = 'combinado' THEN
    RAISE EXCEPTION 'Elegí un solo medio de cobro';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF v_monto IS NULL OR v_monto <= 0 THEN
    RAISE EXCEPTION 'Ingresá un monto mayor a cero';
  END IF;

  PERFORM 1 FROM clientes WHERE id = p_cliente_id FOR UPDATE;

  IF p_venta_id IS NOT NULL THEN
    SELECT s.saldo_pendiente INTO v_saldo
    FROM ventas_cuenta_corriente_saldo s
    WHERE s.id = p_venta_id AND s.cliente_id = p_cliente_id
      AND s.estado <> 'anulada' AND s.estado_interno IS NULL;
  END IF;

  INSERT INTO pagos_cliente (cliente_id, venta_id, monto, forma_pago, usuario_id, origen)
  VALUES (p_cliente_id, p_venta_id, v_monto, p_forma_pago, auth.uid(), v_origen)
  RETURNING id INTO v_pago_id;

  INSERT INTO pagos_cliente_medios (pago_cliente_id, forma_pago, monto, orden)
  VALUES (v_pago_id, p_forma_pago, v_monto, 1);

  IF COALESCE(v_saldo, 0) > 0 THEN
    INSERT INTO pagos_cliente_aplicaciones (pago_cliente_id, venta_id, monto, operacion_id, usuario_id)
    VALUES (v_pago_id, p_venta_id, LEAST(v_saldo, v_monto), v_pago_id, auth.uid());
  END IF;

  IF v_origen = 'general' THEN
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
    SELECT cuenta_id, 'pago_cliente', v_monto, v_pago_id, auth.uid()
    FROM cuenta_forma_pago WHERE forma_pago = p_forma_pago;
  END IF;
  RETURN v_pago_id;
END;
$$;

-- ─── 13. aplicar_cobros_a_cuenta / desaplicar_cobro (espejo de docs/52) ──────────────────────
CREATE OR REPLACE FUNCTION public.aplicar_cobros_a_cuenta(p_cliente_id uuid, p_venta_ids uuid[] DEFAULT NULL, p_pago_ids uuid[] DEFAULT NULL)
  RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_venta_ids UUID[];
  v_pago_ids UUID[];
  v_mal RECORD;
  v_doc_ids UUID[] := '{}';
  v_doc_saldos NUMERIC[] := '{}';
  v_pag_ids UUID[] := '{}';
  v_pag_disp NUMERIC[] := '{}';
  i INT := 1;
  j INT := 1;
  v_aplicar NUMERIC;
  v_total NUMERIC := 0;
  v_ids UUID[] := '{}';
  v_id UUID;
BEGIN
  -- Mismo permiso que cobrar: cualquier perfil activo. No mueve plata.
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  SELECT array_agg(DISTINCT x) INTO v_venta_ids FROM unnest(p_venta_ids) AS x WHERE x IS NOT NULL;
  SELECT array_agg(DISTINCT x) INTO v_pago_ids FROM unnest(p_pago_ids) AS x WHERE x IS NOT NULL;

  PERFORM 1 FROM clientes WHERE id = p_cliente_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Cliente no encontrado'; END IF;

  IF v_venta_ids IS NOT NULL THEN
    IF (SELECT count(*) FROM ventas WHERE id = ANY(v_venta_ids)) <> cardinality(v_venta_ids) THEN
      RAISE EXCEPTION 'Alguna de las ventas elegidas no existe';
    END IF;
    SELECT numero INTO v_mal FROM ventas WHERE id = ANY(v_venta_ids) AND cliente_id IS DISTINCT FROM p_cliente_id LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'La venta N° % no es de este cliente', v_mal.numero; END IF;
    SELECT numero INTO v_mal FROM ventas WHERE id = ANY(v_venta_ids)
      AND (forma_pago <> 'cuenta_corriente' OR estado = 'anulada' OR estado_interno IS NOT NULL) LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'A la venta N° % no se le aplican cobros', v_mal.numero; END IF;
  END IF;
  IF v_pago_ids IS NOT NULL THEN
    IF (SELECT count(*) FROM pagos_cliente WHERE id = ANY(v_pago_ids)) <> cardinality(v_pago_ids) THEN
      RAISE EXCEPTION 'Alguno de los cobros elegidos no existe';
    END IF;
    SELECT * INTO v_mal FROM pagos_cliente_a_cuenta WHERE id = ANY(v_pago_ids) AND cliente_id <> p_cliente_id LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'El cobro del % no es de este cliente', to_char(v_mal.fecha, 'DD/MM/YYYY'); END IF;
    SELECT * INTO v_mal FROM pagos_cliente_a_cuenta WHERE id = ANY(v_pago_ids) AND NOT vigente LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'El cobro del % no está vigente (fue revertido o es una reversión)', to_char(v_mal.fecha, 'DD/MM/YYYY'); END IF;
  END IF;

  SELECT COALESCE(array_agg(s.id ORDER BY s.created_at, s.id), '{}'),
         COALESCE(array_agg(s.saldo_pendiente ORDER BY s.created_at, s.id), '{}')
  INTO v_doc_ids, v_doc_saldos
  FROM ventas_cuenta_corriente_saldo s
  WHERE s.cliente_id = p_cliente_id AND s.estado <> 'anulada' AND s.estado_interno IS NULL
    AND s.saldo_pendiente > 0 AND (v_venta_ids IS NULL OR s.id = ANY(v_venta_ids));
  IF cardinality(v_doc_ids) = 0 THEN
    RAISE EXCEPTION 'No hay saldo pendiente en las ventas al que aplicar el cobro a cuenta';
  END IF;

  SELECT COALESCE(array_agg(p.id ORDER BY p.fecha, p.created_at, p.id), '{}'),
         COALESCE(array_agg(p.a_cuenta ORDER BY p.fecha, p.created_at, p.id), '{}')
  INTO v_pag_ids, v_pag_disp
  FROM pagos_cliente_a_cuenta p
  WHERE p.cliente_id = p_cliente_id AND p.a_cuenta > 0 AND (v_pago_ids IS NULL OR p.id = ANY(v_pago_ids));
  IF cardinality(v_pag_ids) = 0 THEN
    RAISE EXCEPTION 'Este cliente no tiene cobros a cuenta para aplicar';
  END IF;

  WHILE i <= cardinality(v_doc_ids) AND j <= cardinality(v_pag_ids) LOOP
    v_aplicar := LEAST(v_doc_saldos[i], v_pag_disp[j]);
    INSERT INTO pagos_cliente_aplicaciones (pago_cliente_id, venta_id, monto, operacion_id, usuario_id)
    VALUES (v_pag_ids[j], v_doc_ids[i], v_aplicar, v_pag_ids[j], auth.uid())
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
    'a_cuenta_restante', (SELECT COALESCE(SUM(a_cuenta), 0) FROM pagos_cliente_a_cuenta WHERE cliente_id = p_cliente_id),
    'aplicaciones', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', a.id, 'pago_cliente_id', a.pago_cliente_id, 'venta_id', a.venta_id, 'monto', a.monto)
                       ORDER BY array_position(v_ids, a.id))
      FROM pagos_cliente_aplicaciones a WHERE a.id = ANY(v_ids)
    ), '[]'::jsonb)
  );
END;
$$;
REVOKE ALL ON FUNCTION public.aplicar_cobros_a_cuenta(uuid, uuid[], uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.aplicar_cobros_a_cuenta(uuid, uuid[], uuid[]) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.desaplicar_cobro(p_aplicacion_id uuid)
  RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_apl pagos_cliente_aplicaciones%ROWTYPE;
  v_cliente_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede quitar una aplicación de cobro';
  END IF;
  SELECT pc.cliente_id INTO v_cliente_id
  FROM pagos_cliente_aplicaciones a JOIN pagos_cliente pc ON pc.id = a.pago_cliente_id
  WHERE a.id = p_aplicacion_id;
  IF v_cliente_id IS NULL THEN RAISE EXCEPTION 'Aplicación no encontrada'; END IF;

  PERFORM 1 FROM clientes WHERE id = v_cliente_id FOR UPDATE;
  SELECT * INTO v_apl FROM pagos_cliente_aplicaciones WHERE id = p_aplicacion_id FOR UPDATE;
  IF v_apl.revertida_at IS NOT NULL THEN RAISE EXCEPTION 'Esta aplicación ya se había quitado'; END IF;

  UPDATE pagos_cliente_aplicaciones SET revertida_at = now(), revertida_por = auth.uid()
  WHERE id = p_aplicacion_id AND revertida_at IS NULL;

  RETURN jsonb_build_object('id', v_apl.id, 'venta_id', v_apl.venta_id, 'monto', v_apl.monto,
                            'pago_cliente_id', v_apl.pago_cliente_id);
END;
$$;
REVOKE ALL ON FUNCTION public.desaplicar_cobro(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.desaplicar_cobro(uuid) TO authenticated, service_role;

-- ─── 14. Ventas internas: editar / finalizar / reabrir (solo admin) ──────────────────────────
-- p_items: [{item_id, descuento_porcentaje}] con TODOS los ítems de la venta. El descuento global
-- queda en 0 (D6) y rigen los % por ítem, de 0 a 100 sobre el precio registrado (solo bajar).
-- No toca cantidades, productos, stock ni fecha.
CREATE OR REPLACE FUNCTION public.editar_venta_interna(p_venta_id uuid, p_items jsonb, p_version integer)
  RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_venta ventas%ROWTYPE;
  v_elem jsonb;
  v_item_id UUID;
  v_desc NUMERIC;
  v_ids UUID[] := '{}';
  v_subtotal NUMERIC;
  v_total NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede editar un comprobante interno';
  END IF;

  SELECT * INTO v_venta FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Venta no encontrada'; END IF;
  IF v_venta.estado_interno IS NULL THEN
    RAISE EXCEPTION 'Solo se editan comprobantes de clientes internos';
  END IF;
  IF v_venta.estado_interno = 'finalizado' THEN
    RAISE EXCEPTION 'El comprobante está finalizado: reabrilo para editarlo';
  END IF;
  IF v_venta.estado <> 'sin_facturar' THEN
    RAISE EXCEPTION 'El comprobante está %: no se puede editar', CASE WHEN v_venta.estado = 'anulada' THEN 'anulado' ELSE 'facturado' END;
  END IF;
  IF p_version IS NULL OR p_version <> v_venta.version THEN
    RAISE EXCEPTION 'El comprobante cambió mientras lo editabas: volvé a abrirlo';
  END IF;
  IF EXISTS (SELECT 1 FROM pagos_cliente_aplicaciones WHERE venta_id = p_venta_id AND revertida_at IS NULL) THEN
    RAISE EXCEPTION 'El comprobante tiene cobros aplicados: no se puede editar';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'Faltan los ítems a editar';
  END IF;
  FOR v_elem IN SELECT e FROM jsonb_array_elements(p_items) AS e LOOP
    BEGIN
      v_item_id := (v_elem->>'item_id')::uuid;
      v_desc := round((v_elem->>'descuento_porcentaje')::numeric, 2);
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'Ítem o descuento inválido';
    END;
    IF v_item_id IS NULL OR v_desc IS NULL THEN RAISE EXCEPTION 'Ítem o descuento inválido'; END IF;
    IF v_desc < 0 OR v_desc > 100 THEN
      RAISE EXCEPTION 'El descuento tiene que estar entre 0 y 100 %%';
    END IF;
    IF v_item_id = ANY(v_ids) THEN RAISE EXCEPTION 'Un ítem vino repetido'; END IF;
    IF NOT EXISTS (SELECT 1 FROM venta_items WHERE id = v_item_id AND venta_id = p_venta_id) THEN
      RAISE EXCEPTION 'Un ítem no es de este comprobante';
    END IF;
    v_ids := array_append(v_ids, v_item_id);

    UPDATE venta_items
    SET precio_unitario_original = COALESCE(precio_unitario_original, precio_unitario),
        descuento_porcentaje_original = COALESCE(descuento_porcentaje_original, descuento_porcentaje),
        descuento_porcentaje = v_desc,
        importe = ROUND(cantidad * precio_unitario * (1 - v_desc / 100.0), 2)
    WHERE id = v_item_id AND venta_id = p_venta_id;
  END LOOP;
  IF (SELECT count(*) FROM venta_items WHERE venta_id = p_venta_id) <> cardinality(v_ids) THEN
    RAISE EXCEPTION 'Mandá el descuento de todos los ítems del comprobante';
  END IF;

  SELECT COALESCE(SUM(importe), 0) INTO v_subtotal FROM venta_items WHERE venta_id = p_venta_id;
  v_total := ROUND(v_subtotal * (1 + COALESCE(v_venta.recargo_porcentaje, 0) / 100.0), 2);

  UPDATE ventas
  SET subtotal = v_subtotal, descuento_porcentaje = 0,
      precio_oficial = v_total, precio_cobrado = v_total, total = v_total,
      editada_at = now(), editada_por = auth.uid(), version = version + 1
  WHERE id = p_venta_id;

  RETURN jsonb_build_object('venta_id', p_venta_id, 'subtotal', v_subtotal, 'total', v_total,
                            'total_original', v_venta.total_original, 'version', v_venta.version + 1);
END;
$$;
REVOKE ALL ON FUNCTION public.editar_venta_interna(uuid, jsonb, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.editar_venta_interna(uuid, jsonb, integer) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.finalizar_venta_interna(p_venta_id uuid, p_version integer DEFAULT NULL)
  RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_venta ventas%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede finalizar un comprobante interno';
  END IF;
  SELECT * INTO v_venta FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Venta no encontrada'; END IF;
  IF v_venta.estado_interno IS NULL THEN RAISE EXCEPTION 'Solo se finalizan comprobantes de clientes internos'; END IF;
  IF v_venta.estado_interno = 'finalizado' THEN RAISE EXCEPTION 'El comprobante ya está finalizado'; END IF;
  IF v_venta.estado <> 'sin_facturar' THEN RAISE EXCEPTION 'El comprobante está anulado: no se finaliza'; END IF;
  IF p_version IS NOT NULL AND p_version <> v_venta.version THEN
    RAISE EXCEPTION 'El comprobante cambió mientras lo revisabas: volvé a abrirlo';
  END IF;

  -- Sin pagos_cliente, movimientos_cuenta ni venta_pagos: se cierra sin cobro (D1).
  UPDATE ventas
  SET estado_interno = 'finalizado', finalizada_at = now(), finalizada_por = auth.uid(), version = version + 1
  WHERE id = p_venta_id;

  RETURN jsonb_build_object('venta_id', p_venta_id, 'total', v_venta.total, 'version', v_venta.version + 1);
END;
$$;
REVOKE ALL ON FUNCTION public.finalizar_venta_interna(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.finalizar_venta_interna(uuid, integer) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.reabrir_venta_interna(p_venta_id uuid, p_motivo text)
  RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_venta ventas%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede reabrir un comprobante interno';
  END IF;
  IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
    RAISE EXCEPTION 'El motivo es obligatorio para reabrir un comprobante';
  END IF;
  SELECT * INTO v_venta FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Venta no encontrada'; END IF;
  IF v_venta.estado_interno IS DISTINCT FROM 'finalizado' THEN
    RAISE EXCEPTION 'Solo se reabre un comprobante interno finalizado';
  END IF;
  IF v_venta.estado <> 'sin_facturar' THEN RAISE EXCEPTION 'El comprobante está anulado: no se reabre'; END IF;

  -- La auditoría (trg_auditoria_ventas) guarda el antes/después con el motivo y quién reabrió.
  UPDATE ventas
  SET estado_interno = 'pendiente', finalizada_at = NULL, finalizada_por = NULL,
      reabierta_at = now(), reabierta_por = auth.uid(), reabierta_motivo = btrim(p_motivo),
      version = version + 1
  WHERE id = p_venta_id;

  RETURN jsonb_build_object('venta_id', p_venta_id, 'version', v_venta.version + 1);
END;
$$;
REVOKE ALL ON FUNCTION public.reabrir_venta_interna(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reabrir_venta_interna(uuid, text) TO authenticated, service_role;

-- ─── 15. crear_devolucion (D12): misma firma ─────────────────────────────────────────────────
-- Venta a cta. cte.: si el comercio debería devolver plata (o no hay diferencia), la diferencia va
-- a la cuenta (a_cuenta_corriente, sin devolucion_pagos, el Cierre no la ve). Si el cliente lleva
-- más de lo que devuelve, paga la diferencia como hoy, o la carga a la cuenta con
-- p_forma_pago = 'cuenta_corriente'. Interna finalizada: hay que reabrirla primero.
CREATE OR REPLACE FUNCTION public.crear_devolucion(p_venta_id uuid, p_motivo motivo_devolucion, p_motivo_detalle text, p_observaciones text, p_items_devueltos jsonb, p_items_nuevos jsonb DEFAULT NULL::jsonb, p_forma_pago forma_pago_venta DEFAULT NULL::forma_pago_venta, p_pagos jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'America/Argentina/Buenos_Aires'
AS $$
DECLARE
  v_venta ventas%ROWTYPE;
  v_row RECORD;
  v_devolucion_id UUID;
  v_vendida NUMERIC;
  v_ya_devuelta NUMERIC;
  v_precio NUMERIC;
  v_total_devuelto NUMERIC := 0;
  v_total_nuevo NUMERIC := 0;
  v_diferencia NUMERIC;
  v_forma_final forma_pago_venta;
  v_suma_pagos NUMERIC;
  v_suma_asignada NUMERIC := 0;
  v_monto NUMERIC;
  v_pago JSONB;
  v_idx INT := 0;
  v_reingresa BOOLEAN;
  v_nombre TEXT;
  v_marca TEXT;  -- docs/42
  v_items_devueltos JSONB := '[]'::jsonb;
  v_items_nuevos JSONB := '[]'::jsonb;
  v_a_cuenta BOOLEAN := false;  -- docs/68
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  -- Bloquea la venta: dos devoluciones simultáneas sobre la misma venta se serializan, así la
  -- validación de cantidad disponible no se puede saltear con una carrera.
  SELECT * INTO v_venta FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Venta no encontrada'; END IF;
  IF v_venta.estado = 'anulada' THEN
    RAISE EXCEPTION 'No se puede hacer una devolución sobre una venta anulada';
  END IF;
  IF v_venta.estado_interno = 'finalizado' THEN
    RAISE EXCEPTION 'Es un consumo interno ya finalizado: pedile a un administrador que lo reabra antes de la devolución';
  END IF;

  -- Validación 1: plazo de 15 días
  IF v_venta.created_at::date < current_date - 15 THEN
    RAISE EXCEPTION 'Esta venta supera los 15 días permitidos para devolución/cambio';
  END IF;

  -- Validación 3: motivo obligatorio; "otro" exige detalle
  IF p_motivo IS NULL THEN RAISE EXCEPTION 'El motivo es obligatorio'; END IF;
  IF p_motivo = 'otro' AND (p_motivo_detalle IS NULL OR btrim(p_motivo_detalle) = '') THEN
    RAISE EXCEPTION 'Con motivo "otro" el detalle es obligatorio';
  END IF;

  IF p_items_devueltos IS NULL OR jsonb_typeof(p_items_devueltos) <> 'array' OR jsonb_array_length(p_items_devueltos) = 0 THEN
    RAISE EXCEPTION 'Elegí al menos un producto para devolver';
  END IF;

  v_reingresa := (p_motivo <> 'defectuoso');

  -- ---- Ítems devueltos (agrupados por producto por si el cliente manda repetidos) ----
  FOR v_row IN
    SELECT (i->>'producto_id')::UUID AS producto_id, SUM((i->>'cantidad')::NUMERIC) AS cantidad
    FROM jsonb_array_elements(p_items_devueltos) AS i
    GROUP BY 1
  LOOP
    IF v_row.cantidad IS NULL OR v_row.cantidad <= 0 THEN
      RAISE EXCEPTION 'La cantidad a devolver debe ser mayor a 0';
    END IF;

    SELECT COALESCE(SUM(cantidad), 0) INTO v_vendida
    FROM venta_items WHERE venta_id = p_venta_id AND producto_id = v_row.producto_id;

    SELECT nombre INTO v_nombre FROM productos WHERE id = v_row.producto_id;

    IF v_vendida = 0 THEN
      RAISE EXCEPTION 'El producto "%" no forma parte de esta venta', COALESCE(v_nombre, v_row.producto_id::text);
    END IF;

    -- Validación 2: no devolver más de lo vendido, descontando devoluciones activas previas
    SELECT COALESCE(SUM(di.cantidad), 0) INTO v_ya_devuelta
    FROM devolucion_items di
    JOIN devoluciones d ON d.id = di.devolucion_id
    WHERE d.venta_id = p_venta_id AND d.estado = 'activa'
      AND di.tipo = 'devuelto' AND di.producto_id = v_row.producto_id;

    IF v_row.cantidad > v_vendida - v_ya_devuelta THEN
      RAISE EXCEPTION 'No se puede devolver % de "%": solo quedan % disponibles (vendidas %, ya devueltas %)',
        v_row.cantidad, v_nombre, v_vendida - v_ya_devuelta, v_vendida, v_ya_devuelta;
    END IF;

    -- Precio efectivamente pagado por unidad (ver decisión 1 del encabezado)
    SELECT ROUND(
             (SUM(importe) / NULLIF(SUM(cantidad), 0))
             * (CASE WHEN v_venta.subtotal > 0 THEN v_venta.total / v_venta.subtotal ELSE 1 END), 2)
    INTO v_precio
    FROM venta_items WHERE venta_id = p_venta_id AND producto_id = v_row.producto_id;

    v_total_devuelto := v_total_devuelto + ROUND(v_row.cantidad * v_precio, 2);
    v_items_devueltos := v_items_devueltos || jsonb_build_object(
      'producto_id', v_row.producto_id, 'cantidad', v_row.cantidad, 'precio_unitario', v_precio);
  END LOOP;

  -- ---- Ítems nuevos (cambio), a precio actual de lista ----
  IF p_items_nuevos IS NOT NULL AND jsonb_typeof(p_items_nuevos) = 'array' AND jsonb_array_length(p_items_nuevos) > 0 THEN
    FOR v_row IN
      SELECT (i->>'producto_id')::UUID AS producto_id, SUM((i->>'cantidad')::NUMERIC) AS cantidad
      FROM jsonb_array_elements(p_items_nuevos) AS i
      GROUP BY 1
    LOOP
      IF v_row.cantidad IS NULL OR v_row.cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad del producto nuevo debe ser mayor a 0';
      END IF;
      SELECT nombre, precio_venta INTO v_nombre, v_precio
      FROM productos WHERE id = v_row.producto_id AND estado = 'activo';
      IF NOT FOUND THEN RAISE EXCEPTION 'Producto nuevo no encontrado o inactivo'; END IF;

      v_total_nuevo := v_total_nuevo + ROUND(v_row.cantidad * v_precio, 2);
      v_items_nuevos := v_items_nuevos || jsonb_build_object(
        'producto_id', v_row.producto_id, 'cantidad', v_row.cantidad, 'precio_unitario', v_precio);
    END LOOP;
  END IF;

  v_diferencia := ROUND(v_total_nuevo - v_total_devuelto, 2);

  -- docs/68 (D12): venta a cta. cte. → la diferencia va a la cuenta, no se devuelve plata.
  IF v_venta.forma_pago = 'cuenta_corriente'
     AND (v_diferencia <= 0 OR p_forma_pago = 'cuenta_corriente') THEN
    v_a_cuenta := true;
  END IF;

  -- ---- Forma de pago de la diferencia ----
  IF v_diferencia <> 0 AND NOT v_a_cuenta THEN
    IF p_pagos IS NOT NULL AND jsonb_typeof(p_pagos) = 'array' AND jsonb_array_length(p_pagos) > 0 THEN
      IF jsonb_array_length(p_pagos) > 2 THEN
        RAISE EXCEPTION 'Un pago combinado admite hasta 2 medios de pago';
      END IF;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_pagos) AS p
                 WHERE (p->>'forma_pago') IN ('cuenta_corriente', 'combinado')) THEN
        RAISE EXCEPTION 'La diferencia no se puede saldar con cuenta corriente';
      END IF;
      SELECT COALESCE(SUM((p->>'monto')::NUMERIC), 0) INTO v_suma_pagos FROM jsonb_array_elements(p_pagos) AS p;
      IF ABS(v_suma_pagos - ABS(v_diferencia)) > 0.01 THEN
        RAISE EXCEPTION 'La suma de los pagos (%) no coincide con la diferencia (%)', v_suma_pagos, ABS(v_diferencia);
      END IF;
      v_forma_final := CASE WHEN jsonb_array_length(p_pagos) = 1
        THEN (p_pagos->0->>'forma_pago')::forma_pago_venta
        ELSE 'combinado'::forma_pago_venta END;
    ELSE
      IF p_forma_pago IS NULL THEN
        RAISE EXCEPTION 'Elegí la forma de pago para saldar la diferencia';
      END IF;
      IF p_forma_pago IN ('cuenta_corriente', 'combinado') THEN
        RAISE EXCEPTION 'Forma de pago inválida para saldar la diferencia';
      END IF;
      v_forma_final := p_forma_pago;
    END IF;
  ELSE
    v_forma_final := NULL;
  END IF;

  -- ---- Insert de la devolución ----
  INSERT INTO devoluciones (venta_id, usuario_id, motivo, motivo_detalle, observaciones,
                            diferencia_monto, diferencia_forma_pago, a_cuenta_corriente)
  VALUES (p_venta_id, auth.uid(), p_motivo, NULLIF(btrim(p_motivo_detalle), ''), NULLIF(btrim(p_observaciones), ''),
          v_diferencia, v_forma_final, v_a_cuenta)
  RETURNING id INTO v_devolucion_id;

  -- Pagos de la diferencia (monto siempre positivo). La última parte absorbe el centavo de redondeo.
  IF v_diferencia <> 0 AND NOT v_a_cuenta THEN
    IF p_pagos IS NOT NULL AND jsonb_typeof(p_pagos) = 'array' AND jsonb_array_length(p_pagos) > 0 THEN
      FOR v_pago IN SELECT * FROM jsonb_array_elements(p_pagos)
      LOOP
        v_idx := v_idx + 1;
        IF v_idx = jsonb_array_length(p_pagos) THEN
          v_monto := ABS(v_diferencia) - v_suma_asignada;
        ELSE
          v_monto := ROUND((v_pago->>'monto')::NUMERIC, 2);
          v_suma_asignada := v_suma_asignada + v_monto;
        END IF;
        INSERT INTO devolucion_pagos (devolucion_id, forma_pago, monto)
        VALUES (v_devolucion_id, (v_pago->>'forma_pago')::forma_pago_venta, v_monto);
      END LOOP;
    ELSE
      INSERT INTO devolucion_pagos (devolucion_id, forma_pago, monto)
      VALUES (v_devolucion_id, v_forma_final, ABS(v_diferencia));
    END IF;
  END IF;

  -- Ítems devueltos: + stock local solo si reingresa (defectuoso queda separado, sin movimiento)
  FOR v_row IN SELECT (i->>'producto_id')::UUID AS producto_id, (i->>'cantidad')::NUMERIC AS cantidad,
                      (i->>'precio_unitario')::NUMERIC AS precio_unitario
               FROM jsonb_array_elements(v_items_devueltos) AS i
  LOOP
    SELECT nombre, marca INTO v_nombre, v_marca FROM productos WHERE id = v_row.producto_id;  -- docs/42

    INSERT INTO devolucion_items (devolucion_id, tipo, producto_id, cantidad, precio_unitario, reingresa_stock,
                                  producto_nombre, producto_marca)
    VALUES (v_devolucion_id, 'devuelto', v_row.producto_id, v_row.cantidad, v_row.precio_unitario, v_reingresa,
            v_nombre, v_marca);

    IF v_reingresa THEN
      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
      VALUES (v_row.producto_id, 'local', 'ajuste', v_row.cantidad,
              'Devolución de venta #' || v_venta.numero || ' (' || p_motivo::text || ')', v_devolucion_id, auth.uid());
      INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
      VALUES (v_row.producto_id, 'local', v_row.cantidad)
      ON CONFLICT (producto_id, ubicacion)
      DO UPDATE SET cantidad = stock_ubicaciones.cantidad + v_row.cantidad;
    END IF;
  END LOOP;

  -- Ítems nuevos: − stock local
  FOR v_row IN SELECT (i->>'producto_id')::UUID AS producto_id, (i->>'cantidad')::NUMERIC AS cantidad,
                      (i->>'precio_unitario')::NUMERIC AS precio_unitario
               FROM jsonb_array_elements(v_items_nuevos) AS i
  LOOP
    SELECT nombre, marca INTO v_nombre, v_marca FROM productos WHERE id = v_row.producto_id;  -- docs/42

    INSERT INTO devolucion_items (devolucion_id, tipo, producto_id, cantidad, precio_unitario, reingresa_stock,
                                  producto_nombre, producto_marca)
    VALUES (v_devolucion_id, 'nuevo', v_row.producto_id, v_row.cantidad, v_row.precio_unitario, true,
            v_nombre, v_marca);

    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
    VALUES (v_row.producto_id, 'local', 'ajuste', -1 * v_row.cantidad,
            'Cambio sobre venta #' || v_venta.numero, v_devolucion_id, auth.uid());
    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES (v_row.producto_id, 'local', -1 * v_row.cantidad)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad - v_row.cantidad;
  END LOOP;

  RETURN v_devolucion_id;
END;
$$;

-- ─── 16. cerrar_caja + validar_cierre_z: cobros de turno (D13) ───────────────────────────────
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
         cantidad_cobros, total_cobros_efectivo, total_cobros_transferencia, total_cobros_qr, total_cobros_tarjeta)
  VALUES (p_tipo, current_date, v_total_efectivo, v_total_transferencia, v_total_qr, v_total_tarjeta,
         v_total_cuenta_corriente, v_total_egresos, v_total_retiros, v_efectivo_esperado, p_efectivo_contado, v_diferencia,
         CASE WHEN p_tipo = 'z' THEN 'pendiente_validacion'::estado_cierre_z ELSE NULL END, auth.uid(), v_apertura.id,
         v_cant_devoluciones, v_dev_efectivo, v_dev_transferencia, v_dev_qr, v_dev_tarjeta,
         v_cant_cobros, v_cob_efectivo, v_cob_transferencia, v_cob_qr, v_cob_tarjeta)
  RETURNING id INTO v_cierre_id;

  IF p_tipo = 'z' AND v_apertura.id IS NOT NULL THEN
    UPDATE aperturas_caja SET cierre_z_id = v_cierre_id WHERE id = v_apertura.id;
  END IF;

  RETURN v_cierre_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.validar_cierre_z(p_cierre_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_cierre cierres_caja%ROWTYPE;
  v_monto_tarjeta NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede validar un Cierre Z';
  END IF;

  SELECT * INTO v_cierre FROM cierres_caja WHERE id = p_cierre_id AND tipo = 'z';
  IF NOT FOUND THEN RAISE EXCEPTION 'Cierre Z no encontrado'; END IF;
  IF v_cierre.estado_validacion = 'validado' THEN RAISE EXCEPTION 'Este Cierre Z ya fue validado'; END IF;

  UPDATE cierres_caja SET estado_validacion = 'validado', validado_por = auth.uid(), validado_at = now()
  WHERE id = p_cierre_id;

  -- docs/68: + cobros de cuenta corriente del turno (lo no-efectivo va a su cuenta, como las ventas).
  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
  SELECT cfp.cuenta_id, 'cierre_z', v.monto, p_cierre_id, auth.uid()
  FROM (VALUES
    ('transferencia'::forma_pago_venta, v_cierre.total_transferencia + v_cierre.total_devoluciones_transferencia + v_cierre.total_cobros_transferencia),
    ('qr'::forma_pago_venta, v_cierre.total_qr + v_cierre.total_devoluciones_qr + v_cierre.total_cobros_qr)
  ) AS v(forma_pago, monto)
  JOIN cuenta_forma_pago cfp ON cfp.forma_pago = v.forma_pago
  WHERE v.monto <> 0;

  -- Tarjeta (débito+crédito) va a la misma cuenta que QR (Galicia)
  v_monto_tarjeta := v_cierre.total_tarjeta + v_cierre.total_devoluciones_tarjeta + v_cierre.total_cobros_tarjeta;
  IF v_monto_tarjeta <> 0 THEN
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
    SELECT cuenta_id, 'cierre_z', v_monto_tarjeta, p_cierre_id, auth.uid()
    FROM cuenta_forma_pago WHERE forma_pago = 'qr';
  END IF;
END;
$$;

-- ─── 17. reservar_emision_factura_c (D5): una venta interna nunca lleva Factura C ────────────
CREATE OR REPLACE FUNCTION public.reservar_emision_factura_c(p_venta_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_estado estado_comprobante;
  v_interno estado_venta_interna;  -- docs/68
  v_res emisiones_factura_c_en_curso%ROWTYPE;
  v_token uuid := gen_random_uuid();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  -- El lock de la venta serializa reservas y el guardado de la factura (emitir_factura_c).
  SELECT estado, estado_interno INTO v_estado, v_interno FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('resultado', 'no_encontrada');
  END IF;
  -- docs/68 (D5): antes de cualquier reserva, así nunca se llega a pedirle un CAE a ARCA.
  IF v_interno IS NOT NULL THEN
    RAISE EXCEPTION 'Es un consumo interno (cliente interno): no lleva Factura C';
  END IF;
  IF v_estado <> 'sin_facturar' OR EXISTS (SELECT 1 FROM facturas_c WHERE venta_id = p_venta_id) THEN
    RETURN jsonb_build_object('resultado', 'ya_facturada');
  END IF;

  SELECT * INTO v_res FROM emisiones_factura_c_en_curso WHERE venta_id = p_venta_id;
  IF NOT FOUND THEN
    INSERT INTO emisiones_factura_c_en_curso (venta_id, token, tomada_at, tomada_por)
    VALUES (p_venta_id, v_token, now(), auth.uid());
    RETURN jsonb_build_object('resultado', 'reservada', 'token', v_token);
  END IF;

  IF v_res.revisar_at IS NOT NULL THEN
    RETURN jsonb_build_object('resultado', 'revisar');
  END IF;
  IF v_res.tomada_at > now() - interval '5 minutes' THEN
    RETURN jsonb_build_object('resultado', 'en_curso');
  END IF;

  -- Vencida: se toma de nuevo sin borrar ultimo_arca/ambiente. Si esta función también muere antes de
  -- registrar un número nuevo, el próximo sigue teniendo contra qué comparar.
  UPDATE emisiones_factura_c_en_curso
  SET token = v_token, tomada_at = now(), tomada_por = auth.uid()
  WHERE venta_id = p_venta_id;

  RETURN jsonb_build_object(
    'resultado', 'reservada',
    'token', v_token,
    'pendiente_ultimo_arca', v_res.ultimo_arca,
    'pendiente_ambiente', v_res.ambiente
  );
END;
$$;

-- ─── 18. Dashboards (D8): internas fuera; consumo interno aparte ─────────────────────────────
CREATE OR REPLACE FUNCTION public.dashboard_ventas_por_dia(p_desde date, p_hasta date)
 RETURNS TABLE(fecha date, total numeric, cantidad integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  WITH ventas_rango AS (
    SELECT (v.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS dia,
           v.precio_cobrado
    FROM ventas v
    WHERE v.estado <> 'anulada'
      AND v.estado_interno IS NULL  -- docs/68 (D8)
      AND v.created_at >= (p_desde::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires')
      AND v.created_at <  ((p_hasta + 1)::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires')
  )
  SELECT g.dia::date,
         COALESCE(SUM(vr.precio_cobrado), 0)::numeric,
         COUNT(vr.dia)::int
  FROM generate_series(p_desde::timestamp, p_hasta::timestamp, interval '1 day') AS g(dia)
  LEFT JOIN ventas_rango vr ON vr.dia = g.dia::date
  GROUP BY g.dia
  ORDER BY g.dia;
$$;

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
    JOIN ventas vd ON vd.id = d.venta_id
    CROSS JOIN rango r
    WHERE d.estado = 'activa' AND d.fecha BETWEEN r.desde AND r.hasta
      AND vd.estado_interno IS NULL  -- docs/68 (D8)
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

-- Consumo interno en un rango (por fecha de la venta, hora AR): una fila por día × cliente ×
-- producto × estado. La UI agrupa por día, por cliente o por producto. Importe = total final
-- prorrateado por ítem; las devoluciones imputadas restan (a su precio vigente).
CREATE OR REPLACE FUNCTION public.dashboard_consumo_interno(p_desde date, p_hasta date)
 RETURNS TABLE(fecha date, cliente_id uuid, cliente_nombre text, producto_id uuid, nombre text, marca text,
               estado_interno estado_venta_interna, unidades numeric, importe numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  WITH vendidos AS (
    SELECT (v.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS dia,
           v.cliente_id, vi.producto_id, vi.producto_nombre AS nombre, vi.producto_marca AS marca,
           v.estado_interno, vi.cantidad,
           COALESCE(vi.importe * v.precio_cobrado / NULLIF(SUM(vi.importe) OVER (PARTITION BY v.id), 0), 0) AS importe
    FROM ventas v
    JOIN venta_items vi ON vi.venta_id = v.id
    WHERE v.estado <> 'anulada' AND v.estado_interno IS NOT NULL
      AND v.created_at >= (p_desde::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires')
      AND v.created_at <  ((p_hasta + 1)::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires')
  ),
  devueltos AS (
    SELECT d.fecha AS dia, v.cliente_id, di.producto_id, di.producto_nombre, di.producto_marca, v.estado_interno,
           CASE WHEN di.tipo = 'devuelto' THEN -di.cantidad ELSE di.cantidad END,
           CASE WHEN di.tipo = 'devuelto'
                THEN -ROUND(di.cantidad * COALESCE(pu.precio, di.precio_unitario), 2)
                ELSE ROUND(di.cantidad * di.precio_unitario, 2) END
    FROM devoluciones d
    JOIN devolucion_items di ON di.devolucion_id = d.id
    JOIN ventas v ON v.id = d.venta_id
    LEFT JOIN LATERAL (
      SELECT ROUND((SUM(vi.importe) / NULLIF(SUM(vi.cantidad), 0))
                   * (CASE WHEN v.subtotal > 0 THEN v.total / v.subtotal ELSE 1 END), 2) AS precio
      FROM venta_items vi WHERE vi.venta_id = d.venta_id AND vi.producto_id = di.producto_id
    ) pu ON di.tipo = 'devuelto'
    WHERE d.estado = 'activa' AND v.estado <> 'anulada' AND v.estado_interno IS NOT NULL
      AND d.fecha BETWEEN p_desde AND p_hasta
  ),
  movs AS (SELECT * FROM vendidos UNION ALL SELECT * FROM devueltos)
  SELECT m.dia, m.cliente_id, COALESCE(c.razon_social, c.nombre_fantasia), m.producto_id,
         MAX(m.nombre), MAX(m.marca), m.estado_interno,
         SUM(m.cantidad), round(SUM(m.importe), 2)
  FROM movs m
  JOIN clientes c ON c.id = m.cliente_id
  GROUP BY m.dia, m.cliente_id, COALESCE(c.razon_social, c.nombre_fantasia), m.producto_id, m.estado_interno
  ORDER BY m.dia, 3, 5;
$$;
REVOKE ALL ON FUNCTION public.dashboard_consumo_interno(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dashboard_consumo_interno(date, date) TO authenticated, service_role;

-- ─── 19. revertir_movimiento: rama pagos_cliente con medios, aplicaciones y origen ───────────
-- (el resto de la función es idéntico a docs/65 + docs/58)
CREATE OR REPLACE FUNCTION public.revertir_movimiento(p_auditoria_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
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
  v_medio_cli pagos_cliente_medios%ROWTYPE;  -- docs/68
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
    -- docs/68: reversión espejo del cobro. Copia el origen (un cobro de Local revertido resta del
    -- Cierre del día en que se revierte, igual que un egreso), invierte cada medio, devuelve a la
    -- cuenta solo lo que el cobro movió (neto) y deja sin efecto sus aplicaciones.
    v_pago_orig_id := (v_row->>'id')::UUID;
    v_monto := (v_row->>'monto')::NUMERIC;
    IF v_row->>'revierte_pago_cliente_id' IS NOT NULL OR v_monto < 0 THEN
      RAISE EXCEPTION 'Esto ya es la reversión de un cobro — no se revierte de nuevo';
    END IF;
    IF EXISTS (SELECT 1 FROM pagos_cliente WHERE revierte_pago_cliente_id = v_pago_orig_id) THEN
      RAISE EXCEPTION 'Este cobro ya fue revertido';
    END IF;

    INSERT INTO pagos_cliente (cliente_id, venta_id, monto, forma_pago, usuario_id, revierte_pago_cliente_id, origen, nota)
    SELECT pc.cliente_id, pc.venta_id, -1 * pc.monto, pc.forma_pago, auth.uid(), pc.id, pc.origen, 'Reversion desde Historial'
    FROM pagos_cliente pc WHERE pc.id = v_pago_orig_id
    RETURNING id INTO v_pago_rev_id;
    IF v_pago_rev_id IS NULL THEN RAISE EXCEPTION 'Cobro no encontrado'; END IF;

    FOR v_medio_cli IN SELECT * FROM pagos_cliente_medios WHERE pago_cliente_id = v_pago_orig_id ORDER BY orden LOOP
      INSERT INTO pagos_cliente_medios (pago_cliente_id, forma_pago, monto, orden, revierte_medio_id)
      VALUES (v_pago_rev_id, v_medio_cli.forma_pago, -1 * v_medio_cli.monto, v_medio_cli.orden, v_medio_cli.id);
    END LOOP;

    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
    SELECT mc.cuenta_id, 'pago_cliente', -1 * sum(mc.monto), v_pago_orig_id, auth.uid()
    FROM movimientos_cuenta mc
    WHERE mc.referencia_id = v_pago_orig_id AND mc.tipo = 'pago_cliente'
    GROUP BY mc.cuenta_id
    HAVING sum(mc.monto) <> 0;

    UPDATE pagos_cliente_aplicaciones
    SET revertida_at = now(), revertida_por = auth.uid()
    WHERE pago_cliente_id = v_pago_orig_id AND revertida_at IS NULL;

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

-- ─── 20. Datos existentes (re-verificados: si algo difiere, la migración aborta) ─────────────
DO $$
DECLARE
  v_esperados CONSTANT jsonb := '[
    {"cliente": "d69aa425-642a-4463-a41a-37630f5aa093", "nombre": "GRION ALICIA",       "perfil": "696bd7fb-aa27-4051-b8cd-d611ee90d1ae", "perfil_nombre": "Alicia"},
    {"cliente": "f7465242-2ac8-452b-a968-258f2afddfa7", "nombre": "LOPEZ ANA JULIA",    "perfil": "59ea3204-4e4a-4236-b6af-f633d428222a", "perfil_nombre": "Ana Julia"},
    {"cliente": "2efd60e5-d50c-4702-bde9-d53685ee871f", "nombre": "ALBORNOZ ALEJANDRA", "perfil": "baee3f17-904f-4ae8-94be-6c07b726e036", "perfil_nombre": "Ale"},
    {"cliente": "fde6fec6-e323-4e6e-a713-8469208238f7", "nombre": "BARONTINI JOSE",     "perfil": "596c3ed5-10c0-42b8-a6e0-a67967d38a4f", "perfil_nombre": "Jose"},
    {"cliente": "26720d5a-7304-4bae-9c48-c62b83ddb207", "nombre": "MALDONADO BELEN",    "perfil": "d6846144-9b2e-45bf-a46f-7eb8945ba636", "perfil_nombre": "Belu"}
  ]';
  e jsonb;
  v_venta ventas%ROWTYPE;
BEGIN
  FOR e IN SELECT * FROM jsonb_array_elements(v_esperados) LOOP
    IF NOT EXISTS (SELECT 1 FROM clientes WHERE id = (e->>'cliente')::uuid
                   AND COALESCE(razon_social, nombre_fantasia) = e->>'nombre') THEN
      RAISE EXCEPTION 'docs/68: el cliente % (%) no está como se relevó', e->>'nombre', e->>'cliente';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = (e->>'perfil')::uuid AND nombre = e->>'perfil_nombre' AND activo) THEN
      RAISE EXCEPTION 'docs/68: el perfil % (%) no está como se relevó', e->>'perfil_nombre', e->>'perfil';
    END IF;
    UPDATE clientes SET tipo = 'interno', perfil_id = (e->>'perfil')::uuid
    WHERE id = (e->>'cliente')::uuid AND (tipo <> 'interno' OR perfil_id IS DISTINCT FROM (e->>'perfil')::uuid);
  END LOOP;

  -- Venta N° 388 (D9): interna pendiente, sin tocar importes, ítems ni stock.
  SELECT * INTO v_venta FROM ventas WHERE id = '721198f9-ffa3-4b58-923d-9c841b165900';
  IF NOT FOUND OR v_venta.numero <> 388 OR v_venta.cliente_id <> '2efd60e5-d50c-4702-bde9-d53685ee871f'
     OR v_venta.forma_pago <> 'cuenta_corriente' OR v_venta.estado <> 'sin_facturar'
     OR v_venta.precio_cobrado <> 25900 OR v_venta.descuento_porcentaje <> 30 THEN
    RAISE EXCEPTION 'docs/68: la venta 388 no está como se relevó';
  END IF;
  UPDATE ventas
  SET estado_interno = 'pendiente', total_original = precio_cobrado, descuento_global_original = descuento_porcentaje
  WHERE id = '721198f9-ffa3-4b58-923d-9c841b165900' AND estado_interno IS NULL;

  -- Otra venta a cta. cte. de un interno que no sea la 388 → parar (no estaba relevada).
  IF EXISTS (SELECT 1 FROM ventas v JOIN clientes c ON c.id = v.cliente_id
             WHERE c.tipo = 'interno' AND v.forma_pago = 'cuenta_corriente' AND v.estado <> 'anulada'
               AND v.id <> '721198f9-ffa3-4b58-923d-9c841b165900' AND v.estado_interno IS NULL) THEN
    RAISE EXCEPTION 'docs/68: hay ventas a cta. cte. de internos además de la 388 — revisar antes de aplicar';
  END IF;
  IF EXISTS (SELECT 1 FROM pagos_cliente) AND NOT EXISTS (SELECT 1 FROM pagos_cliente_medios) THEN
    RAISE EXCEPTION 'docs/68: hay cobros de clientes previos sin medios — revisar antes de aplicar';
  END IF;
END $$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (solo lectura)
-- ════════════════════════════════════════════════════════════════════════════════════════════════
SELECT 'B1 internos' AS chequeo, count(*) FILTER (WHERE tipo = 'interno') AS internos,
       count(*) FILTER (WHERE perfil_id IS NOT NULL) AS con_perfil, count(*) AS clientes
FROM clientes;
SELECT 'B2 venta 388' AS chequeo, numero, estado_interno, total_original, descuento_global_original,
       precio_cobrado, total, descuento_porcentaje, version
FROM ventas WHERE numero = 388;
SELECT 'B3 vistas invoker' AS chequeo, relname, reloptions,
       has_table_privilege('anon', c.oid, 'SELECT') AS anon_select
FROM pg_class c WHERE relname IN ('clientes_saldo', 'ventas_cuenta_corriente_saldo', 'pagos_cliente_a_cuenta', 'consumo_interno_mensual')
ORDER BY relname;
SELECT 'B4 funciones sin anon' AS chequeo, p.proname, has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_exec,
       p.prosecdef AS definer
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
WHERE p.proname IN ('registrar_cobro_cliente', 'aplicar_cobros_a_cuenta', 'desaplicar_cobro', 'editar_venta_interna',
                    'finalizar_venta_interna', 'reabrir_venta_interna', 'dashboard_consumo_interno', 'credito_devoluciones_venta')
ORDER BY 2;
SELECT 'B5 tablas nuevas RLS' AS chequeo, relname, relrowsecurity,
       has_table_privilege('authenticated', c.oid, 'INSERT') AS auth_insert
FROM pg_class c WHERE relname IN ('pagos_cliente_medios', 'pagos_cliente_aplicaciones');
SELECT 'B6 saldos' AS chequeo, razon_social, tipo, saldo_actual, saldo_cobrable, consumo_interno_pendiente, deuda_comprobantes
FROM clientes_saldo ORDER BY razon_social;
SELECT 'B7 safeupdate' AS chequeo, p.proname
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
WHERE p.proname IN ('registrar_cobro_cliente', 'aplicar_cobros_a_cuenta', 'desaplicar_cobro', 'editar_venta_interna',
                    'finalizar_venta_interna', 'reabrir_venta_interna', 'revertir_movimiento', 'crear_devolucion', 'cerrar_caja')
  AND regexp_replace(regexp_replace(p.prosrc, 'FOR UPDATE|DO UPDATE', '', 'g'), '\s+', ' ', 'g')
      ~* '(UPDATE [a-z_]+ SET [^;]*;)' AND NOT (regexp_replace(p.prosrc, '\s+', ' ', 'g') ~* 'UPDATE [a-z_]+ SET [^;]* WHERE');

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (BEGIN … ROLLBACK). SOLO en la restauración local: confirmar_venta consume
-- ventas.numero aunque se haga ROLLBACK. Usa los usuarios "Admin de prueba" y "Cajero de prueba",
-- el cliente externo HYPRED y la clienta interna MALDONADO BELEN. Termina con RAISE EXCEPTION
-- 'RESULTADO: …' para que nada quede escrito.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
  c_admin  CONSTANT uuid := '6f216c32-2bdb-423c-8aef-a96acaee9cc1';
  c_cajero CONSTANT uuid := 'c982462a-526a-4ee7-aade-4488b74966b3';
  c_ext    CONSTANT uuid := '46df5bd2-cddd-4415-a6d8-bfca4ac26c39';  -- HYPRED (externo)
  c_int    CONSTANT uuid := '26720d5a-7304-4bae-9c48-c62b83ddb207';  -- MALDONADO BELEN (interna)
  p1 uuid; p2 uuid; pr1 numeric; pr2 numeric; co1 numeric; iva1 boolean;
  st1 numeric; st1_post numeric;
  v_int uuid; v_ext_a uuid; v_ext_b uuid; v_ef uuid; v_tmp uuid;
  r record; j jsonb; e text; n int := 0;
  it1 uuid; it2 uuid; v_created timestamptz; v_saldo numeric; v_saldo2 numeric;
  v_x1 uuid; v_x2 uuid; v_esp1 numeric; v_esp2 numeric; v_z uuid;
  v_pago_gen uuid; v_pago_turno uuid; v_aud uuid;
  v_dash_antes numeric; v_dash_despues numeric;
BEGIN
  -- Productos de prueba (activos, con costo).
  SELECT id, precio_venta, costo, iva_porcentaje > 0 INTO p1, pr1, co1, iva1 FROM productos
   WHERE estado = 'activo' AND costo IS NOT NULL AND precio_manual IS NULL ORDER BY nombre LIMIT 1;
  SELECT id, precio_venta INTO p2, pr2 FROM productos
   WHERE estado = 'activo' AND costo IS NOT NULL AND precio_manual IS NULL AND id <> p1 ORDER BY nombre DESC LIMIT 1;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_cajero, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', '{"x-virikyna-app":"local"}', true);
  SELECT d.total INTO v_dash_antes FROM dashboard_ventas_por_dia(current_date, current_date) d;

  -- ── C1: venta nueva a interno → pendiente con costo snapshot ──
  v_int := confirmar_venta(c_int, 'cuenta_corriente',
    jsonb_build_array(jsonb_build_object('producto_id', p1, 'cantidad', 2, 'precio_unitario', pr1),
                      jsonb_build_object('producto_id', p2, 'cantidad', 1, 'precio_unitario', pr2)), 10);
  SELECT * INTO r FROM ventas WHERE id = v_int;
  IF r.estado_interno IS DISTINCT FROM 'pendiente' OR r.total_original <> r.precio_cobrado
     OR r.descuento_global_original <> 10 OR r.version <> 0 THEN
    RAISE EXCEPTION 'FALLA C1 cabecera: %', to_jsonb(r);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM venta_items WHERE venta_id = v_int AND producto_id = p1
                 AND costo_unitario = co1 AND producto_con_iva = iva1) THEN
    RAISE EXCEPTION 'FALLA C1 costo snapshot';
  END IF;
  n := n + 1;

  -- ── C2: venta nueva a externo → igual que hoy ──
  v_ext_a := confirmar_venta(c_ext, 'cuenta_corriente', jsonb_build_array(jsonb_build_object('producto_id', p1, 'cantidad', 1, 'precio_unitario', pr1)));
  v_ext_b := confirmar_venta(c_ext, 'cuenta_corriente', jsonb_build_array(jsonb_build_object('producto_id', p2, 'cantidad', 2, 'precio_unitario', pr2)));
  v_ef := confirmar_venta(NULL, 'efectivo', jsonb_build_array(jsonb_build_object('producto_id', p2, 'cantidad', 1, 'precio_unitario', pr2)));
  IF (SELECT estado_interno FROM ventas WHERE id = v_ext_a) IS NOT NULL
     OR (SELECT count(*) FROM venta_pagos WHERE venta_id = v_ef) <> 1
     OR (SELECT count(*) FROM venta_pagos WHERE venta_id = v_ext_a) <> 0
     OR NOT EXISTS (SELECT 1 FROM venta_items WHERE venta_id = v_ext_a AND costo_unitario = co1) THEN
    RAISE EXCEPTION 'FALLA C2';
  END IF;
  n := n + 1;

  -- ── C3: editar interna ──
  SELECT cantidad INTO st1 FROM stock_ubicaciones WHERE producto_id = p1 AND ubicacion = 'local';
  SELECT created_at INTO v_created FROM ventas WHERE id = v_int;
  SELECT id INTO it1 FROM venta_items WHERE venta_id = v_int AND producto_id = p1;
  SELECT id INTO it2 FROM venta_items WHERE venta_id = v_int AND producto_id = p2;
  BEGIN
    PERFORM editar_venta_interna(v_int, jsonb_build_array(jsonb_build_object('item_id', it1, 'descuento_porcentaje', 20),
                                                         jsonb_build_object('item_id', it2, 'descuento_porcentaje', 0)), 0);
    RAISE EXCEPTION 'FALLA C3: el cajero editó';
  EXCEPTION WHEN others THEN e := SQLERRM; END;
  IF e NOT LIKE 'Solo un administrador%' THEN RAISE EXCEPTION 'FALLA C3 cajero: %', e; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', '{"x-virikyna-app":"gestion"}', true);
  BEGIN PERFORM editar_venta_interna(v_int, jsonb_build_array(jsonb_build_object('item_id', it1, 'descuento_porcentaje', -1),
                                                             jsonb_build_object('item_id', it2, 'descuento_porcentaje', 0)), 0);
        RAISE EXCEPTION 'FALLA C3: aceptó -1'; EXCEPTION WHEN others THEN e := SQLERRM; END;
  IF e NOT LIKE 'El descuento tiene que estar entre 0 y 100%' THEN RAISE EXCEPTION 'FALLA C3 -1: %', e; END IF;
  BEGIN PERFORM editar_venta_interna(v_int, jsonb_build_array(jsonb_build_object('item_id', it1, 'descuento_porcentaje', 101),
                                                             jsonb_build_object('item_id', it2, 'descuento_porcentaje', 0)), 0);
        RAISE EXCEPTION 'FALLA C3: aceptó 101'; EXCEPTION WHEN others THEN e := SQLERRM; END;
  IF e NOT LIKE 'El descuento tiene que estar entre 0 y 100%' THEN RAISE EXCEPTION 'FALLA C3 101: %', e; END IF;
  BEGIN PERFORM editar_venta_interna(v_int, jsonb_build_array(jsonb_build_object('item_id', it1, 'descuento_porcentaje', 5),
                                                             jsonb_build_object('item_id', it2, 'descuento_porcentaje', 0)), 7);
        RAISE EXCEPTION 'FALLA C3: aceptó versión vieja'; EXCEPTION WHEN others THEN e := SQLERRM; END;
  IF e NOT LIKE 'El comprobante cambió%' THEN RAISE EXCEPTION 'FALLA C3 versión: %', e; END IF;
  BEGIN PERFORM editar_venta_interna(v_int, jsonb_build_array(jsonb_build_object('item_id', it1, 'descuento_porcentaje', 5)), 0);
        RAISE EXCEPTION 'FALLA C3: aceptó ítems incompletos'; EXCEPTION WHEN others THEN e := SQLERRM; END;
  IF e NOT LIKE 'Mandá el descuento de todos%' THEN RAISE EXCEPTION 'FALLA C3 incompletos: %', e; END IF;
  BEGIN PERFORM editar_venta_interna(v_ext_a, jsonb_build_array(jsonb_build_object('item_id', it1, 'descuento_porcentaje', 5)), 0);
        RAISE EXCEPTION 'FALLA C3: editó una externa'; EXCEPTION WHEN others THEN e := SQLERRM; END;
  IF e NOT LIKE 'Solo se editan comprobantes de clientes internos%' THEN RAISE EXCEPTION 'FALLA C3 externa: %', e; END IF;

  j := editar_venta_interna(v_int, jsonb_build_array(jsonb_build_object('item_id', it1, 'descuento_porcentaje', 20),
                                                    jsonb_build_object('item_id', it2, 'descuento_porcentaje', 0)), 0);
  SELECT * INTO r FROM ventas WHERE id = v_int;
  IF r.total <> ROUND(ROUND(2 * pr1 * 0.8, 2) + ROUND(pr2, 2), 2) OR r.descuento_porcentaje <> 0
     OR r.precio_cobrado <> r.total OR r.precio_oficial <> r.total OR r.version <> 1 OR r.created_at <> v_created
     OR r.editada_por <> c_admin OR (j->>'version')::int <> 1 THEN
    RAISE EXCEPTION 'FALLA C3 recálculo: % / %', to_jsonb(r), j;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM venta_items WHERE id = it1 AND precio_unitario_original = pr1
                 AND descuento_porcentaje_original = 0 AND descuento_porcentaje = 20 AND precio_unitario = pr1
                 AND cantidad = 2 AND importe = ROUND(2 * pr1 * 0.8, 2)) THEN
    RAISE EXCEPTION 'FALLA C3 ítem';
  END IF;
  SELECT cantidad INTO st1_post FROM stock_ubicaciones WHERE producto_id = p1 AND ubicacion = 'local';
  IF st1_post <> st1 OR (SELECT count(*) FROM movimientos_stock WHERE referencia_id = v_int) <> 2 THEN
    RAISE EXCEPTION 'FALLA C3 stock: % → %', st1, st1_post;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auditoria WHERE tabla_afectada = 'venta_items' AND registro_id = it1 AND accion = 'edicion') THEN
    RAISE EXCEPTION 'FALLA C3 auditoría de ítems';
  END IF;
  -- 100 %: queda en $0 (permitido solo para internas)
  PERFORM editar_venta_interna(v_int, jsonb_build_array(jsonb_build_object('item_id', it1, 'descuento_porcentaje', 100),
                                                       jsonb_build_object('item_id', it2, 'descuento_porcentaje', 100)), 1);
  IF (SELECT total FROM ventas WHERE id = v_int) <> 0 THEN RAISE EXCEPTION 'FALLA C3 100'; END IF;
  PERFORM editar_venta_interna(v_int, jsonb_build_array(jsonb_build_object('item_id', it1, 'descuento_porcentaje', 20),
                                                       jsonb_build_object('item_id', it2, 'descuento_porcentaje', 0)), 2);
  n := n + 1;

  -- ── C4: Factura C sobre interna rechazada; sobre externa reserva normal ──
  BEGIN PERFORM reservar_emision_factura_c(v_int); RAISE EXCEPTION 'FALLA C4: reservó una interna';
  EXCEPTION WHEN others THEN e := SQLERRM; END;
  IF e NOT LIKE 'Es un consumo interno%' THEN RAISE EXCEPTION 'FALLA C4: %', e; END IF;
  IF reservar_emision_factura_c(v_ef)->>'resultado' <> 'reservada' THEN RAISE EXCEPTION 'FALLA C4 externa'; END IF;
  IF EXISTS (SELECT 1 FROM emisiones_factura_c_en_curso WHERE venta_id = v_int) THEN RAISE EXCEPTION 'FALLA C4 quedó reserva'; END IF;
  n := n + 1;

  -- ── C5: devolución sobre interna pendiente (editada) → baja su deuda al precio editado ──
  SELECT saldo_actual INTO v_saldo FROM clientes_saldo WHERE id = c_int;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_cajero, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', '{"x-virikyna-app":"local"}', true);
  -- Local viejo manda forma de pago para "devolver la diferencia": igual va a la cuenta (D12).
  v_tmp := crear_devolucion(v_int, 'arrepentimiento', NULL, NULL,
             jsonb_build_array(jsonb_build_object('producto_id', p1, 'cantidad', 1)), NULL, 'efectivo');
  SELECT * INTO r FROM devoluciones WHERE id = v_tmp;
  IF NOT r.a_cuenta_corriente OR r.diferencia_forma_pago IS NOT NULL
     OR EXISTS (SELECT 1 FROM devolucion_pagos WHERE devolucion_id = v_tmp) THEN
    RAISE EXCEPTION 'FALLA C5 devolución: %', to_jsonb(r);
  END IF;
  SELECT saldo_actual INTO v_saldo2 FROM clientes_saldo WHERE id = c_int;
  IF v_saldo - v_saldo2 <> ROUND(pr1 * 0.8, 2) THEN
    RAISE EXCEPTION 'FALLA C5 saldo: % → % (esperado −%)', v_saldo, v_saldo2, ROUND(pr1 * 0.8, 2);
  END IF;
  n := n + 1;

  -- ── C6: finalizar / reabrir ──
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', '{"x-virikyna-app":"gestion"}', true);
  j := finalizar_venta_interna(v_int, 3);
  SELECT * INTO r FROM ventas WHERE id = v_int;
  IF r.estado_interno <> 'finalizado' OR r.finalizada_por <> c_admin OR r.finalizada_at IS NULL
     OR EXISTS (SELECT 1 FROM pagos_cliente WHERE cliente_id = c_int)
     OR EXISTS (SELECT 1 FROM movimientos_cuenta WHERE referencia_id = v_int)
     OR EXISTS (SELECT 1 FROM venta_pagos WHERE venta_id = v_int) THEN
    RAISE EXCEPTION 'FALLA C6 finalizar: %', to_jsonb(r);
  END IF;
  IF (SELECT saldo_actual FROM clientes_saldo WHERE id = c_int) <> 0 THEN
    RAISE EXCEPTION 'FALLA C6 saldo tras finalizar: %', (SELECT saldo_actual FROM clientes_saldo WHERE id = c_int);
  END IF;
  IF (SELECT total FROM consumo_interno_mensual WHERE cliente_id = c_int
       AND mes = date_trunc('month', now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date) <> v_saldo2 THEN
    RAISE EXCEPTION 'FALLA C6 mensual';
  END IF;
  BEGIN PERFORM editar_venta_interna(v_int, '[]'::jsonb, 4); RAISE EXCEPTION 'FALLA C6 editó finalizada';
  EXCEPTION WHEN others THEN e := SQLERRM; END;
  IF e NOT LIKE 'El comprobante está finalizado%' THEN RAISE EXCEPTION 'FALLA C6 editar finalizada: %', e; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_cajero, 'role', 'authenticated')::text, true);
  BEGIN PERFORM crear_devolucion(v_int, 'arrepentimiento', NULL, NULL, jsonb_build_array(jsonb_build_object('producto_id', p2, 'cantidad', 1)));
        RAISE EXCEPTION 'FALLA C6 devolución sobre finalizada'; EXCEPTION WHEN others THEN e := SQLERRM; END;
  IF e NOT LIKE 'Es un consumo interno ya finalizado%' THEN RAISE EXCEPTION 'FALLA C6 dev finalizada: %', e; END IF;
  BEGIN PERFORM reabrir_venta_interna(v_int, 'x'); RAISE EXCEPTION 'FALLA C6 cajero reabrió';
  EXCEPTION WHEN others THEN e := SQLERRM; END;
  IF e NOT LIKE 'Solo un administrador%' THEN RAISE EXCEPTION 'FALLA C6 cajero: %', e; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_admin, 'role', 'authenticated')::text, true);
  BEGIN PERFORM reabrir_venta_interna(v_int, '  '); RAISE EXCEPTION 'FALLA C6 sin motivo';
  EXCEPTION WHEN others THEN e := SQLERRM; END;
  IF e NOT LIKE 'El motivo es obligatorio%' THEN RAISE EXCEPTION 'FALLA C6 motivo: %', e; END IF;
  PERFORM reabrir_venta_interna(v_int, 'Corrección del descuento');
  SELECT * INTO r FROM ventas WHERE id = v_int;
  IF r.estado_interno <> 'pendiente' OR r.finalizada_at IS NOT NULL OR r.reabierta_motivo <> 'Correccion del descuento'
     OR r.reabierta_por <> c_admin OR r.version <> 5 THEN
    RAISE EXCEPTION 'FALLA C6 reabrir: %', to_jsonb(r);
  END IF;
  IF (SELECT count(*) FROM auditoria WHERE tabla_afectada = 'ventas' AND registro_id = v_int AND accion = 'edicion') < 5 THEN
    RAISE EXCEPTION 'FALLA C6 auditoría ventas';
  END IF;
  n := n + 1;

  -- ── C7: cobros de externo ──
  j := registrar_cobro_cliente(c_ext, jsonb_build_array(jsonb_build_object('forma_pago', 'efectivo', 'monto', 100),
                                                        jsonb_build_object('forma_pago', 'transferencia', 'monto', 50)),
                               ARRAY[v_ext_a], 'general', NULL, 'Cobro parcial', 150);
  v_pago_gen := (j->>'pago_id')::uuid;
  IF (j->>'aplicado')::numeric <> 150 OR (j->>'a_cuenta')::numeric <> 0
     OR (SELECT forma_pago FROM pagos_cliente WHERE id = v_pago_gen) <> 'combinado'
     OR (SELECT count(*) FROM pagos_cliente_medios WHERE pago_cliente_id = v_pago_gen) <> 2
     OR (SELECT count(*) FROM movimientos_cuenta WHERE referencia_id = v_pago_gen AND tipo = 'pago_cliente') <> 2
     OR (SELECT estado_cuenta FROM ventas_cuenta_corriente_saldo WHERE id = v_ext_a) <> 'parcial' THEN
    RAISE EXCEPTION 'FALLA C7 general: %', j;
  END IF;
  BEGIN PERFORM registrar_cobro_cliente(c_int, '[{"forma_pago":"efectivo","monto":10}]', ARRAY[v_int], 'general');
        RAISE EXCEPTION 'FALLA C7 cobró interna'; EXCEPTION WHEN others THEN e := SQLERRM; END;
  IF e NOT LIKE '%es de consumo interno%' THEN RAISE EXCEPTION 'FALLA C7 interna: %', e; END IF;
  SELECT saldo_cobrable INTO v_saldo FROM clientes_saldo WHERE id = c_ext;
  BEGIN PERFORM registrar_cobro_cliente(c_ext, jsonb_build_array(jsonb_build_object('forma_pago', 'efectivo', 'monto', v_saldo + 1)), NULL, 'general');
        RAISE EXCEPTION 'FALLA C7 sobrecobro'; EXCEPTION WHEN others THEN e := SQLERRM; END;
  IF e NOT LIKE 'El cobro % supera lo que debe el cliente%' THEN RAISE EXCEPTION 'FALLA C7 sobrecobro: %', e; END IF;
  BEGIN PERFORM registrar_cobro_cliente(c_ext, '[{"forma_pago":"efectivo","monto":10}]', NULL, 'general', NULL, NULL, 11);
        RAISE EXCEPTION 'FALLA C7 suma'; EXCEPTION WHEN others THEN e := SQLERRM; END;
  IF e NOT LIKE 'La suma de los medios%' THEN RAISE EXCEPTION 'FALLA C7 suma: %', e; END IF;
  BEGIN PERFORM registrar_cobro_cliente(c_ext, '[{"forma_pago":"cuenta_corriente","monto":10}]', NULL, 'general');
        RAISE EXCEPTION 'FALLA C7 medio'; EXCEPTION WHEN others THEN e := SQLERRM; END;
  IF e NOT LIKE 'Medio de cobro%' THEN RAISE EXCEPTION 'FALLA C7 medio: %', e; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_cajero, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', '{"x-virikyna-app":"local"}', true);
  BEGIN PERFORM registrar_cobro_cliente(c_ext, '[{"forma_pago":"efectivo","monto":10}]', NULL, 'general');
        RAISE EXCEPTION 'FALLA C7 cajero general'; EXCEPTION WHEN others THEN e := SQLERRM; END;
  IF e NOT LIKE 'Solo un administrador%' THEN RAISE EXCEPTION 'FALLA C7 cajero: %', e; END IF;
  n := n + 1;

  -- ── C8: cobro turno en efectivo: sin movimiento de cuenta, entra al Cierre X ──
  v_x1 := cerrar_caja('x');
  SELECT efectivo_esperado INTO v_esp1 FROM cierres_caja WHERE id = v_x1;
  j := registrar_cobro_cliente(c_ext, jsonb_build_array(jsonb_build_object('forma_pago', 'efectivo', 'monto', pr1 - 150 + 10)),
                               ARRAY[v_ext_a], 'turno');
  v_pago_turno := (j->>'pago_id')::uuid;
  IF (j->>'a_cuenta')::numeric <> 10 OR (SELECT estado_cuenta FROM ventas_cuenta_corriente_saldo WHERE id = v_ext_a) <> 'pagada'
     OR EXISTS (SELECT 1 FROM movimientos_cuenta WHERE referencia_id = v_pago_turno)
     OR (SELECT origen FROM pagos_cliente WHERE id = v_pago_turno) <> 'turno' THEN
    RAISE EXCEPTION 'FALLA C8 turno: %', j;
  END IF;
  PERFORM registrar_cobro_cliente(c_ext, '[{"forma_pago":"qr","monto":20}]', ARRAY[v_ext_b], 'turno');
  v_x2 := cerrar_caja('x');
  SELECT * INTO r FROM cierres_caja WHERE id = v_x2;
  v_esp2 := r.efectivo_esperado;
  IF v_esp2 - v_esp1 <> pr1 - 150 + 10 OR r.total_cobros_efectivo < pr1 - 150 + 10 OR r.total_cobros_qr < 20
     OR r.cantidad_cobros < 2 THEN
    RAISE EXCEPTION 'FALLA C8 cierre: esp % → %, %', v_esp1, v_esp2, to_jsonb(r);
  END IF;
  BEGIN PERFORM registrar_cobro_cliente(c_ext, '[{"forma_pago":"efectivo","monto":1}]', NULL, 'turno', current_date - 3);
        RAISE EXCEPTION 'FALLA C8 fecha'; EXCEPTION WHEN others THEN e := SQLERRM; END;
  IF e NOT LIKE 'Un cobro en la caja de Local es siempre de hoy%' THEN RAISE EXCEPTION 'FALLA C8 fecha: %', e; END IF;
  n := n + 1;

  -- ── C9: aplicar a cuenta y desaplicar ──
  j := aplicar_cobros_a_cuenta(c_ext, ARRAY[v_ext_b]);
  IF (j->>'aplicado')::numeric <> 10 OR (j->>'a_cuenta_restante')::numeric <> 0 THEN RAISE EXCEPTION 'FALLA C9 aplicar: %', j; END IF;
  v_tmp := (j->'aplicaciones'->0->>'id')::uuid;
  BEGIN PERFORM desaplicar_cobro(v_tmp); RAISE EXCEPTION 'FALLA C9 cajero desaplicó';
  EXCEPTION WHEN others THEN e := SQLERRM; END;
  IF e NOT LIKE 'Solo un administrador%' THEN RAISE EXCEPTION 'FALLA C9 cajero: %', e; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_admin, 'role', 'authenticated')::text, true);
  PERFORM desaplicar_cobro(v_tmp);
  IF (SELECT a_cuenta FROM clientes_saldo WHERE id = c_ext) <> 10 THEN RAISE EXCEPTION 'FALLA C9 desaplicar'; END IF;
  n := n + 1;

  -- ── C10: devolución sobre venta externa a cta. cte. → baja la deuda, sin plata ──
  SELECT saldo_actual INTO v_saldo FROM clientes_saldo WHERE id = c_ext;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_cajero, 'role', 'authenticated')::text, true);
  v_tmp := crear_devolucion(v_ext_b, 'arrepentimiento', NULL, NULL, jsonb_build_array(jsonb_build_object('producto_id', p2, 'cantidad', 1)), NULL, 'efectivo');
  SELECT saldo_actual INTO v_saldo2 FROM clientes_saldo WHERE id = c_ext;
  IF v_saldo - v_saldo2 <> pr2 OR EXISTS (SELECT 1 FROM devolucion_pagos WHERE devolucion_id = v_tmp)
     OR (SELECT total_devuelto FROM ventas_cuenta_corriente_saldo WHERE id = v_ext_b) <> pr2 THEN
    RAISE EXCEPTION 'FALLA C10: % → %', v_saldo, v_saldo2;
  END IF;
  v_tmp := crear_devolucion(v_ef, 'arrepentimiento', NULL, NULL, jsonb_build_array(jsonb_build_object('producto_id', p2, 'cantidad', 1)), NULL, 'efectivo');
  IF (SELECT a_cuenta_corriente FROM devoluciones WHERE id = v_tmp)
     OR NOT EXISTS (SELECT 1 FROM devolucion_pagos WHERE devolucion_id = v_tmp AND forma_pago = 'efectivo' AND monto = pr2) THEN
    RAISE EXCEPTION 'FALLA C10 contado';
  END IF;
  n := n + 1;

  -- ── C11: revertir un cobro desde el Historial ──
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_admin, 'role', 'authenticated')::text, true);
  SELECT saldo_actual INTO v_saldo FROM clientes_saldo WHERE id = c_ext;
  SELECT id INTO v_aud FROM auditoria WHERE tabla_afectada = 'pagos_cliente' AND registro_id = v_pago_gen AND accion = 'alta';
  PERFORM revertir_movimiento(v_aud);
  IF (SELECT saldo_actual FROM clientes_saldo WHERE id = c_ext) <> v_saldo + 150
     OR (SELECT COALESCE(sum(monto), 0) FROM movimientos_cuenta WHERE referencia_id = v_pago_gen) <> 0
     OR EXISTS (SELECT 1 FROM pagos_cliente_aplicaciones WHERE pago_cliente_id = v_pago_gen AND revertida_at IS NULL)
     OR (SELECT sum(m.monto) FROM pagos_cliente_medios m JOIN pagos_cliente pc ON pc.id = m.pago_cliente_id
          WHERE pc.revierte_pago_cliente_id = v_pago_gen) <> -150 THEN
    RAISE EXCEPTION 'FALLA C11';
  END IF;
  n := n + 1;

  -- ── C12: Cierre Z + validar: lo no-efectivo cobrado en turno va a su cuenta ──
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_cajero, 'role', 'authenticated')::text, true);
  v_z := cerrar_caja('z', 0);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_admin, 'role', 'authenticated')::text, true);
  PERFORM validar_cierre_z(v_z);
  IF (SELECT total_cobros_qr FROM cierres_caja WHERE id = v_z) < 20
     OR (SELECT sum(monto) FROM movimientos_cuenta WHERE referencia_id = v_z AND tipo = 'cierre_z'
          AND cuenta_id = (SELECT cuenta_id FROM cuenta_forma_pago WHERE forma_pago = 'qr'))
        <> (SELECT total_qr + total_devoluciones_qr + total_cobros_qr + total_tarjeta + total_devoluciones_tarjeta + total_cobros_tarjeta
            FROM cierres_caja WHERE id = v_z) THEN
    RAISE EXCEPTION 'FALLA C12';
  END IF;
  n := n + 1;

  -- ── C13: dashboards ──
  SELECT d.total INTO v_dash_despues FROM dashboard_ventas_por_dia(current_date, current_date) d;
  IF v_dash_despues - v_dash_antes <> (SELECT sum(precio_cobrado) FROM ventas WHERE id IN (v_ext_a, v_ext_b, v_ef)) THEN
    RAISE EXCEPTION 'FALLA C13 por día: % → %', v_dash_antes, v_dash_despues;
  END IF;
  IF (SELECT d.unidades FROM dashboard_ventas_por_producto(current_date, current_date) d WHERE d.producto_id = p1)
     IS DISTINCT FROM (SELECT sum(vi.cantidad) FROM venta_items vi JOIN ventas v ON v.id = vi.venta_id
                       WHERE vi.producto_id = p1 AND v.estado_interno IS NULL AND v.estado <> 'anulada'
                         AND (v.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
                             = (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date) THEN
    RAISE EXCEPTION 'FALLA C13 por producto incluye internas';
  END IF;
  IF (SELECT sum(importe) FROM dashboard_consumo_interno(current_date, current_date) WHERE cliente_id = c_int)
     <> (SELECT total - credito_devoluciones_venta(id) FROM ventas WHERE id = v_int) THEN
    RAISE EXCEPTION 'FALLA C13 consumo interno: %', (SELECT jsonb_agg(d) FROM dashboard_consumo_interno(current_date, current_date) d);
  END IF;
  n := n + 1;

  -- ── C14: Local viejo — confirmar_venta sin p_client_id y registrar_pago_cliente ──
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_cajero, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', '{"x-virikyna-app":"local"}', true);
  v_ext_a := confirmar_venta(c_ext, 'cuenta_corriente', jsonb_build_array(jsonb_build_object('producto_id', p1, 'cantidad', 1, 'precio_unitario', pr1)), 0, NULL, 0, NULL, NULL);
  v_tmp := registrar_pago_cliente(c_ext, v_ext_a, 30, 'efectivo');
  IF (SELECT origen FROM pagos_cliente WHERE id = v_tmp) <> 'turno'
     OR EXISTS (SELECT 1 FROM movimientos_cuenta WHERE referencia_id = v_tmp)
     OR NOT EXISTS (SELECT 1 FROM pagos_cliente_aplicaciones WHERE pago_cliente_id = v_tmp AND venta_id = v_ext_a AND monto = 30)
     OR NOT EXISTS (SELECT 1 FROM pagos_cliente_medios WHERE pago_cliente_id = v_tmp AND forma_pago = 'efectivo' AND monto = 30) THEN
    RAISE EXCEPTION 'FALLA C14 local';
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', '', true);
  v_tmp := registrar_pago_cliente(c_ext, NULL, 5, 'transferencia');
  IF (SELECT origen FROM pagos_cliente WHERE id = v_tmp) <> 'general'
     OR (SELECT count(*) FROM movimientos_cuenta WHERE referencia_id = v_tmp AND monto = 5) <> 1 THEN
    RAISE EXCEPTION 'FALLA C14 gestion';
  END IF;
  n := n + 1;

  -- ── C15: un cajero no se marca interno / externo ──
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_cajero, 'role', 'authenticated')::text, true);
  BEGIN UPDATE clientes SET tipo = 'externo', perfil_id = NULL WHERE id = c_int; RAISE EXCEPTION 'FALLA C15 cambió tipo';
  EXCEPTION WHEN others THEN e := SQLERRM; END;
  IF e NOT LIKE 'Solo un administrador puede cambiar%' THEN RAISE EXCEPTION 'FALLA C15: %', e; END IF;
  UPDATE clientes SET celular = '123' WHERE id = c_int;  -- el resto de la ficha sí
  BEGIN INSERT INTO clientes (razon_social, tipo) VALUES ('PRUEBA INTERNO', 'interno'); RAISE EXCEPTION 'FALLA C15 alta interna';
  EXCEPTION WHEN others THEN e := SQLERRM; END;
  IF e NOT LIKE 'Solo un administrador puede dar de alta%' THEN RAISE EXCEPTION 'FALLA C15 alta: %', e; END IF;
  n := n + 1;

  RAISE EXCEPTION 'RESULTADO: % de 15 OK', n;
END $$;
ROLLBACK;
