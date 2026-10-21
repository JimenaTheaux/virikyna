import type { TipoCompra } from '../../types/database'
import { TIPO_COMPRA_LABEL } from '../../lib/facturasCompra'

type Variant = 'amber' | 'green' | 'red' | 'neutral' | 'violet'

const VARIANT_CLASSES: Record<Variant, string> = {
  amber: 'bg-badge-amber-bg text-badge-amber-text',
  green: 'bg-badge-green-bg text-badge-green-text',
  red: 'bg-badge-red-bg text-error',
  neutral: 'bg-badge-neutral-bg text-ink-soft',
  violet: 'bg-badge-violet-bg text-badge-violet-text',
}

type Props = {
  children: React.ReactNode
  // ámbar = pendiente/atención, verde = ok/completo, rojo = error/anulado, neutro = inactivo/sin estado.
  // violeta = no es un estado: marca de tipo (servicios, docs/53), para que no se confunda con ninguno.
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

// Chip de tipo de compra (docs/53): solo se marca lo distinto (servicios); artículos es lo de
// siempre y no lleva nada, así los listados no se llenan de chips.
// `className` va en el contenedor (ej. el margen contra el texto de al lado): sin chip no queda nada.
export function ChipTipoCompra({ tipo, className = '' }: { tipo: TipoCompra | null | undefined; className?: string }) {
  if (tipo !== 'servicios') return null
  return (
    <span className={className}>
      <EstadoBadge variant="violet">{TIPO_COMPRA_LABEL.servicios}</EstadoBadge>
    </span>
  )
}
