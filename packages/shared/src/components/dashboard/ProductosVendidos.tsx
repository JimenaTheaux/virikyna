import { useState } from 'react'
import { formatCantidad } from '../../../lib/cargaInicial'
import { formatCurrency } from '../../../lib/format'
import { CeldaStock, separarVendidos } from './columnas'
import { ProductosVendidosModal } from './ProductosVendidosModal'
import type { VentaPorProducto } from './ventasPorProducto'

// Un solo día: lo vendido (unidades netas > 0), del mayor importe al menor. Alto acotado con scroll
// interno y encabezado fijo, para que un día con muchas ventas no empuje la pantalla. Lo devuelto
// ese día de una venta de otro día (neto < 0) va aparte, en "Devoluciones del día". "Ver todos"
// abre lo mismo en grande, con buscador y orden. Gestión y Local (Admin y Cajero) usan la misma
// card; en Local la tabla ocupa el alto que queda (alturaTabla = 'min-h-0 flex-1').
export function ProductosVendidos({
  filas: todas,
  titulo,
  className = '',
  alturaTabla = 'max-h-[8.5rem]',
}: {
  filas: VentaPorProducto[]
  titulo: string
  className?: string
  alturaTabla?: string
}) {
  const [verTodos, setVerTodos] = useState(false)
  const { vendidos: filas, devueltos: devueltas } = separarVendidos(todas)
  const unidades = filas.reduce((acc, f) => acc + f.unidades, 0)
  return (
    <div className={`flex min-w-0 flex-col gap-2 rounded-lg bg-surface p-4 shadow-sm ${className}`}>
      <div className="flex items-baseline justify-between gap-3">
        <p className="font-sans text-label-bold uppercase text-ink-soft">{titulo}</p>
        <p className="font-sans text-label-md text-ink-soft">
          {filas.length} producto{filas.length === 1 ? '' : 's'} · {formatCantidad(unidades)} unid.
        </p>
      </div>
      {filas.length === 0 ? (
        <p className="py-2 font-sans text-body-md text-ink-soft">Sin ventas en el día.</p>
      ) : (
        <div className={`${alturaTabla} overflow-auto`}>
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
              {filas.map((f) => (
                <tr key={f.productoId} className="border-b border-table-divider last:border-0 even:bg-table-row-alt">
                  <td className="truncate px-2 py-1 text-ink" title={f.marca ? `${f.nombre} · ${f.marca}` : f.nombre}>
                    {f.nombre}
                    {f.marca && <span className="text-ink-soft"> · {f.marca}</span>}
                  </td>
                  <td className="px-2 py-1 text-right font-semibold text-ink">{formatCantidad(f.unidades)}</td>
                  <td className="whitespace-nowrap px-2 py-1 text-right text-ink">{formatCurrency(f.importe)}</td>
                  <CeldaStock fila={f} />
                </tr>
              ))}
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
      {(filas.length > 0 || devueltas.length > 0) && (
        <button
          type="button"
          onClick={() => setVerTodos(true)}
          className="self-start rounded px-2 py-0.5 font-sans text-label-md font-semibold text-accent-dark hover:bg-accent-light"
        >
          Ver todos ({filas.length})
        </button>
      )}
      {verTodos && (
        <ProductosVendidosModal
          filas={todas}
          titulo={titulo}
          enRango={false}
          medidaInicial="importe"
          onClose={() => setVerTodos(false)}
        />
      )}
    </div>
  )
}
