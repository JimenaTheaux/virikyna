import { keepPreviousData, useQuery } from '@tanstack/react-query'
import type { SupabaseClient } from '@supabase/supabase-js'

// Fila de dashboard_ventas_por_producto (docs/61): netas de devoluciones, importe prorrateado al
// precio cobrado de cada venta.
export type VentaPorProducto = {
  productoId: string
  nombre: string
  marca: string | null
  unidades: number
  importe: number
  stockActual: number
  stockMinimo: number
  unidadesAnterior: number
  importeAnterior: number
}

// Toggle del Top 10 / resumen por marca.
export type Medida = 'unidades' | 'importe'

export type RangoFechas = { desde: string; hasta: string } // YYYY-MM-DD, hora AR

// Ventas por producto del período, con el período anterior que usa el Dashboard para comparar
// ("mismo tramo de la semana/mes pasado") — docs/61. Agregado en la base, el cliente no suma.
// Sin `anterior`, la RPC compara contra el tramo inmediato anterior del mismo largo.
export async function fetchVentasPorProducto(
  supabase: SupabaseClient,
  actual: RangoFechas,
  anterior?: RangoFechas,
): Promise<VentaPorProducto[]> {
  const { data, error } = await supabase.rpc('dashboard_ventas_por_producto', {
    p_desde: actual.desde,
    p_hasta: actual.hasta,
    ...(anterior ? { p_ant_desde: anterior.desde, p_ant_hasta: anterior.hasta } : {}),
  })
  if (error) throw error
  type Fila = {
    producto_id: string
    nombre: string
    marca: string | null
    unidades: number | string
    importe: number | string
    stock_actual: number | string
    stock_minimo: number | string
    unidades_periodo_anterior: number | string
    importe_periodo_anterior: number | string
  }
  return ((data ?? []) as Fila[]).map((f) => ({
    productoId: f.producto_id,
    nombre: f.nombre,
    marca: f.marca,
    unidades: Number(f.unidades),
    importe: Number(f.importe),
    stockActual: Number(f.stock_actual),
    stockMinimo: Number(f.stock_minimo),
    unidadesAnterior: Number(f.unidades_periodo_anterior),
    importeAnterior: Number(f.importe_periodo_anterior),
  }))
}

// placeholderData: al cambiar de período se siguen mostrando los datos anteriores hasta que llegan
// los nuevos, en vez de volver al estado de carga.
export function useVentasPorProducto(supabase: SupabaseClient, actual: RangoFechas, anterior?: RangoFechas) {
  return useQuery({
    queryKey: ['dashboard', 'productos', actual.desde, actual.hasta, anterior?.desde ?? null, anterior?.hasta ?? null],
    queryFn: () => fetchVentasPorProducto(supabase, actual, anterior),
    placeholderData: keepPreviousData,
  })
}
