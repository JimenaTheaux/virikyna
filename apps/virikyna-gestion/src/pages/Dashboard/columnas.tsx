import { formatCantidad, formatCurrency } from '@virikyna/shared'
import type { Medida, VentaPorProducto } from './types'

// Piezas que comparten las cards de productos (vendidos del día, Top, por marca) y el modal
// "Ver todos" — en un módulo aparte para que card y modal no se importen entre sí.

export function valorDe(fila: Pick<VentaPorProducto, 'unidades' | 'importe'>, medida: Medida): number {
  return medida === 'unidades' ? fila.unidades : fila.importe
}

export function formatMedida(valor: number, medida: Medida): string {
  return medida === 'unidades' ? formatCantidad(valor) : formatCurrency(valor)
}

// Lo vendido (neto > 0) y lo devuelto de ventas de otros días/períodos (neto < 0): un producto con
// neto 0 no está en ninguna de las dos.
export function separarVendidos(filas: VentaPorProducto[]) {
  return { vendidos: filas.filter((f) => f.unidades > 0), devueltos: filas.filter((f) => f.unidades < 0) }
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

// Stock actual de un producto vendido, con aviso si quedó en el mínimo o debajo.
export function CeldaStock({ fila: f }: { fila: VentaPorProducto }) {
  const bajo = f.stockActual <= f.stockMinimo
  return (
    <td
      className={`px-2 py-1 text-right ${bajo ? 'font-semibold text-badge-amber-text' : 'text-ink-soft'}`}
      title={bajo ? `En el mínimo o menos (mínimo ${formatCantidad(f.stockMinimo)})` : undefined}
    >
      {bajo && <span aria-hidden="true">⚠ </span>}
      {formatCantidad(f.stockActual)}
      {bajo && <span className="sr-only"> (stock bajo)</span>}
    </td>
  )
}
