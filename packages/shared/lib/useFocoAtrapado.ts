import { useEffect, useRef, type RefObject } from 'react'

const ENFOCABLES = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled]):not([type="hidden"])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
].join(',')

// Comportamiento de diálogo accesible para Modal / BottomSheet (opt-in con la prop `dialogo`):
// - Tab / Shift+Tab no salen del diálogo (dan la vuelta).
// - Esc llama a onEscape (cada pantalla decide: cerrar, o pedir confirmación si hay cambios).
// - Al abrir, si nada adentro tiene el foco (ningún autoFocus), va al elemento con
//   data-autofocus o al primero enfocable; al cerrar vuelve a donde estaba.
//
// Escucha con addEventListener sobre el nodo del DOM, NO con onKeyDown de React: los eventos de
// React burbujean por el árbol de componentes, y un diálogo abierto encima (ej. ConfirmDialog
// "¿Cerrar sin guardar?", otro portal) es hijo en React del de abajo — con onKeyDown, un Esc en
// el de arriba cerraría también el de abajo. En el DOM son nodos hermanos y no se pisan.
export function useFocoAtrapado(ref: RefObject<HTMLElement>, onEscape: (() => void) | undefined) {
  // Siempre la última versión del callback, sin re-suscribir el listener en cada render.
  const onEscapeRef = useRef(onEscape)
  onEscapeRef.current = onEscape
  const activo = onEscape !== undefined

  useEffect(() => {
    const contenedor = ref.current
    if (!activo || !contenedor) return
    const anterior = document.activeElement as HTMLElement | null

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
      if (anterior && document.contains(anterior)) anterior.focus()
    }
  }, [activo, ref])
}
