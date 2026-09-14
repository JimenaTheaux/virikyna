type Props = {
  title: string
  mensaje: string
  confirmLabel?: string
  onCancel: () => void
  onConfirm: () => void
}

// Chico y centrado a propósito, a diferencia de BottomSheet (pantalla completa): es solo una
// confirmación sí/no, no un formulario, así que no necesita ocupar toda la pantalla. Sin cierre
// por click afuera, mismo criterio que BottomSheet — un toque perdido no debe descartar la
// confirmación. z-[70] para quedar por encima tanto de BottomSheet (z-50) como de BarcodeScanner
// (z-[60]), que puede estar montado debajo cuando se pide cerrar un formulario con el escáner abierto.
export function ConfirmDialog({ title, mensaje, confirmLabel = 'Confirmar', onCancel, onConfirm }: Props) {
  return (
    <div className="fixed inset-0 z-[70] flex items-center justify-center bg-ink/40 p-stack-md">
      <div className="w-full max-w-[400px] rounded-lg bg-surface p-card shadow-sm">
        <h2 className="font-display text-headline-md text-accent-darker">{title}</h2>
        <p className="mt-2 font-sans text-body-md text-ink">{mensaje}</p>
        <div className="mt-stack-md flex justify-end gap-3">
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
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white hover:bg-accent-dark"
          >
            {confirmLabel}
          </button>
        </div>
      </div>
    </div>
  )
}
