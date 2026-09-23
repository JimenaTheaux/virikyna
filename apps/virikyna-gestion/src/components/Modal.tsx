import type { ReactNode } from 'react'
import { createPortal } from 'react-dom'

type Props = {
  title: string
  onClose: () => void
  children: ReactNode
  widthClassName?: string
  // Pie fijo (fuera del área con scroll) — para formularios largos donde los botones de acción
  // deben quedar siempre accesibles sin scrollear (ej. carga de factura de compra tipo planilla).
  footer?: ReactNode
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
export function Modal({ title, onClose, children, widthClassName = 'max-w-[560px]', footer }: Props) {
  return createPortal(
    // Sin cierre por click afuera a propósito — un clic perdido durante la carga de una factura
    // (varios ítems, muchos campos) no debe tirar todo lo cargado. Solo cierran el botón ✕ y los
    // botones explícitos del formulario (Cancelar / Guardar).
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-ink/40 p-4"
      onSubmit={(e) => e.stopPropagation()}
    >
      <div
        className={`flex w-full ${widthClassName} max-h-[90vh] flex-col rounded-lg bg-surface shadow-sm ${
          footer ? '' : 'overflow-y-auto p-card'
        }`}
      >
        <div className={`flex shrink-0 items-center justify-between ${footer ? 'p-card pb-0' : ''}`}>
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
        {/* Sin footer: mismo layout de siempre (todo scrollea junto). Con footer: esta zona es la
            única que scrollea y el footer queda fijo abajo — para formularios largos donde las
            acciones (Cancelar/Guardar) no deben requerir scroll para ser alcanzadas. */}
        <div className={footer ? 'min-h-0 flex-1 overflow-y-auto p-card pt-stack-md' : 'mt-stack-md'}>{children}</div>
        {footer && <div className="shrink-0 border-t border-line p-card pt-4">{footer}</div>}
      </div>
    </div>,
    document.body,
  )
}
