-- 26 — Stock bajo calculado en el servidor (card "Stock bajo" de los dashboards)
--
-- Contexto: StockBajoCard (packages/shared, usada en Virikyna Gestión y en Local Admin/Cajero)
-- traía todos los productos activos con sus stock_ubicaciones y filtraba en el navegador. La API
-- de Supabase corta en 1000 filas por defecto: con más de 1000 productos activos, los que
-- quedaban afuera nunca se evaluaban, aunque tuvieran stock bajo.
--
-- Esta RPC hace la suma, el filtro y el orden en la base, y devuelve solo los primeros p_limite
-- productos + total_count (cuántos hay en total) para el "+N más" de la card.

-- ============================================================
-- 1. productos_stock_bajo
-- Mismo criterio que la card: stock total = suma de stock_ubicaciones en todas las ubicaciones
-- (0 si el producto no tiene ninguna fila), solo productos activos, stock_total <= stock_minimo.
-- Orden: más crítico primero (stock_total - stock_minimo ascendente), desempate por nombre.
-- total_count se calcula con COUNT(*) OVER () antes del LIMIT, así cuenta todos los que cumplen.
-- p_limite NULL = sin límite.
-- SECURITY INVOKER: respeta la RLS de productos y stock_ubicaciones.
-- ============================================================
CREATE OR REPLACE FUNCTION productos_stock_bajo(p_limite INT DEFAULT NULL)
RETURNS TABLE (id UUID, nombre TEXT, stock_total NUMERIC, stock_minimo NUMERIC, total_count INT)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  WITH stock AS (
    SELECT p.id, p.nombre, p.stock_minimo,
           COALESCE(SUM(s.cantidad), 0) AS stock_total
    FROM productos p
    LEFT JOIN stock_ubicaciones s ON s.producto_id = p.id
    WHERE p.estado = 'activo'
    GROUP BY p.id, p.nombre, p.stock_minimo
  )
  SELECT st.id, st.nombre, st.stock_total, st.stock_minimo,
         (COUNT(*) OVER ())::int AS total_count
  FROM stock st
  WHERE st.stock_total <= st.stock_minimo
  ORDER BY st.stock_total - st.stock_minimo, st.nombre
  LIMIT p_limite;
$$;

GRANT EXECUTE ON FUNCTION productos_stock_bajo(INT) TO authenticated;

-- ============================================================
-- Verificación 1: lo que muestra la card (4 primeros) — total_count igual en todas las filas.
-- ============================================================
SELECT * FROM productos_stock_bajo(4);

-- Verificación 2: conteo manual sin la RPC — debe coincidir con total_count de la verificación 1.
SELECT COUNT(*) AS stock_bajo_manual
FROM (
  SELECT p.id
  FROM productos p
  LEFT JOIN stock_ubicaciones s ON s.producto_id = p.id
  WHERE p.estado = 'activo'
  GROUP BY p.id, p.stock_minimo
  HAVING COALESCE(SUM(s.cantidad), 0) <= p.stock_minimo
) t;

-- Verificación 3: más de 1000 productos — si hay más de 1000 activos, el conteo de la
-- verificación 2 tiene que seguir coincidiendo con total_count (antes la card evaluaba solo los
-- primeros 1000 que devolvía la API).
SELECT COUNT(*) AS productos_activos FROM productos WHERE estado = 'activo';
