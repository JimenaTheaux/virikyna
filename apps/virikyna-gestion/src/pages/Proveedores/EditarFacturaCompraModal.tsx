import { useState, type FormEvent } from 'react'
import type { FacturaCompraSaldo, FormaPagoCompra, TipoComprobanteCompra } from '@virikyna/shared'
import { editarFacturaCompra, friendlyError } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { Modal } from '../../components/Modal'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, ErrorText, inputClass, selectClass } from '../../components/FormField'

const TIPOS: { value: TipoComprobanteCompra; label: string }[] = [
  { value: 'factura', label: 'Factura' },
  { value: 'remito', label: 'Remito' },
  { value: 'cupon', label: 'Cupón (no facturado)' },
  { value: 'nota_credito', label: 'Nota de crédito' },
  { value: 'nota_debito', label: 'Nota de débito' },
]

type Props = {
  factura: FacturaCompraSaldo
  onClose: () => void
  onSaved: () => void
}

// editar_factura_compra (docs/06_estructura_de_datos.md, RPC 10) — exclusivo Virikyna Gestión,
// solo campos descriptivos. Si el error está en ítems o montos, la corrección real es anular la
// factura y recargarla de nuevo — este formulario ni siquiera ofrece esos campos.
export function EditarFacturaCompraModal({ factura, onClose, onSaved }: Props) {
  const [tipoComprobante, setTipoComprobante] = useState<TipoComprobanteCompra>(factura.tipo_comprobante)
  const [numeroComprobante, setNumeroComprobante] = useState(factura.numero_comprobante ?? '')
  const [fechaComprobante, setFechaComprobante] = useState(factura.fecha_comprobante)
  const [formaPago, setFormaPago] = useState<FormaPagoCompra>(factura.forma_pago)
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

    if (!fechaComprobante) {
      setError('La fecha del comprobante es obligatoria.')
      return
    }

    setSaving(true)
    const { error: rpcError } = await editarFacturaCompra(supabase, {
      facturaId: factura.id,
      tipoComprobante,
      numeroComprobante: numeroComprobante.trim() || null,
      fechaComprobante,
      formaPago,
    })
    setSaving(false)

    if (rpcError) {
      setError(friendlyError(rpcError))
      return
    }
    onSaved()
  }

  return (
    <Modal title="Editar factura de compra" onClose={pedirCierre} widthClassName="max-w-[480px]">
      <form onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        <p className="font-sans text-body-md text-ink-soft">
          Solo datos descriptivos — ítems y montos no se editan acá. Queda registrado en el
          Historial con el antes y el después.
        </p>

        <Field label="Tipo de comprobante">
          <select
            value={tipoComprobante}
            onChange={(e) => setTipoComprobante(e.target.value as TipoComprobanteCompra)}
            className={selectClass}
          >
            {TIPOS.map((t) => (
              <option key={t.value} value={t.value}>
                {t.label}
              </option>
            ))}
          </select>
        </Field>

        <Field label="Número de comprobante">
          <input
            value={numeroComprobante}
            onChange={(e) => setNumeroComprobante(e.target.value)}
            className={inputClass}
          />
        </Field>

        <Field label="Fecha del comprobante">
          <input
            type="date"
            value={fechaComprobante}
            onChange={(e) => setFechaComprobante(e.target.value)}
            className={inputClass}
          />
        </Field>

        <Field label="Forma de pago">
          <select
            value={formaPago}
            onChange={(e) => setFormaPago(e.target.value as FormaPagoCompra)}
            className={selectClass}
          >
            <option value="contado">Contado</option>
            <option value="cuenta_corriente">Cuenta corriente</option>
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
            {saving ? 'Guardando...' : 'Guardar cambios'}
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
