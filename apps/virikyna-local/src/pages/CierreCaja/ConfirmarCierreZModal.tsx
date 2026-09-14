import { useState, type FormEvent } from 'react'
import { Modal } from '../../components/Modal'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, ErrorText, inputClass } from '../../components/FormField'

type Props = {
  onClose: () => void
  onConfirmar: (efectivoContado: number) => Promise<void>
}

export function ConfirmarCierreZModal({ onClose, onConfirmar }: Props) {
  const [efectivoContado, setEfectivoContado] = useState('')
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

    if (efectivoContado.trim() === '' || Number.isNaN(Number(efectivoContado))) {
      setError('Contá el efectivo en caja e ingresá el monto.')
      return
    }

    setSaving(true)
    try {
      await onConfirmar(Number(efectivoContado))
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Ocurrió un error inesperado.')
      setSaving(false)
    }
  }

  return (
    <Modal title="Cierre Z — Cierre del día" onClose={pedirCierre} widthClassName="max-w-[460px]">
      <form onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        <p className="rounded bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">
          Es el cierre único del día. Una vez validado por un administrador no se puede editar ni revertir —
          solo admite una nota de corrección aparte.
        </p>

        <Field label="Efectivo contado en caja">
          <input
            type="number"
            step="0.01"
            autoFocus
            value={efectivoContado}
            onChange={(e) => setEfectivoContado(e.target.value)}
            className={inputClass}
          />
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
            {saving ? 'Cerrando el día...' : 'Confirmar Cierre Z'}
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
