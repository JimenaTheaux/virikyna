import { useEffect, useState } from 'react'
import type { Egreso, OrigenEgreso } from '@virikyna/shared'
import { formatCurrency, formatFechaCorta, friendlyError, nombresPorId } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { CATEGORIA_EGRESO_LABEL, FORMA_PAGO_EGRESO_LABEL, ORIGEN_EGRESO_LABEL } from '../../lib/caja'
import type { EgresoConUsuario } from './types'

const LIMITE = 200

type OrigenFiltro = 'todos' | OrigenEgreso

// Una sola tabla para egresos de Gestión (origen='general') y de turno cargados desde Virikyna
// Local (origen='turno') — el filtro de origen alcanza para aislar una fuente, no hace falta
// duplicar el componente (docs/04_modulos_y_funciones.md, módulo Egresos).
export function HistorialEgresosTab() {
  const [filas, setFilas] = useState<EgresoConUsuario[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const [origenFiltro, setOrigenFiltro] = useState<OrigenFiltro>('todos')
  const [fechaDesde, setFechaDesde] = useState('')
  const [fechaHasta, setFechaHasta] = useState('')

  async function cargar() {
    setLoading(true)
    setError(null)

    // Filtra por `fecha` (la fecha real del egreso, editable), no por `created_at` (cuándo se
    // cargó en el sistema) — así un egreso backdateado aparece en el rango que corresponde.
    let query = supabase
      .from('egresos')
      .select('*')
      .order('fecha', { ascending: false })
      .order('created_at', { ascending: false })
      .limit(LIMITE)

    if (origenFiltro !== 'todos') query = query.eq('origen', origenFiltro)
    if (fechaDesde) query = query.gte('fecha', fechaDesde)
    if (fechaHasta) query = query.lte('fecha', fechaHasta)

    const { data, error: dbError } = await query
    if (dbError) {
      setError(friendlyError(dbError))
      setLoading(false)
      return
    }

    const filasSinUsuario = (data ?? []) as unknown as Egreso[]
    const nombrePorUsuario = await nombresPorId(
      supabase,
      filasSinUsuario.map((f) => f.usuario_id),
    )
    setFilas(
      filasSinUsuario.map((f) => ({
        ...f,
        usuario: nombrePorUsuario.has(f.usuario_id) ? { nombre: nombrePorUsuario.get(f.usuario_id)! } : null,
      })),
    )
    setLoading(false)
  }

  useEffect(() => {
    cargar()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [origenFiltro, fechaDesde, fechaHasta])

  return (
    <div className="flex flex-col gap-stack-md">
      <div className="flex flex-wrap items-end gap-3">
        <label className="flex flex-col gap-1">
          <span className="font-sans text-label-md text-ink-soft">Origen</span>
          <select
            value={origenFiltro}
            onChange={(e) => setOrigenFiltro(e.target.value as OrigenFiltro)}
            className="rounded border border-line bg-surface px-3 py-2 font-sans text-body-md text-ink outline-none focus:border-accent"
          >
            <option value="todos">Todos</option>
            <option value="general">Gestión</option>
            <option value="turno">Local</option>
          </select>
        </label>
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

      <div className="flex-1 overflow-auto rounded-lg border border-line">
        <table className="w-full text-left font-sans text-body-md">
          <thead>
            <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
              <th className="min-w-[100px] whitespace-nowrap px-4 py-3">Fecha</th>
              <th className="px-4 py-3">Categoría</th>
              <th className="px-4 py-3 text-right">Monto</th>
              <th className="px-4 py-3">Forma de pago</th>
              <th className="px-4 py-3">Descripción</th>
              <th className="px-4 py-3">Origen</th>
              <th className="px-4 py-3">Usuario</th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr>
                <td className="px-4 py-6 text-ink-soft" colSpan={7}>
                  Cargando...
                </td>
              </tr>
            )}
            {!loading && filas.length === 0 && (
              <tr>
                <td className="px-4 py-6 text-ink-soft" colSpan={7}>
                  No hay egresos para este filtro.
                </td>
              </tr>
            )}
            {filas.map((fila) => (
              <tr key={fila.id} className="border-b border-line last:border-0">
                <td className="whitespace-nowrap px-4 py-2.5 text-ink-soft">{formatFechaCorta(fila.fecha)}</td>
                <td className="px-4 py-2.5 text-ink">{CATEGORIA_EGRESO_LABEL[fila.categoria]}</td>
                <td className="px-4 py-2.5 text-right text-error">{formatCurrency(-fila.monto)}</td>
                <td className="px-4 py-2.5 text-ink-soft">{FORMA_PAGO_EGRESO_LABEL[fila.forma_pago]}</td>
                <td className="px-4 py-2.5 text-ink-soft">{fila.descripcion ?? '—'}</td>
                <td className="px-4 py-2.5 text-ink-soft">{ORIGEN_EGRESO_LABEL[fila.origen]}</td>
                <td className="px-4 py-2.5 text-ink-soft">{fila.usuario?.nombre ?? '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {filas.length === LIMITE && (
        <p className="font-sans text-label-md text-ink-soft">
          Mostrando los últimos {LIMITE} egresos — usá los filtros para acotar la búsqueda.
        </p>
      )}
    </div>
  )
}
