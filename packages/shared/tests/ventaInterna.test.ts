// node --test packages/shared/tests — cálculos del comprobante interno (docs/68, D6 y D10).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { calcularFila, costoComparable, descuentoInicial, totalesInternos, type ItemInterno } from '../lib/ventaInterna.ts'

const item = (extra: Partial<ItemInterno> = {}): ItemInterno => ({
  id: 'i1',
  cantidad: 1,
  precio_unitario: 37000,
  descuento_porcentaje: 0,
  costo_unitario: null,
  producto_con_iva: null,
  producto_costo_actual: 14000,
  producto_iva_actual: 21,
  ...extra,
})

test('D10: con IVA el costo comparable es costo × 1,21; sin IVA, el costo', () => {
  assert.deepEqual(costoComparable(item()), { valor: 16940, fuente: 'actual' })
  assert.deepEqual(costoComparable(item({ producto_iva_actual: 0 })), { valor: 14000, fuente: 'actual' })
  assert.deepEqual(costoComparable(item({ costo_unitario: 10000, producto_con_iva: false })), { valor: 10000, fuente: 'snapshot' })
})

test('sin costo cargado: sin margen ni descuento máximo (no 0 %)', () => {
  const f = calcularFila(item({ producto_costo_actual: null }), 30)
  assert.equal(f.costo, null)
  assert.equal(f.margen, null)
  assert.equal(f.margenPorcentaje, null)
  assert.equal(f.descuentoMaximo, null)
  assert.equal(f.bajoCosto, false)
})

test('margen sobre precio final, descuento máximo y bajo costo', () => {
  const f = calcularFila(item(), 30) // 37000 × 0,7 = 25900; costo 16940
  assert.equal(f.precioFinalUnitario, 25900)
  assert.equal(f.margen, 8960)
  assert.equal(f.margenPorcentaje, 34.59)
  assert.equal(f.descuentoMaximo, 54.21) // 1 − 16940/37000 = 54,216… → hacia abajo
  assert.equal(calcularFila(item(), 54.21).bajoCosto, false)
  assert.equal(calcularFila(item(), 60).bajoCosto, true)
})

test('importe igual al de editar_venta_interna (cantidad × precio × (1 − d))', () => {
  assert.equal(calcularFila(item({ cantidad: 3, precio_unitario: 1999.99 }), 12.5).importe, 5249.97)
})

test('D6: el global se precarga en cada ítem; ya editada, rige el del ítem', () => {
  assert.equal(descuentoInicial({ descuento_porcentaje: 0 }, 30), 30)
  assert.equal(descuentoInicial({ descuento_porcentaje: 10 }, 30), 37)
  assert.equal(descuentoInicial({ descuento_porcentaje: 20 }, 0), 20)
})

test('totales: lista, subtotal y total con recargo', () => {
  const items = [item(), item({ id: 'i2', cantidad: 2, precio_unitario: 1000 })]
  const t = totalesInternos(items, new Map([['i1', 30], ['i2', 0]]), 0)
  assert.deepEqual(t, { lista: 39000, subtotal: 27900, total: 27900 })
  assert.equal(totalesInternos(items, new Map(), 10).total, 42900)
})
