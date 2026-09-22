import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Producto, StockUbicacion } from '../../types/database'

export type ProductoStockBajo = {
  id: string
  nombre: string
  stockMinimo: number
  stockTotal: number
}

type ProductoConStock = Pick<Producto, 'id' | 'nombre' | 'stock_minimo'> & {
  stock_ubicaciones: Pick<StockUbicacion, 'cantidad'>[]
}

// Stock bajo = suma de stock en todas las ubicaciones <= stock_minimo del producto (solo activos).
export async function fetchProductosStockBajo(
  supabase: SupabaseClient,
): Promise<{ data: ProductoStockBajo[]; error: unknown }> {
  const { data, error } = await supabase
    .from('productos')
    .select('id, nombre, stock_minimo, stock_ubicaciones(cantidad)')
    .eq('estado', 'activo')

  if (error || !data) return { data: [], error }

  const bajos = (data as unknown as ProductoConStock[])
    .map((producto) => ({
      id: producto.id,
      nombre: producto.nombre,
      stockMinimo: producto.stock_minimo,
      stockTotal: producto.stock_ubicaciones.reduce((acc, s) => acc + s.cantidad, 0),
    }))
    .filter((producto) => producto.stockTotal <= producto.stockMinimo)
    .sort((a, b) => a.stockTotal - a.stockMinimo - (b.stockTotal - b.stockMinimo))

  return { data: bajos, error: null }
}

export interface StockBajoCardProps {
  supabase: SupabaseClient
  className?: string
  maxItems?: number
}

// Card "Stock bajo" del dashboard — misma consulta y mismo listado en Virikyna Local
// (Admin y Cajero) y Virikyna Gestión, por eso vive acá en vez de repetirse por app.
export function StockBajoCard({ supabase, className = '', maxItems = 4 }: StockBajoCardProps) {
  const [loading, setLoading] = useState(true)
  const [stockBajo, setStockBajo] = useState<ProductoStockBajo[]>([])

  useEffect(() => {
    let activo = true
    fetchProductosStockBajo(supabase).then(({ data }) => {
      if (activo) {
        setStockBajo(data)
        setLoading(false)
      }
    })
    return () => {
      activo = false
    }
  }, [supabase])

  return (
    <Link
      to="/inventario"
      className={`flex flex-col rounded-lg p-card shadow-sm transition ${
        stockBajo.length > 0
          ? 'border border-amarillo bg-amarillo/20 hover:bg-amarillo/30'
          : 'bg-surface hover:bg-accent-light'
      } ${className}`}
    >
      <p className="font-sans text-label-bold uppercase text-ink-soft">Stock bajo</p>
      <p className="mt-2 font-display text-headline-md text-accent-darker">
        {loading
          ? '—'
          : stockBajo.length === 0
            ? 'Todo en orden'
            : `${stockBajo.length} producto${stockBajo.length === 1 ? '' : 's'}`}
      </p>
      <ul className="mt-3 flex-1 space-y-1 overflow-hidden">
        {stockBajo.slice(0, maxItems).map((producto) => (
          <li key={producto.id} className="font-sans text-label-md text-ink-soft">
            {producto.nombre} ({producto.stockTotal}/{producto.stockMinimo})
          </li>
        ))}
      </ul>
      {stockBajo.length > maxItems && (
        <p className="mt-1 font-sans text-label-md text-accent-dark">
          +{stockBajo.length - maxItems} más — ver Inventario
        </p>
      )}
    </Link>
  )
}
