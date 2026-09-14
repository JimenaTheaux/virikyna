import { useState, type FormEvent } from 'react'
import { friendlyError } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { Modal } from '../../components/Modal'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, ErrorText, inputClass } from '../../components/FormField'

type Props = {
  autorId: string
  onClose: () => void
  onSaved: () => void
}

export function NuevaNotaModal({ autorId, onClose, onSaved }: Props) {
  const [mensaje, setMensaje] = useState('')
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

    const mensajeLimpio = mensaje.trim()
    if (!mensajeLimpio) {
      setError('Escribí un mensaje para la nota.')
      return
    }

    setSaving(true)
    // origen fijo 'gestion': una nota creada desde Virikyna Gestión siempre es de este origen
    // (docs/06_estructura_de_datos (1).md sección 15) — no hay selector, no depende del rol.
    const { error: dbError } = await supabase
      .from('notas_internas')
      .insert({ mensaje: mensajeLimpio, autor_id: autorId, origen: 'gestion' })
    setSaving(false)

    if (dbError) {
      setError(friendlyError(dbError))
      return
    }
    onSaved()
  }

  return (
    <Modal title="Nueva nota" onClose={pedirCierre} widthClassName="max-w-[480px]">
      <form onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        <Field label="Mensaje">
          <textarea
            autoFocus
            rows={5}
            value={mensaje}
            onChange={(e) => setMensaje(e.target.value)}
            className={`${inputClass} resize-none`}
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
            {saving ? 'Guardando...' : 'Guardar'}
          </button>
        </div>
      </form>

      {confirmCerrar && (
        <ConfirmDialog
          title="Cerrar sin guardar"
          mensaje="Hay una nota sin guardar. ¿Querés cerrar de todos modos?"
          confirmLabel="Cerrar sin guardar"
          onCancel={() => setConfirmCerrar(false)}
          onConfirm={onClose}
        />
      )}
    </Modal>
  )
}
