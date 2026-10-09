-- 41 — Observaciones del proveedor: nota libre (ayuda memoria) visible al cargar una compra y en
-- la cuenta corriente del proveedor
--
-- docs/06_estructura_de_datos.md, sección 26, tiene el detalle. Correr desde la raíz del repo con
-- `npx supabase db query --linked -f docs/41_observaciones_proveedor.sql` (o en el SQL Editor del
-- proyecto ccpinvtleqlsukcqnili), después de 40. La PARTE A va una sola vez; la PARTE B
-- (verificación) y la PARTE C (test, BEGIN … ROLLBACK) se pueden repetir.
--
-- Contexto (relevado contra la base real el 2026-10-08):
--   - proveedores no tiene ninguna columna de notas.
--   - La única vista que lee proveedores es proveedores_saldo (lista de columnas explícita, la de
--     docs/31 con security_invoker = on de docs/38). La usan el listado de Proveedores y la cuenta
--     corriente (useProveedor), así que necesita la columna nueva.
--   - Funciones que tocan proveedores: cargar_saldos_iniciales, eliminar_proveedor,
--     cargar_factura_compra, registrar_pago_proveedor_v2 (no leen columnas de datos) y
--     revertir_alta / revertir_edicion (genéricas, arman el UPDATE desde el JSON de auditoría).
--     Ninguna necesita cambios.
--   - RLS: proveedores_select / _insert / _update / _delete_solo_admin son por fila, no por
--     columna. La columna nueva queda cubierta sin tocar nada.
--
-- Qué hace:
--   1. proveedores.observaciones TEXT NULL, sin default ni constraint. Aditiva: los inserts y
--      updates actuales (que no la mandan) siguen andando y la dejan en null.
--   2. proveedores_saldo: + observaciones al final (CREATE OR REPLACE, mismo cuerpo que docs/31).
--      Así ProveedorSaldo = Proveedor & {...} sigue siendo cierto.
--      ⚠ CREATE OR REPLACE VIEW reemplaza las opciones de la vista: sin el WITH se perdería el
--      security_invoker de docs/38 y la vista volvería a saltear la RLS.
--
-- Auditoría: trg_auditoria_proveedores guarda to_jsonb(NEW/OLD), así que altas y ediciones ya
-- registran observaciones, y revertir_edicion la restaura como cualquier otra columna.

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios (una transacción)
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

ALTER TABLE proveedores ADD COLUMN IF NOT EXISTS observaciones TEXT;

COMMENT ON COLUMN proveedores.observaciones IS
  'Notas internas libres sobre el proveedor (ayuda memoria). Null si no hay. Se muestran al cargar una compra y en su cuenta corriente.';

CREATE OR REPLACE VIEW proveedores_saldo WITH (security_invoker = on) AS
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
  p.saldo_inicial + COALESCE(facturado.total_facturado, 0) - COALESCE(pagado.total_pagado, 0) AS saldo_actual,
  p.observaciones
FROM proveedores p
LEFT JOIN (
  SELECT
    proveedor_id,
    SUM(CASE WHEN tipo_comprobante = 'nota_credito' THEN -total ELSE total END) AS total_facturado
  FROM facturas_compra
  WHERE anulada = false
  GROUP BY proveedor_id
) facturado ON facturado.proveedor_id = p.id
LEFT JOIN (
  SELECT proveedor_id, SUM(monto) AS total_pagado
  FROM pagos_proveedor
  GROUP BY proveedor_id
) pagado ON pagado.proveedor_id = p.id;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (repetible)
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- B1. Columna: text, nullable, sin default.
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'proveedores' AND column_name = 'observaciones';

-- B2. La vista sigue con security_invoker y trae la columna al final.
SELECT c.reloptions,
       (SELECT array_agg(attname ORDER BY attnum) FROM pg_attribute
        WHERE attrelid = c.oid AND attnum > 0 AND NOT attisdropped) AS columnas
FROM pg_class c
WHERE c.oid = 'public.proveedores_saldo'::regclass;

-- B3. Grants de la vista sin cambios (docs/38: solo SELECT para authenticated, nada para anon).
SELECT grantee, privilege_type
FROM information_schema.role_table_grants
WHERE table_schema = 'public' AND table_name = 'proveedores_saldo'
ORDER BY grantee, privilege_type;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (no deja nada: BEGIN … ROLLBACK)
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

INSERT INTO proveedores (razon_social) VALUES ('ZZ test observaciones 41');

-- C1. Un alta sin observaciones (como las versiones viejas de las apps) la deja en null.
SELECT 'C1 alta sin observaciones' AS test, (observaciones IS NULL) AS ok
FROM proveedores WHERE razon_social = 'ZZ test observaciones 41';

-- C2. Multilínea: se guarda tal cual y la vista la devuelve.
UPDATE proveedores SET observaciones = E'Primera línea\nSegunda línea'
WHERE razon_social = 'ZZ test observaciones 41';
SELECT 'C2 multilínea en la vista' AS test, (observaciones = E'Primera línea\nSegunda línea') AS ok
FROM proveedores_saldo WHERE razon_social = 'ZZ test observaciones 41';

-- C3. Vaciar vuelve a null.
UPDATE proveedores SET observaciones = NULL WHERE razon_social = 'ZZ test observaciones 41';
SELECT 'C3 vaciada' AS test, (observaciones IS NULL) AS ok
FROM proveedores_saldo WHERE razon_social = 'ZZ test observaciones 41';

ROLLBACK;
