-- Limpieza de datos ficticios usados para probar la integración con ARCA (homologación).
-- Revisar antes de correr — no lo ejecuto yo automáticamente.
-- Orden: facturas_c antes que ventas (FK), venta_items se borra solo (ON DELETE CASCADE).

-- ============================================================
-- Grupo 1: "Jimena Prueba" — cliente de cuenta corriente usado para probar
-- Factura C real (ventas 21, 22, 25, 27, 30). Incluye las 2 facturas C reales
-- de homologación (CAE 86370882984422 y 86370886239786).
-- ============================================================
DELETE FROM facturas_c WHERE venta_id IN (
  SELECT id FROM ventas WHERE cliente_id = 'c8968af6-f768-41b7-b451-cf0799894c62'
);
DELETE FROM ventas WHERE cliente_id = 'c8968af6-f768-41b7-b451-cf0799894c62';
DELETE FROM clientes WHERE id = 'c8968af6-f768-41b7-b451-cf0799894c62';

-- ============================================================
-- Grupo 2: "Cliente Test 1787923231769" — ventas 9 y 10, sin facturar, sin CAE.
-- ============================================================
DELETE FROM ventas WHERE cliente_id = '649a666a-66f8-4291-bddf-a0f632d4f8c1';
DELETE FROM clientes WHERE id = '649a666a-66f8-4291-bddf-a0f632d4f8c1';

-- ============================================================
-- Grupo 3: "Cliente Test 1787923287349" — cliente sin ninguna venta asociada.
-- ============================================================
DELETE FROM clientes WHERE id = 'd5b2a8f1-d4b3-474f-a478-eed2cc89173f';

-- ============================================================
-- Grupo 4 (OJO — revisar antes de correr): "QA_TEST_Cliente_updgfv", venta N° 13,
-- con una Factura C (CAE 36027040897721) que NO es de esta sesión de trabajo con
-- ARCA — parece un fixture de otra tanda de pruebas de QA anterior. Descomentar
-- solo si confirmás que también se puede borrar.
-- ============================================================
-- DELETE FROM facturas_c WHERE venta_id IN (
--   SELECT id FROM ventas WHERE cliente_id = 'd65afceb-8207-45b0-8698-847b717a6a81'
-- );
-- DELETE FROM ventas WHERE cliente_id = 'd65afceb-8207-45b0-8698-847b717a6a81';
-- DELETE FROM clientes WHERE id = 'd65afceb-8207-45b0-8698-847b717a6a81';

-- ============================================================
-- Nota aparte: estas ventas de prueba impactaron stock real de los productos que se
-- "vendieron" (movimientos_stock). Borrar la venta NO repone ese stock automáticamente
-- (movimientos_stock no tiene FK a ventas, queda como registro histórico huérfano).
-- Si los productos usados en estas ventas de prueba son productos reales del catálogo,
-- pedime que te arme el ajuste de stock correspondiente vía ajustar_stock() para
-- reponerlo — necesito saber qué productos fueron.
-- ============================================================
