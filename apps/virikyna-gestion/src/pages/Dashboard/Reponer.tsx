import { Link } from 'react-router-dom'
import { formatCantidad } from '@virikyna/shared'
import type { VentaPorProducto } from './types'

const MAX_REPONER = 4

// Lateral del gráfico: lo vendido en el período cuyo stock no alcanza para otro período igual —
// stock ≤ máx(mínimo, unidades vendidas). Agotados (stock ≤ 0) primero, después los más vendidos.
export function Reponer({ filas, loading }: { filas: VentaPorProducto[]; loading: boolean }) {
  const aReponer = filas
    .filter((f) => f.unidades > 0 && f.stockActual <= Math.max(f.stockMinimo, f.unidades))
    .sort((a, b) => Number(b.stockActual <= 0) - Number(a.stockActual <= 0) || b.unidades - a.unidades)
  const visibles = aReponer.slice(0, MAX_REPONER)

  return (
    <div className="flex min-w-0 flex-col gap-2 rounded-lg bg-surface p-4 shadow-sm">
      <div>
        <p className="font-sans text-label-bold uppercase text-ink-soft">Reponer</p>
        <p className="font-sans text-label-md text-ink-soft">Su stock no cubre otro período igual</p>
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
              <span
                className="shrink-0 whitespace-nowrap text-ink-soft"
                title={`Stock mínimo: ${formatCantidad(f.stockMinimo)}`}
              >
                {formatCantidad(f.unidades)} vend. ·{' '}
                {/* Mismos colores que Inventario: rojo oscuro negativo, rojo agotado, ámbar el resto
                    (acá ámbar = no cubre otro período, aunque no tenga mínimo cargado). */}
                <span
                  className={`font-semibold ${
                    f.stockActual < 0 ? 'text-error-dark' : f.stockActual === 0 ? 'text-error' : 'text-badge-amber-text'
                  }`}
                >
                  {f.stockActual < 0
                    ? `agotado (${formatCantidad(f.stockActual)})`
                    : f.stockActual === 0
                      ? 'agotado'
                      : `stock ${formatCantidad(f.stockActual)}`}
                </span>
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
