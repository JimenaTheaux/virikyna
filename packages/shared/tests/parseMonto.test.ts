// node --test packages/shared/tests  (npm test desde la raíz)
// Lectura de importes en formato argentino (criterio de la dueña, 2026-11-06).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { montoEditable, parseMonto } from '../lib/parseMonto.ts'

const casos = (pares: [string, string | null][], opciones?: { negativo?: boolean }) => {
  for (const [entrada, esperado] of pares) assert.equal(parseMonto(entrada, opciones), esperado, JSON.stringify(entrada))
}

test('con coma: coma decimal, puntos de miles', () => {
  casos([
    ['4.500,40', '4500.40'],
    ['4500,40', '4500.40'],
    ['1,5', '1.5'],
    ['1.250.000,05', '1250000.05'],
    [',5', '0.5'],
    ['4500,', '4500'], // coma al final mientras tipea
  ])
})

test('sin coma, varios puntos: miles', () => {
  casos([
    ['1.250.000', '1250000'],
    ['12.345.678', '12345678'],
  ])
})

test('sin coma, un punto + 3 dígitos: miles', () => {
  casos([
    ['4.500', '4500'],
    ['632.250', '632250'],
    ['1.000', '1000'],
  ])
})

test('sin coma, un punto + 1 o 2 dígitos: decimal', () => {
  casos([
    ['4500.40', '4500.40'],
    ['1.5', '1.5'],
    ['4500.4', '4500.4'],
    ['.5', '0.5'],
    ['4500.', '4500'], // punto al final mientras tipea
  ])
})

test('quita $, espacios y espacios duros', () => {
  casos([
    ['$ 4.500,40', '4500.40'],
    ['$ 4.500,40', '4500.40'],
    [' 4500 ', '4500'],
    ['$1.250.000', '1250000'],
  ])
})

test('vacío: string vacío (no es inválido)', () => {
  casos([
    ['', ''],
    ['   ', ''],
    ['$', ''],
  ])
})

test('inválidos: más de 2 decimales, letras, negativos, separadores mal puestos', () => {
  casos([
    ['4500,405', null],
    ['4.500,40,1', null],
    ['45.00,40', null], // miles mal agrupados con coma decimal
    ['4.50.0', null],
    ['1.2345', null], // un punto + 4 dígitos
    ['12a', null],
    ['1e3', null],
    ['-10', null],
    ['−10', null],
    ['abc', null],
  ])
})

test('negativos solo con la opción (ej. saldo inicial a favor)', () => {
  casos(
    [
      ['-10', '-10'],
      ['-4.500,40', '-4500.40'],
      ['-', null],
    ],
    { negativo: true },
  )
})

test('ceros a la izquierda', () => {
  casos([
    ['007', '7'],
    ['0,50', '0.50'],
    ['0', '0'],
  ])
})

// Tabla B.5 del diagnóstico: lo que antes leía <input type="number"> y lo que se lee ahora.
test('tabla B.5: "4.500" y "632.250" ya no son 1000 veces menores', () => {
  casos([
    ['4500.40', '4500.40'], // antes 4500,40 — igual
    ['4500,40', '4500.40'], // antes 4500,40 — igual
    ['4.500,40', '4500.40'], // antes 4,5004 (y el navegador bloqueaba) — ahora bien
    ['4.500', '4500'], // antes 4,50 — ahora 4500
    ['632.250', '632250'], // antes 632,25 (Cierre Z del 20/10) — ahora 632250
    ['1,5', '1.5'],
    ['4500,4,0', null], // antes 4500,40 (descartaba la segunda coma) — ahora inválido
    ['-10', null], // antes -10 donde no había min — ahora inválido
    ['1e3', null], // antes 1000 — ahora inválido
  ])
})

test('montoEditable: punto decimal → coma, sin miles', () => {
  assert.equal(montoEditable('4500.40'), '4500,40')
  assert.equal(montoEditable('1250000'), '1250000')
  assert.equal(montoEditable(''), '')
})
