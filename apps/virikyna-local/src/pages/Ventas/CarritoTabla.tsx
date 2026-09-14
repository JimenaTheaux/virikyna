import { formatCurrency } from '@virikyna/shared'
import type { CartItem } from './types'

type Props = {
  items: CartItem[]
  onCantidadChange: (productoId: string, cantidad: number) => void
  onQuitar: (productoId: string) => void
}

export function CarritoTabla({ items, onCantidadChange, onQuitar }: Props) {
  const unidades = items.reduce((acc, it) => acc + it.cantidad, 0)
  const subtotal = items.reduce((acc, it) => acc + it.cantidad * it.precioUnitario, 0)

  return (
    <div className="mt-stack-md flex flex-1 flex-col overflow-hidden rounded-lg border border-line">
      <div className="flex border-b border-line bg-bg px-4 py-3 font-sans text-label-bold text-ink-soft">
        <span className="w-28">Código</span>
        <span className="flex-1">Producto</span>
        <span className="w-28 text-center">Cant.</span>
        <span className="w-32 text-right">Importe</span>
        <span className="w-8" />
      </div>
      <div className="flex-1 overflow-auto">
        {items.length === 0 && (
          <p className="px-4 py-8 text-center font-sans text-body-md text-ink-soft">
            El carrito está vacío. Buscá un producto para empezar.
          </p>
        )}
        {items.map((item) => (
          <div
            key={item.productoId}
            className="flex min-h-[56px] items-center border-b border-line px-4 py-2 last:border-0"
          >
            <span className="w-28 truncate font-sans text-label-md text-ink-soft">{item.codigo || '—'}</span>
            <span className="flex-1 font-sans text-body-lg text-ink">{item.nombre}</span>
            <span className="flex w-28 items-center justify-center gap-1">
              <button
                type="button"
                onClick={() => onCantidadChange(item.productoId, Math.max(0, item.cantidad - 1))}
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
                className="w-12 rounded border border-line bg-surface py-1 text-center font-sans text-body-md text-ink outline-none focus:border-accent"
              />
              <button
                type="button"
                onClick={() => onCantidadChange(item.productoId, item.cantidad + 1)}
                className="h-7 w-7 rounded font-sans text-label-bold text-ink-soft hover:bg-bg"
              >
                +
              </button>
            </span>
            <span className="w-32 text-right font-sans text-label-bold text-ink">
              {formatCurrency(item.cantidad * item.precioUnitario)}
            </span>
            <button
              type="button"
              onClick={() => onQuitar(item.productoId)}
              aria-label={`Quitar ${item.nombre}`}
              className="w-8 text-center font-sans text-body-md text-error hover:opacity-70"
            >
              ✕
            </button>
          </div>
        ))}
      </div>
      <div className="flex justify-between border-t border-line bg-bg px-4 py-3 font-sans text-body-md text-ink-soft">
        <span>
          Unidades: <strong className="text-ink">{unidades}</strong>
        </span>
        <span>
          Subtotal: <strong className="text-ink">{formatCurrency(subtotal)}</strong>
        </span>
      </div>
    </div>
  )
}
