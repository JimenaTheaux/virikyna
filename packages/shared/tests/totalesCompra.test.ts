// node --test packages/shared/tests  (npm test desde la raíz)
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  aAlicuotaIvaCompra,
  alicuotaDefault,
  calcularTotalesFacturaCompra,
  etiquetaAlicuotaIva,
  ivaDeCompra,
} from '../lib/totalesCompra.ts'

const item = (cantidad: string, precio: string, descuento = '0', descripcion = 'X') => ({
  key: crypto.randomUUID(),
  productoId: null,
  descripcion,
  cantidad,
  precioUnitarioSinIva: precio,
  descuentoPorcentaje: descuento,
  ubicacion: 'local' as const,
})

test('alicuotaDefault: 21 en factura, ND y NC; exento en cupón, remito y presupuesto', () => {
  assert.equal(alicuotaDefault('factura'), 21)
  assert.equal(alicuotaDefault('nota_debito'), 21)
  assert.equal(alicuotaDefault('nota_credito'), 21)
  assert.equal(alicuotaDefault('cupon'), 0)
  assert.equal(alicuotaDefault('remito'), 0)
  assert.equal(alicuotaDefault('presupuesto'), 0)
})

test('totales con 21 %: mismos números que el RPC (docs/45, casos 1 y 7)', () => {
  assert.deepEqual(calcularTotalesFacturaCompra([item('2', '500')], 21), {
    subtotalSinIva: 1000,
    descuento: 0,
    iva: 210,
    total: 1210,
    saldoPendiente: 1210,
  })
  const conDescuento = calcularTotalesFacturaCompra([item('2', '1000', '10')], 21)
  assert.equal(conDescuento.subtotalSinIva, 1800)
  assert.equal(conDescuento.descuento, 200)
  assert.equal(conDescuento.iva, 378)
  assert.equal(conDescuento.total, 2178)
})

test('totales exentos: IVA 0 y total = subtotal', () => {
  const r = calcularTotalesFacturaCompra([item('24', '8182')], 0)
  assert.equal(r.subtotalSinIva, 196368)
  assert.equal(r.iva, 0)
  assert.equal(r.total, 196368)
  assert.equal(r.saldoPendiente, 196368)
})

test('el cupón de la auditoría (G): 196.368 con 21 % daba 237.605,28', () => {
  assert.equal(calcularTotalesFacturaCompra([item('24', '8182')], 21).total, 237605.28)
})

test('ítems en blanco no suman', () => {
  const r = calcularTotalesFacturaCompra([item('2', '500'), item('1', '999', '0', '  ')], 21)
  assert.equal(r.subtotalSinIva, 1000)
})

test('ivaDeCompra redondea a centavos', () => {
  assert.equal(ivaDeCompra(100.05, 21), 21.01) // 21,0105
  assert.equal(ivaDeCompra(100.05, 0), 0)
})

test('etiquetas y lectura de la base', () => {
  assert.equal(etiquetaAlicuotaIva(21), 'IVA (21%)')
  assert.equal(etiquetaAlicuotaIva('21.00'), 'IVA (21%)')
  assert.equal(etiquetaAlicuotaIva(0), 'Exento')
  assert.equal(etiquetaAlicuotaIva('0.00'), 'Exento')
  assert.equal(aAlicuotaIvaCompra('0.00'), 0)
  assert.equal(aAlicuotaIvaCompra('21.00'), 21)
})
