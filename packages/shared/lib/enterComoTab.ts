// Enter = Tab en formularios de plata (docs/DIAGNOSTICO_ENTER_Y_FORMATO_IMPORTES.md, sección A).
// HTML envía el formulario con Enter en cualquier input si el botón submit está habilitado: así se
// registraron pagos en efectivo por el total (GUTIERREZ, TOYCO) al querer pasar al campo siguiente.
// Acá Enter en un input o select lleva el foco al siguiente campo editable (salteando botones como
// "✕ Quitar" o "+ Agregar medio"); en el último, al botón principal. Enter sobre el botón principal
// hace lo de siempre (click → submit), y ahí cada formulario decide si confirma antes de guardar.
// Sin imports de valores: la lógica pura la corre node --test directo (tests/enterComoTab.test.ts).

export type CampoNavegable = {
  navegable: boolean // input/select/textarea visible, habilitado y editable
}

export type BotonPrincipal = { deshabilitado: boolean } | null

// Índice del campo destino, 'boton' (el principal) o null (quedarse: no hay a dónde ir, por
// ejemplo el último campo con el botón deshabilitado porque los medios no cierran).
export function destinoEnter(campos: CampoNavegable[], actual: number, boton: BotonPrincipal): number | 'boton' | null {
  for (let i = actual + 1; i < campos.length; i++) {
    if (campos[i].navegable) return i
  }
  return boton && !boton.deshabilitado ? 'boton' : null
}

const TIPOS_SIN_TEXTO = new Set(['button', 'submit', 'reset', 'hidden', 'image', 'file'])

type ElementoFormulario = Element & {
  disabled?: boolean
  readOnly?: boolean
  type?: string
  tagName: string
  focus: () => void
  getClientRects: () => DOMRectList
  closest: (s: string) => Element | null
}

function esCampo(el: ElementoFormulario): boolean {
  const tag = el.tagName
  if (tag === 'SELECT' || tag === 'TEXTAREA') return true
  return tag === 'INPUT' && !TIPOS_SIN_TEXTO.has((el.type ?? 'text').toLowerCase())
}

function esNavegable(el: ElementoFormulario): boolean {
  if (!esCampo(el) || el.disabled || el.readOnly) return false
  if (el.closest('[data-enter-tab="saltear"], fieldset:disabled')) return false
  return el.getClientRects().length > 0 // visible
}

function esBotonPrincipal(el: ElementoFormulario): boolean {
  return el.tagName === 'BUTTON' && (el.type ?? 'submit').toLowerCase() === 'submit'
}

type EventoTeclado = {
  key: string
  defaultPrevented: boolean
  shiftKey: boolean
  ctrlKey: boolean
  altKey: boolean
  metaKey: boolean
  target: EventTarget | null
  nativeEvent?: { isComposing?: boolean }
  preventDefault: () => void
}

// onKeyDown del <form>. `form.elements` incluye el botón del pie asociado con form="id".
export function manejarEnterComoTab(e: EventoTeclado, form: HTMLFormElement) {
  if (e.key !== 'Enter' || e.defaultPrevented || e.nativeEvent?.isComposing) return
  if (e.shiftKey || e.ctrlKey || e.altKey || e.metaKey) return
  const objetivo = e.target as ElementoFormulario | null
  if (!objetivo || !esCampo(objetivo)) return // botones: Enter = click, como siempre
  if (objetivo.tagName === 'TEXTAREA') return // Enter = salto de línea
  if (objetivo.closest('[data-enter-tab="propio"]')) return // buscadores con Enter propio
  e.preventDefault() // nunca envío implícito desde un campo

  const elementos = Array.from(form.elements) as ElementoFormulario[]
  const campos = elementos.filter(esCampo)
  const actual = campos.indexOf(objetivo)
  if (actual < 0) return
  const boton = elementos.find(esBotonPrincipal) as (ElementoFormulario & { disabled: boolean }) | undefined
  const destino = destinoEnter(
    campos.map((c) => ({ navegable: esNavegable(c) })),
    actual,
    boton ? { deshabilitado: Boolean(boton.disabled) } : null,
  )
  if (destino === 'boton') boton?.focus()
  else if (destino !== null) campos[destino].focus()
}
