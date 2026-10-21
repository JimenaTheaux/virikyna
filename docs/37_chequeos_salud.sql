-- 37 — Chequeos de salud: invariantes de stock, dinero y referencias
--
-- SOLO LECTURA. Se corre a mano en el SQL Editor de Supabase (proyecto ccpinvtleqlsukcqnili),
-- una consulta por vez. Cada consulta devuelve SOLO las filas con problema: 0 filas = OK.
-- Las marcadas "(informativo)" no son errores por sí solas: listan casos a mirar.
--
-- Sugerido: correr todo una vez por semana y siempre después de una corrección manual por SQL.
-- Compiladas con EXPLAIN contra la base real el 2026-10-08 (base vacía, sin ejecutar).
--
-- Fechas de caja: cerrar_caja (docs/28) agrupa por día en America/Argentina/Buenos_Aires; acá se
-- usa la misma zona para comparar contra cierres_caja.turno_fecha.


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- STOCK
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- S1. stock_ubicaciones = suma de movimientos_stock, por producto y ubicación.
--     Una diferencia = alguien escribió stock_ubicaciones sin movimiento (la policy ALL lo permite)
--     o se borró un movimiento.
SELECT COALESCE(s.producto_id, m.producto_id) AS producto_id,
       COALESCE(s.ubicacion, m.ubicacion) AS ubicacion,
       s.cantidad AS stock_ubicaciones,
       COALESCE(m.suma, 0) AS suma_movimientos,
       COALESCE(s.cantidad, 0) - COALESCE(m.suma, 0) AS diferencia
FROM stock_ubicaciones s
FULL JOIN (
  SELECT producto_id, ubicacion, sum(cantidad) AS suma
  FROM movimientos_stock GROUP BY producto_id, ubicacion
) m ON m.producto_id = s.producto_id AND m.ubicacion = s.ubicacion
WHERE COALESCE(s.cantidad, 0) <> COALESCE(m.suma, 0)
ORDER BY abs(COALESCE(s.cantidad, 0) - COALESCE(m.suma, 0)) DESC;

-- S2. Venta activa cuyo movimiento de stock no coincide con sus ítems (por producto).
SELECT v.id AS venta_id, v.numero, x.producto_id, x.vendido, x.movido
FROM ventas v
JOIN LATERAL (
  SELECT COALESCE(i.producto_id, m.producto_id) AS producto_id,
         COALESCE(i.cant, 0) AS vendido, COALESCE(-m.cant, 0) AS movido
  FROM (SELECT producto_id, sum(cantidad) AS cant FROM venta_items WHERE venta_id = v.id GROUP BY 1) i
  FULL JOIN (SELECT producto_id, sum(cantidad) AS cant FROM movimientos_stock
             WHERE referencia_id = v.id AND tipo = 'venta' GROUP BY 1) m ON m.producto_id = i.producto_id
) x ON x.vendido <> x.movido
WHERE v.estado <> 'anulada';

-- S3. Venta anulada sin reposición completa de stock (venta + reposición ≠ 0 por producto).
SELECT v.id AS venta_id, v.numero, m.producto_id, sum(m.cantidad) AS neto
FROM ventas v
JOIN movimientos_stock m ON m.referencia_id = v.id
WHERE v.estado = 'anulada'
GROUP BY v.id, v.numero, m.producto_id
HAVING sum(m.cantidad) <> 0;

-- S4. Factura de compra (no anulada) cuyo movimiento de stock no coincide con sus ítems.
SELECT fc.id AS factura_compra_id, fc.numero_comprobante, x.producto_id, x.ubicacion, x.items, x.movido
FROM facturas_compra fc
JOIN LATERAL (
  SELECT COALESCE(i.producto_id, m.producto_id) AS producto_id, COALESCE(i.ubicacion, m.ubicacion) AS ubicacion,
         COALESCE(i.cant, 0) AS items, COALESCE(m.cant, 0) AS movido
  FROM (SELECT producto_id, ubicacion, sum(cantidad) AS cant FROM facturas_compra_items
        WHERE factura_compra_id = fc.id AND producto_id IS NOT NULL GROUP BY 1, 2) i
  FULL JOIN (SELECT producto_id, ubicacion, sum(cantidad) AS cant FROM movimientos_stock
             WHERE referencia_id = fc.id AND tipo = 'compra' GROUP BY 1, 2) m
    ON m.producto_id = i.producto_id AND m.ubicacion = i.ubicacion
) x ON x.items <> x.movido
WHERE NOT fc.anulada;

-- S5. (informativo) Stock negativo.
SELECT s.producto_id, p.nombre, s.ubicacion, s.cantidad
FROM stock_ubicaciones s JOIN productos p ON p.id = s.producto_id
WHERE s.cantidad < 0
ORDER BY s.cantidad;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- VENTAS Y DEVOLUCIONES
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- V1. Ventas sin ítems.
SELECT v.id, v.numero, v.created_at, v.estado
FROM ventas v
WHERE NOT EXISTS (SELECT 1 FROM venta_items i WHERE i.venta_id = v.id);

-- V2. Venta (no cuenta corriente) cuyos pagos no suman lo cobrado. Cuenta corriente no tiene
--     venta_pagos (confirmar_venta); si tiene, también sale acá.
SELECT v.id, v.numero, v.forma_pago, v.precio_cobrado, COALESCE(sum(p.monto), 0) AS suma_pagos
FROM ventas v
LEFT JOIN venta_pagos p ON p.venta_id = v.id
GROUP BY v.id, v.numero, v.forma_pago, v.precio_cobrado
HAVING (v.forma_pago <> 'cuenta_corriente' AND COALESCE(sum(p.monto), 0) <> v.precio_cobrado)
    OR (v.forma_pago = 'cuenta_corriente' AND count(p.id) > 0);

-- V3. Ítems cuyo importe no es cantidad × precio × (1 − descuento) (redondeo a 2 decimales).
SELECT i.venta_id, i.id AS item_id, i.cantidad, i.precio_unitario, i.descuento_porcentaje, i.importe
FROM venta_items i
WHERE i.importe <> round(i.cantidad * i.precio_unitario * (1 - i.descuento_porcentaje / 100.0), 2);

-- V4. Estado de facturación incoherente: 'facturado' sin Factura C, o Factura C en venta que no
--     está 'facturado'.
SELECT v.id, v.numero, v.estado, f.id AS factura_c_id, f.cae
FROM ventas v
LEFT JOIN facturas_c f ON f.venta_id = v.id
WHERE (v.estado = 'facturado') <> (f.id IS NOT NULL);

-- V5. Devolución activa sobre una venta anulada.
SELECT d.id, d.numero, d.venta_id
FROM devoluciones d JOIN ventas v ON v.id = d.venta_id
WHERE d.estado = 'activa' AND v.estado = 'anulada';

-- V6. Más unidades devueltas que vendidas (devoluciones activas).
SELECT d.venta_id, di.producto_id, sum(di.cantidad) AS devuelto,
       (SELECT sum(cantidad) FROM venta_items vi WHERE vi.venta_id = d.venta_id AND vi.producto_id = di.producto_id) AS vendido
FROM devoluciones d JOIN devolucion_items di ON di.devolucion_id = d.id
WHERE d.estado = 'activa' AND di.tipo = 'devuelto'
GROUP BY d.venta_id, di.producto_id
HAVING sum(di.cantidad) > COALESCE((SELECT sum(cantidad) FROM venta_items vi
                                    WHERE vi.venta_id = d.venta_id AND vi.producto_id = di.producto_id), 0);

-- V7. Devolución con diferencia ≠ 0 cuyos pagos no suman |diferencia|.
SELECT d.id, d.numero, d.diferencia_monto, COALESCE(sum(p.monto), 0) AS suma_pagos
FROM devoluciones d LEFT JOIN devolucion_pagos p ON p.devolucion_id = d.id
GROUP BY d.id, d.numero, d.diferencia_monto
HAVING abs(d.diferencia_monto) <> COALESCE(sum(p.monto), 0);

-- V8. (informativo) Devolución con reintegro de dinero sobre una venta en cuenta corriente:
--     el cliente nunca pagó esa venta, pero crear_devolucion le devuelve plata por caja y su
--     saldo de cuenta corriente no baja.
SELECT d.id, d.numero, v.numero AS venta_numero, d.diferencia_monto, d.diferencia_forma_pago
FROM devoluciones d JOIN ventas v ON v.id = d.venta_id
WHERE d.estado = 'activa' AND v.forma_pago = 'cuenta_corriente' AND d.diferencia_monto < 0;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- CLIENTES (cuenta corriente)
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- C1. clientes_saldo coherente con ventas en cuenta corriente y pagos (recalculado acá).
SELECT c.id, c.razon_social, cs.saldo_actual AS saldo_vista,
       c.saldo_inicial
       + COALESCE((SELECT sum(v.total) FROM ventas v WHERE v.cliente_id = c.id
                   AND v.forma_pago = 'cuenta_corriente' AND v.estado <> 'anulada'), 0)
       - COALESCE((SELECT sum(p.monto) FROM pagos_cliente p WHERE p.cliente_id = c.id), 0) AS saldo_recalculado
FROM clientes c JOIN clientes_saldo cs ON cs.id = c.id
WHERE cs.saldo_actual IS DISTINCT FROM
      c.saldo_inicial
      + COALESCE((SELECT sum(v.total) FROM ventas v WHERE v.cliente_id = c.id
                  AND v.forma_pago = 'cuenta_corriente' AND v.estado <> 'anulada'), 0)
      - COALESCE((SELECT sum(p.monto) FROM pagos_cliente p WHERE p.cliente_id = c.id), 0);

-- C2. Pago de cliente imputado a una venta de OTRO cliente, o a una venta que no es cuenta corriente.
SELECT p.id, p.cliente_id, v.cliente_id AS cliente_de_la_venta, v.numero, v.forma_pago
FROM pagos_cliente p JOIN ventas v ON v.id = p.venta_id
WHERE v.cliente_id IS DISTINCT FROM p.cliente_id OR v.forma_pago <> 'cuenta_corriente';

-- C3. Venta en cuenta corriente con más pagos imputados que su total.
SELECT v.id, v.numero, v.total, sum(p.monto) AS pagado
FROM ventas v JOIN pagos_cliente p ON p.venta_id = v.id
WHERE v.forma_pago = 'cuenta_corriente'
GROUP BY v.id, v.numero, v.total
HAVING sum(p.monto) > v.total;

-- C4. Pago de cliente revertido más de una vez, o reversión que no espeja el monto.
SELECT o.id AS pago_original, o.monto, count(r.id) AS reversiones, sum(r.monto) AS suma_reversiones
FROM pagos_cliente o JOIN pagos_cliente r ON r.revierte_pago_cliente_id = o.id
GROUP BY o.id, o.monto
HAVING count(r.id) > 1 OR sum(r.monto) <> -o.monto;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PROVEEDORES (cuenta corriente, docs/31-32)
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- P1. proveedores_saldo coherente con los comprobantes: saldo inicial + pendiente de facturas
--     − crédito disponible de NC − pagos a cuenta (monto del pago no aplicado a ningún comprobante).
WITH a_cuenta AS (
  SELECT p.proveedor_id,
         sum(p.monto - COALESCE((SELECT sum(a.monto) FROM pagos_proveedor_aplicaciones a
                                 WHERE a.pago_proveedor_id = p.id AND a.revertida_at IS NULL), 0)) AS monto
  FROM pagos_proveedor p
  WHERE p.revierte_pago_proveedor_id IS NULL
    AND NOT EXISTS (SELECT 1 FROM pagos_proveedor r WHERE r.revierte_pago_proveedor_id = p.id)
  GROUP BY p.proveedor_id
),
docs AS (
  SELECT proveedor_id, sum(saldo_pendiente) - sum(credito_disponible) AS neto
  FROM facturas_compra_saldo GROUP BY proveedor_id
)
SELECT pr.id, pr.razon_social, ps.saldo_actual AS saldo_vista,
       pr.saldo_inicial + COALESCE(d.neto, 0) - COALESCE(ac.monto, 0) AS saldo_por_comprobantes
FROM proveedores pr
JOIN proveedores_saldo ps ON ps.id = pr.id
LEFT JOIN docs d ON d.proveedor_id = pr.id
LEFT JOIN a_cuenta ac ON ac.proveedor_id = pr.id
WHERE ps.saldo_actual IS DISTINCT FROM pr.saldo_inicial + COALESCE(d.neto, 0) - COALESCE(ac.monto, 0);

-- P2. Comprobante sobrepagado, o NC aplicada por encima de su total.
SELECT id, proveedor_id, tipo_comprobante, numero_comprobante, total, total_aplicado
FROM facturas_compra_saldo
WHERE NOT anulada AND total_aplicado > total;

-- P3. Pago cuyas aplicaciones (vigentes, con plata del pago) superan su monto.
SELECT p.id, p.monto, sum(a.monto) AS aplicado
FROM pagos_proveedor p JOIN pagos_proveedor_aplicaciones a ON a.pago_proveedor_id = p.id AND a.revertida_at IS NULL
GROUP BY p.id, p.monto
HAVING sum(a.monto) > p.monto;

-- P4. Pago revertido con aplicaciones que siguen vigentes (revertir_movimiento las marca).
SELECT o.id AS pago_original, count(a.id) AS aplicaciones_vigentes
FROM pagos_proveedor o
JOIN pagos_proveedor r ON r.revierte_pago_proveedor_id = o.id
JOIN pagos_proveedor_aplicaciones a ON a.operacion_id = o.id AND a.revertida_at IS NULL
GROUP BY o.id;

-- P5. Pago revertido más de una vez.
SELECT revierte_pago_proveedor_id, count(*) FROM pagos_proveedor
WHERE revierte_pago_proveedor_id IS NOT NULL
GROUP BY 1 HAVING count(*) > 1;

-- P6. Aplicación sobre comprobante anulado que sigue vigente.
SELECT a.id, a.factura_compra_id, a.nota_credito_id, a.monto
FROM pagos_proveedor_aplicaciones a
JOIN facturas_compra f ON f.id = a.factura_compra_id OR f.id = a.nota_credito_id
WHERE a.revertida_at IS NULL AND f.anulada;

-- P7. (informativo) Pagos con monto sin ninguna aplicación (quedaron enteros "a cuenta").
SELECT p.id, p.proveedor_id, p.fecha, p.monto
FROM pagos_proveedor p
WHERE p.monto > 0 AND p.revierte_pago_proveedor_id IS NULL
  AND NOT EXISTS (SELECT 1 FROM pagos_proveedor_aplicaciones a WHERE a.pago_proveedor_id = p.id)
  AND NOT EXISTS (SELECT 1 FROM pagos_proveedor r WHERE r.revierte_pago_proveedor_id = p.id);

-- P8. Factura de compra cuyo total no coincide con sus ítems (total_sin_iva = Σ ítems, IVA 21%).
SELECT fc.id, fc.numero_comprobante, fc.total_sin_iva, sum(i.precio_total_sin_iva) AS suma_items
FROM facturas_compra fc JOIN facturas_compra_items i ON i.factura_compra_id = fc.id
GROUP BY fc.id, fc.numero_comprobante, fc.total_sin_iva
HAVING abs(fc.total_sin_iva - sum(i.precio_total_sin_iva)) > 0.05;

-- P9. Comprobantes de compra duplicados (mismo proveedor, tipo, letra, punto de venta y número,
--     no anulados). cargar_factura_compra no lo impide en la base.
SELECT proveedor_id, tipo_comprobante, letra,
       NULLIF(ltrim(btrim(punto_venta), '0'), '') AS pv, ltrim(btrim(numero_comprobante), '0') AS numero,
       count(*) AS cantidad, array_agg(id) AS ids
FROM facturas_compra
WHERE NOT anulada AND btrim(COALESCE(numero_comprobante, '')) <> ''
GROUP BY 1, 2, 3, 4, 5
HAVING count(*) > 1;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- CAJA Y CUENTAS
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- K1. Cierre con aritmética propia inconsistente: esperado ≠ base + efectivo + devoluciones
--     en efectivo − egresos en efectivo − retiros, o diferencia ≠ contado − esperado.
--     (egresos en efectivo no se guarda aparte: se recalcula del día.)
SELECT c.id, c.tipo, c.turno_fecha, c.efectivo_esperado,
       COALESCE(a.monto_real, 0) + c.total_efectivo + c.total_devoluciones_efectivo
       - COALESCE((SELECT sum(e.monto) FROM egresos e
                   WHERE (e.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date = c.turno_fecha
                     AND e.origen = 'turno' AND e.forma_pago = 'efectivo'
                     AND e.created_at <= c.created_at), 0)
       - c.total_retiros AS esperado_recalculado,
       c.efectivo_contado, c.diferencia
FROM cierres_caja c
LEFT JOIN aperturas_caja a ON a.id = c.apertura_id
WHERE c.efectivo_esperado IS DISTINCT FROM
        COALESCE(a.monto_real, 0) + c.total_efectivo + c.total_devoluciones_efectivo
        - COALESCE((SELECT sum(e.monto) FROM egresos e
                    WHERE (e.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date = c.turno_fecha
                      AND e.origen = 'turno' AND e.forma_pago = 'efectivo'
                      AND e.created_at <= c.created_at), 0)
        - c.total_retiros
   OR (c.efectivo_contado IS NOT NULL AND c.diferencia IS DISTINCT FROM c.efectivo_contado - c.efectivo_esperado);

-- K2. Cierre Z cuyos totales por medio ya no coinciden con las ventas de ese día (alguien anuló,
--     borró o editó pagos DESPUÉS del cierre). Compara contra venta_pagos de hoy.
SELECT c.id, c.turno_fecha,
       c.total_efectivo, r.efectivo, c.total_transferencia, r.transferencia,
       c.total_qr, r.qr, c.total_tarjeta, r.tarjeta
FROM cierres_caja c
CROSS JOIN LATERAL (
  SELECT COALESCE(sum(vp.monto) FILTER (WHERE vp.forma_pago = 'efectivo'), 0) AS efectivo,
         COALESCE(sum(vp.monto) FILTER (WHERE vp.forma_pago = 'transferencia'), 0) AS transferencia,
         COALESCE(sum(vp.monto) FILTER (WHERE vp.forma_pago = 'qr'), 0) AS qr,
         COALESCE(sum(vp.monto) FILTER (WHERE vp.forma_pago IN ('tarjeta_debito', 'tarjeta_credito')), 0) AS tarjeta
  FROM venta_pagos vp JOIN ventas v ON v.id = vp.venta_id
  WHERE (v.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date = c.turno_fecha
    AND v.estado <> 'anulada' AND v.created_at <= c.created_at
) r
WHERE c.tipo = 'z'
  AND (c.total_efectivo, c.total_transferencia, c.total_qr, c.total_tarjeta)
      IS DISTINCT FROM (r.efectivo, r.transferencia, r.qr, r.tarjeta);

-- K3. Cierre Z validado cuyos movimientos de cuenta 'cierre_z' no suman lo esperado
--     (falta la acreditación, o se validó dos veces por una carrera).
SELECT c.id, c.turno_fecha,
       c.total_transferencia + c.total_devoluciones_transferencia + c.total_qr + c.total_devoluciones_qr
       + c.total_tarjeta + c.total_devoluciones_tarjeta AS esperado,
       COALESCE((SELECT sum(m.monto) FROM movimientos_cuenta m
                 WHERE m.referencia_id = c.id AND m.tipo = 'cierre_z'), 0) AS acreditado
FROM cierres_caja c
WHERE c.tipo = 'z' AND c.estado_validacion = 'validado'
  AND c.total_transferencia + c.total_devoluciones_transferencia + c.total_qr + c.total_devoluciones_qr
      + c.total_tarjeta + c.total_devoluciones_tarjeta
      <> COALESCE((SELECT sum(m.monto) FROM movimientos_cuenta m
                   WHERE m.referencia_id = c.id AND m.tipo = 'cierre_z'), 0);

-- K4. (informativo) Cierres Z sin validar hace más de 3 días.
SELECT id, turno_fecha, created_at FROM cierres_caja
WHERE tipo = 'z' AND estado_validacion = 'pendiente_validacion' AND created_at < now() - interval '3 days';

-- K5. Más de una caja abierta (el índice ux_aperturas_caja_abierta lo impide; si sale algo, se
--     tocó el índice), o apertura vieja sin Cierre Z (>36 h).
SELECT id, abierta_at, usuario_id FROM aperturas_caja
WHERE cierre_z_id IS NULL
  AND ((SELECT count(*) FROM aperturas_caja WHERE cierre_z_id IS NULL) > 1 OR abierta_at < now() - interval '36 hours');

-- K6. Egreso en efectivo/transferencia sin su movimiento de cuenta (o con más de uno). Incluye las
--     reversiones de egreso: revertir_movimiento hoy NO genera el contra-movimiento de cuenta.
SELECT e.id, e.categoria, e.forma_pago, e.monto, e.revierte_egreso_id,
       (SELECT count(*) FROM movimientos_cuenta m WHERE m.referencia_id = e.id) AS movimientos
FROM egresos e
WHERE e.forma_pago IN ('efectivo', 'transferencia')
  AND e.categoria <> 'pago_proveedor'
  AND (SELECT count(*) FROM movimientos_cuenta m WHERE m.referencia_id = e.id) <> 1;

-- K7. Egreso de pago a proveedor sin pago vinculado, o pago con monto sin egreso.
SELECT 'egreso sin pago' AS caso, e.id, e.monto FROM egresos e
WHERE e.categoria = 'pago_proveedor' AND e.pago_proveedor_id IS NULL
UNION ALL
SELECT 'pago sin egreso', p.id, p.monto FROM pagos_proveedor p
WHERE p.monto <> 0 AND NOT EXISTS (SELECT 1 FROM egresos e WHERE e.pago_proveedor_id = p.id);

-- K8. Retiro de caja sin su movimiento de cuenta, o con monto distinto.
SELECT r.id, r.fecha, r.monto, m.monto AS monto_movimiento
FROM retiros_caja r LEFT JOIN movimientos_cuenta m ON m.id = r.movimiento_cuenta_id
WHERE m.id IS NULL OR m.monto <> r.monto;

-- K9. Movimiento de cuenta corregido/eliminado más de una vez (dos contra-asientos).
SELECT revierte_movimiento_id, count(*) FILTER (WHERE descripcion LIKE 'Eliminación:%' OR descripcion = 'Reversión desde Historial') AS anulaciones
FROM movimientos_cuenta
WHERE revierte_movimiento_id IS NOT NULL
GROUP BY 1
HAVING count(*) FILTER (WHERE descripcion LIKE 'Eliminación:%' OR descripcion = 'Reversión desde Historial') > 1;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- HUÉRFANOS Y REFERENCIAS SUELTAS (referencia_id no tiene FK)
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- H1. Movimientos de stock cuya referencia ya no existe (venta/compra/devolución borrada).
--     'inicial' apunta a carga_inicial_items, que se borra al finalizar: no se chequea.
SELECT m.id, m.tipo, m.producto_id, m.cantidad, m.referencia_id, m.created_at
FROM movimientos_stock m
WHERE m.referencia_id IS NOT NULL AND m.tipo <> 'inicial'
  AND NOT EXISTS (SELECT 1 FROM ventas v WHERE v.id = m.referencia_id)
  AND NOT EXISTS (SELECT 1 FROM facturas_compra f WHERE f.id = m.referencia_id)
  AND NOT EXISTS (SELECT 1 FROM devoluciones d WHERE d.id = m.referencia_id);

-- H2. Movimientos de cuenta cuya referencia ya no existe.
SELECT m.id, m.tipo, m.monto, m.referencia_id
FROM movimientos_cuenta m
WHERE m.referencia_id IS NOT NULL
  AND CASE m.tipo
        WHEN 'pago_cliente' THEN NOT EXISTS (SELECT 1 FROM pagos_cliente p WHERE p.id = m.referencia_id)
        WHEN 'pago_proveedor' THEN NOT EXISTS (SELECT 1 FROM pagos_proveedor p WHERE p.id = m.referencia_id)
        WHEN 'egreso' THEN NOT EXISTS (SELECT 1 FROM egresos e WHERE e.id = m.referencia_id)
        WHEN 'cierre_z' THEN NOT EXISTS (SELECT 1 FROM cierres_caja c WHERE c.id = m.referencia_id)
        ELSE false
      END;

-- H3. Ventas cuyo número tiene huecos (una venta borrada con DELETE directo deja hueco; una
--     anulada no). Solo informa los saltos.
SELECT numero + 1 AS desde, siguiente - 1 AS hasta
FROM (SELECT numero, lead(numero) OVER (ORDER BY numero) AS siguiente FROM ventas) x
WHERE siguiente > numero + 1;

-- H4. Ítems de factura de compra con producto que ya no existe, o descripción vacía y sin producto.
SELECT i.id, i.factura_compra_id, i.producto_id
FROM facturas_compra_items i
WHERE (i.producto_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM productos p WHERE p.id = i.producto_id))
   OR (i.producto_id IS NULL AND btrim(COALESCE(i.descripcion, '')) = '');


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- CARGA INICIAL Y AUDITORÍA
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- A1. Borradores de carga inicial con la carga cerrada (quedaron sin finalizar).
SELECT i.usuario_id, count(*) AS borradores, sum(i.cantidad) AS unidades
FROM carga_inicial_items i
WHERE NOT (SELECT carga_inicial_abierta FROM configuracion)
GROUP BY i.usuario_id;

-- A2. Movimientos 'inicial' hechos con la carga cerrada (por un admin, que puede usarla siempre).
SELECT m.id, m.producto_id, m.cantidad, m.usuario_id, m.created_at
FROM movimientos_stock m, configuracion c
WHERE m.tipo = 'inicial' AND c.cerrada_at IS NOT NULL AND m.created_at > c.cerrada_at
  AND NOT c.carga_inicial_abierta;

-- A3. Filas de auditoría sin usuario (escrituras hechas fuera de la API: SQL Editor, service_role,
--     Edge Function). No es un error en sí, pero cada una merece explicación.
SELECT id, tabla_afectada, accion, registro_id, created_at
FROM auditoria
WHERE usuario_id IS NULL
ORDER BY created_at DESC;

-- A4. Acción revertida más de una vez (no hay índice único sobre revierte_auditoria_id).
SELECT revierte_auditoria_id, count(*) FROM auditoria
WHERE revierte_auditoria_id IS NOT NULL
GROUP BY 1 HAVING count(*) > 1;

-- A5. (informativo) Tamaño y crecimiento de auditoria: filas por día de los últimos 30 días.
SELECT (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS dia, count(*) AS filas,
       pg_size_pretty(sum(pg_column_size(a.*))::bigint) AS tamano_aprox
FROM auditoria a
WHERE created_at > now() - interval '30 days'
GROUP BY 1 ORDER BY 1 DESC;
