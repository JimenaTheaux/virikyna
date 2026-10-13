import { formatCurrency, ProductoLinea } from '@virikyna/shared'
import type { CartItem } from './types'

type Props = {
  items: CartItem[]
  onCantidadChange: (productoId: string, cantidad: number) => void
  onQuitar: (productoId: string) => void
  // Después de −, + o ✕ (no al tipear la cantidad): Ventas devuelve el foco al buscador.
  onBotonUsado?: () => void
}

// Producto (ProductoLinea: nombre y precio unitario arriba; abajo, chico, marca, código y descripción)
// | Cant. | Importe. Es la lista que el cajero lee mientras cobra: el renglón principal sigue en
// body-lg (docs/08 §5).
export function CarritoTabla({ items, onCantidadChange, onQuitar, onBotonUsado }: Props) {
  const unidades = items.reduce((acc, it) => acc + it.cantidad, 0)
  const subtotal = items.reduce((acc, it) => acc + it.cantidad * it.precioUnitario, 0)

  return (
    <div className="mt-stack-md flex flex-1 flex-col overflow-hidden rounded-lg border border-line">
      <div className="flex items-center gap-3 border-b border-line bg-bg px-4 py-2 font-sans text-label-bold text-ink-soft">
        <span className="min-w-0 flex-1">Producto</span>
        <span className="w-28 text-center">Cant.</span>
        <span className="w-32 text-right">Importe</span>
        <span className="w-8" />
      </div>
      <div className="flex-1 overflow-auto">
        {items.length === 0 && (
          <p className="px-4 py-6 text-center font-sans text-body-md text-ink-soft">
            El carrito está vacío. Buscá un producto para empezar.
          </p>
        )}
        {items.map((item) => {
          return (
            <div
              key={item.productoId}
              className="flex min-h-[44px] items-center gap-3 border-b border-line px-4 py-1.5 last:border-0"
            >
              <div className="min-w-0 flex-1">
                <ProductoLinea
                  producto={{ nombre: item.nombre, marca: item.marca, descripcion: item.descripcion, codigo_barras: item.codigo }}
                  precio={item.precioUnitario}
                  tamano="lg"
                />
              </div>
              <span className="flex w-28 items-center justify-center gap-1">
                <button
                  type="button"
                  onClick={() => {
                    onCantidadChange(item.productoId, Math.max(0, item.cantidad - 1))
                    onBotonUsado?.()
                  }}
                  aria-label={`Restar uno de ${item.nombre}`}
                  className="h-7 w-7 rounded font-sans text-label-bold text-ink-soft hover:bg-bg"
                >
                  −
                </button>
                <input
                  type="number"
                  min="0"
                  step="1"
                  value={item.cantidad}
                  onChange={(e) => onCantidadChange(item.productoId, Number(e.target.value) || 0)}
                  aria-label={`Cantidad de ${item.nombre}`}
                  className="w-12 rounded border border-line bg-surface py-1 text-center font-sans text-body-md tabular-nums text-ink outline-none focus:border-accent"
                />
                <button
                  type="button"
                  onClick={() => {
                    onCantidadChange(item.productoId, item.cantidad + 1)
                    onBotonUsado?.()
                  }}
                  aria-label={`Sumar uno de ${item.nombre}`}
                  className="h-7 w-7 rounded font-sans text-label-bold text-ink-soft hover:bg-bg"
                >
                  +
                </button>
              </span>
              <span className="w-32 text-right font-sans text-label-bold tabular-nums text-ink">
                {formatCurrency(item.cantidad * item.precioUnitario)}
              </span>
              <button
                type="button"
                onClick={() => {
                  onQuitar(item.productoId)
                  onBotonUsado?.()
                }}
                aria-label={`Quitar ${item.nombre}`}
                className="w-8 text-center font-sans text-body-md text-error hover:opacity-70"
              >
                ✕
              </button>
            </div>
          )
        })}
      </div>
      <div className="flex justify-between border-t border-line bg-bg px-4 py-2 font-sans text-body-md text-ink-soft">
        <span>
          Unidades: <strong className="text-ink">{unidades}</strong>
        </span>
        <span>
          Subtotal: <strong className="tabular-nums text-ink">{formatCurrency(subtotal)}</strong>
        </span>
      </div>
    </div>
  )
}
