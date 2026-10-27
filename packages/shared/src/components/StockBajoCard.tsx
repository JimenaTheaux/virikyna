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

// Productos con mínimo cargado y stock <= mínimo (solo activos), más crítico primero. Desde docs/64
// un mínimo 0 es "sin definir" y no alerta. Suma, filtro y orden los hace la RPC — así no depende
// del tope de 1000 filas de la API. Devuelve hasta `limite` productos + el total real.
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

// Contadores de activos (docs/64, resumen_stock_inventario): mismas definiciones que los chips de
// Inventario — sin stock = stock <= 0; bajo = mínimo > 0 y 0 < stock <= mínimo.
export async function fetchResumenStock(supabase: SupabaseClient): Promise<{ sinStock: number; bajo: number }> {
  const { data, error } = await supabase.rpc('resumen_stock_inventario')
  if (error) throw error
  const fila = ((data ?? []) as { sin_stock: number; bajo: number }[])[0]
  return { sinStock: fila?.sin_stock ?? 0, bajo: fila?.bajo ?? 0 }
}

// Links a Inventario con el chip de stock aplicado (?stock=, ver lib/estadoStock).
const A_SIN_STOCK = '/inventario?stock=sin_stock'
const A_STOCK_BAJO = '/inventario?stock=bajo'

export interface StockBajoCardProps {
  supabase: SupabaseClient
  className?: string
  maxItems?: number
  // 'compacta' (Dashboard de Gestión): dos renglones "Sin stock · N ›" y "Stock bajo · N ›", sin listado.
  variant?: 'card' | 'compacta'
}

// Card de stock del dashboard — misma consulta y mismo listado en Virikyna Local (Admin y Cajero) y
// Virikyna Gestión, por eso vive acá en vez de repetirse por app. ['stock-bajo'] es el prefijo de
// las dos consultas, para invalidarlas juntas.
export function StockBajoCard({ supabase, className = '', maxItems = 4, variant = 'card' }: StockBajoCardProps) {
  const compacta = variant === 'compacta'
  const resumen = useQuery({
    queryKey: ['stock-bajo', 'resumen'],
    queryFn: () => fetchResumenStock(supabase),
    staleTime: 60_000,
  })
  const listado = useQuery({
    queryKey: ['stock-bajo', maxItems],
    queryFn: () => fetchProductosStockBajo(supabase, maxItems),
    staleTime: 60_000,
    enabled: !compacta,
  })
  const sinStock = resumen.data?.sinStock ?? 0
  const bajo = resumen.data?.bajo ?? 0
  const valor = (n: number) => (resumen.isPending || resumen.isError ? '—' : String(n))

  if (compacta) {
    return (
      <>
        <IndicadorCompacto to={A_SIN_STOCK} label="Sin stock" valor={valor(sinStock)} alerta={sinStock > 0} tono="rojo" className={className} />
        <IndicadorCompacto to={A_STOCK_BAJO} label="Stock bajo" valor={valor(bajo)} alerta={bajo > 0} className={className} />
      </>
    )
  }

  const productos = listado.data?.productos ?? []
  const totalListado = listado.data?.total ?? 0
  const hayAlerta = sinStock > 0 || bajo > 0
  return (
    <div
      className={`flex flex-col rounded-lg p-card shadow-sm ${
        hayAlerta ? 'border border-amarillo bg-amarillo/20' : 'bg-surface'
      } ${className}`}
    >
      <p className="font-sans text-label-bold uppercase text-ink-soft">Stock</p>
      <p className="mt-2 flex flex-wrap items-baseline gap-x-2 font-display text-headline-md text-accent-darker">
        {resumen.isPending || resumen.isError ? (
          '—'
        ) : !hayAlerta ? (
          'Todo en orden'
        ) : (
          <>
            <Link to={A_SIN_STOCK} className="hover:underline">
              Sin stock ({sinStock})
            </Link>
            <span aria-hidden="true" className="text-ink-soft">
              ·
            </span>
            <Link to={A_STOCK_BAJO} className="hover:underline">
              Stock bajo ({bajo})
            </Link>
          </>
        )}
      </p>
      {productos.length > 0 && (
        <>
          <p className="mt-3 font-sans text-label-md font-semibold text-ink-soft">Con mínimo cargado</p>
          <ul className="mt-1 flex-1 space-y-1 overflow-hidden">
            {productos.map((producto) => (
              <li key={producto.id} className="font-sans text-label-md text-ink-soft">
                {producto.nombre} ({producto.stockTotal}/{producto.stockMinimo})
              </li>
            ))}
          </ul>
        </>
      )}
      {totalListado > productos.length && (
        <Link to={A_STOCK_BAJO} className="mt-1 font-sans text-label-md text-accent-dark hover:text-accent-darker">
          +{totalListado - productos.length} más — ver Inventario
        </Link>
      )}
    </div>
  )
}

// Renglón chico con link (o botón, con onClick: abre un modal) — variante 'compacta' de
// StockBajoCard, DefectuososCard y AlertaPreciosCard. Con algo pendiente lleva un punto de color
// además del número (no solo color): ámbar, o rojo para sin stock.
export function IndicadorCompacto({
  to,
  onClick,
  label,
  valor,
  alerta,
  tono = 'ambar',
  className = '',
}: {
  label: string
  valor: string
  alerta: boolean
  tono?: 'ambar' | 'rojo'
  className?: string
} & ({ to: string; onClick?: never } | { to?: never; onClick: () => void })) {
  const color = tono === 'rojo' ? { punto: 'bg-error', texto: 'text-error' } : { punto: 'bg-badge-amber-text', texto: 'text-badge-amber-text' }
  const clases = `flex items-center justify-between gap-2 rounded px-2 py-1 font-sans text-label-md transition hover:bg-accent-light ${className}`
  const contenido = (
    <>
      <span className="flex min-w-0 items-center gap-1.5 text-ink-soft">
        <span aria-hidden="true" className={`h-2 w-2 shrink-0 rounded-full ${alerta ? color.punto : 'bg-line'}`} />
        <span className="truncate">{label}</span>
      </span>
      <span className={`shrink-0 font-semibold ${alerta ? color.texto : 'text-ink'}`}>
        {valor} <span aria-hidden="true">›</span>
      </span>
    </>
  )
  return onClick ? (
    <button type="button" onClick={onClick} className={`w-full text-left ${clases}`}>
      {contenido}
    </button>
  ) : (
    <Link to={to} className={clases}>
      {contenido}
    </Link>
  )
}
