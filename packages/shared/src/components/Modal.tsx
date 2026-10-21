import { createContext, useContext, useId, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { useFocoAtrapado } from '../../lib/useFocoAtrapado'
import { useCambiosSinGuardar } from '../../lib/cambiosSinGuardar'

// Cierre con borrador (docs/54): con esta prop, cerrar un formulario con cambios (✕, Atrás,
// BotonCerrarModal) no lo pregunta el formulario sino Modal/BottomSheet, siempre con el mismo
// diálogo: "Guardar borrador" / "Descartar" / "Seguir editando". Sin la prop, como siempre.
export type CierreBorrador = {
  onGuardar: () => Promise<unknown> | void
  onDescartar: () => Promise<unknown> | void
  // Borrador retomado de la lista: "Descartar" lo elimina entero, el texto lo aclara.
  retomado?: boolean
}

const PedirCierreContext = createContext<(() => void) | null>(null)

// Lo usan Modal y BottomSheet: pregunta solo con cambios y cierreBorrador; si no, cierra directo.
export function useCierreConBorrador(onClose: () => void, cambiosSinGuardar: boolean | undefined, cierre?: CierreBorrador) {
  const [preguntando, setPreguntando] = useState(false)
  const pedirCierre = () => {
    if (cierre && cambiosSinGuardar) setPreguntando(true)
    else onClose()
  }
  const dialogo =
    preguntando && cierre ? (
      <DialogoCierreBorrador
        retomado={cierre.retomado}
        onSeguir={() => setPreguntando(false)}
        onDescartar={async () => {
          await cierre.onDescartar()
          setPreguntando(false)
          onClose()
        }}
        onGuardar={async () => {
          await cierre.onGuardar()
          setPreguntando(false)
          onClose()
        }}
      />
    ) : null
  return { pedirCierre, dialogo }
}

// "Cancelar" del pie de un formulario con cierreBorrador: pasa por el mismo diálogo que la ✕.
export function BotonCerrarModal({ children, className }: { children: ReactNode; className?: string }) {
  const pedirCierre = useContext(PedirCierreContext)
  return (
    <button type="button" onClick={() => pedirCierre?.()} className={className}>
      {children}
    </button>
  )
}

export { PedirCierreContext }

type DialogoCierreProps = {
  retomado?: boolean
  onSeguir: () => void
  onDescartar: () => Promise<void>
  onGuardar: () => Promise<void>
}

// Diálogo de cierre de un formulario con borrador. Mismo criterio que ConfirmDialog: el foco y
// Esc van a "Seguir editando" (nunca descarta), la acción destructiva en rojo y a la izquierda,
// separada de las otras dos. En pantallas angostas los botones se apilan (táctil ≥ 44 px).
export function DialogoCierreBorrador({ retomado, onSeguir, onDescartar, onGuardar }: DialogoCierreProps) {
  const [ocupado, setOcupado] = useState<'guardar' | 'descartar' | null>(null)
  const correr = (accion: 'guardar' | 'descartar', fn: () => Promise<void>) => async () => {
    setOcupado(accion)
    try {
      await fn()
    } finally {
      setOcupado(null)
    }
  }
  return (
    <Modal title="¿Cerrar el formulario?" onClose={onSeguir} widthClassName="max-w-[480px]" dialogo={{ onEscape: onSeguir }}>
      <div className="flex flex-col gap-stack-md">
        <p className="font-sans text-body-md text-ink">
          {retomado
            ? 'Los cambios se guardan en el borrador para seguir después. Descartar elimina el borrador entero.'
            : 'Lo cargado se puede guardar como borrador para seguir después, o descartar. Un borrador no mueve stock, saldos ni caja.'}
        </p>
        <div className="flex flex-col-reverse gap-2 sm:flex-row sm:items-center">
          <button
            type="button"
            onClick={correr('descartar', onDescartar)}
            disabled={ocupado !== null}
            className="min-h-11 rounded border border-error px-4 py-2.5 font-sans text-label-bold text-error transition hover:bg-error hover:text-white disabled:opacity-60"
          >
            {ocupado === 'descartar' ? 'Descartando...' : retomado ? 'Eliminar borrador' : 'Descartar'}
          </button>
          <span className="hidden flex-1 sm:block" />
          <button
            type="button"
            data-autofocus
            onClick={onSeguir}
            disabled={ocupado !== null}
            className="min-h-11 rounded px-4 py-2.5 font-sans text-label-bold text-ink-soft hover:bg-bg disabled:opacity-60"
          >
            Seguir editando
          </button>
          <button
            type="button"
            onClick={correr('guardar', onGuardar)}
            disabled={ocupado !== null}
            className="min-h-11 rounded bg-accent-dark px-4 py-2.5 font-sans text-label-bold text-white transition hover:bg-accent-darker disabled:opacity-60"
          >
            {ocupado === 'guardar' ? 'Guardando...' : 'Guardar borrador'}
          </button>
        </div>
      </div>
    </Modal>
  )
}

type Props = {
  title: string
  onClose: () => void
  children: ReactNode
  widthClassName?: string
  // Pie fijo (fuera del área con scroll) — para formularios largos donde los botones de acción
  // deben quedar siempre accesibles sin scrollear (ej. carga de factura de compra tipo planilla).
  footer?: ReactNode
  // Modales de solo lectura (detalles) y confirmaciones: role="dialog" + aria-modal +
  // aria-labelledby, Esc → onEscape y foco atrapado (useFocoAtrapado).
  dialogo?: { onEscape: () => void }
  // Formularios (docs/auditoria-2026-10-19.md, B.2/B.3): pasar siempre, con su estado `dirty`. Con
  // esta prop el modal es diálogo accesible pero Esc NO cierra (solo ✕ / Cancelar, que ya piden
  // confirmación si hay cambios), y mientras sea true queda anotado como "cambios sin guardar":
  // Atrás / cambio de ruta llaman a onClose en vez de desmontarlo (GuardiaNavegacion) y la
  // actualización de Local pregunta antes de reiniciar.
  cambiosSinGuardar?: boolean
  // Borradores (docs/54): ver CierreBorrador arriba.
  cierreBorrador?: CierreBorrador
}

// Modal centrado de escritorio — lo usan virikyna-local y virikyna-gestion (que lo re-exportan desde
// su propio components/Modal.tsx); virikyna-inventario (celular) usa BottomSheet en su lugar.
// Vive en shared porque los componentes compartidos de escritorio (ej. CargarFacturaCompraModal)
// lo necesitan y las dos apps tenían una copia idéntica.
//
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
export function Modal({
  title,
  onClose,
  children,
  widthClassName = 'max-w-[560px]',
  footer,
  dialogo,
  cambiosSinGuardar,
  cierreBorrador,
}: Props) {
  const tituloId = useId()
  const panelRef = useRef<HTMLDivElement>(null)
  const esFormulario = cambiosSinGuardar !== undefined
  useFocoAtrapado(panelRef, esFormulario ? null : dialogo?.onEscape)
  const cierre = useCierreConBorrador(onClose, cambiosSinGuardar, cierreBorrador)
  // Atrás con cambios: el modal se queda donde está (cancelar) y se pide cerrar (onClose del
  // formulario = su "¿Cerrar sin guardar?", o el diálogo de borrador).
  useCambiosSinGuardar(!!cambiosSinGuardar, ({ cancelar }) => {
    cancelar()
    cierre.pedirCierre()
  })
  const esDialogo = esFormulario || !!dialogo

  return createPortal(
    // Sin cierre por click afuera a propósito — un clic perdido durante la carga de una factura
    // (varios ítems, muchos campos) no debe tirar todo lo cargado. Un formulario solo se cierra con
    // el botón ✕ y los botones explícitos (Cancelar / Guardar); un detalle, también con Esc.
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-ink/40 p-4"
      onSubmit={(e) => e.stopPropagation()}
    >
      <div
        ref={panelRef}
        {...(esDialogo ? { role: 'dialog', 'aria-modal': true, 'aria-labelledby': tituloId } : {})}
        className={`flex w-full ${widthClassName} max-h-[90vh] flex-col rounded-lg bg-surface shadow-sm ${
          footer ? '' : 'overflow-y-auto p-card'
        }`}
      >
        <div className={`flex shrink-0 items-center justify-between ${footer ? 'p-card pb-0' : ''}`}>
          <h2 id={tituloId} className="font-display text-headline-md text-accent-darker">
            {title}
          </h2>
          <button
            type="button"
            onClick={cierre.pedirCierre}
            aria-label="Cerrar"
            className="rounded p-1 font-sans text-body-lg text-ink-soft hover:bg-accent-light hover:text-accent-darker"
          >
            ✕
          </button>
        </div>
        {/* Sin footer: mismo layout de siempre (todo scrollea junto). Con footer: esta zona es la
            única que scrollea y el footer queda fijo abajo — para formularios largos donde las
            acciones (Cancelar/Guardar) no deben requerir scroll para ser alcanzadas. */}
        <PedirCierreContext.Provider value={cierre.pedirCierre}>
          <div className={footer ? 'min-h-0 flex-1 overflow-y-auto p-card pt-stack-md' : 'mt-stack-md'}>{children}</div>
          {footer && <div className="shrink-0 border-t border-line p-card pt-4">{footer}</div>}
        </PedirCierreContext.Provider>
      </div>
      {cierre.dialogo}
    </div>,
    document.body,
  )
}
