import type { ReactNode } from 'react'
import { createPortal } from 'react-dom'

type Props = {
  title: string
  onClose: () => void
  children: ReactNode
}

// Equivalente móvil de Modal (apps/virikyna-local y virikyna-gestion): en vez de un modal
// centrado, ocupa toda la pantalla — el patrón esperado en un formulario de celular en vez
// de una ventana chica sobre la que hay que apuntar con el dedo. Lo usan virikyna-inventario
// y virikyna-local (terminal táctil); virikyna-gestion (backoffice desktop) sigue con Modal.
//
// Portal a document.body a propósito: un BottomSheet puede abrirse desde adentro de OTRO
// formulario (ej. "+ Crear producto nuevo" durante la carga de una factura, ver ItemFacturaRow).
// Sin portal, el <form> de este sheet queda anidado dentro del <form> de afuera — HTML no permite
// forms anidados, así que el navegador lo aplana y "Guardar" termina disparando el formulario
// incorrecto (o ninguno). El portal lo saca del árbol del DOM del padre.
//
// OJO — el portal no alcanza solo: React hace burbujear los eventos sintéticos según el árbol de
// React, no según el árbol real del DOM. Un sheet renderizado por portal sigue siendo, para React,
// hijo del formulario que lo abrió — así que el submit de "Guardar" de ESTE sheet seguía llegando
// también al onSubmit del formulario de afuera (por eso cerrar el subformulario de producto
// cerraba la factura entera). Cortamos esa propagación acá, en el único punto por el que pasan
// todos los sheets de la app.
export function BottomSheet({ title, onClose, children }: Props) {
  return createPortal(
    <div className="fixed inset-0 z-50 flex flex-col bg-bg" onSubmit={(e) => e.stopPropagation()}>
      <div className="flex flex-shrink-0 items-center justify-between border-b border-line bg-surface px-4 py-3 pt-[calc(env(safe-area-inset-top,0px)+12px)]">
        <h2 className="font-display text-headline-md text-accent-darker">{title}</h2>
        <button
          type="button"
          onClick={onClose}
          aria-label="Cerrar"
          className="rounded-full p-2 text-ink-soft hover:bg-accent-light hover:text-accent-darker"
        >
          <svg
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth={2}
            strokeLinecap="round"
            strokeLinejoin="round"
            className="h-6 w-6"
          >
            <path d="M18 6 6 18M6 6l12 12" />
          </svg>
        </button>
      </div>
      <div className="flex-1 overflow-y-auto p-stack-md pb-[calc(32px+env(safe-area-inset-bottom,0px))]">
        {children}
      </div>
    </div>,
    document.body,
  )
}
