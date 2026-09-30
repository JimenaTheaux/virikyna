type Variant = 'amber' | 'green' | 'red' | 'neutral'

const VARIANT_CLASSES: Record<Variant, string> = {
  amber: 'bg-badge-amber-bg text-badge-amber-text',
  green: 'bg-badge-green-bg text-badge-green-text',
  red: 'bg-badge-red-bg text-error',
  neutral: 'bg-badge-neutral-bg text-ink-soft',
}

type Props = {
  children: React.ReactNode
  // ámbar = pendiente/atención, verde = ok/completo, rojo = error/anulado, neutro = inactivo/sin estado.
  variant: Variant
}

// Badge de estado para tablas de listado (docs/08_estilos_y_diseno.md, sección 5.2).
export function EstadoBadge({ children, variant }: Props) {
  return (
    <span
      className={`inline-block whitespace-nowrap rounded-[6px] px-2 py-0.5 font-sans text-table-row font-semibold ${VARIANT_CLASSES[variant]}`}
    >
      {children}
    </span>
  )
}
