import { useState, type FormEvent } from 'react'
import { friendlyError } from '@virikyna/shared'
import { editarMovimientoCuenta } from '../../lib/historial'
import { TIPO_MOVIMIENTO_CUENTA_LABEL } from '../../lib/caja'
import { Modal } from '../../components/Modal'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, ErrorText, inputClass } from '../../components/FormField'
import type { MovimientoCuentaConUsuario } from './types'

type Props = {
  movimiento: MovimientoCuentaConUsuario
  onClose: () => void
  onSaved: () => void
}

// editar_movimiento_cuenta (docs/06 sección 12) nunca pisa la fila original: anula con un
// contra-asiento e inserta la versión corregida, ambas visibles en el Historial. El signo del
// monto lo decide el tipo original (egreso = negativo) — acá el usuario solo ve el valor absoluto.
export function EditarMovimientoModal({ movimiento, onClose, onSaved }: Props) {
  const [monto, setMonto] = useState(String(Math.abs(movimiento.monto)))
  const [descripcion, setDescripcion] = useState(movimiento.descripcion ?? '')
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

    const montoNum = Number(monto)
    if (!montoNum || montoNum <= 0) {
      setError('Ingresá un monto mayor a cero.')
      return
    }
    if (!descripcion.trim()) {
      setError('La descripción es obligatoria.')
      return
    }
    if (!motivo.trim()) {
      setError('Contá el motivo de la corrección.')
      return
    }

    const montoConSigno = movimiento.tipo === 'egreso' ? -Math.abs(montoNum) : Math.abs(montoNum)

    setSaving(true)
    const { error: rpcError } = await editarMovimientoCuenta(
      movimiento.id,
      montoConSigno,
      descripcion.trim(),
      motivo.trim(),
    )
    setSaving(false)

    if (rpcError) {
      setError(friendlyError(rpcError))
      return
    }
    onSaved()
  }

  return (
    <Modal title={`Editar ${TIPO_MOVIMIENTO_CUENTA_LABEL[movimiento.tipo].toLowerCase()}`} onClose={pedirCierre} widthClassName="max-w-[480px]">
      <form onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        <p className="font-sans text-body-md text-ink-soft">
          Esto no pisa el movimiento original — genera un contra-asiento y una versión corregida.
          Ambos quedan visibles en el Historial.
        </p>

        <Field label="Monto">
          <input
            autoFocus
            type="number"
            step="0.01"
            value={monto}
            onChange={(e) => setMonto(e.target.value)}
            className={inputClass}
          />
        </Field>

        <Field label="Descripción">
          <input value={descripcion} onChange={(e) => setDescripcion(e.target.value)} className={inputClass} />
        </Field>

        <Field label="Motivo de la corrección">
          <input value={motivo} onChange={(e) => setMotivo(e.target.value)} className={inputClass} />
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
            {saving ? 'Guardando...' : 'Guardar corrección'}
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
