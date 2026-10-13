import type { ReactNode } from 'react'
import { formatCurrency } from '../../lib/format'
import { etiquetaAccesibleProducto, lineaSecundaria, type ProductoTexto } from '../../lib/productoTexto'

// 'lg': buscador y carrito de Ventas (la lista que el cajero lee mientras cobra, body-lg).
// 'md': listas compactas (devolución, dropdown de factura de compra). 'card': tarjetas de celular.
type Tamano = 'lg' | 'md' | 'card'

const NOMBRE: Record<Tamano, string> = {
  lg: 'font-sans text-body-lg text-ink',
  md: 'font-sans text-body-md text-ink',
  card: 'font-sans text-label-bold text-ink',
}
const PRECIO: Record<Tamano, string> = {
  lg: 'font-sans text-label-bold text-accent-darker',
  md: 'font-sans text-label-bold text-accent-darker',
  card: 'font-display text-headline-md text-accent-darker',
}

type Props = {
  producto: ProductoTexto
  // undefined = sin precio; null = el producto no tiene (ej. sin costo cargado): se muestra "—".
  precio?: number | null
  // Texto chico antes del precio cuando no es el de venta (ej. "Costo" en la factura de compra).
  etiquetaPrecio?: string
  // Algo más en el renglón 1, a la derecha del precio (ej. un badge).
  slotDerecha?: ReactNode
  // Tercer renglón, chico (ej. stock + estado en las tarjetas de Inventario).
  children?: ReactNode
  tamano?: Tamano
}

// Producto en una lista — un solo formato para Ventas, Devolución, factura de compra e Inventario:
//   NOMBRE (salto de línea si no entra, nunca "…") ··········· PRECIO
//   MARCA    código    Descripción        ← chico y más claro (ink-soft: contraste AA en todos los
//                                            fondos de lista); partes vacías se omiten
// Para lectores de pantalla el bloque se anuncia como "NOMBRE, MARCA, $ precio" (si va dentro de un
// botón, ese es también el nombre del botón).
export function ProductoLinea({ producto, precio, etiquetaPrecio, slotDerecha, children, tamano = 'md' }: Props) {
  const secundaria = lineaSecundaria(producto)
  const conPrecio = precio !== undefined
  return (
    <div role="group" aria-label={etiquetaAccesibleProducto(producto, precio, etiquetaPrecio)} className="min-w-0">
      <div className="flex items-start justify-between gap-3">
        <span className={`min-w-0 [overflow-wrap:anywhere] ${NOMBRE[tamano]}`}>{producto.nombre}</span>
        {(conPrecio || slotDerecha) && (
          <span className="flex flex-shrink-0 items-start gap-2">
            {conPrecio && (
              <span className={`whitespace-nowrap tabular-nums ${PRECIO[tamano]}`}>
                {etiquetaPrecio && (
                  <span className="mr-1 font-sans text-label-md font-medium text-ink-soft">{etiquetaPrecio}</span>
                )}
                {precio === null ? '—' : formatCurrency(precio)}
              </span>
            )}
            {slotDerecha}
          </span>
        )}
      </div>
      {secundaria.length > 0 && (
        <div className="mt-0.5 flex flex-wrap gap-x-4 font-sans text-label-md text-ink-soft">
          {secundaria.map((parte, i) => (
            <span key={i} className="min-w-0 [overflow-wrap:anywhere]">
              {parte}
            </span>
          ))}
        </div>
      )}
      {children && <div className="mt-1 font-sans text-label-md text-ink-soft">{children}</div>}
    </div>
  )
}
