import type { ReactNode } from 'react'
import { createPortal } from 'react-dom'

type Props = {
  title: string
  onClose: () => void
  children: ReactNode
  widthClassName?: string
}

// Portal a document.body a propósito: un Modal puede abrirse desde adentro de OTRO formulario
// (ej. "+ Crear producto nuevo" durante la carga de una factura de compra, ver ItemFacturaRow).
// Sin portal, el <form> de este modal queda anidado dentro del <form> de afuera — HTML no permite
// forms anidados, así que el navegador lo aplana y el submit de "Guardar" termina disparando el
// formulario incorrecto (o ninguno). El portal saca este modal del árbol del DOM del padre.
//
// OJO — el portal no alcanza solo: React hace burbujear los eventos sintéticos según el árbol de
// React (quién envuelve a quién en el JSX), no según el árbol real del DOM. Un modal renderizado
// por portal sigue siendo, para React, un hijo del formulario que lo abrió — así que el submit de
// "Guardar" de ESTE modal seguía llegando también al onSubmit del formulario de afuera (por eso
// cerrar el subformulario de producto cerraba la factura entera). Cortamos esa propagación acá,
// en el único punto por el que pasan todos los modales de la app — así ningún formulario futuro
// que se abra dentro de otro va a heredar este mismo bug.
export function Modal({ title, onClose, children, widthClassName = 'max-w-[560px]' }: Props) {
  return createPortal(
    // Sin cierre por click afuera a propósito — un clic perdido durante la carga de un formulario
    // largo no debe tirar todo lo cargado. Solo cierran el botón ✕ y los botones explícitos del
    // formulario (Cancelar / Guardar).
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-ink/40 p-4"
      onSubmit={(e) => e.stopPropagation()}
    >
      <div className={`w-full ${widthClassName} max-h-[90vh] overflow-y-auto rounded-lg bg-surface p-card shadow-sm`}>
        <div className="flex items-center justify-between">
          <h2 className="font-display text-headline-md text-accent-darker">{title}</h2>
          <button
            type="button"
            onClick={onClose}
            aria-label="Cerrar"
            className="rounded p-1 font-sans text-body-lg text-ink-soft hover:bg-accent-light hover:text-accent-darker"
          >
            ✕
          </button>
        </div>
        <div className="mt-stack-md">{children}</div>
      </div>
    </div>,
    document.body,
  )
}
