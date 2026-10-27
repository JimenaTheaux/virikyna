import { useState } from 'react'
import { formatCantidad, formatCurrency } from '@virikyna/shared'
import type { Medida, VentaPorProducto } from './types'

const TOP = 10
const TOP_CORTO = 5

export function valorDe(fila: Pick<VentaPorProducto, 'unidades' | 'importe'>, medida: Medida): number {
  return medida === 'unidades' ? fila.unidades : fila.importe
}

export function formatMedida(valor: number, medida: Medida): string {
  return medida === 'unidades' ? formatCantidad(valor) : formatCurrency(valor)
}

// Mismo aspecto que el selector de período (pastillas): Unid. / $.
export function ToggleMedida({ medida, onChange }: { medida: Medida; onChange: (m: Medida) => void }) {
  return (
    <div role="group" aria-label="Ordenar por" className="flex gap-1 rounded-full bg-bg p-0.5">
      {(
        [
          ['unidades', 'Unid.'],
          ['importe', '$'],
        ] as const
      ).map(([id, label]) => (
        <button
          key={id}
          type="button"
          aria-pressed={medida === id}
          aria-label={id === 'unidades' ? 'Unidades' : 'Importe'}
          onClick={() => onChange(id)}
          className={`rounded-full px-3 py-1 font-sans text-label-bold transition ${
            medida === id ? 'bg-surface text-accent-darker shadow-sm' : 'text-ink-soft hover:text-accent-darker'
          }`}
        >
          {label}
        </button>
      ))}
    </div>
  )
}

// ↑ / ↓ con el % contra el período anterior. Flecha + número, no solo color.
export function Tendencia({ actual, anterior, medida }: { actual: number; anterior: number; medida: Medida }) {
  const titulo = `Período anterior: ${formatMedida(anterior, medida)}`
  if (anterior <= 0) {
    return (
      <span title={titulo} className="font-sans text-label-md text-ink-soft">
        {actual > 0 ? 'Nuevo' : '—'}
      </span>
    )
  }
  const pct = Math.round(((actual - anterior) / anterior) * 100)
  if (pct === 0) {
    return (
      <span title={titulo} className="whitespace-nowrap font-sans text-label-md text-ink-soft">
        = 0%
      </span>
    )
  }
  const sube = pct > 0
  return (
    <span title={titulo} className={`whitespace-nowrap font-sans text-label-md font-semibold ${sube ? 'text-success' : 'text-error'}`}>
      <span aria-hidden="true">{sube ? '↑' : '↓'}</span> {Math.abs(pct)}%
      <span className="sr-only">{sube ? ' más' : ' menos'} que el período anterior</span>
    </span>
  )
}

// Top del período (rango): ordenado por la medida elegida, con tendencia contra el anterior.
// Arranca en 5 para que Semana entre sin scroll en 1366×768; "Ver top 10" lo abre.
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
  const ordenadas = [...filas].filter((f) => valorDe(f, medida) > 0).sort((a, b) => valorDe(b, medida) - valorDe(a, medida))
  const cuantos = verDiez ? TOP : TOP_CORTO
  const top = ordenadas.slice(0, cuantos)
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
      {ordenadas.length > TOP_CORTO && (
        <button
          type="button"
          aria-expanded={verDiez}
          onClick={() => setVerDiez((v) => !v)}
          className="self-start rounded px-2 py-0.5 font-sans text-label-md font-semibold text-accent-dark hover:bg-accent-light"
        >
          {verDiez ? `Ver top ${TOP_CORTO}` : `Ver top ${TOP}`}
        </button>
      )}
    </div>
  )
}
