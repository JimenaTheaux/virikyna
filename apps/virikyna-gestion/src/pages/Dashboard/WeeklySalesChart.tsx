import { formatCurrency, formatCurrencyCompact, formatFechaCorta } from '@virikyna/shared'
import type { VentaDelDia } from './types'

type Props = {
  titulo: string
  dias: string[] // un día por barra, en orden (YYYY-MM-DD, hora AR)
  serie: VentaDelDia[] // filas de la RPC, ya agregadas por día
  hoy: string // YYYY-MM-DD en hora AR — su barra va resaltada
}

// Con más de 7 barras la etiqueta pasa de día de la semana a número de día; con más de 14 se
// sacan los montos de arriba de las barras (no entran) y queda el tooltip.
const MAX_BARRAS_DIA_SEMANA = 7
const MAX_BARRAS_CON_MONTO = 14

export function WeeklySalesChart({ titulo, dias, serie: datos, hoy }: Props) {
  const conMonto = dias.length <= MAX_BARRAS_CON_MONTO
  const cadaCuantas = Math.ceil(dias.length / 16) // cada cuántas barras va etiqueta en meses/rangos largos

  const serie = dias.map((fecha, i) => {
    const total = datos.find((d) => d.fecha === fecha)?.total ?? 0
    return {
      fecha,
      total,
      esHoy: fecha === hoy,
      label:
        dias.length <= MAX_BARRAS_DIA_SEMANA
          ? new Date(`${fecha}T00:00:00`).toLocaleDateString('es-AR', { weekday: 'short' })
          : i % cadaCuantas === 0 || fecha === hoy
            ? String(Number(fecha.slice(8, 10)))
            : '',
    }
  })

  const max = Math.max(...serie.map((d) => d.total), 1)

  return (
    <div className="flex h-full flex-col">
      <p className="font-sans text-label-bold uppercase text-ink-soft">{titulo}</p>
      <div className={`mt-stack-md flex flex-1 items-end ${dias.length > MAX_BARRAS_CON_MONTO ? 'gap-1' : 'gap-3'}`}>
        {serie.map((dia) => (
          <div
            key={dia.fecha}
            className="flex min-w-0 flex-1 flex-col items-center gap-2"
            title={`${formatFechaCorta(dia.fecha)}: ${formatCurrency(dia.total)}`}
          >
            {conMonto && (
              <span className="font-sans text-label-md text-ink-soft">
                {dia.total > 0 ? formatCurrencyCompact(dia.total) : ''}
              </span>
            )}
            <div className="flex h-32 w-full items-end">
              <div
                className={`w-full rounded-t ${dia.esHoy ? 'bg-accent-darker' : 'bg-accent'}`}
                style={{ height: `${Math.max((dia.total / max) * 100, dia.total > 0 ? 4 : 1)}%` }}
              />
            </div>
            <span
              className={`h-[18px] font-sans text-label-md capitalize ${dia.esHoy ? 'font-bold text-accent-darker' : 'text-ink-soft'}`}
            >
              {dia.label}
            </span>
          </div>
        ))}
      </div>
    </div>
  )
}
