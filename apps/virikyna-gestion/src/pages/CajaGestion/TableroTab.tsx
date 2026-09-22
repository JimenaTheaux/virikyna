import { useEffect, useState } from 'react'
import { Eye } from 'lucide-react'
import { supabase } from '../../lib/supabaseClient'
import { friendlyError, nombresPorId } from '@virikyna/shared'
import { formatCurrency, formatFechaHora, fechaHoyISO } from '@virikyna/shared'
import { diferenciaLabel } from '../../lib/caja'
import { CierreDetalleModal } from '../CierreCaja/CierreDetalleModal'
import type { AperturaCaja, CierreCaja } from '@virikyna/shared'
import type { CierreCajaConUsuario } from '../CierreCaja/types'

export function TableroTab() {
  const [cierres, setCierres] = useState<CierreCajaConUsuario[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [validando, setValidando] = useState<string | null>(null)
  const [verDetalle, setVerDetalle] = useState<CierreCajaConUsuario | null>(null)
  const [fechaDesde, setFechaDesde] = useState(fechaHoyISO())
  const [fechaHasta, setFechaHasta] = useState(fechaHoyISO())

  async function cargar() {
    setLoading(true)
    setError(null)
    let query = supabase.from('cierres_caja').select('*').order('created_at', { ascending: false })

    if (fechaDesde) query = query.gte('turno_fecha', fechaDesde)
    if (fechaHasta) query = query.lte('turno_fecha', fechaHasta)

    const { data, error: dbError } = await query

    if (dbError) {
      setError(friendlyError(dbError))
      setLoading(false)
      return
    }

    const cierresSinUsuario = (data ?? []) as unknown as CierreCaja[]

    const aperturaIds = Array.from(
      new Set(cierresSinUsuario.map((c) => c.apertura_id).filter((id): id is string => Boolean(id))),
    )
    const aperturasRes =
      aperturaIds.length > 0
        ? await supabase.from('aperturas_caja').select('*').in('id', aperturaIds)
        : { data: [] as AperturaCaja[] }
    const aperturaPorId = new Map(
      ((aperturasRes.data ?? []) as unknown as AperturaCaja[]).map((a) => [a.id, a]),
    )

    const nombrePorUsuario = await nombresPorId(supabase, [
      ...cierresSinUsuario.flatMap((c) => [c.usuario_id, c.validado_por]),
      ...Array.from(aperturaPorId.values()).map((a) => a.usuario_id),
    ])
    setCierres(
      cierresSinUsuario.map((c) => {
        const apertura = c.apertura_id ? aperturaPorId.get(c.apertura_id) ?? null : null
        return {
          ...c,
          usuario: nombrePorUsuario.has(c.usuario_id) ? { nombre: nombrePorUsuario.get(c.usuario_id)! } : null,
          validador:
            c.validado_por && nombrePorUsuario.has(c.validado_por)
              ? { nombre: nombrePorUsuario.get(c.validado_por)! }
              : null,
          apertura: apertura
            ? { ...apertura, usuarioNombre: nombrePorUsuario.get(apertura.usuario_id) ?? null }
            : null,
        }
      }),
    )
    setLoading(false)
  }

  useEffect(() => {
    cargar()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [fechaDesde, fechaHasta])

  async function validar(cierreId: string) {
    setValidando(cierreId)
    setError(null)
    const { error: rpcError } = await supabase.rpc('validar_cierre_z', { p_cierre_id: cierreId })
    setValidando(null)
    if (rpcError) {
      setError(friendlyError(rpcError))
      return
    }
    cargar()
  }

  return (
    <div className="flex flex-col gap-stack-md">
      <p className="font-sans text-body-md text-ink-soft">
        Todos los cierres X y Z registrados en el rango de fechas elegido, en cualquier terminal.
      </p>

      <div className="flex flex-wrap items-end gap-3">
        <label className="flex flex-col gap-1">
          <span className="font-sans text-label-md text-ink-soft">Desde</span>
          <input
            type="date"
            value={fechaDesde}
            onChange={(e) => setFechaDesde(e.target.value)}
            className="rounded border border-line bg-surface px-3 py-2 font-sans text-body-md text-ink outline-none focus:border-accent"
          />
        </label>
        <label className="flex flex-col gap-1">
          <span className="font-sans text-label-md text-ink-soft">Hasta</span>
          <input
            type="date"
            value={fechaHasta}
            onChange={(e) => setFechaHasta(e.target.value)}
            className="rounded border border-line bg-surface px-3 py-2 font-sans text-body-md text-ink outline-none focus:border-accent"
          />
        </label>
      </div>

      {error && <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>}

      <div className="overflow-auto rounded-lg border border-line">
        <table className="w-full text-left font-sans text-body-md leading-5">
          <thead>
            <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
              <th className="px-3 py-2">Tipo</th>
              <th className="px-3 py-2">Hora</th>
              <th className="px-3 py-2">Usuario</th>
              <th className="px-3 py-2 text-right">Efectivo esperado</th>
              <th className="px-3 py-2">Diferencia</th>
              <th className="px-3 py-2">Estado</th>
              <th className="px-3 py-2"></th>
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
            {!loading && cierres.length === 0 && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={7}>
                  No hay cierres registrados en este rango de fechas.
                </td>
              </tr>
            )}
            {cierres.map((cierre) => {
              const diferencia = diferenciaLabel(cierre.diferencia)
              return (
                <tr key={cierre.id} className="border-b border-line last:border-0">
                  <td className="px-3 py-1.5">
                    <span
                      className={
                        cierre.tipo === 'z'
                          ? 'rounded-full bg-accent px-3 py-1 font-sans text-label-md text-white'
                          : 'rounded-full bg-bg px-3 py-1 font-sans text-label-md text-ink-soft'
                      }
                    >
                      {cierre.tipo === 'z' ? 'Cierre Z' : 'Cierre X'}
                    </span>
                  </td>
                  <td className="px-3 py-1.5 text-ink-soft">{formatFechaHora(cierre.created_at)}</td>
                  <td className="px-3 py-1.5 text-ink-soft">{cierre.usuario?.nombre ?? '—'}</td>
                  <td className="px-3 py-1.5 text-right text-ink">{formatCurrency(cierre.efectivo_esperado)}</td>
                  <td className={`px-3 py-1.5 font-sans text-label-bold ${diferencia.className}`}>
                    {diferencia.texto}
                  </td>
                  <td className="px-3 py-1.5 text-ink-soft">
                    {cierre.tipo === 'z'
                      ? cierre.estado_validacion === 'validado'
                        ? 'Validado'
                        : 'Pendiente de validación'
                      : '—'}
                  </td>
                  <td className="px-3 py-1.5 text-right">
                    <div className="flex justify-end gap-2">
                      {cierre.tipo === 'z' && cierre.estado_validacion === 'pendiente_validacion' && (
                        <button
                          type="button"
                          onClick={() => validar(cierre.id)}
                          disabled={validando === cierre.id}
                          className="rounded bg-accent px-3 py-1.5 font-sans text-label-bold text-white hover:bg-accent-dark disabled:opacity-60"
                        >
                          {validando === cierre.id ? 'Validando...' : 'Validar'}
                        </button>
                      )}
                      <button
                        type="button"
                        onClick={() => setVerDetalle(cierre)}
                        title="Ver detalle"
                        aria-label="Ver detalle"
                        className="rounded px-3 py-1.5 text-accent-dark hover:bg-accent-light"
                      >
                        <Eye size={18} strokeWidth={1.5} />
                      </button>
                    </div>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      {verDetalle && <CierreDetalleModal cierre={verDetalle} onClose={() => setVerDetalle(null)} />}
    </div>
  )
}
