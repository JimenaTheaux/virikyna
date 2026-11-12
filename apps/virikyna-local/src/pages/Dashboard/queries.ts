import { supabase } from '../../lib/supabaseClient'
import { diferenciaQueMueveDinero, fechaISO, fechaLocalDeISO, rangoTimestampsAR, type ResolucionDevolucion } from '@virikyna/shared'
import type { VentaDelDia } from './types'

// Una sola consulta cubre "hoy" y "ayer" (variación) y los últimos 7 días (gráfico semanal),
// agrupando por día argentino en el cliente. Solo ventas comerciales: el consumo interno (dueñas y
// empleados, docs/68 D8) va aparte, en su card.
export async function fetchVentasUltimosDias(dias: number) {
  const { desde, hasta } = rangoTimestampsAR(fechaISO(-(dias - 1)), fechaISO(0))

  const { data, error } = await supabase
    .from('ventas')
    .select('precio_cobrado, created_at')
    .neq('estado', 'anulada')
    .is('estado_interno', null)
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

type DevolucionDia = {
  fecha: string
  diferencia_monto: number
  resolucion: ResolucionDevolucion
  tickets: { venta: { estado_interno: string | null } | null }[]
}

// Devoluciones/cambios activas por día (docs/24, docs/74). Venta neta del día = venta bruta + neto,
// y el neto es SOLO la plata que se movió (cobro / reintegro): un saldo a favor (vale manual) o una
// devolución imputada a la cuenta corriente no la cambian; los saldos a favor se cuentan aparte.
// Las devoluciones de ventas internas no cuentan (docs/68 D8): ahora por los tickets de la devolución
// (con 2–3 tickets devoluciones.venta_id es null).
export async function fetchDevolucionesUltimosDias(dias: number) {
  const { data, error } = await supabase
    .from('devoluciones')
    .select('fecha, diferencia_monto, resolucion, tickets:devolucion_tickets(venta:ventas!devolucion_tickets_venta_id_fkey(estado_interno))')
    .eq('estado', 'activa')
    .gte('fecha', fechaISO(-(dias - 1)))
    .lte('fecha', fechaISO(0))

  const netoPorDia = new Map<string, number>()
  const aFavorPorDia = new Map<string, { cantidad: number; total: number }>()
  if (error || !data) return { netoPorDia, aFavorPorDia, error }
  for (const d of data as unknown as DevolucionDia[]) {
    if ((d.tickets ?? []).some((t) => t.venta?.estado_interno)) continue
    netoPorDia.set(d.fecha, (netoPorDia.get(d.fecha) ?? 0) + diferenciaQueMueveDinero(d))
    if (d.resolucion === 'a_favor') {
      const prev = aFavorPorDia.get(d.fecha) ?? { cantidad: 0, total: 0 }
      aFavorPorDia.set(d.fecha, { cantidad: prev.cantidad + 1, total: prev.total - d.diferencia_monto })
    }
  }
  return { netoPorDia, aFavorPorDia, error: null }
}
