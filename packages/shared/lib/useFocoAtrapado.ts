import { useEffect, useRef, type RefObject } from 'react'

const ENFOCABLES = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled]):not([type="hidden"])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
].join(',')

// Último elemento que perdió el foco. Un hijo con autoFocus toma el foco durante el render, antes del
// efecto de abajo: para entonces activeElement ya está adentro del diálogo, y "dónde estaba" es el
// elemento que lo acaba de perder (ej. el ⋮ de RowActionsMenu antes de abrir Devolución / Cambio).
let ultimoQuePerdioFoco: HTMLElement | null = null
if (typeof document !== 'undefined') {
  document.addEventListener(
    'focusout',
    (e) => {
      if (e.target instanceof HTMLElement) ultimoQuePerdioFoco = e.target
    },
    true,
  )
}

// Comportamiento de diálogo accesible para Modal / BottomSheet (opt-in con la prop `dialogo`):
// - Tab / Shift+Tab no salen del diálogo (dan la vuelta).
// - Esc llama a onEscape. Con onEscape = null el diálogo queda activo pero Esc no hace nada (ni
//   llega a lo de abajo): es el caso de los formularios, que solo se cierran con ✕ / Cancelar.
//   undefined = sin comportamiento de diálogo.
// - Al abrir, si nada adentro tiene el foco (ningún autoFocus), va al elemento con
//   data-autofocus o al primero enfocable; al cerrar vuelve a donde estaba (también con autoFocus).
//
// Escucha con addEventListener sobre el nodo del DOM, NO con onKeyDown de React: los eventos de
// React burbujean por el árbol de componentes, y un diálogo abierto encima (ej. ConfirmDialog
// "¿Cerrar sin guardar?", otro portal) es hijo en React del de abajo — con onKeyDown, un Esc en
// el de arriba cerraría también el de abajo. En el DOM son nodos hermanos y no se pisan.
export function useFocoAtrapado(ref: RefObject<HTMLElement>, onEscape: (() => void) | null | undefined) {
  // Siempre la última versión del callback, sin re-suscribir el listener en cada render.
  const onEscapeRef = useRef(onEscape)
  onEscapeRef.current = onEscape
  const activo = onEscape !== undefined

  useEffect(() => {
    const contenedor = ref.current
    if (!activo || !contenedor) return
    const activoAlAbrir = document.activeElement as HTMLElement | null
    const anterior =
      activoAlAbrir && contenedor.contains(activoAlAbrir)
        ? ultimoQuePerdioFoco && !contenedor.contains(ultimoQuePerdioFoco)
          ? ultimoQuePerdioFoco
          : null
        : activoAlAbrir

    const enfocables = () =>
      Array.from(contenedor.querySelectorAll<HTMLElement>(ENFOCABLES)).filter((el) => el.offsetParent !== null)

    if (!contenedor.contains(document.activeElement)) {
      const inicial = contenedor.querySelector<HTMLElement>('[data-autofocus]') ?? enfocables()[0]
      inicial?.focus()
    }

    function onKeyDown(e: KeyboardEvent) {
      if (e.key === 'Escape') {
        e.stopPropagation()
        onEscapeRef.current?.()
        return
      }
      if (e.key !== 'Tab') return
      // Un diálogo anidado en el DOM del de abajo (ConfirmDialog de Inventario) resuelve su Tab
      // acá y no deja que el de abajo lo vuelva a procesar.
      e.stopPropagation()
      const lista = enfocables()
      if (lista.length === 0) {
        e.preventDefault()
        return
      }
      const primero = lista[0]
      const ultimo = lista[lista.length - 1]
      if (e.shiftKey && document.activeElement === primero) {
        e.preventDefault()
        ultimo.focus()
      } else if (!e.shiftKey && document.activeElement === ultimo) {
        e.preventDefault()
        primero.focus()
      }
    }

    contenedor.addEventListener('keydown', onKeyDown)
    return () => {
      contenedor.removeEventListener('keydown', onKeyDown)
      // Solo al cerrarse de verdad (en StrictMode el efecto se desmonta y se vuelve a montar con el
      // diálogo todavía en el DOM) y si nadie más tomó el foco (otro diálogo que se abrió con
      // autoFocus): quedó en el body o adentro de este diálogo.
      if (document.contains(contenedor)) return
      const ahora = document.activeElement
      const libre = !ahora || ahora === document.body || contenedor.contains(ahora)
      if (libre && anterior && document.contains(anterior)) anterior.focus()
    }
  }, [activo, ref])
}
