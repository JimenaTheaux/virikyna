import { createContext, useContext, useEffect, useId, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { Minus } from 'lucide-react'
import { focoFueraDeDialogos, useFocoAtrapado } from '../../lib/useFocoAtrapado'
import { useCambiosSinGuardar } from '../../lib/cambiosSinGuardar'
import { useDocumento } from './documentos/contexto'

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
  // Bandeja de documentos (docs/73): solo tiene efecto si el modal se abrió como documento de la
  // bandeja (DocumentosAbiertos). Muestra "Minimizar" junto a la ✕ y reporta el chip.
  minimizable?: boolean
  // Texto del chip; sin esta prop, el título.
  etiquetaBandeja?: string
}

// ¿El elemento se ve y se puede enfocar? (dentro de un documento minimizado, no)
function enfocable(el: Element | null): el is HTMLElement {
  return el instanceof HTMLElement && el.isConnected && el.offsetParent !== null && getComputedStyle(el).visibility !== 'hidden'
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
  minimizable,
  etiquetaBandeja,
}: Props) {
  const tituloId = useId()
  const panelRef = useRef<HTMLDivElement>(null)
  const esFormulario = cambiosSinGuardar !== undefined
  // Bandeja (docs/73): adentro de un documento minimizado, este modal (y cualquier otro anidado)
  // queda montado pero invisible — conserva todo su estado, no recibe foco ni clics.
  const doc = useDocumento()
  const oculto = doc?.minimizado ?? false
  const esRaiz = Boolean(minimizable && doc)
  // false hasta que se mostró una vez: al volver de minimizado el foco se restaura, no se reinicia.
  const yaMostradoRef = useRef(false)
  // Último elemento con foco DENTRO de este panel (listener nativo: un diálogo anidado es otro
  // nodo del DOM y lleva su propia cuenta). Al restaurar vuelve ahí: "la misma fila seleccionada".
  const ultimoFocoRef = useRef<HTMLElement | null>(null)
  // Lo que tenía el foco en la página cuando se abrió: a dónde vuelve al minimizar.
  const focoPaginaRef = useRef<Element | null>(typeof document !== 'undefined' ? document.activeElement : null)

  useEffect(() => {
    const panel = panelRef.current
    if (!panel) return
    // El botón Minimizar no cuenta: al restaurar, el foco vuelve a donde se estaba trabajando.
    const alEnfocar = (e: FocusEvent) => {
      if (e.target instanceof HTMLElement && !e.target.hasAttribute('data-minimizar')) ultimoFocoRef.current = e.target
    }
    panel.addEventListener('focusin', alEnfocar)
    return () => panel.removeEventListener('focusin', alEnfocar)
  }, [])

  // Antes que useFocoAtrapado (los efectos corren en orden): al restaurar, el foco vuelve al campo
  // donde estaba, si nadie más lo tomó (un diálogo anidado restaurado corre antes, es hijo).
  useEffect(() => {
    if (oculto || !yaMostradoRef.current) return
    const guardado = ultimoFocoRef.current
    if (focoFueraDeDialogos() && guardado && panelRef.current?.contains(guardado) && enfocable(guardado)) {
      guardado.focus({ preventScroll: true })
    }
  }, [oculto])

  useFocoAtrapado(panelRef, oculto ? undefined : esFormulario ? null : dialogo?.onEscape, yaMostradoRef.current)

  useEffect(() => {
    if (!oculto) yaMostradoRef.current = true
  }, [oculto])

  // Al minimizar (solo el raíz, una vez): el foco vuelve a la página — a donde estaba al abrir, o
  // al chip del documento si eso ya no está (se navegó a otra pantalla).
  useEffect(() => {
    if (!oculto || !esRaiz) return
    const previo = focoPaginaRef.current
    if (enfocable(previo)) previo.focus({ preventScroll: true })
    else doc?.enfocarChip()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [oculto, esRaiz])

  const cierre = useCierreConBorrador(onClose, cambiosSinGuardar, cierreBorrador)
  // Atrás con cambios: el modal se queda donde está (cancelar) y se pide cerrar (onClose del
  // formulario = su "¿Cerrar sin guardar?", o el diálogo de borrador). Minimizado sale de la
  // pila: no se pierde nada al navegar, así que no frena (docs/73).
  useCambiosSinGuardar(!!cambiosSinGuardar && !oculto, ({ cancelar }) => {
    cancelar()
    cierre.pedirCierre()
  })
  const esDialogo = esFormulario || !!dialogo

  // El raíz le cuenta a la bandeja qué mostrar en el chip y cómo cerrarlo / guardarlo.
  const reportar = esRaiz ? doc?.reportar : undefined
  const etiqueta = etiquetaBandeja ?? title
  useEffect(() => {
    reportar?.({ etiqueta, cambios: !!cambiosSinGuardar })
  }, [reportar, etiqueta, cambiosSinGuardar])
  const pedirCierreRef = useRef(cierre.pedirCierre)
  pedirCierreRef.current = cierre.pedirCierre
  const guardarRef = useRef(cierreBorrador?.onGuardar)
  guardarRef.current = cierreBorrador?.onGuardar
  const registrarCierre = esRaiz ? doc?.registrarCierre : undefined
  const registrarGuardado = esRaiz ? doc?.registrarGuardado : undefined
  useEffect(() => {
    if (!registrarCierre) return
    registrarCierre(() => pedirCierreRef.current())
    return () => registrarCierre(null)
  }, [registrarCierre])
  const conBorrador = Boolean(cierreBorrador && cambiosSinGuardar)
  useEffect(() => {
    if (!registrarGuardado) return
    registrarGuardado(conBorrador ? () => guardarRef.current?.() : null)
    return () => registrarGuardado(null)
  }, [registrarGuardado, conBorrador])

  const botonCabecera =
    'rounded p-1 font-sans text-body-lg text-ink-soft hover:bg-accent-light hover:text-accent-darker focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent-dark'

  return createPortal(
    // Sin cierre por click afuera a propósito — un clic perdido durante la carga de una factura
    // (varios ítems, muchos campos) no debe tirar todo lo cargado. Un formulario solo se cierra con
    // el botón ✕ y los botones explícitos (Cancelar / Guardar); un detalle, también con Esc.
    // Minimizado: invisible (visibility, no display — así no pierde el scroll), sin clics, fuera
    // del árbol de accesibilidad.
    <div
      className={`fixed inset-0 z-50 flex items-center justify-center bg-ink/40 p-4 ${oculto ? 'pointer-events-none invisible' : ''}`}
      aria-hidden={oculto || undefined}
      onSubmit={(e) => e.stopPropagation()}
    >
      <div
        ref={panelRef}
        {...(esDialogo ? { role: 'dialog', 'aria-modal': true, 'aria-labelledby': tituloId } : {})}
        className={`flex w-full ${widthClassName} max-h-[90vh] flex-col rounded-lg bg-surface shadow-sm ${
          footer ? '' : 'overflow-y-auto p-card'
        }`}
      >
        <div className={`flex shrink-0 items-center justify-between gap-2 ${footer ? 'p-card pb-0' : ''}`}>
          <h2 id={tituloId} className="min-w-0 font-display text-headline-md text-accent-darker">
            {title}
          </h2>
          <div className="flex shrink-0 items-center gap-1">
            {esRaiz && (
              <button
                type="button"
                onClick={() => doc?.minimizar()}
                data-minimizar
                aria-label="Minimizar"
                title="Minimizar: queda arriba, en la barra, tal como está"
                className={`flex items-center ${botonCabecera}`}
              >
                <Minus size={20} strokeWidth={2} aria-hidden="true" />
              </button>
            )}
            <button type="button" onClick={cierre.pedirCierre} aria-label="Cerrar" className={botonCabecera}>
              ✕
            </button>
          </div>
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
