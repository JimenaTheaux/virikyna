import { StickyNote } from 'lucide-react'

// Observaciones del proveedor (docs/41): la ayuda memoria que la dueña carga en el formulario del
// proveedor. Debajo del selector de proveedor al cargar una compra (escritorio y celular) y en la
// cabecera de su cuenta corriente. Nada si no hay texto. Ámbar = atención (docs/08 §5.2).
export function ObservacionesProveedor({
  observaciones,
  className = '',
}: {
  observaciones?: string | null
  className?: string
}) {
  if (!observaciones?.trim()) return null
  return (
    <aside
      aria-label="Observaciones del proveedor"
      className={`flex gap-2 rounded border border-badge-amber-text/40 border-l-4 border-l-badge-amber-text bg-badge-amber-bg px-3 py-2 ${className}`}
    >
      <StickyNote aria-hidden size={18} strokeWidth={2} className="mt-px shrink-0 text-badge-amber-text" />
      <div className="min-w-0">
        <p className="font-sans text-label-bold text-badge-amber-text">Observaciones</p>
        <p className="whitespace-pre-wrap font-sans text-body-md text-ink [overflow-wrap:anywhere]">{observaciones}</p>
      </div>
    </aside>
  )
}
