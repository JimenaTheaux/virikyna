import { useEffect, useId, useRef, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { formatCurrency } from '../../lib/format'
import type { ProductoParaPrecios } from '../../lib/useActualizarPrecios'
import { estadoFilaIva, OPCIONES_ACCION_IVA, textoAccionIva, useMarcarIva } from '../../lib/useMarcarIva'
import { Modal } from './Modal'
import { ConfirmDialog } from './ConfirmDialog'
import { ErrorText, inputClass } from './FormField'
import { EstadoBadge } from './EstadoBadge'
import { ControlSegmentado } from './ControlSegmentado'
import { ListaSeleccionProductos } from './ListaSeleccionProductos'

type Props = {
  supabase: SupabaseClient
  productos: ProductoParaPrecios[]
  seleccionInicial: string[]
  onClose: () => void
  onSaved: (cantidad: number) => void
}

const FOCO = 'focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-dark'
const inputAccesible = `${inputClass} focus:border-accent-dark focus:ring-1 focus:ring-accent-dark`

// Acción masiva "Lleva IVA" de escritorio (docs/47), compartida por Virikyna Local y Gestión. Solo la
// abre un admin (ProductosTab no muestra el botón a un cajero; el RPC igual lo valida). La lógica
// vive en useMarcarIva, la misma del sheet de Virikyna Inventario. Mismo esquema que Actualizar
// precios: datos arriba, "Ver vista previa" genera la tabla, y "Marcar…" pide confirmación con la
// cantidad antes de aplicar. Cualquier cambio descarta la vista previa.
export function MarcarIvaModal({ supabase, productos, seleccionInicial, onClose, onSaved }: Props) {
  const a = useMarcarIva({ supabase, productos, seleccionInicial, onSaved })
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

  return (
    <Modal
      title="IVA de productos"
      onClose={pedirCierre}
      cambiosSinGuardar={dirty}
      widthClassName="max-w-[820px]"
      footer={
        <div className="flex flex-col gap-stack-sm">
          {a.error && <ErrorText>{a.error}</ErrorText>}
          <div className="flex items-center justify-between gap-3">
            <button
              type="button"
              onClick={pedirCierre}
              className={`rounded px-4 py-3 font-sans text-label-bold text-ink-soft hover:bg-bg ${FOCO}`}
            >
              Cancelar
            </button>
            <button
              type="button"
              onClick={a.pedirConfirmacion}
              disabled={!vista || a.saving}
              aria-describedby={vista ? undefined : `${id}-sin-vista`}
              className={`rounded bg-accent-dark px-5 py-3 font-sans text-label-bold text-white transition hover:bg-accent-darker disabled:cursor-not-allowed disabled:opacity-50 ${FOCO}`}
            >
              {a.saving ? 'Aplicando...' : vista ? textoAccionIva(n, vista.llevaIva) : 'Aplicar'}
            </button>
          </div>
        </div>
      }
    >
      <form onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        <ControlSegmentado
          legend="Acción"
          opciones={OPCIONES_ACCION_IVA}
          value={a.accion}
          onChange={(v) => cambiar(() => a.setAccion(v))}
        />
        <p className="font-sans text-label-md text-ink-soft">
          Con IVA: costo × margen 1 × margen 2 × IVA 21%. Sin IVA: costo × margen 1 × margen 2. Un producto con
          precio manual no cambia de precio hasta que tenga costo cargado.
        </p>

        <ListaSeleccionProductos sel={a} onToggle={(pid) => cambiar(() => a.toggle(pid))} inputClassName={inputAccesible} />

        <button
          type="submit"
          className={`self-start rounded border border-accent-dark bg-surface px-4 py-2.5 font-sans text-label-bold text-accent-dark transition hover:bg-accent-light ${FOCO}`}
        >
          Ver vista previa
        </button>

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
              Generá la vista previa para ver cómo queda cada precio antes de aplicar.
            </p>
          )}
          {vista && (
            <div className="overflow-hidden rounded-xl shadow-sm">
              <table className="w-full table-fixed text-left font-sans text-table-row tabular-nums max-xl:[&_td]:px-2 max-xl:[&_th]:px-2">
                <caption className="sr-only">Precio de venta actual y nuevo por producto</caption>
                <colgroup>
                  <col />
                  <col className="w-[7.5rem]" />
                  <col className="w-[7.5rem]" />
                  <col className="w-[13rem]" />
                </colgroup>
                <thead>
                  <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
                    <th scope="col" className="px-3 py-2.5">Producto</th>
                    <th scope="col" className="px-3 py-2.5 text-right">Precio actual</th>
                    <th scope="col" className="px-3 py-2.5 text-right">Precio nuevo</th>
                    <th scope="col" className="px-3 py-2.5 text-right">Cambio</th>
                  </tr>
                </thead>
                <tbody>
                  {vista.filas.map((f) => {
                    const estado = estadoFilaIva(f)
                    return (
                      <tr key={f.id} className="border-b border-table-divider last:border-0 even:bg-table-row-alt">
                        <th scope="row" className="px-3 py-3 font-normal text-ink [overflow-wrap:anywhere]">
                          {f.nombre}
                        </th>
                        <td className="px-3 py-3 text-right text-ink">{formatCurrency(f.precioActual)}</td>
                        <td className="px-3 py-3 text-right font-semibold text-accent-darker">{formatCurrency(f.precioNuevo)}</td>
                        <td className="px-3 py-3 text-right">
                          {estado.sinCambio ? (
                            <EstadoBadge variant="neutral">{estado.texto}</EstadoBadge>
                          ) : (
                            <span className="font-semibold text-ink">{estado.texto}</span>
                          )}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
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
    </Modal>
  )
}
