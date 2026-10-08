import { formatAjuste, formatCurrency } from '../../lib/format'
import type { PrecioProducto } from '../../lib/precios'

// Debajo del precio de venta de los formularios de producto (Local, Gestión, Inventario): cuánto
// dio la fórmula exacta y cuánto se ajustó con el redondeo escalonado (redondearPrecioVenta,
// docs/30 — el ajuste puede llegar a ±$500 en precios de $10.000 o más). Nada si no hubo ajuste.
export function NotaRedondeoPrecio({ precio, className = '' }: { precio: PrecioProducto; className?: string }) {
  // Con precio manual (o sin costo) no hay redondeo: ajuste 0.
  if (precio.ajuste === 0 || precio.calculado === null) return null
  return (
    <p className={`font-sans text-label-md text-ink-soft ${className}`}>
      Calculado {formatCurrency(precio.calculado)} → redondeado {formatCurrency(precio.venta)} (
      {formatAjuste(precio.ajuste)})
    </p>
  )
}
