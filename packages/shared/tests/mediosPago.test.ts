// node --test packages/shared/tests  (npm test desde la raíz)
// Medios de un pago a proveedor (docs/65). El RPC registrar_pago_proveedor_v3 valida lo mismo.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  diferenciaMedios,
  generarCheques,
  nuevoMedio,
  payloadMedios,
  sumarDias,
  totalMedios,
  validarMedios,
} from '../lib/mediosPago.ts'

test('total y diferencia en centavos (sin errores de coma flotante)', () => {
  const medios = [nuevoMedio('efectivo', '0.1'), nuevoMedio('transferencia', '0.2')]
  assert.equal(totalMedios(medios), 0.3)
  assert.deepEqual(diferenciaMedios(0.3, medios), { estado: 'cierra', monto: 0 })
  assert.deepEqual(diferenciaMedios(1, medios), { estado: 'falta', monto: 0.7 })
  assert.deepEqual(diferenciaMedios(0.25, medios), { estado: 'sobra', monto: 0.05 })
})

test('validarMedios: vacíos, montos, datos de cheque y suma', () => {
  assert.equal(validarMedios([], 100), 'Agregá al menos un medio de pago.')
  assert.equal(validarMedios([], 0, { permiteSinMedios: true }), null)
  assert.equal(validarMedios([nuevoMedio('efectivo', '')], 100), 'Ingresá el monto del medio 1.')
  assert.equal(validarMedios([nuevoMedio('cheque', '100')], 100), 'Ingresá el número del cheque (medio 1).')
  assert.equal(validarMedios([nuevoMedio('echeq', '100', { numero: 'E1' })], 100), 'Ingresá la fecha de pago del cheque E1.')
  assert.equal(
    validarMedios([nuevoMedio('cheque', '100', { numero: 'C1', fechaPago: '2026-10-01' })], 100, { fechaPagoProveedor: '2026-10-27' }),
    'El cheque C1 se cobra antes de la fecha del pago.',
  )
  assert.equal(validarMedios([nuevoMedio('efectivo', '60'), nuevoMedio('transferencia', '30')], 100), 'Los medios suman 90.00 y el pago es de 100.00: falta 10.00.')
  assert.equal(validarMedios([nuevoMedio('efectivo', '60'), nuevoMedio('transferencia', '40')], 100), null)
})

test('generarCheques 30/60/90 repartiendo un total: el último absorbe los centavos', () => {
  const ch = generarCheques({ medio: 'cheque', cantidad: 3, modo: 'total', monto: 1000, cadaDias: 30, desde: '2026-10-27', banco: 'Nación', numeroInicial: '00098' })
  assert.deepEqual(ch.map((c) => c.monto), ['333.33', '333.33', '333.34'])
  assert.deepEqual(ch.map((c) => c.fechaPago), ['2026-11-26', '2026-12-26', '2027-01-25'])
  assert.deepEqual(ch.map((c) => c.numero), ['00098', '00099', '00100'])
  assert.ok(ch.every((c) => c.medio === 'cheque' && c.banco === 'Nación'))
  assert.equal(totalMedios(ch), 1000)
})

test('generarCheques con monto de cada uno y sin número inicial', () => {
  const ch = generarCheques({ medio: 'echeq', cantidad: 2, modo: 'cada', monto: 250.5, cadaDias: 15, desde: '2026-12-25', banco: '', numeroInicial: '' })
  assert.deepEqual(ch.map((c) => c.monto), ['250.50', '250.50'])
  assert.deepEqual(ch.map((c) => c.fechaPago), ['2027-01-09', '2027-01-24'])
  assert.deepEqual(ch.map((c) => c.numero), ['', ''])
  assert.deepEqual(generarCheques({ medio: 'cheque', cantidad: 0, modo: 'cada', monto: 1, cadaDias: 30, desde: '2026-10-27', banco: '', numeroInicial: '' }), [])
})

test('sumarDias cruza meses y años', () => {
  assert.equal(sumarDias('2026-01-31', 1), '2026-02-01')
  assert.equal(sumarDias('2026-12-31', 1), '2027-01-01')
})

test('payloadMedios: solo los cheques llevan número, banco y fecha; banco vacío = null', () => {
  const p = payloadMedios([
    nuevoMedio('efectivo', '100', { numero: 'ignorado' }),
    nuevoMedio('cheque', '200.456', { numero: ' 12 ', banco: '', fechaPago: '2026-11-26' }),
  ])
  assert.deepEqual(p, [
    { medio: 'efectivo', monto: 100 },
    { medio: 'cheque', monto: 200.46, numero: '12', banco: null, fecha_pago: '2026-11-26', propio: true },
  ])
})
