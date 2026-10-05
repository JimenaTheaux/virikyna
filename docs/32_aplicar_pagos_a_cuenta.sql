-- 32 — Aplicar los pagos "a cuenta" anteriores a docs/31 a las facturas pendientes más viejas
--
-- ✅ APLICADO el 2026-10-05 (solo el bloque DO, sin BEGIN/ROLLBACK) — resultado igual al esperado
-- de abajo: 3 aplicaciones nuevas (Proveedor Test $5.300, QA_TEST $200). Los 3 pagos de prueba de
-- Toys (sin facturas pendientes) se BORRARON a mano el mismo día junto con sus egresos y sus 2
-- movimientos de cuenta (Mercado Pago −$500, Efectivo −$50): Toys quedó en su saldo inicial
-- ($2.000) y la verificación V6 de docs/31 da vacío.
--
-- Contexto: la verificación V6 de docs/31 lista pagos sin factura (pago "a cuenta general",
-- anteriores a las imputaciones). Restan del saldo del proveedor pero no están aplicados a ningún
-- comprobante, así que sus facturas siguen figurando pendientes. Son datos de prueba.
--
-- Qué hace: cada pago vigente (monto > 0, no es reversión, no fue revertido) SIN ninguna
-- aplicación se aplica a las facturas pendientes de su proveedor con la misma regla FIFO que
-- registrar_pago_proveedor_v2 (docs/31): fecha_comprobante, created_at, id ascendente; nunca a
-- notas de crédito ni anuladas; lo que sobra queda a cuenta. Pagos en orden de created_at.
--
-- No cambia saldos de proveedor (proveedores_saldo no mira aplicaciones): solo pasa deuda de
-- "pendiente" a "pagada/parcial" por comprobante. No toca egresos, cuentas ni pagos_proveedor.
-- Idempotente: un pago que ya tiene alguna aplicación no se vuelve a procesar.
--
-- Auditoría: NO se suprime — cada aplicación queda como 'alta' en el Historial con usuario NULL
-- (= acción hecha por SQL, docs/06 sección 3).
--
-- Relevado el 2026-10-05 (6 pagos). Resultado esperado:
--
--   Proveedor Test 1787923231341  (saldo $ 55.200, no cambia)
--     pago 09/09 $ 300  (efectivo) → factura 15/09 $ 19.360 (la primera cargada)
--     pago 12/09 $ 5.000 (echeq)   → factura 15/09 $ 19.360
--     ⇒ factura $ 19.360: parcial, saldo $ 14.060 · factura $ 41.140: pendiente, sin cambios
--
--   QA_TEST_Proveedor_6kqw05      (saldo $ 57.759, no cambia)
--     pago 09/09 $ 200 (transferencia) → remito 10/09 $ 15.125
--     ⇒ remito: parcial, saldo $ 14.925 · cupón 29/09 $ 42.834: pendiente, sin cambios
--
--   Toys                          (saldo $ 1.250 = saldo inicial $ 2.000 − pagos $ 750, no cambia)
--     pagos 05/09 $ 500, 05/09 $ 200, 09/09 $ 50 → sin facturas pendientes: quedan a cuenta
--     (cubren el saldo inicial, que no es un comprobante).
--
-- ⚠ Termina en ROLLBACK a propósito: correrlo tal cual es la vista previa (NOTICE por pago +
-- tabla de resultado). Cuando coincida con lo esperado, cambiar ROLLBACK por COMMIT y volver a correr.

BEGIN;

DO $$
DECLARE
  v_pago RECORD;
  v_doc RECORD;
  v_rest NUMERIC;
  v_aplicar NUMERIC;
BEGIN
  FOR v_pago IN
    SELECT pp.*, p.razon_social
    FROM pagos_proveedor pp
    JOIN proveedores p ON p.id = pp.proveedor_id
    WHERE pp.monto > 0
      AND pp.revierte_pago_proveedor_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM pagos_proveedor r WHERE r.revierte_pago_proveedor_id = pp.id)
      AND NOT EXISTS (SELECT 1 FROM pagos_proveedor_aplicaciones a WHERE a.pago_proveedor_id = pp.id)
    ORDER BY pp.created_at, pp.id
  LOOP
    -- Mismo lock que v2: nadie paga a este proveedor mientras se reparte.
    PERFORM 1 FROM proveedores WHERE id = v_pago.proveedor_id FOR UPDATE;
    v_rest := v_pago.monto;

    -- El saldo se calcula al abrir el loop, por pago: incluye lo aplicado por los pagos anteriores.
    FOR v_doc IN
      SELECT fc.id, fc.tipo_comprobante, fc.fecha_comprobante,
             fc.total - COALESCE((SELECT SUM(a.monto) FROM pagos_proveedor_aplicaciones a
                                  WHERE a.factura_compra_id = fc.id AND a.revertida_at IS NULL), 0) AS saldo
      FROM facturas_compra fc
      WHERE fc.proveedor_id = v_pago.proveedor_id
        AND NOT fc.anulada
        AND fc.tipo_comprobante <> 'nota_credito'
      ORDER BY fc.fecha_comprobante, fc.created_at, fc.id
    LOOP
      EXIT WHEN v_rest <= 0;
      CONTINUE WHEN v_doc.saldo <= 0;
      v_aplicar := LEAST(v_doc.saldo, v_rest);

      INSERT INTO pagos_proveedor_aplicaciones
        (factura_compra_id, monto, pago_proveedor_id, operacion_id, usuario_id)
      VALUES (v_doc.id, v_aplicar, v_pago.id, v_pago.id, v_pago.usuario_id);

      RAISE NOTICE '% · pago % $% → % % $%',
        v_pago.razon_social, v_pago.fecha, v_pago.monto, v_doc.tipo_comprobante, v_doc.fecha_comprobante, v_aplicar;
      v_rest := v_rest - v_aplicar;
    END LOOP;

    IF v_rest > 0 THEN
      RAISE NOTICE '% · pago % $% → queda a cuenta $%', v_pago.razon_social, v_pago.fecha, v_pago.monto, v_rest;
    END IF;
  END LOOP;
END;
$$;

-- Resultado por comprobante de los proveedores afectados (estado, saldo) + saldo del proveedor.
SELECT p.razon_social, ps.saldo_actual AS saldo_proveedor,
       f.tipo_comprobante, f.fecha_comprobante, f.total, f.total_aplicado, f.saldo_pendiente, f.estado
FROM facturas_compra_saldo f
JOIN proveedores p ON p.id = f.proveedor_id
JOIN proveedores_saldo ps ON ps.id = p.id
WHERE f.proveedor_id IN (
  SELECT pp.proveedor_id FROM pagos_proveedor pp
  WHERE pp.factura_compra_id IS NULL AND pp.monto > 0 AND pp.revierte_pago_proveedor_id IS NULL
)
ORDER BY p.razon_social, f.fecha_comprobante, f.created_at;

-- Pagos que siguen sin aplicar (esperado: solo los 3 de Toys).
SELECT p.razon_social, pp.fecha, pp.monto
FROM pagos_proveedor pp JOIN proveedores p ON p.id = pp.proveedor_id
WHERE pp.monto > 0 AND pp.revierte_pago_proveedor_id IS NULL
  AND NOT EXISTS (SELECT 1 FROM pagos_proveedor_aplicaciones a WHERE a.pago_proveedor_id = pp.id)
ORDER BY 1, 2;

ROLLBACK;  -- ← vista previa. Cambiar por COMMIT para aplicar.
