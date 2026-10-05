// node --test packages/shared/tests  (npm test desde la raíz)
// Mismos casos que la parte C de docs/31_cuenta_corriente_proveedor.sql — si el reparto de la vista
// previa (TS) y el de registrar_pago_proveedor_v2 (SQL) se separan, alguno de estos falla.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { simularRepartoPago, type ComprobanteReparto } from '../lib/repartoPagoProveedor.ts'

function doc(id: string, fecha: string, saldo: number, extra: Partial<ComprobanteReparto> = {}): ComprobanteReparto {
  return {
    id,
    tipo_comprobante: 'factura',
    fecha_comprobante: fecha,
    created_at: `${fecha}T12:00:00+00:00`,
    anulada: false,
    saldo_pendiente: saldo,
    credito_disponible: 0,
    ...extra,
  }
}
function nc(id: string, fecha: string, credito: number): ComprobanteReparto {
  return doc(id, fecha, 0, { tipo_comprobante: 'nota_credito', credito_disponible: credito })
}

test('T1: 2 facturas de 100.000, pago 150.000 → la más vieja pagada, la otra con 50.000', () => {
  const r = simularRepartoPago({
    comprobantes: [doc('f2', '2026-01-02', 100000), doc('f1', '2026-01-01', 100000)],
    facturaIds: ['f2', 'f1'],
    notaCreditoIds: [],
    monto: 150000,
  })
  assert.equal(r.error, null)
  assert.equal(r.saldoFinal.get('f1'), 0)
  assert.equal(r.saldoFinal.get('f2'), 50000)
  assert.equal(r.aCuenta, 0)
})

test('T2: NC 30.000 + factura 100.000, pago 70.000 → factura pagada, NC agotada', () => {
  const r = simularRepartoPago({
    comprobantes: [doc('f', '2026-01-01', 100000), nc('n', '2026-01-05', 30000)],
    facturaIds: ['f'],
    notaCreditoIds: ['n'],
    monto: 70000,
  })
  assert.equal(r.error, null)
  assert.equal(r.restanteTrasNotas, 70000)
  assert.equal(r.aplicadoNotaCredito, 30000)
  assert.equal(r.aplicadoPago, 70000)
  assert.equal(r.saldoFinal.get('f'), 0)
  assert.equal(r.creditoFinal.get('n'), 0)
  // Primero la NC, después la plata.
  assert.deepEqual(
    r.aplicaciones.map((a) => [a.fuente, a.monto]),
    [['nota_credito', 30000], ['pago', 70000]],
  )
})

test('T3: pago mayor al saldo seleccionado → error', () => {
  const r = simularRepartoPago({
    comprobantes: [doc('f', '2026-01-01', 100000)],
    facturaIds: ['f'],
    notaCreditoIds: [],
    monto: 150000,
  })
  assert.match(r.error ?? '', /supera el saldo/)
})

test('anuladas y NC nunca se pagan, aunque estén en la lista', () => {
  const r = simularRepartoPago({
    comprobantes: [doc('a', '2026-01-01', 5000, { anulada: true }), nc('n', '2026-01-02', 1000), doc('f', '2026-01-03', 2000)],
    facturaIds: [],
    notaCreditoIds: [],
    monto: 2000,
  })
  assert.deepEqual(r.aplicaciones.map((a) => a.comprobanteId), ['f'])
})

test('T7: solo NC (monto 0), sin selección → cancela la factura y deja crédito disponible', () => {
  const r = simularRepartoPago({
    comprobantes: [doc('f', '2026-01-01', 30000), nc('n', '2026-01-02', 50000)],
    facturaIds: [],
    notaCreditoIds: ['n'],
    monto: 0,
  })
  assert.equal(r.error, null)
  assert.equal(r.saldoFinal.get('f'), 0)
  assert.equal(r.creditoFinal.get('n'), 20000)
  assert.equal(r.aplicadoPago, 0)
})

test('T7: sin selección el excedente queda a cuenta', () => {
  const r = simularRepartoPago({
    comprobantes: [doc('f', '2026-01-01', 100000)],
    facturaIds: [],
    notaCreditoIds: [],
    monto: 120000,
  })
  assert.equal(r.error, null)
  assert.equal(r.aCuenta, 20000)
})

test('monto 0 sin NC, o NC sin nada que cancelar → error', () => {
  const sinNc = simularRepartoPago({ comprobantes: [doc('f', '2026-01-01', 100)], facturaIds: [], notaCreditoIds: [], monto: 0 })
  assert.match(sinNc.error ?? '', /mayor a cero/)
  const ncSola = simularRepartoPago({ comprobantes: [nc('n', '2026-01-01', 100)], facturaIds: [], notaCreditoIds: ['n'], monto: 0 })
  assert.match(ncSola.error ?? '', /No hay saldo pendiente/)
})

test('mismo día: desempata por created_at y después por id (igual que el ORDER BY del RPC)', () => {
  const r = simularRepartoPago({
    comprobantes: [
      doc('b', '2026-09-15', 41140, { created_at: '2026-09-15T10:00:00+00:00' }),
      doc('a', '2026-09-15', 19360, { created_at: '2026-09-15T09:00:00+00:00' }),
    ],
    facturaIds: [],
    notaCreditoIds: [],
    monto: 300,
  })
  assert.deepEqual(r.aplicaciones.map((a) => a.comprobanteId), ['a'])
})

test('centavos: sin error de punto flotante', () => {
  const r = simularRepartoPago({
    comprobantes: [doc('a', '2026-01-01', 0.1), doc('b', '2026-01-02', 0.2)],
    facturaIds: ['a', 'b'],
    notaCreditoIds: [],
    monto: 0.3,
  })
  assert.equal(r.error, null)
  assert.equal(r.saldoFinal.get('b'), 0)
})
