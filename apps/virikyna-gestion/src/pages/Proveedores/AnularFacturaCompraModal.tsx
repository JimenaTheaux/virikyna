import { useState, type FormEvent } from 'react'
import type { FacturaCompraSaldo } from '@virikyna/shared'
import { anularFacturaCompra, formatCurrency, friendlyError } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { Modal } from '../../components/Modal'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, ErrorText, inputClass } from '../../components/FormField'

type Props = {
  factura: FacturaCompraSaldo
  onClose: () => void
  onAnulada: () => void
}

// anular_factura_compra (docs/06_estructura_de_datos.md, RPC 11) — exclusivo Virikyna Gestión.
// Revierte el stock que la carga original había sumado y marca la factura como anulada. Si ya
// tiene pagos registrados, el RPC rechaza la anulación con su propio mensaje — se muestra tal
// cual acá (friendlyError no lo reinterpreta), nunca un mensaje genérico inventado en el cliente.
export function AnularFacturaCompraModal({ factura, onClose, onAnulada }: Props) {
  const [motivo, setMotivo] = useState('')
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

    if (!motivo.trim()) {
      setError('El motivo es obligatorio para anular una factura de compra.')
      return
    }

    setSaving(true)
    const { error: rpcError } = await anularFacturaCompra(supabase, factura.id, motivo.trim())
    setSaving(false)

    if (rpcError) {
      setError(friendlyError(rpcError))
      return
    }
    onAnulada()
  }

  return (
    <Modal title="Anular factura de compra" onClose={pedirCierre} widthClassName="max-w-[480px]">
      <form onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        <div className="rounded border border-error/40 bg-error/5 p-4">
          <p className="font-sans text-body-md text-ink">
            El stock que esta factura había sumado se revierte. No se puede anular si ya tiene
            pagos registrados — resolvé esos pagos antes.
          </p>
          <p className="mt-2 font-sans text-label-bold text-ink">Total: {formatCurrency(factura.total)}</p>
        </div>

        <Field label="Motivo de la anulación">
          <input autoFocus value={motivo} onChange={(e) => setMotivo(e.target.value)} className={inputClass} />
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
            className="rounded bg-error px-4 py-3 font-sans text-label-bold text-white transition hover:bg-error/90 disabled:opacity-60"
          >
            {saving ? 'Anulando...' : 'Anular factura'}
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
