import { Modal } from './Modal'

type Props = {
  title: string
  mensaje: string
  confirmLabel?: string
  confirmando?: boolean
  onCancel: () => void
  onConfirm: () => void
}

// Mismo patrón en toda la app para cualquier acción destructiva (docs/08_estilos_y_diseno.md,
// sección 5): cancelar a la izquierda, acción destructiva a la derecha en `error`, siempre en
// esa posición — evita que un click apurado confirme algo pensando que era el botón de siempre.
export function ConfirmDialog({ title, mensaje, confirmLabel = 'Eliminar', confirmando, onCancel, onConfirm }: Props) {
  return (
    <Modal title={title} onClose={onCancel} widthClassName="max-w-[440px]">
      <div className="flex flex-col gap-stack-md">
        <p className="font-sans text-body-md text-ink">{mensaje}</p>
        <div className="flex justify-end gap-3">
          <button
            type="button"
            onClick={onCancel}
            className="rounded px-4 py-3 font-sans text-label-bold text-ink-soft hover:bg-bg"
          >
            Cancelar
          </button>
          <button
            type="button"
            onClick={onConfirm}
            disabled={confirmando}
            className="rounded border border-error px-4 py-3 font-sans text-label-bold text-error transition hover:bg-error hover:text-white disabled:opacity-60"
          >
            {confirmando ? 'Confirmando...' : confirmLabel}
          </button>
        </div>
      </div>
    </Modal>
  )
}
