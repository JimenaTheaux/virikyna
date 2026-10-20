// node --test packages/shared/tests  (npm test desde la raíz)
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { limpiarLecturaCamara, soloDigitos } from '../lib/lecturaCamara.ts'

test('quita el prefijo AIM de Code 128 con FNC1 (]C1): el 1 es parte del prefijo', () => {
  assert.equal(limpiarLecturaCamara(']C107727030081532'), '07727030081532')
  assert.equal(limpiarLecturaCamara(']C16920220026209'), '6920220026209')
})

test('quita el prefijo AIM de EAN-13 (]E0)', () => {
  assert.equal(limpiarLecturaCamara(']E07790001234567'), '7790001234567')
})

test('sin prefijo: igual que antes (solo saca espacios)', () => {
  assert.equal(limpiarLecturaCamara('7790001234567'), '7790001234567')
  assert.equal(limpiarLecturaCamara(' 0012 345678905 '), '0012345678905')
})

test('con letras u otros caracteres: se descarta', () => {
  assert.equal(limpiarLecturaCamara('LS20024'), null)
  assert.equal(limpiarLecturaCamara('ZZ619470684278'), null)
  assert.equal(limpiarLecturaCamara('https://virikyna.com/p/123'), null)
  assert.equal(limpiarLecturaCamara('INT-MABC123'), null)
  assert.equal(limpiarLecturaCamara(']C1'), null) // solo el prefijo
  assert.equal(limpiarLecturaCamara(''), null)
  assert.equal(limpiarLecturaCamara('123-456'), null)
})

test('un "]" que no es prefijo AIM completo no se toma como tal', () => {
  assert.equal(limpiarLecturaCamara(']1234'), null)
})

test('entrada manual: solo dígitos', () => {
  assert.equal(soloDigitos('77 9000-1234a567'), '7790001234567')
  assert.equal(soloDigitos('abc'), '')
})
