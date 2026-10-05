import { formatAjuste, formatCurrency } from '../../lib/format'
import type { PrecioProducto } from '../../lib/precios'

// Debajo del precio de venta de los formularios de producto (Local, Gestión, Inventario): cuánto
// dio la fórmula exacta y cuánto se ajustó al redondear a la centena. Nada si no hubo ajuste.
export function NotaRedondeoPrecio({ precio, className = '' }: { precio: PrecioProducto; className?: string }) {
  if (precio.ajuste === 0) return null
  return (
    <p className={`font-sans text-label-md text-ink-soft ${className}`}>
      Calculado {formatCurrency(precio.calculado)} → redondeado {formatCurrency(precio.venta)} (
      {formatAjuste(precio.ajuste)})
    </p>
  )
}
