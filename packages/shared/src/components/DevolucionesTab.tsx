import { useEffect, useState, type ComponentType } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { Ban, Eye } from 'lucide-react'
import {
  MOTIVO_DEVOLUCION_LABEL,
  RESOLUCION_DEVOLUCION_LABEL,
  anularDevolucion,
  diferenciaQueMueveDinero,
} from '../../lib/devoluciones'
import type { DatosComprobante } from '../../lib/comprobante'
import { fechaHoyISO, fechaISO, formatCurrency, formatFechaCortaLocal, formatHora } from '../../lib/format'
import { friendlyError } from '../../lib/supabaseErrors'
import { nombresPorId } from '../../lib/perfiles'
import { EstadoBadge } from './EstadoBadge'
import { RowActionsMenu } from './RowActionsMenu'
import { Modal } from './Modal'
import { ConfirmDialog } from './ConfirmDialog'
import { ErrorText, Field, inputClass } from './FormField'
import {
  DevolucionDetalleModal,
  SELECT_DEVOLUCION_DETALLE,
  numerosDeTickets,
  ordenarTickets,
  sentidoDiferencia,
  type DevolucionConDetalle,
} from './DevolucionDetalleModal'

type DevolucionFila = DevolucionConDetalle

export interface DevolucionesTabProps {
  supabase: SupabaseClient
  // Anular solo lo ofrece la UI a un admin; el RPC lo vuelve a validar.
  esAdmin: boolean
  // Aviso de "anulada" — Local lo manda a su toast. Sin callback (Gestión no tiene toast) se
  // muestra como banner arriba de la tabla.
  onAviso?: (mensaje: string) => void
  // "Ver ticket" en el detalle (docs/74): cada app enchufa su ComprobanteModal.
  ComprobanteModal?: ComponentType<{ datos: DatosComprobante; onClose: () => void }>
}

// Listado de devoluciones/cambios del período — fila compacta con lo esencial; el detalle completo
// (ítems, observaciones, forma de pago de la diferencia) va en "Ver detalle". Anulación solo admin.
// Compartido por Local y Gestión; registrar una devolución (DevolucionModal) es solo de Local.
export function DevolucionesTab({ supabase, esAdmin, onAviso, ComprobanteModal }: DevolucionesTabProps) {
  const [desde, setDesde] = useState(fechaISO(-6))
  const [hasta, setHasta] = useState(fechaHoyISO())
  const [filas, setFilas] = useState<DevolucionFila[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [aviso, setAviso] = useState<string | null>(null)

  const [verDetalle, setVerDetalle] = useState<DevolucionFila | null>(null)
  const [aAnular, setAAnular] = useState<DevolucionFila | null>(null)
  const [motivoAnulacion, setMotivoAnulacion] = useState('')
  const [anulando, setAnulando] = useState(false)
  const [errorAnulacion, setErrorAnulacion] = useState<string | null>(null)
  const [confirmCerrarAnulacion, setConfirmCerrarAnulacion] = useState(false)

  // El modal de anulación es un formulario (motivo): ✕ / Cancelar con el motivo escrito piden
  // confirmación y Esc no cierra.
  const motivoEscrito = motivoAnulacion.trim() !== ''
  function pedirCierreAnulacion() {
    if (motivoEscrito) setConfirmCerrarAnulacion(true)
    else setAAnular(null)
  }

  async function cargar() {
    setLoading(true)
    setError(null)
    const { data, error: dbError } = await supabase
      .from('devoluciones')
      .select(SELECT_DEVOLUCION_DETALLE)
      .gte('fecha', desde)
      .lte('fecha', hasta)
      .order('created_at', { ascending: false })

    if (dbError) {
      setError(friendlyError(dbError))
      setLoading(false)
      return
    }
    const base = ((data ?? []) as unknown as Omit<DevolucionFila, 'usuarioNombre'>[]).map(ordenarTickets)
    const nombres = await nombresPorId(supabase, base.map((d) => d.usuario_id))
    setFilas(base.map((d) => ({ ...d, usuarioNombre: nombres.get(d.usuario_id) ?? null })))
    setLoading(false)
  }

  useEffect(() => {
    cargar()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [desde, hasta])

  async function confirmarAnulacion() {
    if (!aAnular) return
    if (!motivoAnulacion.trim()) return setErrorAnulacion('El motivo es obligatorio.')
    setAnulando(true)
    setErrorAnulacion(null)
    const { error: rpcError } = await anularDevolucion(supabase, aAnular.id, motivoAnulacion.trim())
    setAnulando(false)
    if (rpcError) return setErrorAnulacion(friendlyError(rpcError))
    const mensaje = `Devolución ${aAnular.numero} anulada.`
    if (onAviso) onAviso(mensaje)
    else setAviso(mensaje)
    setAAnular(null)
    setMotivoAnulacion('')
    cargar()
  }

  const activas = filas.filter((f) => f.estado === 'activa')
  // docs/74: el neto es solo la plata que se movió (cobro / reintegro); lo que quedó a favor (vale
  // manual) va aparte y no suma a la caja.
  const totalDiferencia = activas.reduce((acc, f) => acc + diferenciaQueMueveDinero(f), 0)
  const aFavor = activas.filter((f) => f.resolucion === 'a_favor')
  const totalAFavor = aFavor.reduce((acc, f) => acc - f.diferencia_monto, 0)

  return (
    <div className="flex h-full flex-col">
      <div className="flex items-end gap-3">
        <label className="flex w-[9.5rem] shrink-0 flex-col gap-1">
          <span className="font-sans text-label-md text-ink-soft">Desde</span>
          <input type="date" value={desde} onChange={(e) => setDesde(e.target.value)} className={inputClass} />
        </label>
        <label className="flex w-[9.5rem] shrink-0 flex-col gap-1">
          <span className="font-sans text-label-md text-ink-soft">Hasta</span>
          <input type="date" value={hasta} onChange={(e) => setHasta(e.target.value)} className={inputClass} />
        </label>
        <p className="ml-auto min-w-0 text-right font-sans text-body-md text-ink-soft">
          {activas.length} activa{activas.length === 1 ? '' : 's'} · Neto en caja{' '}
          <span className="font-sans text-label-bold text-ink">{formatCurrency(totalDiferencia)}</span>
          {aFavor.length > 0 && (
            <>
              {' '}
              · A favor (vale manual) <span className="font-sans text-label-bold text-ink">{formatCurrency(totalAFavor)}</span>
            </>
          )}
        </p>
      </div>

      {error && <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>}
      {aviso && (
        <p className="mt-stack-md rounded bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">{aviso}</p>
      )}

      <div className="mt-stack-md flex-1 overflow-auto rounded-xl shadow-sm">
        {/* Mismo criterio que Facturación: table-fixed + colgroup, columnas cortas fijas (rem) y
            Motivo se lleva el resto. El detalle de ítems vive en "Ver detalle", no en la fila. */}
        <table className="w-full table-fixed text-left font-sans text-table-row max-xl:[&_td]:px-2 max-xl:[&_th]:px-2">
          <colgroup>
            <col className="w-16" />
            <col className="w-[7.5rem] xl:w-[9rem]" />
            <col className="w-[8.5rem]" />
            <col />
            <col className="w-[9rem]" />
            <col className="w-24" />
            <col className="w-14" />
          </colgroup>
          <thead>
            <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
              <th className="px-3 py-2.5">N°</th>
              <th className="px-3 py-2.5">Fecha</th>
              <th className="px-3 py-2.5">Tickets</th>
              <th className="px-3 py-2.5">Motivo</th>
              <th className="px-3 py-2.5 text-right">Diferencia</th>
              <th className="px-3 py-2.5">Estado</th>
              <th className="px-3 py-2.5"></th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={7}>
                  Cargando...
                </td>
              </tr>
            )}
            {!loading && filas.length === 0 && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={7}>
                  No hay devoluciones en este período.
                </td>
              </tr>
            )}
            {filas.map((f) => (
              <tr
                key={f.id}
                className={`border-b border-table-divider last:border-0 even:bg-table-row-alt ${f.estado === 'anulada' ? 'opacity-60' : ''}`}
              >
                <td className="px-3 py-3 text-ink">{f.numero}</td>
                <td className="px-3 py-3 text-ink-soft">
                  <span className="whitespace-nowrap">{formatFechaCortaLocal(f.created_at)}</span>{' '}
                  <span className="whitespace-nowrap">{formatHora(f.created_at)}</span>
                </td>
                <td className="px-3 py-3 text-ink-soft [overflow-wrap:anywhere]">{numerosDeTickets(f) || '—'}</td>
                <td className="px-3 py-3 text-ink-soft">
                  <span className="block truncate">{MOTIVO_DEVOLUCION_LABEL[f.motivo]}</span>
                  {f.motivo_detalle && (
                    <span className="block truncate text-label-md" title={f.motivo_detalle}>
                      {f.motivo_detalle}
                    </span>
                  )}
                </td>
                <td className="px-3 py-3 text-right">
                  <span className="block whitespace-nowrap font-sans font-semibold text-ink">
                    {formatCurrency(Math.abs(f.diferencia_monto))}
                  </span>
                  <span
                    className={`block truncate text-label-md ${f.resolucion === 'a_favor' ? 'text-accent-darker' : 'text-ink-soft'}`}
                    title={sentidoDiferencia(f.diferencia_monto)}
                  >
                    {RESOLUCION_DEVOLUCION_LABEL[f.resolucion] ?? sentidoDiferencia(f.diferencia_monto)}
                  </span>
                </td>
                <td className="px-3 py-3">
                  {f.estado === 'anulada' ? (
                    <span title={f.motivo_anulacion ?? undefined}>
                      <EstadoBadge variant="red">Anulada</EstadoBadge>
                    </span>
                  ) : (
                    <EstadoBadge variant="green">Activa</EstadoBadge>
                  )}
                </td>
                <td className="px-3 py-3 text-right">
                  {esAdmin && f.estado === 'activa' ? (
                    <RowActionsMenu
                      ariaLabel={`Más acciones para la devolución ${f.numero}`}
                      items={[
                        { label: 'Ver detalle', icon: Eye, onClick: () => setVerDetalle(f) },
                        {
                          label: 'Anular',
                          icon: Ban,
                          destructive: true,
                          onClick: () => {
                            setAAnular(f)
                            setMotivoAnulacion('')
                            setErrorAnulacion(null)
                          },
                        },
                      ]}
                    />
                  ) : (
                    <button
                      type="button"
                      onClick={() => setVerDetalle(f)}
                      title="Ver detalle"
                      aria-label={`Ver detalle de la devolución ${f.numero}`}
                      className="rounded p-1 text-accent-dark hover:bg-accent-light"
                    >
                      <Eye size={18} strokeWidth={1.5} />
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {verDetalle && (
        <DevolucionDetalleModal
          supabase={supabase}
          devolucion={verDetalle}
          onClose={() => setVerDetalle(null)}
          ComprobanteModal={ComprobanteModal}
        />
      )}

      {aAnular && (
        <Modal
          title={`Anular devolución ${aAnular.numero}`}
          onClose={pedirCierreAnulacion}
          cambiosSinGuardar={motivoEscrito}
          widthClassName="max-w-[440px]"
        >
          <div className="flex flex-col gap-stack-md">
            <p className="font-sans text-body-md text-ink">
              Se revierte el stock movido por esta devolución. La venta original no se modifica. Solo para devoluciones mal cargadas.
            </p>
            <Field label="Motivo de la anulación" compact>
              <input
                value={motivoAnulacion}
                onChange={(e) => setMotivoAnulacion(e.target.value)}
                className={inputClass}
                autoFocus
              />
            </Field>
            {errorAnulacion && <ErrorText>{errorAnulacion}</ErrorText>}
            <div className="flex justify-end gap-3">
              <button
                type="button"
                onClick={pedirCierreAnulacion}
                className="rounded px-4 py-3 font-sans text-label-bold text-ink-soft hover:bg-bg"
              >
                Cancelar
              </button>
              <button
                type="button"
                onClick={confirmarAnulacion}
                disabled={anulando}
                className="rounded border border-error px-4 py-3 font-sans text-label-bold text-error transition hover:bg-error hover:text-white disabled:opacity-60"
              >
                {anulando ? 'Anulando...' : 'Anular devolución'}
              </button>
            </div>
          </div>
          {confirmCerrarAnulacion && (
            <ConfirmDialog
              title="Cerrar sin guardar"
              mensaje="Escribiste un motivo de anulación. ¿Querés cerrar de todos modos?"
              confirmLabel="Cerrar sin guardar"
              onCancel={() => setConfirmCerrarAnulacion(false)}
              onConfirm={() => {
                setConfirmCerrarAnulacion(false)
                setAAnular(null)
              }}
            />
          )}
        </Modal>
      )}
    </div>
  )
}
