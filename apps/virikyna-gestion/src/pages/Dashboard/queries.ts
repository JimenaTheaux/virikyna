import { keepPreviousData, useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabaseClient'
import type { VentaDelDia } from './types'

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
