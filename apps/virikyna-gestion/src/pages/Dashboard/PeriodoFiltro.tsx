import { Field, inputClass } from '../../components/FormField'
import { OPCIONES_PERIODO, MAX_DIAS_RANGO, type Periodo, type TipoPeriodo } from './periodo'

type Props = {
  periodo: Periodo
  onTipo: (tipo: TipoPeriodo) => void
  onRango: (desde: string, hasta: string) => void
}

// Selector de período del Dashboard. Solo dispara cambios: el período vive en la URL
// (DashboardPage), no en estado local.
export function PeriodoFiltro({ periodo, onTipo, onRango }: Props) {
  return (
    <div className="flex flex-wrap items-end gap-stack-md">
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

      {periodo.tipo === 'rango' && (
        <div className="flex flex-wrap items-end gap-stack-md">
          <Field label="Desde" compact>
            <input
              type="date"
              value={periodo.actual.desde}
              onChange={(e) => e.target.value && onRango(e.target.value, periodo.actual.hasta)}
              className={inputClass}
            />
          </Field>
          <Field label="Hasta" compact>
            <input
              type="date"
              value={periodo.actual.hasta}
              onChange={(e) => e.target.value && onRango(periodo.actual.desde, e.target.value)}
              className={inputClass}
            />
          </Field>
          <span className="pb-3 font-sans text-label-md text-ink-soft">Máximo {MAX_DIAS_RANGO} días</span>
        </div>
      )}
    </div>
  )
}
