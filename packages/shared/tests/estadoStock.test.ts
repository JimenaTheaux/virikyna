// node --test packages/shared/tests  (npm test desde la raíz)
// Las definiciones tienen que coincidir con resumen_stock_inventario (docs/64, PARTE C).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  avisoStockMinimo,
  cantidadFiltrosAplicados,
  clasificarStock,
  escribirFiltrosInventario,
  FILTROS_INVENTARIO_DEFAULT,
  filtrarInventario,
  leerFiltrosInventario,
  type ProductoFiltrable,
} from '../lib/estadoStock.ts'

type P = ProductoFiltrable & { stock: number }

function p(id: string, stock: number, minimo: number, extra: Partial<P> = {}): P {
  return { id, nombre: id, marca: null, proveedor_id: null, estado: 'activo', stock_minimo: minimo, precio_venta: 100, stock, ...extra }
}

const opts = { stockDe: (x: P) => x.stock, coincideBusqueda: (x: P, q: string) => x.nombre.toLowerCase().includes(q.toLowerCase()) }

test('clasificarStock: el más grave que aplica', () => {
  assert.equal(clasificarStock(-2, 5), 'negativo')
  assert.equal(clasificarStock(0, 0), 'sin_stock')
  assert.equal(clasificarStock(0, 5), 'sin_stock')
  assert.equal(clasificarStock(3, 5), 'bajo')
  assert.equal(clasificarStock(5, 5), 'bajo')
  assert.equal(clasificarStock(6, 5), 'ok')
  assert.equal(clasificarStock(4, 0), 'sin_minimo')
})

test('contadores: sin stock incluye negativos; bajo excluye sin stock; sin mínimo es mínimo 0', () => {
  const prods = [p('a', -1, 0), p('b', 0, 3), p('c', 2, 3), p('d', 10, 3), p('e', 4, 0)]
  const { contadores } = filtrarInventario(prods, FILTROS_INVENTARIO_DEFAULT, opts)
  assert.deepEqual(contadores, { todos: 5, sin_stock: 2, negativo: 1, bajo: 1, sin_minimo: 2 })
})

test('contadores respetan estado, marca, proveedor y búsqueda, pero no el chip elegido', () => {
  const prods = [
    p('alfa', 0, 0, { marca: 'X' }),
    p('beta', 0, 0, { marca: 'Y' }),
    p('gama', 0, 0, { marca: 'X', estado: 'inactivo' }),
    p('delta', 5, 0, { marca: 'X', proveedor_id: 'prov1' }),
  ]
  const r = filtrarInventario(prods, { ...FILTROS_INVENTARIO_DEFAULT, marca: 'X', stock: 'sin_stock' }, opts)
  assert.equal(r.contadores.todos, 2) // alfa y delta (gama es inactivo)
  assert.equal(r.contadores.sin_stock, 1)
  assert.deepEqual(r.visibles.map((x) => x.id), ['alfa'])
  assert.equal(r.totalEstado, 3) // activos, sin importar marca

  const inactivos = filtrarInventario(prods, { ...FILTROS_INVENTARIO_DEFAULT, estado: 'inactivos' }, opts)
  assert.deepEqual(inactivos.visibles.map((x) => x.id), ['gama'])

  const prov = filtrarInventario(prods, { ...FILTROS_INVENTARIO_DEFAULT, proveedor: 'prov1' }, opts)
  assert.deepEqual(prov.visibles.map((x) => x.id), ['delta'])

  const q = filtrarInventario(prods, { ...FILTROS_INVENTARIO_DEFAULT, q: 'TA' }, opts)
  assert.deepEqual(q.visibles.map((x) => x.id), ['beta', 'delta'])
})

test('orden: nombre por defecto; stock ascendente en chips de problemas; orden elegido gana', () => {
  const prods = [p('c', -1, 0), p('a', 0, 2), p('b', -5, 0)]
  assert.deepEqual(filtrarInventario(prods, FILTROS_INVENTARIO_DEFAULT, opts).visibles.map((x) => x.id), ['a', 'b', 'c'])
  assert.deepEqual(
    filtrarInventario(prods, { ...FILTROS_INVENTARIO_DEFAULT, stock: 'sin_stock' }, opts).visibles.map((x) => x.id),
    ['b', 'c', 'a'],
  )
  assert.deepEqual(
    filtrarInventario(prods, { ...FILTROS_INVENTARIO_DEFAULT, stock: 'sin_stock' }, { ...opts, orden: { campo: 'nombre', dir: 'desc' } }).visibles.map((x) => x.id),
    ['c', 'b', 'a'],
  )
})

test('URL: solo lo distinto del default, valores desconocidos vuelven al default, otros params se conservan', () => {
  const escrito = escribirFiltrosInventario(new URLSearchParams('tab=x'), { ...FILTROS_INVENTARIO_DEFAULT, stock: 'bajo', marca: 'LEGO' })
  assert.equal(escrito.toString(), 'tab=x&stock=bajo&marca=LEGO')
  assert.deepEqual(leerFiltrosInventario(escrito), { ...FILTROS_INVENTARIO_DEFAULT, stock: 'bajo', marca: 'LEGO' })
  assert.deepEqual(leerFiltrosInventario(new URLSearchParams('estado=raro&stock=x')), FILTROS_INVENTARIO_DEFAULT)
  assert.equal(escribirFiltrosInventario(escrito, FILTROS_INVENTARIO_DEFAULT).toString(), 'tab=x')
})

test('avisoStockMinimo: alta con mínimo, edición con mínimo = stock, nada en el resto', () => {
  assert.equal(avisoStockMinimo({ minimo: 0, stockActual: 0, esAlta: true }), null)
  assert.match(avisoStockMinimo({ minimo: 5, stockActual: 0, esAlta: true }) ?? '', /no es la cantidad que entra/)
  assert.equal(avisoStockMinimo({ minimo: 6, stockActual: 6, esAlta: false }), '¿Seguro? El mínimo es igual al stock cargado.')
  assert.equal(avisoStockMinimo({ minimo: 3, stockActual: 6, esAlta: false }), null)
  assert.equal(avisoStockMinimo({ minimo: 0, stockActual: 0, esAlta: false }), null)
})

test('cantidadFiltrosAplicados', () => {
  assert.equal(cantidadFiltrosAplicados(FILTROS_INVENTARIO_DEFAULT), 0)
  const f = { ...FILTROS_INVENTARIO_DEFAULT, estado: 'todos' as const, stock: 'bajo' as const, marca: 'X' }
  assert.equal(cantidadFiltrosAplicados(f), 3)
  assert.equal(cantidadFiltrosAplicados(f, { conStock: false }), 2)
})
