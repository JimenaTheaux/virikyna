import { supabase } from '../../lib/supabaseClient'
import { fechaISO, fechaLocalDeISO } from '@virikyna/shared'
import type { VentaDelDia } from './types'

// Una sola consulta cubre "hoy" y "ayer" (variación) y los últimos 7 días (gráfico semanal),
// agrupando por día local en el cliente.
export async function fetchVentasUltimosDias(dias: number) {
  const desde = `${fechaISO(-(dias - 1))}T00:00:00`
  const hasta = `${fechaISO(0)}T23:59:59`

  const { data, error } = await supabase
    .from('ventas')
    .select('precio_cobrado, created_at')
    .neq('estado', 'anulada')
    .gte('created_at', desde)
    .lte('created_at', hasta)

  if (error || !data) return { porDia: new Map<string, VentaDelDia>(), error }

  const porDia = new Map<string, VentaDelDia>()
  for (const venta of data as { precio_cobrado: number; created_at: string }[]) {
    const fecha = fechaLocalDeISO(venta.created_at)
    const actual = porDia.get(fecha) ?? { fecha, total: 0, cantidad: 0 }
    actual.total += venta.precio_cobrado
    actual.cantidad += 1
    porDia.set(fecha, actual)
  }
  return { porDia, error: null }
}
