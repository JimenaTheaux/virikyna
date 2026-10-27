import { useEffect, useId, useState } from 'react'
import type { FormaPagoEgreso } from '../../types/database'
import { FORMA_PAGO_EGRESO_LABEL, FORMAS_PAGO_EGRESO } from '../../lib/facturasCompra'
import { formatCurrency } from '../../lib/format'
import {
  diferenciaMedios,
  esChequeMedio,
  generarCheques,
  montoDe,
  nuevoMedio,
  totalMedios,
  type GenerarChequesInput,
  type MedioPagoForm,
} from '../../lib/mediosPago'
import { Field, inputClass, selectClass } from './FormField'

// Estado de los medios de un pago (docs/65). Arranca con un efectivo por el total; mientras haya un
// solo medio y nadie haya tocado su monto, sigue al total del pago. Al editar el monto o agregar un
// medio, deja de seguirlo.
export function useMediosPago(totalTexto: string) {
  const [medios, setMedios] = useState<MedioPagoForm[]>(() => [nuevoMedio('efectivo', totalTexto)])
  const [sigueTotal, setSigueTotal] = useState(true)

  useEffect(() => {
    if (sigueTotal) setMedios((ms) => (ms.length === 1 ? [{ ...ms[0], monto: totalTexto }] : ms))
  }, [totalTexto, sigueTotal])

  function cambiar(siguientes: MedioPagoForm[]) {
    if (siguientes.length !== 1 || siguientes[0].monto !== medios[0]?.monto) setSigueTotal(false)
    setMedios(siguientes)
  }

  return { medios, cambiar }
}

type Props = {
  medios: MedioPagoForm[]
  onChange: (medios: MedioPagoForm[]) => void
  total: number // total del pago (NaN si el campo está vacío)
  fechaPago: string // fecha del pago: base de "Generar cheques"
  // false cuando el modal muestra ResumenMedios en su pie fijo (con muchos medios la lista scrollea
  // y el resumen tiene que verse siempre, al lado de Guardar).
  conResumen?: boolean
}

const ESTADO_DIFERENCIA = {
  cierra: 'bg-badge-green-bg text-badge-green-text',
  falta: 'bg-badge-amber-bg text-badge-amber-text',
  sobra: 'bg-badge-red-bg text-error',
} as const

// "Suman $ X · Falta $ Y" (o "Cierra con el total").
export function ResumenMedios({ medios, total, className = '' }: { medios: MedioPagoForm[]; total: number; className?: string }) {
  const dif = Number.isFinite(total) ? diferenciaMedios(total, medios) : null
  return (
    <div className={`flex flex-wrap items-center gap-3 font-sans text-body-md ${className}`} aria-live="polite">
      <span className="text-ink-soft">
        {medios.length} medio{medios.length === 1 ? '' : 's'} · suman{' '}
        <span className="font-semibold tabular-nums text-ink">{formatCurrency(totalMedios(medios))}</span>
      </span>
      {dif && (
        <span className={`rounded-[6px] px-2 py-0.5 font-semibold tabular-nums ${ESTADO_DIFERENCIA[dif.estado]}`}>
          {dif.estado === 'cierra' ? 'Cierra con el total' : `${dif.estado === 'falta' ? 'Falta' : 'Sobra'} ${formatCurrency(dif.monto)}`}
        </span>
      )}
    </div>
  )
}

// Lista de medios de un pago a proveedor: cualquier combinación, tipos repetidos, sin límite (con
// 6–10 renglones la lista scrollea sola). Cheques y eCheqs piden número, banco y fecha de pago.
// "Generar cheques" arma varios de una vez (cantidad, monto o total a repartir, cada X días).
export function MediosPagoEditor({ medios, onChange, total, fechaPago, conResumen = true }: Props) {
  const idBase = useId()
  const [generando, setGenerando] = useState(false)
  const dif = Number.isFinite(total) ? diferenciaMedios(total, medios) : null

  function actualizar(key: string, cambios: Partial<MedioPagoForm>) {
    onChange(medios.map((m) => (m.key === key ? { ...m, ...cambios } : m)))
  }

  function agregar() {
    // El nuevo medio propone lo que falta, así el caso común (dos medios) cierra solo.
    const falta = dif?.estado === 'falta' ? dif.monto.toFixed(2) : ''
    onChange([...medios, nuevoMedio('transferencia', falta)])
  }

  function agregarCheques(filas: MedioPagoForm[]) {
    // Un único renglón vacío (recién abierto) se reemplaza en vez de quedar colgado.
    const vacios = medios.filter((m) => !Number.isFinite(montoDe(m)))
    onChange([...(vacios.length === medios.length ? [] : medios.filter((m) => Number.isFinite(montoDe(m)))), ...filas])
    setGenerando(false)
  }

  return (
    <section aria-labelledby={`${idBase}-titulo`} className="flex flex-col gap-stack-sm">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 id={`${idBase}-titulo`} className="font-sans text-label-bold text-ink">
          Medios de pago <span className="font-normal text-ink-soft">({medios.length})</span>
        </h3>
        <div className="flex gap-2">
          <button
            type="button"
            onClick={agregar}
            className="rounded border border-line bg-surface px-3 py-2 font-sans text-label-bold text-accent-dark transition hover:border-accent hover:bg-accent-light"
          >
            + Agregar medio
          </button>
          <button
            type="button"
            aria-expanded={generando}
            onClick={() => setGenerando((g) => !g)}
            className="rounded border border-line bg-surface px-3 py-2 font-sans text-label-bold text-accent-dark transition hover:border-accent hover:bg-accent-light"
          >
            + Generar cheques
          </button>
        </div>
      </div>

      {generando && (
        <GenerarChequesPanel
          fechaPago={fechaPago}
          falta={dif?.estado === 'falta' ? dif.monto : 0}
          onGenerar={agregarCheques}
          onCancelar={() => setGenerando(false)}
        />
      )}

      <ol className="flex max-h-[22rem] flex-col gap-2 overflow-y-auto pr-1">
        {medios.map((m, i) => {
          const cheque = esChequeMedio(m.medio)
          const n = i + 1
          return (
            <li key={m.key} className="rounded-lg border border-line bg-bg/60 p-3">
              <div className="grid grid-cols-[1.5rem_minmax(0,1fr)_minmax(0,1fr)_2.5rem] items-end gap-2">
                <span className="pb-3 text-right font-sans text-label-md tabular-nums text-ink-soft" aria-hidden="true">
                  {n}
                </span>
                <Field label="Medio" compact>
                  <select
                    aria-label={`Medio ${n}`}
                    value={m.medio}
                    onChange={(e) => actualizar(m.key, { medio: e.target.value as FormaPagoEgreso })}
                    className={selectClass}
                  >
                    {FORMAS_PAGO_EGRESO.map((f) => (
                      <option key={f} value={f}>
                        {FORMA_PAGO_EGRESO_LABEL[f]}
                      </option>
                    ))}
                  </select>
                </Field>
                <Field label="Monto" compact>
                  <input
                    aria-label={`Monto del medio ${n}`}
                    type="number"
                    step="0.01"
                    min={0}
                    value={m.monto}
                    onChange={(e) => actualizar(m.key, { monto: e.target.value })}
                    className={`${inputClass} text-right tabular-nums`}
                  />
                </Field>
                <button
                  type="button"
                  onClick={() => onChange(medios.filter((x) => x.key !== m.key))}
                  disabled={medios.length === 1}
                  aria-label={`Quitar medio ${n}`}
                  title={medios.length === 1 ? 'Un pago tiene al menos un medio' : 'Quitar'}
                  className="mb-0.5 flex h-10 w-10 items-center justify-center rounded text-ink-soft transition hover:bg-error/10 hover:text-error disabled:opacity-30 disabled:hover:bg-transparent disabled:hover:text-ink-soft"
                >
                  <span aria-hidden="true">✕</span>
                </button>
              </div>
              {cheque && (
                <div className="mt-2 grid grid-cols-3 gap-2 pl-8 pr-12">
                  <Field label="N° de cheque" compact>
                    <input
                      aria-label={`Número del cheque ${n}`}
                      value={m.numero}
                      onChange={(e) => actualizar(m.key, { numero: e.target.value })}
                      className={inputClass}
                    />
                  </Field>
                  <Field label="Banco" compact>
                    <input
                      aria-label={`Banco del cheque ${n}`}
                      value={m.banco}
                      onChange={(e) => actualizar(m.key, { banco: e.target.value })}
                      className={inputClass}
                    />
                  </Field>
                  <Field label="Fecha de pago" compact>
                    <input
                      aria-label={`Fecha de pago del cheque ${n}`}
                      type="date"
                      min={fechaPago || undefined}
                      value={m.fechaPago}
                      onChange={(e) => actualizar(m.key, { fechaPago: e.target.value })}
                      className={`${inputClass} px-2`}
                    />
                  </Field>
                </div>
              )}
            </li>
          )
        })}
      </ol>

      {conResumen && <ResumenMedios medios={medios} total={total} className="justify-end" />}
    </section>
  )
}

function GenerarChequesPanel({
  fechaPago,
  falta,
  onGenerar,
  onCancelar,
}: {
  fechaPago: string
  falta: number
  onGenerar: (filas: MedioPagoForm[]) => void
  onCancelar: () => void
}) {
  const [medio, setMedio] = useState<GenerarChequesInput['medio']>('cheque')
  const [cantidad, setCantidad] = useState('3')
  const [modo, setModo] = useState<GenerarChequesInput['modo']>('total')
  const [monto, setMonto] = useState(falta > 0 ? falta.toFixed(2) : '')
  const [cadaDias, setCadaDias] = useState('30')
  const [desde, setDesde] = useState(fechaPago)
  const [banco, setBanco] = useState('')
  const [numeroInicial, setNumeroInicial] = useState('')
  const [error, setError] = useState<string | null>(null)
  const name = useId()

  function generar() {
    const cant = Number(cantidad)
    const m = Number(monto)
    const dias = Number(cadaDias)
    if (!Number.isInteger(cant) || cant < 1 || cant > 24) return setError('Cantidad: de 1 a 24 cheques.')
    if (!monto.trim() || !Number.isFinite(m) || m <= 0) return setError('Ingresá el monto.')
    if (!Number.isInteger(dias) || dias < 0) return setError('Ingresá cada cuántos días.')
    if (!desde) return setError('Ingresá la fecha desde la que se cuentan los días.')
    onGenerar(generarCheques({ medio, cantidad: cant, modo, monto: m, cadaDias: dias, desde, banco, numeroInicial }))
  }

  return (
    // Vive dentro del <form> del pago: Enter acá genera los cheques, no registra el pago.
    <div
      onKeyDown={(e) => {
        if (e.key === 'Enter' && (e.target as HTMLElement).tagName === 'INPUT') {
          e.preventDefault()
          generar()
        }
      }}
      className="flex flex-col gap-stack-sm rounded-lg border border-accent/60 bg-accent-light/40 p-3"
    >
      <p className="font-sans text-label-bold text-accent-darker">Generar cheques</p>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
        <Field label="Tipo" compact>
          <select value={medio} onChange={(e) => setMedio(e.target.value as GenerarChequesInput['medio'])} className={selectClass}>
            <option value="cheque">{FORMA_PAGO_EGRESO_LABEL.cheque}</option>
            <option value="echeq">{FORMA_PAGO_EGRESO_LABEL.echeq}</option>
          </select>
        </Field>
        <Field label="Cantidad" compact>
          <input type="number" min={1} max={24} value={cantidad} onChange={(e) => setCantidad(e.target.value)} className={`${inputClass} tabular-nums`} />
        </Field>
        <Field label="Cada (días)" compact>
          <input type="number" min={0} value={cadaDias} onChange={(e) => setCadaDias(e.target.value)} className={`${inputClass} tabular-nums`} />
        </Field>
        <Field label="Desde" compact>
          <input type="date" value={desde} onChange={(e) => setDesde(e.target.value)} className={`${inputClass} px-2`} />
        </Field>
      </div>
      <fieldset className="flex flex-wrap items-center gap-x-4 gap-y-1 font-sans text-body-md text-ink">
        <legend className="sr-only">Cómo se reparte el monto</legend>
        <label className="flex items-center gap-2">
          <input type="radio" name={name} checked={modo === 'total'} onChange={() => setModo('total')} className="accent-accent" />
          Total a repartir
        </label>
        <label className="flex items-center gap-2">
          <input type="radio" name={name} checked={modo === 'cada'} onChange={() => setModo('cada')} className="accent-accent" />
          Monto de cada cheque
        </label>
      </fieldset>
      <div className="grid grid-cols-3 gap-2">
        <Field label={modo === 'total' ? 'Total a repartir' : 'Monto de cada uno'} compact>
          <input type="number" step="0.01" min={0} value={monto} onChange={(e) => setMonto(e.target.value)} className={`${inputClass} text-right tabular-nums`} />
        </Field>
        <Field label="Banco" compact>
          <input value={banco} onChange={(e) => setBanco(e.target.value)} className={inputClass} />
        </Field>
        <Field label="N° del primero" compact hint="Opcional: los demás siguen">
          <input value={numeroInicial} onChange={(e) => setNumeroInicial(e.target.value)} className={inputClass} />
        </Field>
      </div>
      {error && <p className="font-sans text-label-md text-error">{error}</p>}
      <div className="flex justify-end gap-2">
        <button type="button" onClick={onCancelar} className="rounded px-3 py-2 font-sans text-label-bold text-ink-soft hover:bg-bg">
          Cancelar
        </button>
        <button type="button" onClick={generar} className="rounded bg-accent px-3 py-2 font-sans text-label-bold text-white hover:bg-accent-dark">
          Agregar {Number(cantidad) > 0 ? cantidad : ''} cheques
        </button>
      </div>
    </div>
  )
}
