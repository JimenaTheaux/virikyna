// node --test packages/shared/tests  (npm test desde la raíz)
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { quitarAcentos, textoParaBuscar } from '../lib/texto.ts'

test('quitarAcentos: tildes, diéresis y graves; conserva la Ñ (igual que quitar_acentos en SQL)', () => {
  assert.equal(quitarAcentos('MUÑECA ÁRBOL Pingüino Ñandú'), 'MUÑECA ARBOL Pinguino Ñandu')
  assert.equal(quitarAcentos('àèìòù âêîôû äëïö'), 'aeiou aeiou aeio')
  assert.equal(quitarAcentos('sin cambios 123 → ok'), 'sin cambios 123 → ok')
})

test('quitarAcentos: acento combinado (NFD) también se limpia', () => {
  assert.equal(quitarAcentos('línea'), 'linea')
})

test('textoParaBuscar: lo tipeado con acento encuentra el dato sin acento', () => {
  assert.equal(textoParaBuscar('  Línea '), 'linea')
  assert.ok(textoParaBuscar('JUEGO DE MESA 4 EN LINEA').includes(textoParaBuscar('línea')))
  assert.ok(textoParaBuscar('SÚPER HÉROE').includes(textoParaBuscar('super heroe')))
  assert.equal(textoParaBuscar(null), '')
})
