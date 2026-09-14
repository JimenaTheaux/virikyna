import type { Producto, StockUbicacion } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { fechaISO, fechaLocalDeISO } from '@virikyna/shared'
import type { ProductoStockBajo, VentaDelDia } from './types'

type ProductoConStock = Pick<Producto, 'id' | 'nombre' | 'stock_minimo'> & {
  stock_ubicaciones: Pick<StockUbicacion, 'cantidad'>[]
}

// Una sola consulta cubre "hoy" y "ayer" (variación) y los últimos 7 días (gráfico semanal),
// agrupando por día local en el cliente.
export async function fetchVentasUltimosDias(dias: number) {
  const desde = `${fechaISO(-(dias - 1))}T00:00:00`
  const hasta = `${fechaISO(0)}T23:59:59`

  const { data, error } = await supabase
    .from('ventas')
    .select('total, created_at')
    .neq('estado', 'anulada')
    .gte('created_at', desde)
    .lte('created_at', hasta)

  if (error || !data) return { porDia: new Map<string, VentaDelDia>(), error }

  const porDia = new Map<string, VentaDelDia>()
  for (const venta of data as { total: number; created_at: string }[]) {
    const fecha = fechaLocalDeISO(venta.created_at)
    const actual = porDia.get(fecha) ?? { fecha, total: 0, cantidad: 0 }
    actual.total += venta.total
    actual.cantidad += 1
    porDia.set(fecha, actual)
  }
  return { porDia, error: null }
}

// Stock bajo = suma de stock en todas las ubicaciones <= stock_minimo del producto (solo activos).
export async function fetchProductosStockBajo(): Promise<{ data: ProductoStockBajo[]; error: unknown }> {
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
