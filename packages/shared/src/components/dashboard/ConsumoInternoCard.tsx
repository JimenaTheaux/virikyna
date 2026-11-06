import { useMemo } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { useDashboardConsumoInterno } from '../../../lib/cuentaCorrienteCliente'
import { formatCurrency } from '../../../lib/format'
import { friendlyError } from '../../../lib/supabaseErrors'

type Props = {
  supabase: SupabaseClient
  desde: string
  hasta: string
  onAbrirCliente?: (clienteId: string) => void // /clientes/:id
}

type Fila = { clienteId: string; nombre: string; pendiente: number; finalizado: number }

// Consumo interno (dueñas y empleados, docs/68 D8): fuera de las ventas comerciales del dashboard,
// discriminado por cliente y por estado (a revisar / finalizado), con el total final.
export function ConsumoInternoCard({ supabase, desde, hasta, onAbrirCliente }: Props) {
  const q = useDashboardConsumoInterno(supabase, desde, hasta)
  const filas = useMemo(() => {
    const porCliente = new Map<string, Fila>()
    for (const f of q.data ?? []) {
      const fila = porCliente.get(f.cliente_id) ?? { clienteId: f.cliente_id, nombre: f.cliente_nombre, pendiente: 0, finalizado: 0 }
      if (f.estado_interno === 'pendiente') fila.pendiente += f.importe
      else fila.finalizado += f.importe
      porCliente.set(f.cliente_id, fila)
    }
    return [...porCliente.values()].sort((a, b) => b.pendiente + b.finalizado - (a.pendiente + a.finalizado))
  }, [q.data])
  const total = filas.reduce((acc, f) => ({ pendiente: acc.pendiente + f.pendiente, finalizado: acc.finalizado + f.finalizado }), {
    pendiente: 0,
    finalizado: 0,
  })

  return (
    <section aria-labelledby="consumo-interno-titulo" className="min-w-0 rounded-lg bg-surface p-4 shadow-sm">
      <h2 id="consumo-interno-titulo" className="font-display text-headline-md text-accent-darker">
        Consumo interno
      </h2>
      <p className="font-sans text-label-md text-ink-soft">Dueñas y empleados · no suma a las ventas</p>

      {q.error && <p className="mt-2 rounded bg-error/10 px-3 py-2 font-sans text-body-md text-error">{friendlyError(q.error as Error)}</p>}

      <table className="mt-3 w-full table-fixed text-left font-sans text-body-md leading-5">
        <colgroup>
          <col />
          <col className="w-[7.5rem]" />
          <col className="w-[7.5rem]" />
        </colgroup>
        <thead>
          <tr className="border-b border-line text-table-head uppercase text-ink-soft">
            <th scope="col" className="py-2 pr-2">Cliente</th>
            <th scope="col" className="px-2 py-2 text-right">A revisar</th>
            <th scope="col" className="py-2 pl-2 text-right">Finalizado</th>
          </tr>
        </thead>
        <tbody>
          {q.isPending && (
            <tr>
              <td colSpan={3} className="py-2 text-ink-soft">Cargando...</td>
            </tr>
          )}
          {!q.isPending && filas.length === 0 && (
            <tr>
              <td colSpan={3} className="py-2 text-ink-soft">Sin consumo interno en el período.</td>
            </tr>
          )}
          {filas.map((f) => (
            <tr key={f.clienteId} className="border-b border-table-divider last:border-0">
              <td className="py-1.5 pr-2 text-ink [overflow-wrap:anywhere]">
                {onAbrirCliente ? (
                  <button
                    type="button"
                    onClick={() => onAbrirCliente(f.clienteId)}
                    className="rounded text-left hover:underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
                  >
                    {f.nombre}
                  </button>
                ) : (
                  f.nombre
                )}
              </td>
              <td className={`px-2 py-1.5 text-right tabular-nums ${f.pendiente > 0 ? 'text-ink' : 'text-ink-soft'}`}>{formatCurrency(f.pendiente)}</td>
              <td className="py-1.5 pl-2 text-right tabular-nums text-ink">{formatCurrency(f.finalizado)}</td>
            </tr>
          ))}
        </tbody>
        {filas.length > 1 && (
          <tfoot>
            <tr className="border-t border-line font-semibold">
              <th scope="row" className="py-2 pr-2 text-left text-ink">Total</th>
              <td className="px-2 py-2 text-right tabular-nums text-ink">{formatCurrency(total.pendiente)}</td>
              <td className="py-2 pl-2 text-right tabular-nums text-ink">{formatCurrency(total.finalizado)}</td>
            </tr>
          </tfoot>
        )}
      </table>
    </section>
  )
}
