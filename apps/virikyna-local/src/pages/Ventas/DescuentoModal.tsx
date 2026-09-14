import { useState, type FormEvent } from 'react'
import { Modal } from '../../components/Modal'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, ErrorText, inputClass } from '../../components/FormField'

type Props = {
  valorActual: number
  onClose: () => void
  onAplicar: (porcentaje: number) => void
}

export function DescuentoModal({ valorActual, onClose, onAplicar }: Props) {
  const [valor, setValor] = useState(valorActual ? String(valorActual) : '')
  const [error, setError] = useState<string | null>(null)
  const [dirty, setDirty] = useState(false)
  const [confirmCerrar, setConfirmCerrar] = useState(false)

  function pedirCierre() {
    if (dirty) {
      setConfirmCerrar(true)
    } else {
      onClose()
    }
  }

  function handleSubmit(e: FormEvent) {
    e.preventDefault()
    const num = Number(valor) || 0
    if (num < 0 || num > 100) {
      setError('El descuento debe estar entre 0% y 100%.')
      return
    }
    onAplicar(num)
    onClose()
  }

  return (
    <Modal title="Aplicar descuento" onClose={pedirCierre} widthClassName="max-w-[360px]">
      <form onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        <Field label="Descuento sobre el total (%)">
          <input
            autoFocus
            type="number"
            min="0"
            max="100"
            step="0.01"
            value={valor}
            onChange={(e) => setValor(e.target.value)}
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
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white hover:bg-accent-dark"
          >
            Aplicar
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
