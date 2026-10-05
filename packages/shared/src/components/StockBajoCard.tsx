import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import type { SupabaseClient } from '@supabase/supabase-js'

export type ProductoStockBajo = {
  id: string
  nombre: string
  stockMinimo: number
  stockTotal: number
}

// Stock bajo = suma de stock en todas las ubicaciones <= stock_minimo del producto (solo activos).
// Suma, filtro y orden (más crítico primero) los hace la RPC (docs/26_stock_bajo.sql) — así no
// depende del tope de 1000 filas de la API. Devuelve hasta `limite` productos + el total real.
export async function fetchProductosStockBajo(
  supabase: SupabaseClient,
  limite: number,
): Promise<{ productos: ProductoStockBajo[]; total: number }> {
  const { data, error } = await supabase.rpc('productos_stock_bajo', { p_limite: limite })
  if (error) throw error

  const filas = (data ?? []) as {
    id: string
    nombre: string
    stock_total: number | string
    stock_minimo: number | string
    total_count: number
  }[]
  return {
    productos: filas.map((fila) => ({
      id: fila.id,
      nombre: fila.nombre,
      stockMinimo: Number(fila.stock_minimo),
      stockTotal: Number(fila.stock_total),
    })),
    total: filas[0]?.total_count ?? 0,
  }
}

export interface StockBajoCardProps {
  supabase: SupabaseClient
  className?: string
  maxItems?: number
}

// Card "Stock bajo" del dashboard — misma consulta y mismo listado en Virikyna Local
// (Admin y Cajero) y Virikyna Gestión, por eso vive acá en vez de repetirse por app.
export function StockBajoCard({ supabase, className = '', maxItems = 4 }: StockBajoCardProps) {
  // maxItems va en la key porque es el p_limite de la RPC — ['stock-bajo'] sigue sirviendo de
  // prefijo para invalidar todas las variantes juntas.
  const { data, isPending } = useQuery({
    queryKey: ['stock-bajo', maxItems],
    queryFn: () => fetchProductosStockBajo(supabase, maxItems),
    staleTime: 60_000,
  })
  const stockBajo = data?.productos ?? []
  const total = data?.total ?? 0

  return (
    <Link
      to="/inventario"
      className={`flex flex-col rounded-lg p-card shadow-sm transition ${
        total > 0
          ? 'border border-amarillo bg-amarillo/20 hover:bg-amarillo/30'
          : 'bg-surface hover:bg-accent-light'
      } ${className}`}
    >
      <p className="font-sans text-label-bold uppercase text-ink-soft">Stock bajo</p>
      <p className="mt-2 font-display text-headline-md text-accent-darker">
        {isPending
          ? '—'
          : total === 0
            ? 'Todo en orden'
            : `${total} producto${total === 1 ? '' : 's'}`}
      </p>
      <ul className="mt-3 flex-1 space-y-1 overflow-hidden">
        {stockBajo.map((producto) => (
          <li key={producto.id} className="font-sans text-label-md text-ink-soft">
            {producto.nombre} ({producto.stockTotal}/{producto.stockMinimo})
          </li>
        ))}
      </ul>
      {total > stockBajo.length && (
        <p className="mt-1 font-sans text-label-md text-accent-dark">
          +{total - stockBajo.length} más — ver Inventario
        </p>
      )}
    </Link>
  )
}
