import { useEffect, useId, useRef, useState, type FormEvent } from 'react'
import {
  BottomSheet,
  ControlSegmentado,
  ErrorText,
  EstadoBadge,
  estadoFilaIva,
  formatCurrency,
  ListaSeleccionProductos,
  OPCIONES_ACCION_IVA,
  textoAccionIva,
  useMarcarIva,
} from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { inputClass } from '../../components/FormField'
import type { ProductoConRelaciones } from './types'

type Props = {
  productos: ProductoConRelaciones[]
  onClose: () => void
  onSaved: (cantidad: number) => void
}

const FOCO = 'focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-dark'
const inputAccesible = `${inputClass} focus:border-accent-dark focus:ring-1 focus:ring-accent-dark`

// "Lleva IVA" masivo en el celular (docs/47), solo admin (InventarioPage no lo ofrece a un cajero;
// el RPC igual lo valida). Misma lógica que el modal de escritorio (useMarcarIva + MarcarIvaModal)
// y mismo flujo que ActualizarPreciosSheet: elegir, ver la vista previa en tarjetas y confirmar.
export function MarcarIvaSheet({ productos, onClose, onSaved }: Props) {
  const a = useMarcarIva({ supabase, productos, onSaved })
  const [dirty, setDirty] = useState(false)
  const [confirmCerrar, setConfirmCerrar] = useState(false)
  const vista = a.vistaPrevia
  const id = useId()
  const tituloVistaRef = useRef<HTMLHeadingElement>(null)

  useEffect(() => {
    if (!vista) return
    tituloVistaRef.current?.focus()
    tituloVistaRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }, [vista])

  function pedirCierre() {
    if (dirty) setConfirmCerrar(true)
    else onClose()
  }

  // Descarta la vista previa y el error anterior (ej. "Tildá al menos un producto" ya tildados).
  function cambiar(accion: () => void) {
    setDirty(true)
    a.volver()
    accion()
  }

  function handleSubmit(e: FormEvent) {
    e.preventDefault()
    a.verVistaPrevia()
  }

  const n = vista?.filas.length ?? 0
  const formId = `${id}-form`

  return (
    <BottomSheet
      title="IVA de productos"
      onClose={pedirCierre}
      cambiosSinGuardar={dirty}
      footer={
        <div className="flex flex-col gap-2">
          {a.error && <ErrorText>{a.error}</ErrorText>}
          <div className="grid grid-cols-2 gap-3">
            <button
              type="submit"
              form={formId}
              className={`min-h-12 rounded border border-accent-dark bg-surface px-3 font-sans text-label-bold text-accent-dark active:bg-accent-light ${FOCO}`}
            >
              Ver vista previa
            </button>
            <button
              type="button"
              onClick={a.pedirConfirmacion}
              disabled={!vista || a.saving}
              aria-describedby={vista ? undefined : `${id}-sin-vista`}
              className={`min-h-12 rounded bg-accent-dark px-3 font-sans text-label-bold text-white transition active:bg-accent-darker disabled:opacity-50 ${FOCO}`}
            >
              {a.saving ? 'Aplicando...' : vista ? textoAccionIva(n, vista.llevaIva) : 'Aplicar'}
            </button>
          </div>
        </div>
      }
    >
      <form id={formId} onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        <ControlSegmentado
          legend="Acción"
          opciones={OPCIONES_ACCION_IVA}
          value={a.accion}
          onChange={(v) => cambiar(() => a.setAccion(v))}
          size="touch"
        />
        <p className="font-sans text-label-md text-ink-soft">
          Un producto con precio manual no cambia de precio hasta que tenga costo cargado.
        </p>

        <ListaSeleccionProductos
          sel={a}
          onToggle={(pid) => cambiar(() => a.toggle(pid))}
          inputClassName={inputAccesible}
          size="touch"
        />

        <section aria-labelledby={`${id}-vp`} className="flex flex-col gap-2 border-t border-line pt-stack-md">
          <h3 id={`${id}-vp`} ref={tituloVistaRef} tabIndex={-1} className="scroll-mt-4 font-sans text-label-bold text-ink outline-none">
            Vista previa
          </h3>
          <p role="status" aria-live="polite" className="font-sans text-body-md text-ink">
            {vista
              ? `${n} producto${n === 1 ? '' : 's'}: ${vista.cambian} cambia${vista.cambian === 1 ? '' : 'n'} a ${
                  vista.llevaIva ? 'con' : 'sin'
                } IVA.`
              : ''}
          </p>
          {!vista && (
            <p id={`${id}-sin-vista`} className="font-sans text-label-md text-ink-soft">
              Tocá “Ver vista previa” para ver cómo queda cada precio antes de aplicar.
            </p>
          )}
          {vista && (
            <ul className="flex flex-col gap-2" aria-label="Precio actual y nuevo por producto">
              {vista.filas.map((f) => {
                const estado = estadoFilaIva(f)
                return (
                  <li key={f.id} className="rounded-lg border border-line bg-surface p-4 font-sans">
                    <p className="text-body-md text-ink [overflow-wrap:anywhere]">{f.nombre}</p>
                    <p className="mt-1 flex items-baseline justify-between gap-2 tabular-nums">
                      <span className="text-label-md text-ink-soft">
                        <span className="sr-only">Precio actual </span>
                        {formatCurrency(f.precioActual)} <span aria-hidden="true">→</span>
                      </span>
                      <span className="font-display text-headline-md text-accent-darker">
                        <span className="sr-only">Precio nuevo </span>
                        {formatCurrency(f.precioNuevo)}
                      </span>
                    </p>
                    <p className="mt-1 text-label-md">
                      {estado.sinCambio ? (
                        <EstadoBadge variant="neutral">{estado.texto}</EstadoBadge>
                      ) : (
                        <span className="font-semibold text-ink">{estado.texto}</span>
                      )}
                    </p>
                  </li>
                )
              })}
            </ul>
          )}
        </section>
      </form>

      {a.confirmando && vista && (
        <ConfirmDialog
          title={textoAccionIva(n, vista.llevaIva)}
          mensaje={`Se ${vista.llevaIva ? 'agrega' : 'saca'} el IVA a ${vista.cambian} de ${n} producto${
            n === 1 ? '' : 's'
          } (los demás ya estaban así). Los de precio manual no cambian de precio.`}
          confirmLabel="Confirmar"
          onCancel={a.cancelarConfirmacion}
          onConfirm={a.aplicar}
        />
      )}

      {confirmCerrar && (
        <ConfirmDialog
          title="Cerrar sin guardar"
          mensaje="Hay cambios sin guardar en este formulario. ¿Querés cerrar de todos modos?"
          confirmLabel="Cerrar sin guardar"
          onCancel={() => setConfirmCerrar(false)}
          onConfirm={onClose}
        />
      )}
    </BottomSheet>
  )
}
