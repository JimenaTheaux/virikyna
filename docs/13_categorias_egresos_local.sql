-- 13 — Ajuste de categorías de egreso para Virikyna-Local (Cierre de Caja, origen='turno')
--
-- Decisión: "Sueldos" es una categoría de Virikyna-Gestión (egresos generales, origen='general'),
-- no de Local. Las categorías de gasto de turno que carga un cajero pasan a ser:
-- Pago a proveedor (sin cambios, sigue yendo por registrar_pago_proveedor), Agua, Descartables,
-- Super, Otro. No se toca nada de Gestión: sus egresos con categoria='sueldo' o 'servicio'
-- quedan intactos, y esas dos categorías siguen existiendo en el enum para no romperlos.
--
-- Ejecutar la Parte 1 sola primero, esperar a que confirme, y recién después correr la Parte 2 —
-- Postgres no permite usar un valor de enum nuevo en la misma transacción/lote en que se agregó.

-- ============================================================
-- Parte 1 — nuevos valores del enum (correr esto solo, primero)
-- ============================================================
ALTER TYPE categoria_egreso ADD VALUE IF NOT EXISTS 'agua';
ALTER TYPE categoria_egreso ADD VALUE IF NOT EXISTS 'descartables';
ALTER TYPE categoria_egreso ADD VALUE IF NOT EXISTS 'super';

-- ============================================================
-- Parte 2 — migrar egresos viejos de Local que quedaron sin categoría válida (correr después)
-- ============================================================
-- Egresos de turno con categoría vieja ("sueldo"/"servicio") no matchean ninguna de las 5
-- categorías nuevas de Local → se migran a "otro" para no perderlos. No toca origen='general'
-- (Gestión), que conserva sueldo/servicio como siempre.
UPDATE egresos
SET categoria = 'otro'
WHERE origen = 'turno' AND categoria IN ('sueldo', 'servicio');

-- Verificación: no debería quedar ningún egreso de turno con categoria sueldo/servicio.
SELECT categoria, count(*)
FROM egresos
WHERE origen = 'turno'
GROUP BY categoria
ORDER BY categoria;
