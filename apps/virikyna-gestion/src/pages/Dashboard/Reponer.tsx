import { Link } from 'react-router-dom'
import { formatCantidad } from '@virikyna/shared'
import type { VentaPorProducto } from './types'

const MAX_REPONER = 6

// Lateral del gráfico: lo más vendido del período que quedó con stock ≤ mínimo.
export function Reponer({ filas, loading }: { filas: VentaPorProducto[]; loading: boolean }) {
  const aReponer = filas
    .filter((f) => f.unidades > 0 && f.stockActual <= f.stockMinimo)
    .sort((a, b) => b.unidades - a.unidades)
  const visibles = aReponer.slice(0, MAX_REPONER)

  return (
    <div className="flex min-w-0 flex-col gap-2 rounded-lg bg-surface p-4 shadow-sm">
      <div>
        <p className="font-sans text-label-bold uppercase text-ink-soft">Reponer</p>
        <p className="font-sans text-label-md text-ink-soft">Más vendidos con stock en el mínimo o menos</p>
      </div>
      {loading ? (
        <p className="font-sans text-body-md text-ink-soft">—</p>
      ) : visibles.length === 0 ? (
        <p className="font-sans text-body-md text-ink-soft">Nada para reponer entre lo vendido.</p>
      ) : (
        <ul className="flex flex-col divide-y divide-table-divider">
          {visibles.map((f) => (
            <li key={f.productoId} className="flex items-baseline justify-between gap-2 py-1.5 font-sans text-label-md">
              <span className="min-w-0 truncate text-ink" title={f.marca ? `${f.nombre} · ${f.marca}` : f.nombre}>
                {f.nombre}
              </span>
              <span className="shrink-0 whitespace-nowrap text-ink-soft">
                {formatCantidad(f.unidades)} vend. ·{' '}
                <span className={f.stockActual <= 0 ? 'font-semibold text-error' : 'font-semibold text-badge-amber-text'}>
                  stock {formatCantidad(f.stockActual)}
                </span>
                /{formatCantidad(f.stockMinimo)}
              </span>
            </li>
          ))}
        </ul>
      )}
      {aReponer.length > visibles.length && (
        <Link to="/inventario" className="font-sans text-label-md text-accent-dark hover:text-accent-darker">
          +{aReponer.length - visibles.length} más — ver Inventario
        </Link>
      )}
    </div>
  )
}
