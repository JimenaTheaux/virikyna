-- 25 — Resumen de ventas por día para el Dashboard de Virikyna Gestión
--
-- Contexto: el Dashboard traía las ventas crudas de los últimos 7 días y las sumaba/agrupaba en
-- el navegador, con un rango `desde`/`hasta` armado como texto sin zona horaria. La base está en
-- UTC, así que Postgres leía "hoy 23:59:59" como 23:59:59 UTC = 20:59:59 hora argentina: las
-- ventas de después de las 21:00 (AR) no contaban en el día de hoy.
--
-- Este patch mueve la agregación a la base: una fila por día del rango (incluso sin ventas), con
-- el día calculado en hora argentina explícita — no depende ni de la zona de la base ni del reloj
-- de la PC.

-- ============================================================
-- 1. Índice en ventas(created_at)
-- Ya existe en docs/06 (sección 4) con este mismo nombre — IF NOT EXISTS lo deja como está.
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_ventas_created_at ON ventas(created_at);

-- ============================================================
-- 2. dashboard_ventas_por_dia
-- SECURITY INVOKER: corre con los permisos de quien llama, así que respeta la RLS de ventas
-- (policy "ventas_todos": cualquier perfil activo) — no abre nada que el cliente no pudiera leer.
-- El filtro por created_at es un rango de timestamptz (usa idx_ventas_created_at); el día de cada
-- venta se calcula recién después, con (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date.
-- ============================================================
CREATE OR REPLACE FUNCTION dashboard_ventas_por_dia(p_desde DATE, p_hasta DATE)
RETURNS TABLE (fecha DATE, total NUMERIC, cantidad INT)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  WITH ventas_rango AS (
    SELECT (v.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS dia,
           v.precio_cobrado
    FROM ventas v
    WHERE v.estado <> 'anulada'
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

GRANT EXECUTE ON FUNCTION dashboard_ventas_por_dia(DATE, DATE) TO authenticated;

-- ============================================================
-- Verificación 1: últimos 7 días (hora AR) — debe devolver exactamente 7 filas, con total 0 y
-- cantidad 0 en los días sin ventas.
-- ============================================================
SELECT * FROM dashboard_ventas_por_dia(
  (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - 6,
  (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
);

-- Verificación 2: suma manual sobre la tabla, sin la RPC — debe coincidir día por día con la
-- verificación 1 (los días sin ventas no aparecen acá, en la RPC salen con 0).
SELECT (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS fecha,
       SUM(precio_cobrado) AS total,
       COUNT(*) AS cantidad
FROM ventas
WHERE estado <> 'anulada'
  AND (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
      >= (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date - 6
GROUP BY 1
ORDER BY 1;

-- Verificación 3: una venta cargada a las 22:00 hora AR tiene created_at del día siguiente en
-- UTC (01:00Z) — confirmar que cae en el día AR correcto.
SELECT id, created_at,
       (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires') AS hora_ar,
       (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS dia_ar
FROM ventas
WHERE (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::time >= '21:00'
ORDER BY created_at DESC
LIMIT 5;
