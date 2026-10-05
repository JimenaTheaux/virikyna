// node --test packages/shared/tests  (npm test desde la raíz)
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  calcularPrecio,
  cambiosPrecioFactura,
  costoConPorcentaje,
  redondearPrecioVenta,
  type ProductoPrecioActual,
} from '../lib/precios.ts'

// Sin márgenes ni IVA el precio calculado es el costo: sirve para probar solo el redondeo.
const venta = (costo: number | string) => calcularPrecio({ costo, margen1: 0, margen2: 0, iva: 0 }).venta

// Mismos casos que el bloque de tests de docs/30_redondeo_escalonado.sql: [base, esperado].
const CASOS_REDONDEO: [number, number][] = [
  [0, 0], [49, 0], [50, 100], [149, 100], [150, 200], [449.99, 400], [450, 500],
  [499, 500], [500, 500], [700, 500], [700.01, 1000], [6000, 6000],
  [6100, 6000], [6200, 6000], [6200.01, 6500], [6300, 6500], [6500, 6500],
  [6700, 6500], [6700.01, 7000], [6800, 7000], [9700, 9500], [9750, 10000],
  [9999.99, 10000], [10000, 10000], [10400, 10000], [11200, 11000],
  [11499.99, 11000], [11500, 12000], [11680, 12000],
]

test('redondeo escalonado: los 29 casos de docs/30', () => {
  for (const [base, esperado] of CASOS_REDONDEO) {
    assert.equal(redondearPrecioVenta(base), esperado, `redondearPrecioVenta(${base})`)
  }
})

test('calcularPrecio usa la misma regla (venta = redondeo de calculado)', () => {
  for (const [base, esperado] of CASOS_REDONDEO) {
    assert.equal(venta(base), esperado, `calcularPrecio(costo ${base}).venta`)
  }
})

test('redondeo: la base es ROUND(x, 2) y acepta texto', () => {
  assert.equal(redondearPrecioVenta(6200.004), 6000) // → 6200,00 → baja
  assert.equal(redondearPrecioVenta(6200.005), 6500) // → 6200,01 → sube
  assert.equal(redondearPrecioVenta('449.995'), 500) // → 450,00 → sube
  assert.equal(redondearPrecioVenta(''), 0)
})

test('calculado, venta y ajuste con márgenes e IVA', () => {
  // 1000 × 1,2 × 1,1 × 1,21 = 1597,20 → resto 97,20 → baja a 1500
  assert.deepEqual(calcularPrecio({ costo: 1000, margen1: 20, margen2: 10, iva: 21 }), {
    calculado: 1597.2,
    venta: 1500,
    ajuste: -97.2,
  })
  // 1500 × 1,155 × 1,21 = 2096,325 → calculado 2096,33 (la mitad redondea hacia afuera) → 2000
  assert.deepEqual(calcularPrecio({ costo: 1500, margen1: 15.5, margen2: 0, iva: 21 }), {
    calculado: 2096.33,
    venta: 2000,
    ajuste: -96.33,
  })
  // 9000 × 1,21 = 10890 → múltiplo de 1000 → 11000
  assert.deepEqual(calcularPrecio({ costo: 9000, margen1: 0, margen2: 0, iva: 21 }), {
    calculado: 10890,
    venta: 11000,
    ajuste: 110,
  })
})

test('entradas de formulario: texto, vacío, inválido, más de 2 decimales', () => {
  assert.equal(venta(''), 0)
  assert.equal(venta('abc'), 0)
  assert.equal(calcularPrecio({ costo: '100', margen1: '33.333', margen2: '', iva: '21' }).calculado, 161.33)
})

test('punto flotante: 2,675 redondea como NUMERIC (2,68), no como double (2,67)', () => {
  assert.equal(calcularPrecio({ costo: '2.675', margen1: 0, margen2: 0, iva: 0 }).calculado, 2.68)
})

test('costoConPorcentaje = ROUND(costo × (1 + p/100), 2)', () => {
  assert.equal(costoConPorcentaje(1000, 10), 1100)
  assert.equal(costoConPorcentaje(1000, '-12.5'), 875)
  assert.equal(costoConPorcentaje(1234.56, '7.5'), 1327.15) // 1327,152
  assert.equal(costoConPorcentaje(10.05, '5'), 10.55) // 10,5525
  assert.equal(costoConPorcentaje(0.1, '5'), 0.11) // 0,105 → mitad hacia afuera
})

const producto = (extra: Partial<ProductoPrecioActual> = {}): ProductoPrecioActual => ({
  costo: 1000,
  margen_1: 0,
  margen_2: 0,
  iva_porcentaje: 21,
  proveedor_id: 'prov-a',
  precio_venta: 1500, // 1210 → resto 210 → 1500
  ...extra,
})
const item = (key: string, precio: string, productoId = 'p1', productoPrecio = producto()) => ({
  key,
  productoId,
  precioUnitarioSinIva: precio,
  productoPrecio,
})
const proveedores = [
  { id: 'prov-a', margen_1_default: 0, margen_2_default: 0 },
  { id: 'prov-b', margen_1_default: 100, margen_2_default: 20 },
]

test('factura: costo nuevo actualiza el precio de venta', () => {
  const r = cambiosPrecioFactura([item('a', '2000')], 'factura', 'prov-a', proveedores)
  assert.deepEqual(r.get('a'), { tipo: 'actualiza', antes: 1500, despues: 2500 }) // 2420 → resto 420 → 2500
})

test('factura: mismo costo y mismo proveedor no muestra nada', () => {
  assert.equal(cambiosPrecioFactura([item('a', '1000')], 'factura', 'prov-a', proveedores).size, 0)
})

test('factura: costo distinto que redondea al mismo precio', () => {
  const r = cambiosPrecioFactura([item('a', '1001')], 'factura', 'prov-a', proveedores) // 1211,21 → 1500
  assert.deepEqual(r.get('a'), { tipo: 'sin_cambio_precio', precio: 1500 })
})

test('nota de crédito / débito y precio 0 no tocan el costo', () => {
  assert.equal(cambiosPrecioFactura([item('a', '5000')], 'nota_credito', 'prov-a', proveedores).size, 0)
  assert.equal(cambiosPrecioFactura([item('a', '5000')], 'nota_debito', 'prov-a', proveedores).size, 0)
  assert.equal(cambiosPrecioFactura([item('a', '0')], 'factura', 'prov-a', proveedores).size, 0)
})

test('producto repetido: gana la última línea', () => {
  const r = cambiosPrecioFactura([item('a', '3000'), item('b', '2000')], 'factura', 'prov-a', proveedores)
  assert.deepEqual(r.get('a'), { tipo: 'repetido' })
  assert.deepEqual(r.get('b'), { tipo: 'actualiza', antes: 1500, despues: 2500 })
})

test('proveedor distinto: márgenes default del proveedor nuevo (también en nota de crédito)', () => {
  // 3000 × 2 × 1,2 × 1,21 = 8712 → resto 212 → 9000
  const r = cambiosPrecioFactura([item('a', '3000')], 'factura', 'prov-b', proveedores)
  assert.deepEqual(r.get('a'), { tipo: 'actualiza', antes: 1500, despues: 9000 })
  // NC: costo queda 1000, márgenes 100/20 → 2904 → resto 404 → 3000
  const nc = cambiosPrecioFactura([item('a', '3000')], 'nota_credito', 'prov-b', proveedores)
  assert.deepEqual(nc.get('a'), { tipo: 'actualiza', antes: 1500, despues: 3000 })
})
