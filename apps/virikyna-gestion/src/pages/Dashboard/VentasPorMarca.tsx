import { formatMedida, valorDe } from './TopProductos'
import type { Medida, VentaPorProducto } from './types'

const MARCAS_VISIBLES = 8

// Resumen por marca (no hay categorías de producto: la marca es el agrupador, decisión 2026-10-26).
// Barras horizontales finas de una sola serie — el título nombra la medida, sin leyenda.
export function VentasPorMarca({ filas, medida }: { filas: VentaPorProducto[]; medida: Medida }) {
  const porMarca = new Map<string, number>()
  for (const f of filas) {
    const marca = f.marca?.trim() || 'Sin marca'
    porMarca.set(marca, (porMarca.get(marca) ?? 0) + valorDe(f, medida))
  }
  const ordenadas = [...porMarca.entries()].filter(([, v]) => v > 0).sort((a, b) => b[1] - a[1])
  const visibles = ordenadas.slice(0, MARCAS_VISIBLES)
  const resto = ordenadas.slice(MARCAS_VISIBLES)
  if (resto.length > 0) visibles.push([`Otras ${resto.length} marcas`, resto.reduce((acc, [, v]) => acc + v, 0)])
  const max = Math.max(...visibles.map(([, v]) => v), 1)

  return (
    <div className="flex min-w-0 flex-col gap-2 rounded-lg bg-surface p-4 shadow-sm">
      <div>
        <p className="font-sans text-label-bold uppercase text-ink-soft">Por marca</p>
        <p className="font-sans text-label-md text-ink-soft">{medida === 'unidades' ? 'Unidades vendidas' : 'Importe vendido'}</p>
      </div>
      {visibles.length === 0 ? (
        <p className="py-2 font-sans text-body-md text-ink-soft">Sin ventas en el período.</p>
      ) : (
        <ul className="flex flex-col gap-1.5">
          {visibles.map(([marca, valor]) => (
            <li
              key={marca}
              title={`${marca}: ${formatMedida(valor, medida)}`}
              className="grid grid-cols-[minmax(0,7rem)_1fr_auto] items-center gap-2 font-sans text-label-md"
            >
              <span className="truncate text-ink">{marca}</span>
              <span className="h-2" aria-hidden="true">
                <span className="block h-full rounded-r bg-accent" style={{ width: `${Math.max((valor / max) * 100, 2)}%` }} />
              </span>
              <span className="whitespace-nowrap text-right text-ink-soft">{formatMedida(valor, medida)}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
