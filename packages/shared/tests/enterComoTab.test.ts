// node --test packages/shared/tests  (npm test desde la raíz)
// Enter = Tab en formularios de plata: orden de foco, último campo y botón deshabilitado.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { destinoEnter, manejarEnterComoTab } from '../lib/enterComoTab.ts'

const n = (navegable: boolean) => ({ navegable })

test('pasa al siguiente campo navegable', () => {
  assert.equal(destinoEnter([n(true), n(true), n(true)], 0, { deshabilitado: false }), 1)
})

test('saltea campos no navegables (deshabilitados, ocultos, de solo lectura)', () => {
  assert.equal(destinoEnter([n(true), n(false), n(false), n(true)], 0, { deshabilitado: false }), 3)
})

test('en el último campo va al botón principal', () => {
  assert.equal(destinoEnter([n(true), n(true)], 1, { deshabilitado: false }), 'boton')
  // Lo que queda después son todos no navegables: también al botón.
  assert.equal(destinoEnter([n(true), n(false)], 0, { deshabilitado: false }), 'boton')
})

test('con el botón deshabilitado se queda donde está (no envía)', () => {
  assert.equal(destinoEnter([n(true), n(true)], 1, { deshabilitado: true }), null)
})

test('sin botón principal se queda donde está', () => {
  assert.equal(destinoEnter([n(true)], 0, null), null)
})

// ── Manejador sobre un "DOM" mínimo ──
type Fake = {
  tagName: string
  type?: string
  disabled?: boolean
  readOnly?: boolean
  visible?: boolean
  dentroDe?: string // selector que matchea closest()
  enfocado?: boolean
  focus: () => void
  getClientRects: () => { length: number }
  closest: (s: string) => object | null
}
function el(tagName: string, extra: Partial<Fake> = {}): Fake {
  const e: Fake = {
    tagName,
    visible: true,
    ...extra,
    focus() {
      e.enfocado = true
    },
    getClientRects() {
      return { length: e.visible ? 1 : 0 }
    },
    closest(s: string) {
      return e.dentroDe && s.includes(e.dentroDe) ? {} : null
    },
  }
  return e
}
function evento(target: Fake, extra: Partial<{ defaultPrevented: boolean; shiftKey: boolean }> = {}) {
  const ev = {
    key: 'Enter',
    defaultPrevented: false,
    shiftKey: false,
    ctrlKey: false,
    altKey: false,
    metaKey: false,
    target: target as unknown as EventTarget,
    prevenido: false,
    preventDefault() {
      ev.prevenido = true
    },
    ...extra,
  }
  return ev
}
const form = (elementos: Fake[]) => ({ elements: elementos }) as unknown as HTMLFormElement

// Formulario de pago: Total, Fecha, [+ Agregar medio], Medio (select), Monto, [✕ Quitar], Nota, botón del pie.
function formularioPago(botonDeshabilitado = false) {
  const total = el('INPUT', { type: 'number' })
  const fecha = el('INPUT', { type: 'date' })
  const agregar = el('BUTTON', { type: 'button' })
  const medio = el('SELECT')
  const monto = el('INPUT', { type: 'number' })
  const quitar = el('BUTTON', { type: 'button' })
  const nota = el('INPUT', { type: 'text' })
  const registrar = el('BUTTON', { type: 'submit', disabled: botonDeshabilitado })
  return { total, fecha, agregar, medio, monto, quitar, nota, registrar, f: form([total, fecha, agregar, medio, monto, quitar, nota, registrar]) }
}

test('orden de foco: Total → Fecha → Medio → Monto → Nota → botón (saltea botones)', () => {
  const p = formularioPago()
  const pasos: [Fake, Fake][] = [
    [p.total, p.fecha],
    [p.fecha, p.medio],
    [p.medio, p.monto],
    [p.monto, p.nota],
    [p.nota, p.registrar],
  ]
  for (const [desde, hacia] of pasos) {
    hacia.enfocado = false
    const ev = evento(desde)
    manejarEnterComoTab(ev, p.f)
    assert.equal(ev.prevenido, true, 'Enter en un campo nunca envía')
    assert.equal(hacia.enfocado, true)
  }
  assert.equal(p.agregar.enfocado, undefined)
  assert.equal(p.quitar.enfocado, undefined)
})

test('último campo con el botón deshabilitado: no envía ni mueve el foco', () => {
  const p = formularioPago(true)
  const ev = evento(p.nota)
  manejarEnterComoTab(ev, p.f)
  assert.equal(ev.prevenido, true)
  assert.equal(p.registrar.enfocado, undefined)
})

test('Enter sobre un botón no se toca (click → submit, como siempre)', () => {
  const p = formularioPago()
  const ev = evento(p.registrar)
  manejarEnterComoTab(ev, p.f)
  assert.equal(ev.prevenido, false)
})

test('respeta un Enter ya manejado (panel "Generar cheques") y los modificadores', () => {
  const p = formularioPago()
  const ev = evento(p.total, { defaultPrevented: true })
  manejarEnterComoTab(ev, p.f)
  assert.equal(ev.prevenido, false)
  assert.equal(p.fecha.enfocado, undefined)
  const ev2 = evento(p.total, { shiftKey: true })
  manejarEnterComoTab(ev2, p.f)
  assert.equal(ev2.prevenido, false)
})

test('textarea: Enter es salto de línea; buscador con Enter propio: no se toca', () => {
  const area = el('TEXTAREA')
  const buscador = el('INPUT', { type: 'search', dentroDe: 'data-enter-tab="propio"' })
  const f = form([area, buscador, el('BUTTON', { type: 'submit' })])
  const ev = evento(area)
  manejarEnterComoTab(ev, f)
  assert.equal(ev.prevenido, false)
  const ev2 = evento(buscador)
  manejarEnterComoTab(ev2, f)
  assert.equal(ev2.prevenido, false)
})

test('saltea campos deshabilitados, de solo lectura y ocultos', () => {
  const a = el('INPUT')
  const b = el('INPUT', { disabled: true })
  const c = el('INPUT', { readOnly: true })
  const d = el('INPUT', { visible: false })
  const e2 = el('SELECT')
  const f = form([a, b, c, d, e2, el('BUTTON', { type: 'submit' })])
  manejarEnterComoTab(evento(a), f)
  assert.equal(e2.enfocado, true)
  assert.equal(b.enfocado ?? c.enfocado ?? d.enfocado, undefined)
})
