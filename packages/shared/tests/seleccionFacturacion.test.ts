// node --test packages/shared/tests  (npm test desde la raíz)
// "Lo que sumo" (cualquier venta tildada y visible) vs. "lo que facturo" (solo sin facturar emitibles).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { alternarTodas, resumenSeleccion } from '../lib/seleccionFacturacion.ts'

const v = (id: string, estado: string, total: number, extra: { estado_interno?: string | null } = {}) => ({
  id,
  estado,
  total,
  ...extra,
})

const sf1 = v('sf1', 'sin_facturar', 100.1)
const sf2 = v('sf2', 'sin_facturar', 200.2)
const f1 = v('f1', 'facturado', 50)
const rev = v('rev', 'sin_facturar', 30)
const visibles = [sf1, sf2, f1, rev]

test('solo facturadas: suman, pero no hay nada para emitir', () => {
  const r = resumenSeleccion(visibles, new Set(['f1']), new Set())
  assert.equal(r.total, 50)
  assert.deepEqual(r.facturadas, { cantidad: 1, total: 50 })
  assert.deepEqual(r.sinFacturar, { cantidad: 0, total: 0 })
  assert.equal(r.paraEmitir.length, 0)
})

test('mezcla: total y desglose; se emiten solo las sin facturar que no están a revisar', () => {
  const r = resumenSeleccion(visibles, new Set(['sf1', 'sf2', 'f1', 'rev']), new Set(['rev']))
  assert.equal(r.total, 380.3) // sin colas de float
  assert.deepEqual(r.sinFacturar, { cantidad: 3, total: 330.3 })
  assert.deepEqual(r.facturadas, { cantidad: 1, total: 50 })
  assert.deepEqual(r.paraEmitir.map((x) => x.id), ['sf1', 'sf2'])
})

test('una venta interna nunca va al lote de Factura C', () => {
  const interna = v('int', 'sin_facturar', 10, { estado_interno: 'pendiente' })
  const r = resumenSeleccion([interna, sf1], new Set(['int', 'sf1']), new Set())
  assert.deepEqual(r.paraEmitir.map((x) => x.id), ['sf1'])
  assert.equal(r.total, 110.1)
})

test('una tildada que quedó oculta no suma ni se emite', () => {
  const r = resumenSeleccion([sf1], new Set(['sf1', 'sf2']), new Set())
  assert.equal(r.paraSumar.length, 1)
  assert.equal(r.total, 100.1)
  assert.equal(r.estadoTodo, 'todas')
})

test('tri-estado del encabezado', () => {
  assert.equal(resumenSeleccion(visibles, new Set(), new Set()).estadoTodo, 'ninguna')
  assert.equal(resumenSeleccion(visibles, new Set(['f1']), new Set()).estadoTodo, 'algunas')
  assert.equal(resumenSeleccion(visibles, new Set(['sf1', 'sf2', 'f1', 'rev']), new Set()).estadoTodo, 'todas')
  assert.equal(resumenSeleccion([], new Set(), new Set()).estadoTodo, 'ninguna')
})

test('seleccionar todo tilda las visibles; con todas tildadas, las destilda', () => {
  const todas = alternarTodas(visibles, new Set(['f1']), 'algunas')
  assert.deepEqual([...todas].sort(), ['f1', 'rev', 'sf1', 'sf2'])
  assert.equal(alternarTodas(visibles, todas, 'todas').size, 0)
  assert.equal(alternarTodas(visibles, new Set(), 'ninguna').size, 4)
})
