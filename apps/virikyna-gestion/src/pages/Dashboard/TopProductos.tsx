import { useState } from 'react'
import {
  formatCantidad,
  formatCurrency,
  ProductosVendidosModal,
  separarVendidos,
  Tendencia,
  ToggleMedida,
  valorDe,
  type Medida,
  type VentaPorProducto,
} from '@virikyna/shared'

const TOP = 10
const TOP_CORTO = 5

// Top del período (rango): ordenado por la medida elegida, con tendencia contra el anterior.
// Arranca en 5 para que Semana entre sin scroll en 1366×768; "Ver top 10" lo abre y "Ver todos"
// muestra el ranking completo (y lo devuelto de más, que acá no aparece) en un modal.
export function TopProductos({
  filas,
  medida,
  onMedida,
  comparacion,
}: {
  filas: VentaPorProducto[]
  medida: Medida
  onMedida: (m: Medida) => void
  comparacion: string
}) {
  const [verDiez, setVerDiez] = useState(false)
  const [verTodos, setVerTodos] = useState(false)
  const ordenadas = [...filas].filter((f) => valorDe(f, medida) > 0).sort((a, b) => valorDe(b, medida) - valorDe(a, medida))
  const cuantos = verDiez ? TOP : TOP_CORTO
  const top = ordenadas.slice(0, cuantos)
  const { vendidos, devueltos } = separarVendidos(filas)
  return (
    <div className="flex min-w-0 flex-col gap-2 rounded-lg bg-surface p-4 shadow-sm">
      <div className="flex items-center justify-between gap-3">
        <div className="min-w-0">
          <p className="font-sans text-label-bold uppercase text-ink-soft">Top {cuantos} productos</p>
          <p className="truncate font-sans text-label-md text-ink-soft">Tendencia vs. {comparacion}</p>
        </div>
        <ToggleMedida medida={medida} onChange={onMedida} />
      </div>
      {top.length === 0 ? (
        <p className="py-2 font-sans text-body-md text-ink-soft">Sin ventas en el período.</p>
      ) : (
        <table className="w-full table-fixed text-left font-sans text-table-row">
          <colgroup>
            <col className="w-7" />
            <col />
            <col className="w-16" />
            <col className="w-[7.5rem]" />
            <col className="w-[4.5rem]" />
          </colgroup>
          <thead>
            <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
              <th className="px-2 py-2">#</th>
              <th className="px-2 py-2">Producto</th>
              <th className="px-2 py-2 text-right">Unid.</th>
              <th className="px-2 py-2 text-right">Importe</th>
              <th className="px-2 py-2 text-right">
                <span className="sr-only">Tendencia</span>
                <span aria-hidden="true">±</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {top.map((f, i) => (
              <tr key={f.productoId} className="border-b border-table-divider last:border-0 even:bg-table-row-alt">
                <td className="px-2 py-1 text-ink-soft">{i + 1}</td>
                <td className="truncate px-2 py-1 text-ink" title={f.marca ? `${f.nombre} · ${f.marca}` : f.nombre}>
                  {f.nombre}
                  {f.marca && <span className="text-ink-soft"> · {f.marca}</span>}
                </td>
                <td className={`px-2 py-1 text-right ${medida === 'unidades' ? 'font-semibold text-ink' : 'text-ink-soft'}`}>
                  {formatCantidad(f.unidades)}
                </td>
                <td className={`whitespace-nowrap px-2 py-1 text-right ${medida === 'importe' ? 'font-semibold text-ink' : 'text-ink-soft'}`}>
                  {formatCurrency(f.importe)}
                </td>
                <td className="px-2 py-1 text-right">
                  <Tendencia
                    actual={valorDe(f, medida)}
                    anterior={medida === 'unidades' ? f.unidadesAnterior : f.importeAnterior}
                    medida={medida}
                  />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <div className="flex flex-wrap gap-2">
        {ordenadas.length > TOP_CORTO && (
          <button
            type="button"
            aria-expanded={verDiez}
            onClick={() => setVerDiez((v) => !v)}
            className="rounded px-2 py-0.5 font-sans text-label-md font-semibold text-accent-dark hover:bg-accent-light"
          >
            {verDiez ? `Ver top ${TOP_CORTO}` : `Ver top ${TOP}`}
          </button>
        )}
        {(vendidos.length > 0 || devueltos.length > 0) && (
          <button
            type="button"
            onClick={() => setVerTodos(true)}
            className="rounded px-2 py-0.5 font-sans text-label-md font-semibold text-accent-dark hover:bg-accent-light"
          >
            Ver todos ({vendidos.length})
          </button>
        )}
      </div>
      {verTodos && (
        <ProductosVendidosModal
          filas={filas}
          titulo="Productos vendidos en el período"
          enRango
          medidaInicial={medida}
          comparacion={comparacion}
          onClose={() => setVerTodos(false)}
        />
      )}
    </div>
  )
}
