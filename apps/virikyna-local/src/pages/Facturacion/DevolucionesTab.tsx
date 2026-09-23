import { useEffect, useState } from 'react'
import type { Devolucion, DevolucionItem } from '@virikyna/shared'
import {
  MOTIVO_DEVOLUCION_LABEL,
  anularDevolucion,
  fechaHoyISO,
  fechaISO,
  formatCurrency,
  formatFechaHora,
  friendlyError,
  nombresPorId,
} from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { showToast } from '../../lib/toast'
import { usePerfil } from '../../auth/AuthContext'
import { FORMA_PAGO_LABEL } from '../../lib/comprobante'
import { Modal } from '../../components/Modal'
import { ErrorText, Field, inputClass } from '../../components/FormField'

type ItemConProducto = DevolucionItem & { producto: { nombre: string } | null }

type DevolucionFila = Devolucion & {
  venta: { numero: number } | null
  items: ItemConProducto[]
  usuarioNombre: string | null
}

// Listado de devoluciones/cambios del período — detalle accesible para la dueña y el cajero, y
// anulación (solo admin) de una devolución mal cargada.
export function DevolucionesTab() {
  const { rol } = usePerfil()
  const [desde, setDesde] = useState(fechaISO(-6))
  const [hasta, setHasta] = useState(fechaHoyISO())
  const [filas, setFilas] = useState<DevolucionFila[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const [aAnular, setAAnular] = useState<DevolucionFila | null>(null)
  const [motivoAnulacion, setMotivoAnulacion] = useState('')
  const [anulando, setAnulando] = useState(false)
  const [errorAnulacion, setErrorAnulacion] = useState<string | null>(null)

  async function cargar() {
    setLoading(true)
    setError(null)
    const { data, error: dbError } = await supabase
      .from('devoluciones')
      .select('*, venta:ventas(numero), items:devolucion_items(*, producto:productos(nombre))')
      .gte('fecha', desde)
      .lte('fecha', hasta)
      .order('created_at', { ascending: false })

    if (dbError) {
      setError(friendlyError(dbError))
      setLoading(false)
      return
    }
    const base = (data ?? []) as unknown as Omit<DevolucionFila, 'usuarioNombre'>[]
    const nombres = await nombresPorId(supabase, base.map((d) => d.usuario_id))
    setFilas(base.map((d) => ({ ...d, usuarioNombre: nombres.get(d.usuario_id) ?? null })))
    setLoading(false)
  }

  useEffect(() => {
    cargar()
  }, [desde, hasta])

  async function confirmarAnulacion() {
    if (!aAnular) return
    if (!motivoAnulacion.trim()) return setErrorAnulacion('El motivo es obligatorio.')
    setAnulando(true)
    setErrorAnulacion(null)
    const { error: rpcError } = await anularDevolucion(supabase, aAnular.id, motivoAnulacion.trim())
    setAnulando(false)
    if (rpcError) return setErrorAnulacion(friendlyError(rpcError))
    showToast(`Devolución ${aAnular.numero} anulada.`)
    setAAnular(null)
    setMotivoAnulacion('')
    cargar()
  }

  const activas = filas.filter((f) => f.estado === 'activa')
  const totalDiferencia = activas.reduce((acc, f) => acc + f.diferencia_monto, 0)

  return (
    <div className="flex h-full flex-col">
      <div className="flex flex-wrap items-end gap-3">
        <label className="flex flex-col gap-1">
          <span className="font-sans text-label-md text-ink-soft">Desde</span>
          <input type="date" value={desde} onChange={(e) => setDesde(e.target.value)} className={inputClass} />
        </label>
        <label className="flex flex-col gap-1">
          <span className="font-sans text-label-md text-ink-soft">Hasta</span>
          <input type="date" value={hasta} onChange={(e) => setHasta(e.target.value)} className={inputClass} />
        </label>
        <p className="ml-auto font-sans text-body-md text-ink-soft">
          {activas.length} activa{activas.length === 1 ? '' : 's'} · Neto de diferencias{' '}
          <span className="font-sans text-label-bold text-ink">{formatCurrency(totalDiferencia)}</span>
        </p>
      </div>

      {error && <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>}

      <div className="mt-stack-md flex-1 overflow-auto rounded-lg border border-line">
        <table className="w-full text-left font-sans text-body-md leading-5">
          <thead>
            <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
              <th className="whitespace-nowrap px-3 py-2">N°</th>
              <th className="whitespace-nowrap px-3 py-2">Fecha</th>
              <th className="whitespace-nowrap px-3 py-2">Ticket</th>
              <th className="px-3 py-2">Detalle</th>
              <th className="whitespace-nowrap px-3 py-2">Motivo</th>
              <th className="whitespace-nowrap px-3 py-2">Usuario</th>
              <th className="whitespace-nowrap px-3 py-2 text-right">Diferencia</th>
              <th className="whitespace-nowrap px-3 py-2"></th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={8}>
                  Cargando...
                </td>
              </tr>
            )}
            {!loading && filas.length === 0 && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={8}>
                  No hay devoluciones en este período.
                </td>
              </tr>
            )}
            {filas.map((f) => (
              <tr key={f.id} className={`border-b border-line last:border-0 ${f.estado === 'anulada' ? 'opacity-60' : ''}`}>
                <td className="px-3 py-1.5 text-ink">{f.numero}</td>
                <td className="whitespace-nowrap px-3 py-1.5 text-ink-soft">{formatFechaHora(f.created_at)}</td>
                <td className="px-3 py-1.5 text-ink-soft">{f.venta?.numero ?? '—'}</td>
                <td className="px-3 py-1.5 text-ink-soft">
                  {f.items.map((it) => (
                    <p key={it.id}>
                      {it.tipo === 'devuelto' ? '↩' : '→'} {it.cantidad} × {it.producto?.nombre ?? 'Producto'}
                      {it.tipo === 'devuelto' && !it.reingresa_stock && (
                        <span className="ml-1 text-error">(defectuoso, sin reingreso)</span>
                      )}
                    </p>
                  ))}
                  {f.observaciones && <p className="mt-0.5 text-label-md italic">{f.observaciones}</p>}
                </td>
                <td className="px-3 py-1.5 text-ink-soft">
                  {MOTIVO_DEVOLUCION_LABEL[f.motivo]}
                  {f.motivo_detalle && <span className="block text-label-md">{f.motivo_detalle}</span>}
                </td>
                <td className="px-3 py-1.5 text-ink-soft">{f.usuarioNombre ?? '—'}</td>
                <td className="whitespace-nowrap px-3 py-1.5 text-right">
                  <span className="font-sans text-label-bold text-ink">{formatCurrency(f.diferencia_monto)}</span>
                  <span className="block text-label-md text-ink-soft">
                    {f.diferencia_forma_pago
                      ? `${f.diferencia_monto < 0 ? 'Devuelto en' : 'Cobrado en'} ${FORMA_PAGO_LABEL[f.diferencia_forma_pago]}`
                      : 'Sin diferencia'}
                  </span>
                </td>
                <td className="px-3 py-1.5 text-right">
                  {f.estado === 'anulada' ? (
                    <span className="font-sans text-label-bold text-error" title={f.motivo_anulacion ?? undefined}>
                      Anulada
                    </span>
                  ) : (
                    rol === 'admin' && (
                      <button
                        type="button"
                        onClick={() => {
                          setAAnular(f)
                          setMotivoAnulacion('')
                          setErrorAnulacion(null)
                        }}
                        className="rounded px-3 py-1.5 font-sans text-label-bold text-error hover:bg-error/10"
                      >
                        Anular
                      </button>
                    )
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {aAnular && (
        <Modal title={`Anular devolución ${aAnular.numero}`} onClose={() => setAAnular(null)} widthClassName="max-w-[440px]">
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
                onClick={() => setAAnular(null)}
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
        </Modal>
      )}
    </div>
  )
}
