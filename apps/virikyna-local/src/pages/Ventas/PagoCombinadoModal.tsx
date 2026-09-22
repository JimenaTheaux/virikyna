import { useState, type FormEvent } from 'react'
import type { FormaPagoVenta } from '@virikyna/shared'
import { formatCurrency } from '@virikyna/shared'
import { Modal } from '../../components/Modal'
import { Field, ErrorText, inputClass, selectClass } from '../../components/FormField'
import { FORMA_PAGO_LABEL } from '../../lib/comprobante'
import type { PagoParcial } from './types'

const MEDIOS_COMBINABLES: FormaPagoVenta[] = ['efectivo', 'transferencia', 'qr', 'tarjeta_debito', 'tarjeta_credito']

type Props = {
  total: number
  valorActual: PagoParcial[] | null
  onClose: () => void
  onAplicar: (pagos: PagoParcial[]) => void
}

// Reparte el total de la venta entre hasta 2 medios de pago (docs/22) — cuenta corriente no
// combina, se sigue eligiendo como medio único desde FormaPagoSelector.
export function PagoCombinadoModal({ total, valorActual, onClose, onAplicar }: Props) {
  const [medio1, setMedio1] = useState<FormaPagoVenta>(valorActual?.[0]?.formaPago ?? 'efectivo')
  const [monto1, setMonto1] = useState(valorActual?.[0] ? String(valorActual[0].monto) : '')
  const [medio2, setMedio2] = useState<FormaPagoVenta>(
    valorActual?.[1]?.formaPago ?? MEDIOS_COMBINABLES.find((m) => m !== medio1) ?? 'transferencia',
  )
  const [monto2, setMonto2] = useState(valorActual?.[1] ? String(valorActual[1].monto) : '')
  const [monto2Tocado, setMonto2Tocado] = useState(Boolean(valorActual?.[1]))
  const [error, setError] = useState<string | null>(null)

  const numMonto1 = Number(monto1) || 0
  const numMonto2 = Number(monto2) || 0
  const suma = Math.round((numMonto1 + numMonto2) * 100) / 100
  const diferencia = Math.round((total - suma) * 100) / 100

  function handleMonto1(value: string) {
    setMonto1(value)
    if (!monto2Tocado) {
      const restante = Math.round((total - (Number(value) || 0)) * 100) / 100
      setMonto2(restante > 0 ? String(restante) : '')
    }
  }

  function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (medio1 === medio2) {
      setError('Elegí dos medios de pago distintos.')
      return
    }
    if (numMonto1 <= 0 || numMonto2 <= 0) {
      setError('Los dos montos tienen que ser mayores a $0.')
      return
    }
    if (diferencia !== 0) {
      setError(
        diferencia > 0
          ? `Falta ${formatCurrency(diferencia)} para cubrir el total.`
          : `Te pasaste por ${formatCurrency(Math.abs(diferencia))}.`,
      )
      return
    }
    onAplicar([
      { formaPago: medio1, monto: numMonto1 },
      { formaPago: medio2, monto: numMonto2 },
    ])
    onClose()
  }

  return (
    <Modal title="Pago combinado" onClose={onClose} widthClassName="max-w-[400px]">
      <form onSubmit={handleSubmit} className="flex flex-col gap-stack-md">
        <p className="text-center font-sans text-body-md text-ink-soft">
          Total a cubrir: <span className="font-sans text-label-bold text-ink">{formatCurrency(total)}</span>
        </p>

        <div className="grid grid-cols-[1fr_120px] gap-3">
          <Field label="Medio 1">
            <select value={medio1} onChange={(e) => setMedio1(e.target.value as FormaPagoVenta)} className={selectClass}>
              {MEDIOS_COMBINABLES.map((m) => (
                <option key={m} value={m}>
                  {FORMA_PAGO_LABEL[m]}
                </option>
              ))}
            </select>
          </Field>
          <Field label="Monto">
            <input
              autoFocus
              type="number"
              min="0"
              step="0.01"
              value={monto1}
              onChange={(e) => handleMonto1(e.target.value)}
              className={inputClass}
            />
          </Field>
        </div>

        <div className="grid grid-cols-[1fr_120px] gap-3">
          <Field label="Medio 2">
            <select value={medio2} onChange={(e) => setMedio2(e.target.value as FormaPagoVenta)} className={selectClass}>
              {MEDIOS_COMBINABLES.map((m) => (
                <option key={m} value={m}>
                  {FORMA_PAGO_LABEL[m]}
                </option>
              ))}
            </select>
          </Field>
          <Field label="Monto">
            <input
              type="number"
              min="0"
              step="0.01"
              value={monto2}
              onChange={(e) => {
                setMonto2Tocado(true)
                setMonto2(e.target.value)
              }}
              className={inputClass}
            />
          </Field>
        </div>

        <p className={`text-right font-sans text-label-bold ${diferencia === 0 ? 'text-success' : 'text-ink-soft'}`}>
          {diferencia === 0
            ? 'Cubre el total ✓'
            : diferencia > 0
              ? `Falta ${formatCurrency(diferencia)}`
              : `Sobra ${formatCurrency(Math.abs(diferencia))}`}
        </p>

        {error && <ErrorText>{error}</ErrorText>}

        <div className="flex justify-end gap-3">
          <button
            type="button"
            onClick={onClose}
            className="rounded px-4 py-3 font-sans text-label-bold text-ink-soft hover:bg-bg"
          >
            Cancelar
          </button>
          <button
            type="submit"
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white hover:bg-accent-dark"
          >
            Aplicar
          </button>
        </div>
      </form>
    </Modal>
  )
}
