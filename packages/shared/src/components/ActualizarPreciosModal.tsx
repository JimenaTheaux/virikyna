import { useEffect, useId, useRef, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Proveedor } from '../../types/database'
import { formatAjuste, formatCurrency, resumenVistaPreviaPrecios } from '../../lib/format'
import {
  useActualizarPrecios,
  type ModoActualizarPrecios,
  type ProductoParaPrecios,
} from '../../lib/useActualizarPrecios'
import { Modal } from './Modal'
import { ConfirmDialog } from './ConfirmDialog'
import { ErrorText, inputClass, selectClass } from './FormField'
import { MostrarMas } from './MostrarMas'
import { EstadoBadge } from './EstadoBadge'
import { ControlSegmentado } from './ControlSegmentado'

export type { ProductoParaPrecios } from '../../lib/useActualizarPrecios'

type Props = {
  supabase: SupabaseClient
  productos: ProductoParaPrecios[]
  proveedores: Proveedor[]
  seleccionInicial: string[]
  onClose: () => void
  onSaved: (cantidad: number) => void
}

export const MODOS_ACTUALIZAR_PRECIOS: { value: ModoActualizarPrecios; label: string }[] = [
  { value: 'proveedor', label: 'Por proveedor' },
  { value: 'seleccion', label: 'Selección manual' },
]

// Foco visible con contraste AA (accent-dark, 5,2:1 sobre blanco). El borde `accent` de inputClass
// queda en 2,4:1, por debajo del 3:1 que pide AA para indicadores de foco.
const FOCO = 'focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-dark'
const inputAccesible = `${inputClass} focus:border-accent-dark focus:ring-1 focus:ring-accent-dark`
const selectAccesible = `${selectClass} focus:border-accent-dark focus:ring-1 focus:ring-accent-dark`

// Actualización masiva de precios de escritorio, compartida por Virikyna Local y Virikyna Gestión
// (docs/04_modulos_y_funciones.md, módulo 5). La lógica (validación, vista previa, RPC) vive en
// useActualizarPrecios, la misma que usa el sheet de Virikyna Inventario; acá solo el markup.
//
// Una sola pantalla: porcentaje y productos arriba, "Ver vista previa" genera la tabla abajo (estilo
// "G", docs/08 sección 5.2) y recién ahí se habilita "Aplicar a N productos". Cualquier cambio en
// los datos descarta la vista previa, así nunca se aplica una vista previa vieja.
//
// Botón primario en accent-dark y no accent: blanco sobre accent da 2,4:1 (no cumple AA).
export function ActualizarPreciosModal({ supabase, productos, proveedores, seleccionInicial, onClose, onSaved }: Props) {
  const a = useActualizarPrecios({ supabase, productos, seleccionInicial, onSaved })
  const [dirty, setDirty] = useState(false)
  const [confirmCerrar, setConfirmCerrar] = useState(false)
  const vista = a.vistaPrevia
  const id = useId()
  const tituloVistaRef = useRef<HTMLHeadingElement>(null)

  // Al generar la vista previa, el foco pasa a su título (el resumen además se anuncia por aria-live).
  useEffect(() => {
    if (!vista) return
    tituloVistaRef.current?.focus()
    tituloVistaRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }, [vista])

  function pedirCierre() {
    if (dirty) {
      setConfirmCerrar(true)
    } else {
      onClose()
    }
  }

  // Todo cambio en los datos invalida la vista previa (y deshabilita "Aplicar").
  function cambiar(accion: () => void) {
    if (vista) a.volver()
    accion()
  }

  function handleSubmit(e: FormEvent) {
    e.preventDefault()
    a.verVistaPrevia()
  }

  const n = vista?.filas.length ?? 0

  return (
    <Modal
      title="Actualizar precios"
      onClose={pedirCierre}
      dialogo={{ onEscape: pedirCierre }}
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
              onClick={a.aplicar}
              disabled={!vista || a.saving}
              aria-describedby={vista ? undefined : `${id}-sin-vista`}
              className={`rounded bg-accent-dark px-5 py-3 font-sans text-label-bold text-white transition hover:bg-accent-darker disabled:cursor-not-allowed disabled:opacity-50 ${FOCO}`}
            >
              {a.saving ? 'Aplicando...' : vista ? `Aplicar a ${n} producto${n === 1 ? '' : 's'}` : 'Aplicar'}
            </button>
          </div>
        </div>
      }
    >
      <form
        id="form-actualizar-precios"
        onSubmit={handleSubmit}
        onChangeCapture={() => setDirty(true)}
        className="flex flex-col gap-stack-md"
      >
        <div className="flex flex-col gap-2">
          <label htmlFor={`${id}-pct`} className="font-sans text-label-md text-ink">
            Porcentaje sobre el costo (%)
          </label>
          <input
            id={`${id}-pct`}
            type="number"
            step="0.01"
            autoFocus
            value={a.porcentaje}
            onChange={(e) => cambiar(() => a.setPorcentaje(e.target.value))}
            aria-describedby={`${id}-pct-hint`}
            className={`${inputAccesible} max-w-[240px] tabular-nums`}
          />
          <p id={`${id}-pct-hint`} className="font-sans text-label-md text-ink-soft">
            Positivo para aumentar, negativo para bajar. Enter genera la vista previa.
          </p>
        </div>

        <ControlSegmentado
          legend="Productos a actualizar"
          opciones={MODOS_ACTUALIZAR_PRECIOS}
          value={a.modo}
          onChange={(m) => cambiar(() => a.setModo(m))}
        />

        {a.modo === 'proveedor' && (
          <div className="flex flex-col gap-2">
            <label htmlFor={`${id}-prov`} className="font-sans text-label-md text-ink">
              Proveedor
            </label>
            <select
              id={`${id}-prov`}
              value={a.proveedorId}
              onChange={(e) => cambiar(() => a.setProveedorId(e.target.value))}
              className={selectAccesible}
            >
              <option value="">Elegí un proveedor...</option>
              {proveedores.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.razon_social}
                </option>
              ))}
            </select>
          </div>
        )}

        {a.modo === 'seleccion' && (
          <div className="flex flex-col gap-2">
            <div className="flex items-end justify-between gap-3">
              <div className="flex flex-col gap-2">
                <label htmlFor={`${id}-buscar`} className="font-sans text-label-md text-ink">
                  Buscar producto
                </label>
                <input
                  id={`${id}-buscar`}
                  type="search"
                  value={a.busqueda}
                  onChange={(e) => a.buscar(e.target.value)}
                  placeholder="Nombre, marca, código o proveedor"
                  className={`${inputAccesible} w-72 py-2`}
                />
              </div>
              <p aria-live="polite" className="pb-2 font-sans text-label-bold text-ink">
                {a.seleccion.size} seleccionado{a.seleccion.size === 1 ? '' : 's'}
              </p>
            </div>
            <ul className="overflow-hidden rounded-xl font-sans text-table-row shadow-sm" aria-label="Productos">
              {a.productosVisibles.map((p) => (
                <li
                  key={p.id}
                  className="flex items-center gap-3 border-b border-table-divider px-3 last:border-0 even:bg-table-row-alt"
                >
                  <input
                    id={`${id}-chk-${p.id}`}
                    type="checkbox"
                    checked={a.seleccion.has(p.id)}
                    onChange={() => cambiar(() => a.toggle(p.id))}
                    aria-labelledby={`${id}-nom-${p.id}`}
                    aria-describedby={`${id}-prv-${p.id}`}
                    className={`h-4 w-4 flex-shrink-0 accent-accent-dark ${FOCO}`}
                  />
                  {/* Toda la fila es clickeable; el nombre accesible es solo el del producto. */}
                  <label htmlFor={`${id}-chk-${p.id}`} className="flex flex-1 cursor-pointer items-center gap-3 py-3">
                    <span id={`${id}-nom-${p.id}`} className="text-ink [overflow-wrap:anywhere]">
                      {p.nombre}
                    </span>
                    <span id={`${id}-prv-${p.id}`} className="ml-auto text-ink-soft">
                      {p.proveedor?.razon_social ?? 'Sin proveedor'}
                    </span>
                  </label>
                </li>
              ))}
              {a.sinResultados && <li className="px-3 py-4 text-center text-ink-soft">Sin resultados.</li>}
            </ul>
            <MostrarMas restantes={a.restantes} onClick={a.verMas} />
          </div>
        )}

        <button
          type="submit"
          className={`self-start rounded border border-accent-dark bg-surface px-4 py-2.5 font-sans text-label-bold text-accent-dark transition hover:bg-accent-light ${FOCO}`}
        >
          Ver vista previa
        </button>

        <section aria-labelledby={`${id}-vp`} className="flex flex-col gap-2 border-t border-line pt-stack-md">
          <h3
            id={`${id}-vp`}
            ref={tituloVistaRef}
            tabIndex={-1}
            className="scroll-mt-4 font-sans text-label-bold text-ink outline-none"
          >
            Vista previa
          </h3>
          <p role="status" aria-live="polite" className="font-sans text-body-md text-ink">
            {vista ? resumenVistaPreviaPrecios(n, vista.sinCambio, vista.porcentaje) : ''}
          </p>
          {!vista && (
            <p id={`${id}-sin-vista`} className="font-sans text-label-md text-ink-soft">
              Generá la vista previa para ver cómo queda cada precio antes de aplicar.
            </p>
          )}

          {vista && (
            <>
              <div className="overflow-hidden rounded-xl shadow-sm">
                <table className="w-full table-fixed text-left font-sans text-table-row tabular-nums max-xl:[&_td]:px-2 max-xl:[&_th]:px-2">
                  <caption className="sr-only">Precio de venta actual y nuevo por producto</caption>
                  <colgroup>
                    <col />
                    <col className="w-[7.5rem]" />
                    <col className="w-[7.5rem]" />
                    <col className="w-[7.5rem]" />
                    <col className="w-[6.5rem]" />
                  </colgroup>
                  <thead>
                    <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
                      <th scope="col" className="px-3 py-2.5">
                        Producto
                      </th>
                      <th scope="col" className="px-3 py-2.5 text-right">
                        Precio actual
                      </th>
                      <th scope="col" className="px-3 py-2.5 text-right">
                        Precio nuevo
                      </th>
                      <th scope="col" className="px-3 py-2.5 text-right">
                        Diferencia
                      </th>
                      <th scope="col" className="px-3 py-2.5 text-right">
                        Redondeo
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {a.filasVisibles.map((f) => {
                      const diferencia = f.precioNuevo - f.precioActual
                      return (
                        <tr key={f.id} className="border-b border-table-divider last:border-0 even:bg-table-row-alt">
                          <th scope="row" className="px-3 py-3 font-normal [overflow-wrap:anywhere]">
                            <span className="text-ink">{f.nombre}</span>
                            <span className="block text-ink-soft">
                              Costo {formatCurrency(f.costoActual)} → {formatCurrency(f.costoNuevo)}
                            </span>
                          </th>
                          <td className="px-3 py-3 text-right text-ink">{formatCurrency(f.precioActual)}</td>
                          <td className="px-3 py-3 text-right font-semibold text-accent-darker">
                            {formatCurrency(f.precioNuevo)}
                          </td>
                          <td className="px-3 py-3 text-right">
                            {diferencia > 0 ? (
                              <span className="font-semibold text-accent-dark">{formatAjuste(diferencia)}</span>
                            ) : diferencia === 0 ? (
                              <EstadoBadge variant="neutral">Sin cambio</EstadoBadge>
                            ) : (
                              <span className="text-ink">{formatAjuste(diferencia)}</span>
                            )}
                          </td>
                          <td className="px-3 py-3 text-right text-ink-soft">
                            {f.ajuste === 0 ? (
                              <>
                                <span aria-hidden="true">—</span>
                                <span className="sr-only">Sin redondeo</span>
                              </>
                            ) : (
                              formatAjuste(f.ajuste)
                            )}
                          </td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>
              <MostrarMas restantes={a.filasRestantes} onClick={a.verMasFilas} />
            </>
          )}
        </section>
      </form>

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
