import { useState } from 'react'
import { formatCurrency } from '../../lib/format'
import { formatCantidad } from '../../lib/cargaInicial'
import { nombreItemVendido } from '../../lib/productoTexto'
import { SELECT_ITEMS_COMPROBANTE, type VentaItemComprobanteRow } from '../../lib/comprobante'

// Renglón de ítems bajo cada venta en los listados (Ventas del día, Facturación de Local y Gestión):
// "2× PRODUCTO · 1× PRODUCTO" en una línea, "+N más" pasado el tercero; click en la fila despliega la
// lista completa con importes. Los ítems vienen embebidos en la misma consulta de ventas, con el
// mismo select que el comprobante: "Ver detalle" no los vuelve a pedir.

// Para sumar al select de `ventas`: `*, …, ${SELECT_ITEMS_VENTA_EMBEBIDOS}`.
export const SELECT_ITEMS_VENTA_EMBEBIDOS = `items:venta_items(${SELECT_ITEMS_COMPROBANTE})`

export type ConItemsVenta = { items: VentaItemComprobanteRow[] }

// Ítems que entran en el renglón resumen antes del "+N más" (promedio real: 1,3 por ticket).
const ITEMS_EN_RESUMEN = 3

// Cada venta son dos <tr> (datos + renglón de ítems). Las celdas cortas que no deben estirar la
// primera fila (checkbox, estado, ⋮ de 26px) abarcan las dos con rowSpan: ~56px por venta.
export function clasesFilaConItems(conItems: boolean) {
  return {
    celda: conItems ? 'px-3 pb-0 pt-2.5' : 'px-3 py-2.5',
    celdaDoble: conItems ? 'px-3 pt-2 align-top' : 'px-3 py-2.5',
    rowSpan: conItems ? 2 : undefined,
  }
}

export function useVentasExpandidas() {
  const [expandidas, setExpandidas] = useState<Set<string>>(new Set())
  function toggle(id: string) {
    setExpandidas((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }
  return { expandidas, toggle }
}

function nombreCorto(it: VentaItemComprobanteRow): string {
  return it.producto_nombre ?? it.producto?.nombre ?? 'Producto'
}

type Props = {
  items: VentaItemComprobanteRow[]
  numero: number
  expandida: boolean
  onToggle: () => void
  // Columnas que ocupa el renglón: las de la tabla menos las que van con rowSpan.
  colSpan: number
  // Franja alternada de la venta (las dos filas comparten color).
  className?: string
}

export function FilaItemsVenta({ items, numero, expandida, onToggle, colSpan, className = '' }: Props) {
  const ocultos = items.length - ITEMS_EN_RESUMEN
  return (
    <tr onClick={onToggle} className={`cursor-pointer border-b border-table-divider ${className}`}>
      <td colSpan={colSpan} className="px-3 pb-2.5 pt-0">
        <button
          type="button"
          aria-expanded={expandida}
          aria-label={`${expandida ? 'Ocultar' : 'Ver'} ítems de la venta N° ${numero}`}
          onClick={(e) => {
            e.stopPropagation()
            onToggle()
          }}
          className="block w-full rounded-sm text-left font-sans text-label-md text-ink-soft focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
        >
          {expandida ? (
            <ul className="flex max-w-2xl flex-col gap-0.5 py-0.5">
              {items.map((it, j) => (
                <li key={j} className="flex justify-between gap-stack-md">
                  <span className="min-w-0 [overflow-wrap:anywhere]">
                    {formatCantidad(Number(it.cantidad))}× {nombreItemVendido(it, it.producto)}
                  </span>
                  <span className="whitespace-nowrap">{formatCurrency(Number(it.importe))}</span>
                </li>
              ))}
            </ul>
          ) : (
            <span className="flex min-w-0 gap-1">
              <span className="min-w-0 truncate">
                {items
                  .slice(0, ITEMS_EN_RESUMEN)
                  .map((it) => `${formatCantidad(Number(it.cantidad))}× ${nombreCorto(it)}`)
                  .join(' · ')}
              </span>
              {ocultos > 0 && <span className="shrink-0">· +{ocultos} más</span>}
            </span>
          )}
        </button>
      </td>
    </tr>
  )
}
