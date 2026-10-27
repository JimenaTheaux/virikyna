import { fechaISO, formatCurrency, formatCurrencyCompact } from '@virikyna/shared'
import type { VentaDelDia } from './types'

type Props = {
  porDia: Map<string, VentaDelDia>
  altoBarras?: string // clase de alto del área de barras
}

const DIAS = 7

export function WeeklySalesChart({ porDia, altoBarras = 'h-32' }: Props) {
  const hoy = fechaISO(0)
  const serie = Array.from({ length: DIAS }, (_, i) => {
    const fecha = fechaISO(-(DIAS - 1 - i))
    const dato = porDia.get(fecha)
    return {
      fecha,
      total: dato?.total ?? 0,
      esHoy: fecha === hoy,
      label: new Date(`${fecha}T00:00:00`).toLocaleDateString('es-AR', { weekday: 'short' }),
    }
  })

  const max = Math.max(...serie.map((d) => d.total), 1)

  return (
    <div className="flex h-full flex-col">
      <p className="font-sans text-label-bold uppercase text-ink-soft">Ventas de la semana</p>
      <div className="mt-2 flex flex-1 items-end gap-1.5">
        {serie.map((dia) => (
          <div key={dia.fecha} className="flex min-w-0 flex-1 flex-col items-center gap-1" title={formatCurrency(dia.total)}>
            {/* Sin "$" ni espacios: la card vive en la columna angosta del dashboard. */}
            <span className="whitespace-nowrap font-sans text-[11px] leading-none text-ink-soft">
              {dia.total > 0 ? formatCurrencyCompact(dia.total).replace(/[$\s]/g, '') : ''}
            </span>
            <div className={`flex ${altoBarras} w-full items-end`}>
              <div
                className={`w-full rounded-t ${dia.esHoy ? 'bg-accent-darker' : 'bg-accent'}`}
                style={{ height: `${Math.max((dia.total / max) * 100, dia.total > 0 ? 4 : 1)}%` }}
              />
            </div>
            <span
              className={`font-sans text-label-md capitalize ${dia.esHoy ? 'font-bold text-accent-darker' : 'text-ink-soft'}`}
            >
              {dia.label}
            </span>
          </div>
        ))}
      </div>
    </div>
  )
}
