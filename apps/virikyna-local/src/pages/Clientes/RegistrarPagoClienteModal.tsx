import { useState, type FormEvent } from 'react'
import type { Cliente, FormaPagoVenta, Venta } from '@virikyna/shared'
import { formatCurrency, mensajeErrorGuardado } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { Modal } from '../../components/Modal'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, ErrorText, inputClass, selectClass } from '../../components/FormField'
import { FORMA_PAGO_LABEL } from '../../lib/comprobante'

type Props = {
  cliente: Cliente
  ventasCuentaCorriente: Pick<Venta, 'id' | 'numero' | 'total'>[]
  onClose: () => void
  onSaved: () => void
}

// Cobro de cuenta corriente: siempre es plata real entrando por un solo medio, nunca
// "cuenta_corriente" ni "combinado" (docs/06_estructura_de_datos.md, constraint chk_pago_cliente_forma_pago).
const FORMAS_PAGO_COBRO = (Object.keys(FORMA_PAGO_LABEL) as FormaPagoVenta[]).filter(
  (fp) => fp !== 'cuenta_corriente' && fp !== 'combinado',
)

export function RegistrarPagoClienteModal({ cliente, ventasCuentaCorriente, onClose, onSaved }: Props) {
  const [monto, setMonto] = useState('')
  const [formaPago, setFormaPago] = useState<FormaPagoVenta>('efectivo')
  const [ventaId, setVentaId] = useState('') // '' = a cuenta general, sin venta puntual
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

    setSaving(true)
    const { error: rpcError, status } = await supabase.rpc('registrar_pago_cliente', {
      p_cliente_id: cliente.id,
      p_venta_id: ventaId || null,
      p_monto: montoNum,
      p_forma_pago: formaPago,
    })
    setSaving(false)

    if (rpcError) {
      setError(mensajeErrorGuardado(rpcError, status, 'registrar el cobro', 'los datos siguen acá'))
      return
    }
    onSaved()
  }

  return (
    <Modal
      title={`Cobrar — ${cliente.razon_social ?? cliente.nombre_fantasia}`}
      onClose={pedirCierre}
      widthClassName="max-w-[480px]"
    >
      <form onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        <Field label="Monto">
          <input
            type="number"
            min="0"
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
            onChange={(e) => setFormaPago(e.target.value as FormaPagoVenta)}
            className={selectClass}
          >
            {FORMAS_PAGO_COBRO.map((fp) => (
              <option key={fp} value={fp}>
                {FORMA_PAGO_LABEL[fp]}
              </option>
            ))}
          </select>
        </Field>

        <Field label="Aplicar a" hint="Elegí a qué venta corresponde este pago, o dejalo a cuenta general.">
          <select value={ventaId} onChange={(e) => setVentaId(e.target.value)} className={selectClass}>
            <option value="">Cuenta general (sin venta puntual)</option>
            {ventasCuentaCorriente.map((v) => (
              <option key={v.id} value={v.id}>
                Venta N° {v.numero} — {formatCurrency(v.total)}
              </option>
            ))}
          </select>
        </Field>

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
            {saving ? 'Guardando...' : 'Registrar cobro'}
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
