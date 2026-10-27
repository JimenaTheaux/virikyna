import { formatCantidad, formatCurrency } from '@virikyna/shared'
import type { VentaPorProducto } from './types'

// Un solo día: lo vendido (unidades netas > 0), del mayor importe al menor. Alto acotado con scroll
// interno y encabezado fijo, para que un día con muchas ventas no empuje la pantalla. Lo devuelto
// ese día de una venta de otro día (neto < 0) va aparte, en "Devoluciones del día".
export function ProductosVendidos({ filas: todas, titulo }: { filas: VentaPorProducto[]; titulo: string }) {
  const filas = todas.filter((f) => f.unidades > 0)
  const devueltas = todas.filter((f) => f.unidades < 0)
  const unidades = filas.reduce((acc, f) => acc + f.unidades, 0)
  return (
    <div className="flex min-w-0 flex-col gap-2 rounded-lg bg-surface p-4 shadow-sm">
      <div className="flex items-baseline justify-between gap-3">
        <p className="font-sans text-label-bold uppercase text-ink-soft">{titulo}</p>
        <p className="font-sans text-label-md text-ink-soft">
          {filas.length} producto{filas.length === 1 ? '' : 's'} · {formatCantidad(unidades)} unid.
        </p>
      </div>
      {filas.length === 0 ? (
        <p className="py-2 font-sans text-body-md text-ink-soft">Sin ventas en el día.</p>
      ) : (
        <div className="max-h-[8.5rem] overflow-auto">
          <table className="w-full table-fixed text-left font-sans text-table-row">
            <colgroup>
              <col />
              <col className="w-16" />
              <col className="w-[7.5rem]" />
              <col className="w-20" />
            </colgroup>
            <thead className="sticky top-0">
              <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
                <th className="px-2 py-2">Producto</th>
                <th className="px-2 py-2 text-right">Unid.</th>
                <th className="px-2 py-2 text-right">Importe</th>
                <th className="px-2 py-2 text-right">Stock</th>
              </tr>
            </thead>
            <tbody>
              {filas.map((f) => {
                const bajo = f.stockActual <= f.stockMinimo
                return (
                  <tr key={f.productoId} className="border-b border-table-divider last:border-0 even:bg-table-row-alt">
                    <td className="truncate px-2 py-1 text-ink" title={f.marca ? `${f.nombre} · ${f.marca}` : f.nombre}>
                      {f.nombre}
                      {f.marca && <span className="text-ink-soft"> · {f.marca}</span>}
                    </td>
                    <td className="px-2 py-1 text-right font-semibold text-ink">{formatCantidad(f.unidades)}</td>
                    <td className="whitespace-nowrap px-2 py-1 text-right text-ink">{formatCurrency(f.importe)}</td>
                    <td
                      className={`px-2 py-1 text-right ${bajo ? 'font-semibold text-badge-amber-text' : 'text-ink-soft'}`}
                      title={bajo ? `En el mínimo o menos (mínimo ${formatCantidad(f.stockMinimo)})` : undefined}
                    >
                      {bajo && <span aria-hidden="true">⚠ </span>}
                      {formatCantidad(f.stockActual)}
                      {bajo && <span className="sr-only"> (stock bajo)</span>}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
      {devueltas.length > 0 && (
        <div className="border-t border-table-divider pt-2">
          <p className="font-sans text-label-md font-semibold text-ink-soft">Devoluciones del día</p>
          <ul className="mt-0.5">
            {devueltas.map((f) => (
              <li key={f.productoId} className="flex items-baseline justify-between gap-3 font-sans text-label-md text-ink-soft">
                <span className="min-w-0 truncate" title={f.marca ? `${f.nombre} · ${f.marca}` : f.nombre}>
                  {f.nombre}
                </span>
                <span className="shrink-0 whitespace-nowrap">
                  {formatCantidad(f.unidades)} unid. · {formatCurrency(f.importe)}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}
