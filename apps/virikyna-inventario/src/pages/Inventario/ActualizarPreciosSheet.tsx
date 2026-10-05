import { useEffect, useId, useRef, useState, type FormEvent } from 'react'
import type { Proveedor } from '@virikyna/shared'
import {
  BottomSheet,
  ControlSegmentado,
  ErrorText,
  EstadoBadge,
  formatAjuste,
  formatCurrency,
  MODOS_ACTUALIZAR_PRECIOS,
  MostrarMas,
  resumenVistaPreviaPrecios,
  useActualizarPrecios,
} from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { inputClass, selectClass } from '../../components/FormField'
import type { ProductoConRelaciones } from './types'

type Props = {
  productos: ProductoConRelaciones[]
  proveedores: Proveedor[]
  onClose: () => void
  onSaved: (cantidad: number) => void
}

// Foco visible con contraste AA (accent-dark); el borde `accent` de inputClass no llega a 3:1.
const FOCO = 'focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-dark'
const inputAccesible = `${inputClass} focus:border-accent-dark focus:ring-1 focus:ring-accent-dark`
const selectAccesible = `${selectClass} focus:border-accent-dark focus:ring-1 focus:ring-accent-dark`

// Misma lógica y mismo flujo que el modal de escritorio de Virikyna Local y Gestión
// (useActualizarPrecios + ActualizarPreciosModal, @virikyna/shared): una sola pantalla, la vista
// previa se genera abajo y recién ahí se habilita "Aplicar"; cualquier cambio la descarta. Acá la
// vista previa va en tarjetas (una tabla no entra en 360px) y las dos acciones viven en el pie fijo
// del sheet, al alcance del pulgar.
export function ActualizarPreciosSheet({ productos, proveedores, onClose, onSaved }: Props) {
  const a = useActualizarPrecios({ supabase, productos, onSaved })
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
    if (dirty) {
      setConfirmCerrar(true)
    } else {
      onClose()
    }
  }

  function cambiar(accion: () => void) {
    if (vista) a.volver()
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
      title="Actualizar precios"
      onClose={pedirCierre}
      dialogo={{ onEscape: pedirCierre }}
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
              onClick={a.aplicar}
              disabled={!vista || a.saving}
              aria-describedby={vista ? undefined : `${id}-sin-vista`}
              className={`min-h-12 rounded bg-accent-dark px-3 font-sans text-label-bold text-white transition active:bg-accent-darker disabled:opacity-50 ${FOCO}`}
            >
              {a.saving ? 'Aplicando...' : vista ? `Aplicar a ${n} producto${n === 1 ? '' : 's'}` : 'Aplicar'}
            </button>
          </div>
        </div>
      }
    >
      <form id={formId} onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        <div className="flex flex-col gap-2">
          <label htmlFor={`${id}-pct`} className="font-sans text-label-md text-ink">
            Porcentaje sobre el costo (%)
          </label>
          <input
            id={`${id}-pct`}
            type="number"
            inputMode="decimal"
            step="0.01"
            autoFocus
            value={a.porcentaje}
            onChange={(e) => cambiar(() => a.setPorcentaje(e.target.value))}
            aria-describedby={`${id}-pct-hint`}
            className={`${inputAccesible} tabular-nums`}
          />
          <p id={`${id}-pct-hint`} className="font-sans text-label-md text-ink-soft">
            Positivo para aumentar, negativo para bajar.
          </p>
        </div>

        <ControlSegmentado
          legend="Productos a actualizar"
          opciones={MODOS_ACTUALIZAR_PRECIOS}
          value={a.modo}
          onChange={(m) => cambiar(() => a.setModo(m))}
          size="touch"
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
            <label htmlFor={`${id}-buscar`} className="font-sans text-label-md text-ink">
              Buscar producto
            </label>
            <input
              id={`${id}-buscar`}
              type="search"
              value={a.busqueda}
              onChange={(e) => a.buscar(e.target.value)}
              placeholder="Nombre, marca, código o proveedor"
              className={inputAccesible}
            />
            <p aria-live="polite" className="font-sans text-label-bold text-ink">
              {a.seleccion.size} seleccionado{a.seleccion.size === 1 ? '' : 's'}
            </p>
            <ul className="overflow-hidden rounded-lg border border-line bg-surface" aria-label="Productos">
              {a.productosVisibles.map((p) => (
                <li key={p.id} className="flex items-center gap-3 border-b border-line px-3 last:border-0">
                  <input
                    id={`${id}-chk-${p.id}`}
                    type="checkbox"
                    checked={a.seleccion.has(p.id)}
                    onChange={() => cambiar(() => a.toggle(p.id))}
                    aria-labelledby={`${id}-nom-${p.id}`}
                    aria-describedby={`${id}-prv-${p.id}`}
                    className={`h-5 w-5 flex-shrink-0 accent-accent-dark ${FOCO}`}
                  />
                  {/* Toda la fila (48px) es tocable; el nombre accesible es solo el del producto. */}
                  <label
                    htmlFor={`${id}-chk-${p.id}`}
                    className="flex min-h-12 flex-1 cursor-pointer flex-col justify-center py-2 active:bg-bg"
                  >
                    <span id={`${id}-nom-${p.id}`} className="font-sans text-body-md text-ink [overflow-wrap:anywhere]">
                      {p.nombre}
                    </span>
                    <span id={`${id}-prv-${p.id}`} className="font-sans text-label-md text-ink-soft">
                      {p.proveedor?.razon_social ?? 'Sin proveedor'}
                    </span>
                  </label>
                </li>
              ))}
              {a.sinResultados && (
                <li className="px-3 py-4 text-center font-sans text-body-md text-ink-soft">Sin resultados.</li>
              )}
            </ul>
            <MostrarMas restantes={a.restantes} onClick={a.verMas} size="touch" />
          </div>
        )}

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
              Tocá “Ver vista previa” para ver cómo queda cada precio antes de aplicar.
            </p>
          )}

          {vista && (
            <>
              <ul className="flex flex-col gap-2" aria-label="Precio actual y nuevo por producto">
                {a.filasVisibles.map((f) => {
                  const diferencia = f.precioNuevo - f.precioActual
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
                      <p className="mt-1 flex flex-wrap items-center justify-between gap-x-3 gap-y-1 text-label-md tabular-nums">
                        {diferencia > 0 ? (
                          <span className="font-semibold text-accent-dark">
                            <span className="sr-only">Diferencia </span>
                            {formatAjuste(diferencia)}
                          </span>
                        ) : diferencia === 0 ? (
                          <EstadoBadge variant="neutral">Sin cambio</EstadoBadge>
                        ) : (
                          <span className="text-ink">
                            <span className="sr-only">Diferencia </span>
                            {formatAjuste(diferencia)}
                          </span>
                        )}
                        <span className="text-ink-soft">
                          {f.ajuste === 0 ? 'Sin redondeo' : `Redondeo ${formatAjuste(f.ajuste)}`}
                        </span>
                      </p>
                      <p className="mt-1 text-label-md text-ink-soft tabular-nums">
                        Costo {formatCurrency(f.costoActual)} → {formatCurrency(f.costoNuevo)}
                      </p>
                    </li>
                  )
                })}
              </ul>
              <MostrarMas restantes={a.filasRestantes} onClick={a.verMasFilas} size="touch" />
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
    </BottomSheet>
  )
}
