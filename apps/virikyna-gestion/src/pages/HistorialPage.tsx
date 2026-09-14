import { useEffect, useMemo, useState } from 'react'
import { Eye } from 'lucide-react'
import type { Auditoria, PerfilPublico, TipoAccionAuditoria } from '@virikyna/shared'
import { formatFechaHora, friendlyError, nombresPorId } from '@virikyna/shared'
import { supabase } from '../lib/supabaseClient'
import { ACCION_LABEL, accionRevertible, tablaLabel } from '../lib/historial'
import { DetalleAuditoriaModal } from './Historial/DetalleAuditoriaModal'
import { NotaCorreccionModal } from './Historial/NotaCorreccionModal'
import type { AuditoriaConUsuario } from './Historial/types'

const LIMITE = 200

// Historial y Auditoría (docs/04_modulos_y_funciones.md, módulo 10) — exclusivo de Virikyna
// Gestión. Todo lo que pasa en el sistema, quién lo hizo, y reversión según la tabla de reglas
// del módulo 10. Revertir una venta ya facturada no tiene botón — no es reversible, y así queda
// confirmado (no es un bug si no aparece esa opción).
export function HistorialPage() {
  const [filas, setFilas] = useState<AuditoriaConUsuario[]>([])
  const [usuarios, setUsuarios] = useState<PerfilPublico[]>([])
  const [ventaEstados, setVentaEstados] = useState<Map<string, string>>(new Map())
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const [usuarioFiltro, setUsuarioFiltro] = useState('todos')
  const [tablaFiltro, setTablaFiltro] = useState('todos')
  const [accionFiltro, setAccionFiltro] = useState<'todos' | TipoAccionAuditoria>('todos')
  const [fechaDesde, setFechaDesde] = useState('')
  const [fechaHasta, setFechaHasta] = useState('')

  const [verDetalle, setVerDetalle] = useState<AuditoriaConUsuario | null>(null)
  const [modalNota, setModalNota] = useState(false)

  async function cargar() {
    setLoading(true)
    setError(null)

    let query = supabase
      .from('auditoria')
      .select('*')
      .order('created_at', { ascending: false })
      .limit(LIMITE)

    if (usuarioFiltro !== 'todos') query = query.eq('usuario_id', usuarioFiltro)
    if (tablaFiltro !== 'todos') query = query.eq('tabla_afectada', tablaFiltro)
    if (accionFiltro !== 'todos') query = query.eq('accion', accionFiltro)
    if (fechaDesde) query = query.gte('created_at', `${fechaDesde}T00:00:00`)
    if (fechaHasta) query = query.lte('created_at', `${fechaHasta}T23:59:59`)

    const { data, error: dbError } = await query
    if (dbError) {
      setError(friendlyError(dbError))
      setLoading(false)
      return
    }

    const filasSinUsuario = (data ?? []) as unknown as Auditoria[]

    const nombrePorUsuario = await nombresPorId(
      supabase,
      filasSinUsuario.map((f) => f.usuario_id),
    )

    const lista: AuditoriaConUsuario[] = filasSinUsuario.map((f) => ({
      ...f,
      usuario: nombrePorUsuario.has(f.usuario_id) ? { nombre: nombrePorUsuario.get(f.usuario_id)! } : null,
    }))
    setFilas(lista)

    // Estado ACTUAL de cada venta que aparece — no el que quedó en el snapshot de auditoría —
    // porque una venta puede haberse facturado después del alta que estamos mirando acá.
    const ventaIds = Array.from(
      new Set(lista.filter((f) => f.tabla_afectada === 'ventas').map((f) => f.registro_id)),
    )
    if (ventaIds.length > 0) {
      const { data: ventasData } = await supabase.from('ventas').select('id, estado').in('id', ventaIds)
      setVentaEstados(new Map((ventasData ?? []).map((v) => [v.id as string, v.estado as string])))
    } else {
      setVentaEstados(new Map())
    }

    setLoading(false)
  }

  useEffect(() => {
    // `perfiles_publico` (id + nombre), no `perfiles` directo — ver nota en cargar().
    supabase
      .from('perfiles_publico')
      .select('id, nombre')
      .order('nombre')
      .then(({ data }) => setUsuarios((data ?? []) as PerfilPublico[]))
  }, [])

  useEffect(() => {
    cargar()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [usuarioFiltro, tablaFiltro, accionFiltro, fechaDesde, fechaHasta])

  const tablasPresentes = useMemo(
    () => Array.from(new Set(filas.map((f) => f.tabla_afectada))).sort(),
    [filas],
  )

  return (
    <section className="flex h-full flex-col rounded-lg bg-surface p-card shadow-sm">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="font-display text-headline-lg text-accent-darker">Historial y Auditoría</h1>
          <p className="mt-1 font-sans text-body-md text-ink-soft">
            Quién hizo qué, cuándo, y reversión de acciones cuando corresponde.
          </p>
        </div>
        <button
          type="button"
          onClick={() => setModalNota(true)}
          className="rounded-lg border border-line px-4 py-3 font-sans text-label-bold text-ink-soft hover:border-accent"
        >
          + Nota de corrección
        </button>
      </div>

      <div className="mt-stack-md flex flex-wrap items-end gap-3">
        <label className="flex flex-col gap-1">
          <span className="font-sans text-label-md text-ink-soft">Usuario</span>
          <select
            value={usuarioFiltro}
            onChange={(e) => setUsuarioFiltro(e.target.value)}
            className="rounded border border-line bg-surface px-3 py-2 font-sans text-body-md text-ink outline-none focus:border-accent"
          >
            <option value="todos">Todos</option>
            {usuarios.map((u) => (
              <option key={u.id} value={u.id}>
                {u.nombre}
              </option>
            ))}
          </select>
        </label>
        <label className="flex flex-col gap-1">
          <span className="font-sans text-label-md text-ink-soft">Módulo</span>
          <select
            value={tablaFiltro}
            onChange={(e) => setTablaFiltro(e.target.value)}
            className="rounded border border-line bg-surface px-3 py-2 font-sans text-body-md text-ink outline-none focus:border-accent"
          >
            <option value="todos">Todos</option>
            {tablasPresentes.map((t) => (
              <option key={t} value={t}>
                {tablaLabel(t)}
              </option>
            ))}
          </select>
        </label>
        <label className="flex flex-col gap-1">
          <span className="font-sans text-label-md text-ink-soft">Tipo de acción</span>
          <select
            value={accionFiltro}
            onChange={(e) => setAccionFiltro(e.target.value as 'todos' | TipoAccionAuditoria)}
            className="rounded border border-line bg-surface px-3 py-2 font-sans text-body-md text-ink outline-none focus:border-accent"
          >
            <option value="todos">Todos</option>
            {Object.entries(ACCION_LABEL).map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
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

      {error && (
        <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>
      )}

      <div className="mt-stack-md flex-1 overflow-auto rounded-lg border border-line">
        <table className="w-full text-left font-sans text-body-md">
          <thead>
            <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
              <th className="min-w-[120px] whitespace-nowrap px-4 py-3">Fecha</th>
              <th className="px-4 py-3">Usuario</th>
              <th className="px-4 py-3">Módulo</th>
              <th className="px-4 py-3">Acción</th>
              <th className="px-4 py-3"></th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr>
                <td className="px-4 py-6 text-ink-soft" colSpan={5}>
                  Cargando...
                </td>
              </tr>
            )}
            {!loading && filas.length === 0 && (
              <tr>
                <td className="px-4 py-6 text-ink-soft" colSpan={5}>
                  No hay acciones para este filtro.
                </td>
              </tr>
            )}
            {filas.map((fila) => {
              const ventaEstado = fila.tabla_afectada === 'ventas' ? ventaEstados.get(fila.registro_id) : undefined
              const revertible = accionRevertible(fila, ventaEstado)
              return (
                <tr key={fila.id} className="border-b border-line last:border-0">
                  <td className="whitespace-nowrap px-4 py-2.5 text-ink-soft">{formatFechaHora(fila.created_at)}</td>
                  <td className="px-4 py-2.5 text-ink-soft">{fila.usuario?.nombre ?? '—'}</td>
                  <td className="px-4 py-2.5 text-ink">{tablaLabel(fila.tabla_afectada)}</td>
                  <td className="px-4 py-2.5">
                    <span
                      className={
                        fila.accion === 'reversion'
                          ? 'text-accent-dark'
                          : fila.accion === 'anulacion' || fila.accion === 'eliminacion'
                            ? 'text-error'
                            : 'text-ink-soft'
                      }
                    >
                      {ACCION_LABEL[fila.accion]}
                    </span>
                  </td>
                  <td className="px-4 py-2.5 text-right">
                    <button
                      type="button"
                      onClick={() => setVerDetalle(fila)}
                      title="Ver detalle"
                      aria-label="Ver detalle"
                      className="rounded px-3 py-1.5 text-accent-dark hover:bg-accent-light"
                    >
                      <Eye size={18} strokeWidth={1.5} />
                    </button>
                    {revertible && <span className="ml-2 font-sans text-label-md text-error">Revertible</span>}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      {filas.length === LIMITE && (
        <p className="mt-2 font-sans text-label-md text-ink-soft">
          Mostrando las últimas {LIMITE} acciones — usá los filtros para acotar la búsqueda.
        </p>
      )}

      {verDetalle && (
        <DetalleAuditoriaModal
          auditoria={verDetalle}
          ventaEstado={verDetalle.tabla_afectada === 'ventas' ? ventaEstados.get(verDetalle.registro_id) : undefined}
          onClose={() => setVerDetalle(null)}
          onReverted={() => {
            setVerDetalle(null)
            cargar()
          }}
        />
      )}

      {modalNota && (
        <NotaCorreccionModal
          onClose={() => setModalNota(false)}
          onSaved={() => {
            setModalNota(false)
            cargar()
          }}
        />
      )}
    </section>
  )
}
