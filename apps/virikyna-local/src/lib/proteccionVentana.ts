import { isTauri } from '@tauri-apps/api/core'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { showToast } from './toast'

// Protección contra recargas y cierres que pierden lo que está en pantalla (docs/04, módulo 3).
// - En la app instalada (build de producción) las teclas de recarga y de navegación del webview no
//   hacen nada: F5, Ctrl+R, Ctrl+Shift+R, Alt+← / Alt+→. En desarrollo siguen andando, salvo durante
//   un cobro.
// - Mientras se guarda un cobro (confirmar_venta en vuelo) tampoco se puede cerrar la ventana ni
//   recargar: si se cortara en el medio, la venta queda grabada y el ticket sigue en la barra.
//   La idempotencia (docs/43) lo resuelve al volver, pero es mejor que no pase.

let cobrosEnCurso = 0

export function marcarCobroEnCurso(enCurso: boolean) {
  cobrosEnCurso = Math.max(0, cobrosEnCurso + (enCurso ? 1 : -1))
}

export function hayCobroEnCurso() {
  return cobrosEnCurso > 0
}

function esTeclaDeRecargaONavegacion(e: KeyboardEvent) {
  if (e.key === 'F5' || e.key === 'BrowserRefresh' || e.key === 'BrowserBack' || e.key === 'BrowserForward') return true
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'r') return true
  if (e.altKey && (e.key === 'ArrowLeft' || e.key === 'ArrowRight')) return true
  return false
}

export const AVISO_COBRO = 'Se está guardando el cobro. Esperá a que termine.'

// Se llama una sola vez, en main.tsx.
export function instalarProteccionVentana() {
  window.addEventListener(
    'keydown',
    (e) => {
      if (!esTeclaDeRecargaONavegacion(e)) return
      if (!import.meta.env.PROD && !hayCobroEnCurso()) return
      e.preventDefault()
      if (hayCobroEnCurso()) showToast(AVISO_COBRO)
    },
    // Captura: corre antes que cualquier otro listener de la app.
    true,
  )

  window.addEventListener('beforeunload', (e) => {
    if (!hayCobroEnCurso()) return
    e.preventDefault()
    e.returnValue = ''
  })

  // El onCloseRequested de Tauri, si no se cancela, cierra con destroy() — por eso la capability
  // necesita core:window:allow-destroy (src-tauri/capabilities/default.json).
  if (isTauri()) {
    void getCurrentWindow().onCloseRequested((evento) => {
      if (!hayCobroEnCurso()) return
      evento.preventDefault()
      showToast(AVISO_COBRO)
    })
  }
}
