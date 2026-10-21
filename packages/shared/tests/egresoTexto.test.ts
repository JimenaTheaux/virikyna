// node --test packages/shared/tests  (npm test desde la raíz)
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { descripcionSinCategoria } from '../lib/egresoTexto.ts'

test('descripcionSinCategoria: igual a la categoría (sin importar mayúsculas ni acentos) → null', () => {
  assert.equal(descripcionSinCategoria('Pago a proveedor', 'Pago a proveedor'), null)
  assert.equal(descripcionSinCategoria('  PAGO A PROVEEDOR ', 'Pago a proveedor'), null)
  assert.equal(descripcionSinCategoria('Pago a proveedór', 'Pago a proveedor'), null)
  assert.equal(descripcionSinCategoria(null, 'Agua'), null)
  assert.equal(descripcionSinCategoria('   ', 'Agua'), null)
})

test('descripcionSinCategoria: "categoría — nota" deja solo la nota', () => {
  assert.equal(
    descripcionSinCategoria('Pago a proveedor — Correccion: se habia registrado por error', 'Pago a proveedor'),
    'Correccion: se habia registrado por error',
  )
  assert.equal(descripcionSinCategoria('Pago a proveedor - Factura 123', 'Pago a proveedor'), 'Factura 123')
  assert.equal(descripcionSinCategoria('Pago a proveedor — ', 'Pago a proveedor'), null)
})

test('descripcionSinCategoria: otra descripción queda igual', () => {
  assert.equal(descripcionSinCategoria('Bidones', 'Agua'), 'Bidones')
  assert.equal(descripcionSinCategoria('Agua mineral para el local', 'Agua'), 'Agua mineral para el local')
  assert.equal(
    descripcionSinCategoria('Reversion: Pago a proveedor', 'Pago a proveedor'),
    'Reversion: Pago a proveedor',
  )
})
