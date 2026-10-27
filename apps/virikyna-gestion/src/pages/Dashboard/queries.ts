import { keepPreviousData, useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabaseClient'
import type { VentaDelDia, VentaPorProducto } from './types'

// Ventas por día (hora AR) ya agregadas en la base — una fila por día del rango, incluso sin
// ventas (docs/25_dashboard_resumen.sql). El cliente no suma ni agrupa.
async function fetchVentasPorDia(desde: string, hasta: string): Promise<VentaDelDia[]> {
  const { data, error } = await supabase.rpc('dashboard_ventas_por_dia', { p_desde: desde, p_hasta: hasta })
  if (error) throw error
  return ((data ?? []) as { fecha: string; total: number | string; cantidad: number }[]).map((fila) => ({
    fecha: fila.fecha,
    total: Number(fila.total),
    cantidad: fila.cantidad,
  }))
}

// placeholderData: al cambiar de período se siguen mostrando los datos anteriores hasta que llegan
// los nuevos, en vez de volver al estado de carga.
export function useVentasPorDia(desde: string, hasta: string) {
  return useQuery({
    queryKey: ['dashboard', 'ventas', desde, hasta],
    queryFn: () => fetchVentasPorDia(desde, hasta),
    placeholderData: keepPreviousData,
  })
}

type Rango = { desde: string; hasta: string }

// Ventas por producto del período, con el período anterior que usa el Dashboard para comparar
// ("mismo tramo de la semana/mes pasado") — docs/61. Agregado en la base, el cliente no suma.
async function fetchVentasPorProducto(actual: Rango, anterior: Rango): Promise<VentaPorProducto[]> {
  const { data, error } = await supabase.rpc('dashboard_ventas_por_producto', {
    p_desde: actual.desde,
    p_hasta: actual.hasta,
    p_ant_desde: anterior.desde,
    p_ant_hasta: anterior.hasta,
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

export function useVentasPorProducto(actual: Rango, anterior: Rango) {
  return useQuery({
    queryKey: ['dashboard', 'productos', actual.desde, actual.hasta, anterior.desde, anterior.hasta],
    queryFn: () => fetchVentasPorProducto(actual, anterior),
    placeholderData: keepPreviousData,
  })
}
