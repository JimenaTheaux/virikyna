-- 28 — Día de caja en hora argentina (la base está en UTC)
--
-- Contexto: la base de Supabase corre en UTC (`SHOW timezone` → UTC). Dentro de las funciones,
-- `current_date` y `created_at::date` calculan el día en UTC: entre las 21:00 y las 00:00 hora
-- argentina ya es "mañana". Un Cierre Z hecho a las 22:00 AR quedaba con turno_fecha del día
-- siguiente y, peor, sumaba solo las ventas/egresos de después de las 21:00, ningún retiro del
-- día (Local guarda retiros_caja.fecha con el día AR) y las devoluciones de después de las 21:00.
--
-- Arreglo: fijar la zona horaria argentina en las funciones que calculan "el día de caja"
-- (ALTER FUNCTION … SET timezone, sin reescribir sus cuerpos) y en los DEFAULT de las columnas
-- `fecha`. Con eso, current_date y ::date dentro de esas funciones dan el día argentino.
--
-- ⚠ CREATE OR REPLACE FUNCTION reemplaza también los SET de la función: si en el futuro se
-- redefine cerrar_caja o crear_devolucion, la nueva versión TIENE QUE incluir
--   SET timezone = 'America/Argentina/Buenos_Aires'
-- junto al SET search_path, o el problema vuelve. La verificación 1 de abajo lo detecta.
--
-- ORDEN: después de docs/24 (versión vigente de cerrar_caja y crear_devolucion). Se puede correr
-- más de una vez sin efectos secundarios.

-- ============================================================
-- 1. cerrar_caja — ventas, egresos, retiros, devoluciones y turno_fecha del día AR
-- ============================================================
ALTER FUNCTION cerrar_caja(tipo_cierre, NUMERIC)
  SET timezone = 'America/Argentina/Buenos_Aires';

-- ============================================================
-- 2. crear_devolucion — plazo de 15 días (created_at::date vs current_date) y la fecha de caja
-- de la devolución (devoluciones.fecha toma su DEFAULT dentro de esta función)
-- ============================================================
ALTER FUNCTION crear_devolucion(UUID, motivo_devolucion, TEXT, TEXT, JSONB, JSONB, forma_pago_venta, JSONB)
  SET timezone = 'America/Argentina/Buenos_Aires';

-- ============================================================
-- 3. DEFAULT de las columnas `fecha` — día AR explícito, sin depender de la zona de la sesión
-- (cubre cualquier insert que no mande la fecha, venga de la función que venga: p. ej.
-- registrar_pago_proveedor, que no fija egresos.fecha).
-- ============================================================
ALTER TABLE devoluciones ALTER COLUMN fecha
  SET DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);
ALTER TABLE retiros_caja ALTER COLUMN fecha
  SET DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);
ALTER TABLE egresos ALTER COLUMN fecha
  SET DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);

-- Nota: registrar_retiro_caja(p_fecha DEFAULT CURRENT_DATE) y registrar_egreso_general(p_fecha
-- DEFAULT CURRENT_DATE) siguen con ese default de parámetro (se evalúa en UTC), pero las apps
-- siempre mandan p_fecha, calculada en hora AR (fechaHoyISO → hoyAR, packages/shared/lib/format.ts).

-- ============================================================
-- Verificación 1: las dos funciones tienen la zona fijada — proconfig debe incluir
-- 'TimeZone=America/Argentina/Buenos_Aires' (además de search_path=public).
-- ============================================================
SELECT p.proname, p.proconfig
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('cerrar_caja', 'crear_devolucion');

-- Verificación 2: los DEFAULT nuevos.
SELECT table_name, column_name, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND column_name = 'fecha'
  AND table_name IN ('devoluciones', 'retiros_caja', 'egresos');

-- Verificación 3 (correr entre las 21:00 y las 00:00 hora AR para que se note la diferencia):
-- la sesión sigue en UTC — current_date da mañana, el día AR da hoy.
SELECT current_date AS dia_utc,
       (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS dia_ar;

-- Verificación 4: después de hacer un Cierre X o Z de prueba (idealmente después de las 21:00
-- AR), no debe aparecer ningún cierre nuevo con turno_fecha distinta al día AR en que se hizo.
SELECT id, tipo, turno_fecha, created_at,
       (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS fecha_ar
FROM cierres_caja
WHERE turno_fecha <> (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
ORDER BY created_at DESC;
