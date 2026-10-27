import { OPCIONES_PERIODO, MAX_DIAS_RANGO, type Periodo, type TipoPeriodo } from './periodo'

const fechaClass =
  'rounded border border-line bg-surface px-2 py-1 font-sans text-label-md text-ink outline-none focus:border-accent'

type Props = {
  periodo: Periodo
  onTipo: (tipo: TipoPeriodo) => void
  onRango: (desde: string, hasta: string) => void
}

// Selector de período del Dashboard. Solo dispara cambios: el período vive en la URL
// (DashboardPage), no en estado local.
export function PeriodoFiltro({ periodo, onTipo, onRango }: Props) {
  return (
    <div className="flex flex-wrap items-center gap-2">
      <div role="group" aria-label="Período" className="flex flex-wrap gap-1 rounded-full bg-surface p-1 shadow-sm">
        {OPCIONES_PERIODO.map((op) => (
          <button
            key={op.id}
            type="button"
            aria-pressed={periodo.tipo === op.id}
            onClick={() => onTipo(op.id)}
            className={`rounded-full px-4 py-2 font-sans text-label-bold transition ${
              periodo.tipo === op.id ? 'bg-accent-light text-accent-darker' : 'text-ink-soft hover:text-accent-darker'
            }`}
          >
            {op.label}
          </button>
        ))}
      </div>

      {/* Fechas en línea, a la altura de las pastillas (1366×768: el encabezado no crece). */}
      {periodo.tipo === 'rango' && (
        <div
          title={`Máximo ${MAX_DIAS_RANGO} días`}
          className="flex flex-wrap items-center gap-2 rounded-full bg-surface px-3 py-1 shadow-sm"
        >
          <label className="flex items-center gap-1.5 font-sans text-label-md text-ink-soft">
            Desde
            <input
              type="date"
              value={periodo.actual.desde}
              onChange={(e) => e.target.value && onRango(e.target.value, periodo.actual.hasta)}
              className={fechaClass}
            />
          </label>
          <label className="flex items-center gap-1.5 font-sans text-label-md text-ink-soft">
            Hasta
            <input
              type="date"
              value={periodo.actual.hasta}
              onChange={(e) => e.target.value && onRango(periodo.actual.desde, e.target.value)}
              className={fechaClass}
            />
          </label>
        </div>
      )}
    </div>
  )
}
