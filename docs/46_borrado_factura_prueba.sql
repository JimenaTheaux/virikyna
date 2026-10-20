-- 46 — Borrado de la factura de compra de prueba (cupón 1 de CARLEVARIS, 2026-10-17)
--
-- Datos de una sola vez, no es una migración de schema. Correr desde la raíz del repo con
-- `npx supabase db query --linked -f docs/46_borrado_factura_prueba.sql`. Se ejecutó el 2026-10-19,
-- después de 45, con backup previo (backups\virikyna_2026-10-19_pre-borrado-factura-2).
-- Detalle de lo que se borra: docs/auditoria-2026-10-19.md, sección G.
--
-- Qué era: un cupón cargado como prueba con 21 % de IVA sumado ($196.368 + $41.237,28 =
-- $237.605,28) y pagado en efectivo por ese total desde Gestión. La dueña lo vuelve a cargar con
-- la alícuota correcta (docs/45). Tiene que quedar como si nunca hubiera existido:
--   - factura ccc2d35f…, su ítem y el movimiento de stock "compra" +24;
--   - pago 172df418…, su aplicación, su egreso y su movimiento de cuenta (−$237.605,28 en Efectivo);
--   - stock del producto cccaaed9… (SQUISHI BUTTER MANTECA) en local: 25 → 1.
-- Qué NO se toca:
--   - El producto: Alicia lo editó a mano el 2026-10-19 (auditoría ae866148…, costo 9.900, márgenes
--     100/0) y esa edición es intencional. Queda proveedor CARLEVARIS y precio de venta $24.000.
--   - auditoria: es append-only. Las altas originales quedan; los DELETE de pagos_proveedor y
--     egresos y el UPDATE de stock_ubicaciones agregan sus filas (eliminación/edición) como rastro.
--     No se usa virikyna.suppress_audit.
--   - El saldo de Efectivo no se ajusta a mano: cuentas_saldo lo calcula desde movimientos_cuenta,
--     así que al borrar el movimiento recupera los $237.605,28 solo.
--
-- Cada DELETE va por id exacto y exige afectar exactamente 1 fila; el stock se descuenta solo si
-- está en 25. Cualquier diferencia aborta todo (RAISE dentro de la transacción).
-- El dry-run es este mismo archivo con ROLLBACK en lugar de COMMIT.

BEGIN;

CREATE TEMP TABLE t46 (momento text, factura_compras bigint, pagos_proveedor bigint, aplicaciones bigint,
  stock_local numeric, producto jsonb, saldo_carlevaris numeric, saldo_efectivo numeric) ON COMMIT DROP;

INSERT INTO t46
SELECT 'antes',
  (SELECT count(*) FROM facturas_compra),
  (SELECT count(*) FROM pagos_proveedor),
  (SELECT count(*) FROM pagos_proveedor_aplicaciones),
  (SELECT cantidad FROM stock_ubicaciones WHERE producto_id = 'cccaaed9-a863-4590-b2d2-96f3e9e95abe' AND ubicacion = 'local'),
  (SELECT jsonb_build_object('costo', costo, 'm1', margen_1, 'm2', margen_2, 'proveedor', proveedor_id,
          'precio_manual', precio_manual, 'precio_venta', precio_venta, 'iva', iva_porcentaje, 'updated_at', updated_at)
     FROM productos WHERE id = 'cccaaed9-a863-4590-b2d2-96f3e9e95abe'),
  (SELECT saldo_actual FROM proveedores_saldo WHERE id = 'efb7c750-2c10-4957-979d-cd5bdec49f8b'),
  (SELECT saldo_actual FROM cuentas_saldo WHERE id = 'cc43498c-0924-4ba8-9ec3-0a2d95b58ee7');

DO $borrado$
DECLARE
  n int;
BEGIN
  -- Guardas: lo mismo que se verificó antes de escribir esto.
  IF (SELECT count(*) FROM venta_items WHERE producto_id = 'cccaaed9-a863-4590-b2d2-96f3e9e95abe') <> 0 THEN
    RAISE EXCEPTION 'El producto tiene ventas: no se borra';
  END IF;
  IF EXISTS (SELECT 1 FROM auditoria WHERE tabla_afectada = 'productos'
               AND registro_id = 'cccaaed9-a863-4590-b2d2-96f3e9e95abe'
               AND created_at > '2026-10-19 22:19:37.821003+00') THEN
    RAISE EXCEPTION 'El producto se editó después de ae866148: no se borra';
  END IF;
  IF EXISTS (SELECT 1 FROM facturas_compra WHERE copiada_de_id = 'ccc2d35f-eeb4-4cae-a24c-0d8537487056')
     OR EXISTS (SELECT 1 FROM pagos_proveedor WHERE revierte_pago_proveedor_id = '172df418-9c9f-4773-911e-ded7a4d853fd')
     OR EXISTS (SELECT 1 FROM movimientos_cuenta WHERE revierte_movimiento_id = '41154dd3-5e51-4da3-94eb-060087c9745b')
     OR EXISTS (SELECT 1 FROM retiros_caja WHERE movimiento_cuenta_id = '41154dd3-5e51-4da3-94eb-060087c9745b')
     OR EXISTS (SELECT 1 FROM egresos WHERE revierte_egreso_id = '1cfe34ba-49b0-4b7d-befe-caeacb56cbf6') THEN
    RAISE EXCEPTION 'Hay registros nuevos que apuntan a la factura o al pago: no se borra';
  END IF;

  DELETE FROM pagos_proveedor_aplicaciones WHERE id = '354c762a-b6d5-43c6-a13c-380a42919572'
    AND pago_proveedor_id = '172df418-9c9f-4773-911e-ded7a4d853fd' AND factura_compra_id = 'ccc2d35f-eeb4-4cae-a24c-0d8537487056';
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'aplicación: % filas', n; END IF;
  IF EXISTS (SELECT 1 FROM pagos_proveedor_aplicaciones
             WHERE pago_proveedor_id = '172df418-9c9f-4773-911e-ded7a4d853fd' OR operacion_id = '172df418-9c9f-4773-911e-ded7a4d853fd'
                OR factura_compra_id = 'ccc2d35f-eeb4-4cae-a24c-0d8537487056') THEN
    RAISE EXCEPTION 'quedan otras aplicaciones del pago o de la factura';
  END IF;

  DELETE FROM movimientos_cuenta WHERE id = '41154dd3-5e51-4da3-94eb-060087c9745b'
    AND referencia_id = '172df418-9c9f-4773-911e-ded7a4d853fd' AND monto = -237605.28;
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'movimiento de cuenta: % filas', n; END IF;

  DELETE FROM egresos WHERE id = '1cfe34ba-49b0-4b7d-befe-caeacb56cbf6'
    AND pago_proveedor_id = '172df418-9c9f-4773-911e-ded7a4d853fd' AND monto = 237605.28;
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'egreso: % filas', n; END IF;

  DELETE FROM pagos_proveedor WHERE id = '172df418-9c9f-4773-911e-ded7a4d853fd' AND monto = 237605.28;
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'pago: % filas', n; END IF;

  DELETE FROM movimientos_stock WHERE id = 'd654e023-14d6-42ab-8f39-7e915246164a'
    AND referencia_id = 'ccc2d35f-eeb4-4cae-a24c-0d8537487056' AND tipo = 'compra' AND cantidad = 24;
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'movimiento de stock: % filas', n; END IF;

  DELETE FROM facturas_compra_items WHERE id = '99757fa8-8e3b-4f78-addf-db177a85cc5d'
    AND factura_compra_id = 'ccc2d35f-eeb4-4cae-a24c-0d8537487056';
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'ítem: % filas', n; END IF;

  DELETE FROM facturas_compra WHERE id = 'ccc2d35f-eeb4-4cae-a24c-0d8537487056' AND total = 237605.28;
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'factura: % filas', n; END IF;

  UPDATE stock_ubicaciones SET cantidad = cantidad - 24
  WHERE producto_id = 'cccaaed9-a863-4590-b2d2-96f3e9e95abe' AND ubicacion = 'local' AND cantidad = 25;
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'stock: % filas (¿no estaba en 25?)', n; END IF;
END
$borrado$;

INSERT INTO t46
SELECT 'después',
  (SELECT count(*) FROM facturas_compra),
  (SELECT count(*) FROM pagos_proveedor),
  (SELECT count(*) FROM pagos_proveedor_aplicaciones),
  (SELECT cantidad FROM stock_ubicaciones WHERE producto_id = 'cccaaed9-a863-4590-b2d2-96f3e9e95abe' AND ubicacion = 'local'),
  (SELECT jsonb_build_object('costo', costo, 'm1', margen_1, 'm2', margen_2, 'proveedor', proveedor_id,
          'precio_manual', precio_manual, 'precio_venta', precio_venta, 'iva', iva_porcentaje, 'updated_at', updated_at)
     FROM productos WHERE id = 'cccaaed9-a863-4590-b2d2-96f3e9e95abe'),
  (SELECT saldo_actual FROM proveedores_saldo WHERE id = 'efb7c750-2c10-4957-979d-cd5bdec49f8b'),
  (SELECT saldo_actual FROM cuentas_saldo WHERE id = 'cc43498c-0924-4ba8-9ec3-0a2d95b58ee7');

-- Esperado después: 0 / 0 / 0, stock 1, producto igual que antes, CARLEVARIS 0, Efectivo +237.605,28.
SELECT *,
  (SELECT d.factura_compras = 0 AND d.pagos_proveedor = 0 AND d.aplicaciones = 0 AND d.stock_local = 1
          AND d.producto = a.producto AND d.saldo_carlevaris = 0
          AND d.saldo_efectivo - a.saldo_efectivo = 237605.28
     FROM t46 a, t46 d WHERE a.momento = 'antes' AND d.momento = 'después') AS todo_ok
FROM t46 ORDER BY momento;

-- Si el resultado no es exactamente el esperado, nada se confirma.
DO $guarda$
BEGIN
  IF NOT (SELECT d.factura_compras = 0 AND d.pagos_proveedor = 0 AND d.aplicaciones = 0 AND d.stock_local = 1
                 AND d.producto = a.producto AND d.saldo_carlevaris = 0
                 AND d.saldo_efectivo - a.saldo_efectivo = 237605.28
            FROM t46 a, t46 d WHERE a.momento = 'antes' AND d.momento = 'después') THEN
    RAISE EXCEPTION 'El resultado no coincide con lo esperado: no se confirma nada';
  END IF;
END
$guarda$;

COMMIT;
