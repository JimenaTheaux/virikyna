-- 30 — Redondeo escalonado del precio de venta (reemplaza el redondeo a la centena de docs/29)
--
-- docs/06_estructura_de_datos.md, sección 21, tiene el detalle. Correr en el SQL Editor de
-- Supabase (proyecto ccpinvtleqlsukcqnili), después de 29. Requiere PostgreSQL 17
-- (ALTER COLUMN … SET EXPRESSION). Se puede correr más de una vez.
--
-- Regla (base = precio_calculado = ROUND(fórmula cruda, 2)):
--   base < 500            → centena más cercana, la mitad sube         149 → 100, 150 → 200, 450 → 500
--   500 <= base < 10000   → múltiplo de 500: resto = base mod 500;
--                           resto <= 200 baja, resto > 200 sube        6200 → 6000, 6200,01 → 6500, 6700 → 6500, 9750 → 10000
--   base >= 10000         → múltiplo de 1000 más cercano, 500 sube     11200 → 11000, 11500 → 12000
--   0 → 0
--
-- Espejo en el cliente: redondearPrecioVenta() en packages/shared/lib/precios.ts (mismos casos
-- de test en packages/shared/tests/precios.test.ts). Si se cambia la regla, cambiar los dos.
--
-- ⚠ SI SE CAMBIA redondear_precio_venta (CREATE OR REPLACE), las filas ya guardadas NO se
-- recalculan solas: precio_venta es una columna generada STORED y Postgres la recalcula solo al
-- escribir la fila. Después de cambiar la función hay que volver a correr el ALTER TABLE … SET
-- EXPRESSION del paso 2 (reescribe la tabla y recalcula todas las filas).
--
-- La función no se puede borrar mientras precio_venta dependa de ella (DROP FUNCTION falla).
--
-- Al reescribir la tabla no se disparan triggers de fila: el recálculo no genera filas de
-- auditoría (mismo comportamiento que docs/29).

BEGIN;

-- ============================================================
-- 1. redondear_precio_venta — la regla, en un solo lugar
-- IMMUTABLE: obligatorio para usarla en una columna generada (depende solo del argumento).
-- ROUND de NUMERIC redondea la mitad hacia afuera: para precios positivos, "la mitad sube".
-- ============================================================
CREATE OR REPLACE FUNCTION redondear_precio_venta(p_precio NUMERIC) RETURNS NUMERIC
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
AS $$
DECLARE
  v_base NUMERIC := ROUND(p_precio, 2);  -- = precio_calculado
  v_resto NUMERIC;
BEGIN
  IF v_base < 500 THEN
    RETURN ROUND(v_base, -2);
  ELSIF v_base < 10000 THEN
    v_resto := mod(v_base, 500);
    RETURN CASE WHEN v_resto <= 200 THEN v_base - v_resto ELSE v_base - v_resto + 500 END;
  ELSE
    RETURN ROUND(v_base, -3);
  END IF;
END;
$$;

-- ============================================================
-- 2. precio_venta — misma fórmula cruda de siempre, ahora pasada por la función
-- (una columna generada no puede leer precio_calculado; la función hace el ROUND(…, 2) adentro,
-- así la base del redondeo es exactamente precio_calculado).
-- ============================================================
ALTER TABLE productos ALTER COLUMN precio_venta SET EXPRESSION AS (
  redondear_precio_venta(costo * (1 + margen_1/100.0) * (1 + margen_2/100.0) * (1 + iva_porcentaje/100.0))
);

COMMIT;

-- ============================================================
-- 3. Tests — los mismos casos que packages/shared/tests/precios.test.ts. Debe dar 0 filas con ok = false.
-- ============================================================
SELECT t.base, t.esperado, redondear_precio_venta(t.base) AS obtenido,
       redondear_precio_venta(t.base) = t.esperado AS ok
FROM (VALUES
  (0, 0), (49, 0), (50, 100), (149, 100), (150, 200), (449.99, 400), (450, 500),
  (499, 500), (500, 500), (700, 500), (700.01, 1000), (6000, 6000),
  (6100, 6000), (6200, 6000), (6200.01, 6500), (6300, 6500), (6500, 6500),
  (6700, 6500), (6700.01, 7000), (6800, 7000), (9700, 9500), (9750, 10000),
  (9999.99, 10000), (10000, 10000), (10400, 10000), (11200, 11000),
  (11499.99, 11000), (11500, 12000), (11680, 12000)
) AS t(base, esperado)
ORDER BY t.base;

-- Resumen: debe dar casos = 29, fallas = 0.
SELECT COUNT(*) AS casos, COUNT(*) FILTER (WHERE redondear_precio_venta(base) <> esperado) AS fallas
FROM (VALUES
  (0, 0), (49, 0), (50, 100), (149, 100), (150, 200), (449.99, 400), (450, 500),
  (499, 500), (500, 500), (700, 500), (700.01, 1000), (6000, 6000),
  (6100, 6000), (6200, 6000), (6200.01, 6500), (6300, 6500), (6500, 6500),
  (6700, 6500), (6700.01, 7000), (6800, 7000), (9700, 9500), (9750, 10000),
  (9999.99, 10000), (10000, 10000), (10400, 10000), (11200, 11000),
  (11499.99, 11000), (11500, 12000), (11680, 12000)
) AS t(base, esperado);

-- ============================================================
-- 4. Productos guardados — las tres consultas deben dar 0
-- ============================================================
SELECT COUNT(*) AS bajo_500_fuera_de_100
FROM productos WHERE precio_venta < 500 AND precio_venta % 100 <> 0;

SELECT COUNT(*) AS entre_500_y_9999_fuera_de_500
FROM productos WHERE precio_venta >= 500 AND precio_venta < 10000 AND precio_venta % 500 <> 0;

SELECT COUNT(*) AS desde_10000_fuera_de_1000
FROM productos WHERE precio_venta >= 10000 AND precio_venta % 1000 <> 0;

-- Y precio_venta coincide con la función aplicada a precio_calculado (debe dar 0).
SELECT COUNT(*) AS distinto_de_la_regla
FROM productos WHERE precio_venta <> redondear_precio_venta(precio_calculado);

-- 5. Paridad con el cliente (desde la raíz del repo): npm run paridad-precios → 0 diferencias.
