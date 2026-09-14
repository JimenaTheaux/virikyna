import { useState, type FormEvent } from 'react'
import type { FormaPagoEgreso } from '@virikyna/shared'
import { fechaHoyISO, formatCurrency, friendlyError, registrarPagoProveedor } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { FORMA_PAGO_EGRESO_LABEL } from '../../lib/caja'
import { Modal } from '../../components/Modal'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, ErrorText, inputClass, selectClass } from '../../components/FormField'

const FORMAS_PAGO = Object.keys(FORMA_PAGO_EGRESO_LABEL) as FormaPagoEgreso[]
const ES_CHEQUE = (f: FormaPagoEgreso) => f === 'cheque' || f === 'echeq'

type Props = {
  proveedorId: string
  proveedorNombre: string
  facturaCompraId: string | null // null = pago a cuenta general del proveedor
  saldoPendiente?: number
  onClose: () => void
  onSaved: () => void
}

// Misma UI y mismo RPC compartido `registrarPagoProveedor` que usa Virikyna Local desde el
// detalle de una factura puntual (docs/04_modulos_y_funciones.md, módulo 7.1: "registra pagos —
// mismas acciones y misma función de sistema que usa el cajero desde Virikyna Local").
export function RegistrarPagoProveedorModal({
  proveedorId,
  proveedorNombre,
  facturaCompraId,
  saldoPendiente,
  onClose,
  onSaved,
}: Props) {
  const [monto, setMonto] = useState(saldoPendiente && saldoPendiente > 0 ? String(saldoPendiente) : '')
  const [formaPago, setFormaPago] = useState<FormaPagoEgreso>('efectivo')
  const [chequeNumero, setChequeNumero] = useState('')
  const [chequeFechaSalida, setChequeFechaSalida] = useState(fechaHoyISO())
  const [chequeFechaVencimiento, setChequeFechaVencimiento] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [dirty, setDirty] = useState(false)
  const [confirmCerrar, setConfirmCerrar] = useState(false)

  function pedirCierre() {
    if (dirty) {
      setConfirmCerrar(true)
    } else {
      onClose()
    }
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)

    const montoNum = Number(monto)
    if (!montoNum || montoNum <= 0) {
      setError('Ingresá un monto mayor a cero.')
      return
    }

    if (ES_CHEQUE(formaPago)) {
      if (!chequeNumero.trim()) {
        setError('Ingresá el número de cheque.')
        return
      }
      if (!chequeFechaSalida) {
        setError('Ingresá la fecha de salida del cheque.')
        return
      }
      if (!chequeFechaVencimiento) {
        setError('Ingresá la fecha de vencimiento del cheque.')
        return
      }
    }

    setSaving(true)
    const { error: dbError } = await registrarPagoProveedor(supabase, {
      proveedorId,
      facturaCompraId,
      monto: montoNum,
      formaPago,
      chequeNumero: ES_CHEQUE(formaPago) ? chequeNumero.trim() : null,
      chequeFechaSalida: ES_CHEQUE(formaPago) ? chequeFechaSalida : null,
      chequeFechaVencimiento: ES_CHEQUE(formaPago) ? chequeFechaVencimiento : null,
    })
    setSaving(false)

    if (dbError) {
      setError(friendlyError(dbError))
      return
    }
    onSaved()
  }

  return (
    <Modal title="Registrar pago a proveedor" onClose={pedirCierre} widthClassName="max-w-[460px]">
      <form onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        <p className="font-sans text-body-md text-ink-soft">
          Proveedor: <span className="text-ink">{proveedorNombre}</span>
        </p>
        {saldoPendiente !== undefined && (
          <p className="font-sans text-body-md text-ink-soft">
            Saldo pendiente de esta factura: <span className="text-ink">{formatCurrency(saldoPendiente)}</span>
          </p>
        )}

        <Field label="Monto">
          <input
            type="number"
            step="0.01"
            autoFocus
            value={monto}
            onChange={(e) => setMonto(e.target.value)}
            className={inputClass}
          />
        </Field>

        <Field label="Forma de pago">
          <select
            value={formaPago}
            onChange={(e) => setFormaPago(e.target.value as FormaPagoEgreso)}
            className={selectClass}
          >
            {FORMAS_PAGO.map((f) => (
              <option key={f} value={f}>
                {FORMA_PAGO_EGRESO_LABEL[f]}
              </option>
            ))}
          </select>
        </Field>

        {ES_CHEQUE(formaPago) && (
          <div className="flex flex-col gap-stack-sm">
            <Field label="Nro. de cheque">
              <input
                value={chequeNumero}
                onChange={(e) => setChequeNumero(e.target.value)}
                className={inputClass}
              />
            </Field>
            <div className="grid grid-cols-2 gap-stack-sm">
              <Field label="Fecha de salida">
                <input
                  type="date"
                  value={chequeFechaSalida}
                  onChange={(e) => setChequeFechaSalida(e.target.value)}
                  className={inputClass}
                />
              </Field>
              <Field label="Fecha de vencimiento">
                <input
                  type="date"
                  value={chequeFechaVencimiento}
                  onChange={(e) => setChequeFechaVencimiento(e.target.value)}
                  className={inputClass}
                />
              </Field>
            </div>
          </div>
        )}

        {error && <ErrorText>{error}</ErrorText>}

        <div className="flex justify-end gap-3">
          <button
            type="button"
            onClick={pedirCierre}
            className="rounded px-4 py-3 font-sans text-label-bold text-ink-soft hover:bg-bg"
          >
            Cancelar
          </button>
          <button
            type="submit"
            disabled={saving}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
          >
            {saving ? 'Guardando...' : 'Registrar pago'}
          </button>
        </div>
      </form>

      {confirmCerrar && (
        <ConfirmDialog
          title="Cerrar sin guardar"
          mensaje="Hay cambios sin guardar en este formulario. ¿Querés cerrar de todos modos?"
          confirmLabel="Cerrar sin guardar"
          onCancel={() => setConfirmCerrar(false)}
          onConfirm={onClose}
        />
      )}
    </Modal>
  )
}
