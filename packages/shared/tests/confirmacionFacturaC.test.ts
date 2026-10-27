// node --test packages/shared/tests  (npm test desde la raíz)
// El documento tiene que coincidir con lo que manda arca-emitir-factura: solo CUIT de 11 dígitos.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { confirmacionFacturaC, documentoParaArca } from '../lib/confirmacionFacturaC.ts'

const n = (s: string) => s.replace(/ /g, ' ')

test('CUIT de 11 dígitos (con o sin guiones) se informa formateado', () => {
  assert.deepEqual(documentoParaArca('20123456789'), { tipo: 'cuit', texto: 'CUIT 20-12345678-9' })
  assert.deepEqual(documentoParaArca('20-12345678-9'), { tipo: 'cuit', texto: 'CUIT 20-12345678-9' })
})

test('sin documento: consumidor final sin aviso', () => {
  assert.deepEqual(documentoParaArca(null), { tipo: 'consumidor_final', texto: 'Consumidor final (sin documento)', aviso: null })
  assert.deepEqual(documentoParaArca('  '), { tipo: 'consumidor_final', texto: 'Consumidor final (sin documento)', aviso: null })
})

test('DNI: consumidor final con aviso', () => {
  const d = documentoParaArca('30.123.456')
  assert.equal(d.tipo, 'consumidor_final')
  assert.equal(d.tipo === 'consumidor_final' && d.aviso, 'El DNI no se informa: sale como consumidor final.')
})

test('CUIT mal cargado: consumidor final con aviso que lo nombra', () => {
  const d = documentoParaArca('2012345678')
  assert.ok(d.tipo === 'consumidor_final' && d.aviso?.includes('2012345678'))
})

test('una venta: renglones en orden, punto de venta y aviso de DNI', () => {
  const r = confirmacionFacturaC([{ numero: 1234, total: 15000, cliente: { razon_social: 'PEREZ', nombre_fantasia: null, cuit: '30123456' } }], '0002')
  assert.equal(r.titulo, 'Emitir Factura C')
  assert.equal(r.confirmLabel, 'Emitir factura')
  assert.equal(
    n(r.mensaje),
    [
      'Cliente: PEREZ',
      'Documento: Consumidor final (sin documento)',
      '⚠ El DNI no se informa: sale como consumidor final.',
      'Ticket: 1234 · Total: $ 15.000,00',
      'Punto de venta: 0002',
      'Esta acción no se puede deshacer.',
    ].join('\n'),
  )
})

test('una venta sin cliente y sin punto de venta conocido: se omite el renglón', () => {
  const r = confirmacionFacturaC([{ numero: 7, total: 100, cliente: null }], null)
  assert.ok(!r.mensaje.includes('Punto de venta'))
  assert.ok(r.mensaje.startsWith('Cliente: Consumidor final\nDocumento: Consumidor final (sin documento)\nTicket: 7'))
})

test('varias: lista de tickets, total general y aviso para los sin CUIT válido', () => {
  const r = confirmacionFacturaC(
    [
      { numero: 1, total: 1000, cliente: null },
      { numero: 2, total: 2500.5, cliente: { razon_social: 'ACME SA', nombre_fantasia: null, cuit: '30-71234567-1' } },
      { numero: 3, total: 500, cliente: { razon_social: null, nombre_fantasia: 'Juana', cuit: '25111222' } },
    ],
    '0002',
  )
  assert.equal(r.titulo, 'Emitir 3 Facturas C')
  assert.equal(r.confirmLabel, 'Emitir 3 facturas')
  const m = n(r.mensaje)
  assert.ok(m.includes('Ticket 1 · Consumidor final · $ 1.000,00'))
  assert.ok(m.includes('Ticket 2 · ACME SA (CUIT 30-71234567-1) · $ 2.500,50'))
  assert.ok(m.includes('Ticket 3 · Juana ⚠ sale como consumidor final · $ 500,00'))
  assert.ok(m.includes('Total: $ 4.000,50'))
  assert.ok(m.includes('⚠ Los marcados'))
  assert.ok(m.endsWith('Punto de venta: 0002\nEsta acción no se puede deshacer.'))
})
