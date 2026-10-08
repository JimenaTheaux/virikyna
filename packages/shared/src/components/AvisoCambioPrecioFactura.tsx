import { formatCurrency } from '../../lib/format'
import type { CambioPrecioFactura } from '../../lib/precios'

// Debajo de un ítem de factura de compra vinculado a un producto: cómo queda su precio de venta al
// guardar (cargar_factura_compra pisa el costo con el precio unitario — ver cambiosPrecioFactura).
// Fila de planilla de escritorio (ItemFacturaRow) y tarjeta de celular de Virikyna Inventario.
export function AvisoCambioPrecioFactura({ cambio, className = '' }: { cambio?: CambioPrecioFactura; className?: string }) {
  if (!cambio) return null
  const texto =
    cambio.tipo === 'actualiza'
      ? `Actualiza precio de venta: ${formatCurrency(cambio.antes)} → ${formatCurrency(cambio.despues)}`
      : cambio.tipo === 'reemplaza_manual'
        ? // docs/34: la factura le pone costo y el precio deja de ser manual.
          `Precio manual ${formatCurrency(cambio.manual)} → calculado ${formatCurrency(cambio.despues)}`
        : cambio.tipo === 'sin_cambio_precio'
          ? `Actualiza el costo; el precio de venta sigue en ${formatCurrency(cambio.precio)}`
          : 'Este producto se repite más abajo: el costo lo define la última línea.'
  return <p className={`font-sans text-label-md text-ink-soft ${className}`}>{texto}</p>
}
