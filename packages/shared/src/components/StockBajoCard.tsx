import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { nombreConMarca } from '../../lib/productoTexto'

export type ProductoStockBajo = {
  id: string
  nombre: string // nombre · marca
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
    marca: string | null // docs/42
    stock_total: number | string
    stock_minimo: number | string
    total_count: number
  }[]
  return {
    productos: filas.map((fila) => ({
      id: fila.id,
      nombre: nombreConMarca(fila),
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
  // 'compacta' (Dashboard de Gestión): un renglón "Stock bajo · N ›", sin listado.
  variant?: 'card' | 'compacta'
}

// Card "Stock bajo" del dashboard — misma consulta y mismo listado en Virikyna Local
// (Admin y Cajero) y Virikyna Gestión, por eso vive acá en vez de repetirse por app.
export function StockBajoCard({ supabase, className = '', maxItems = 4, variant = 'card' }: StockBajoCardProps) {
  const compacta = variant === 'compacta'
  // maxItems va en la key porque es el p_limite de la RPC — ['stock-bajo'] sigue sirviendo de
  // prefijo para invalidar todas las variantes juntas. La compacta solo usa el total.
  const limite = compacta ? 1 : maxItems
  const { data, isPending } = useQuery({
    queryKey: ['stock-bajo', limite],
    queryFn: () => fetchProductosStockBajo(supabase, limite),
    staleTime: 60_000,
  })
  const stockBajo = data?.productos ?? []
  const total = data?.total ?? 0

  if (compacta) {
    return (
      <IndicadorCompacto to="/inventario" label="Stock bajo" valor={isPending ? '—' : String(total)} alerta={total > 0} className={className} />
    )
  }

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

// Renglón chico con link — variante 'compacta' de StockBajoCard y DefectuososCard. Con algo
// pendiente lleva un punto ámbar además del número (no solo color).
export function IndicadorCompacto({
  to,
  label,
  valor,
  alerta,
  className = '',
}: {
  to: string
  label: string
  valor: string
  alerta: boolean
  className?: string
}) {
  return (
    <Link
      to={to}
      className={`flex items-center justify-between gap-2 rounded px-2 py-1 font-sans text-label-md transition hover:bg-accent-light ${className}`}
    >
      <span className="flex min-w-0 items-center gap-1.5 text-ink-soft">
        <span aria-hidden="true" className={`h-2 w-2 shrink-0 rounded-full ${alerta ? 'bg-badge-amber-text' : 'bg-line'}`} />
        <span className="truncate">{label}</span>
      </span>
      <span className={`shrink-0 font-semibold ${alerta ? 'text-badge-amber-text' : 'text-ink'}`}>
        {valor} <span aria-hidden="true">›</span>
      </span>
    </Link>
  )
}
