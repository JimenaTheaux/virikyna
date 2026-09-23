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

// Neto de devoluciones/cambios por día (docs/24): suma de diferencia_monto de las devoluciones
// activas — negativo = se devolvió plata al cliente. Venta neta del día = venta bruta + este valor.
export async function fetchDevolucionesUltimosDias(dias: number) {
  const { data, error } = await supabase
    .from('devoluciones')
    .select('fecha, diferencia_monto')
    .eq('estado', 'activa')
    .gte('fecha', fechaISO(-(dias - 1)))
    .lte('fecha', fechaISO(0))

  const netoPorDia = new Map<string, number>()
  if (error || !data) return { netoPorDia, error }
  for (const d of data as { fecha: string; diferencia_monto: number }[]) {
    netoPorDia.set(d.fecha, (netoPorDia.get(d.fecha) ?? 0) + d.diferencia_monto)
  }
  return { netoPorDia, error: null }
}

export type DefectuosoPendiente = { productoId: string; nombre: string; cantidad: number }

// Ítems devueltos como defectuosos (reingresa_stock = false) de devoluciones activas: mercadería
// separada que no volvió al stock y espera revisión.
export async function fetchDefectuososPendientes() {
  const { data, error } = await supabase
    .from('devolucion_items')
    .select('producto_id, cantidad, producto:productos(nombre), devolucion:devoluciones!inner(estado)')
    .eq('tipo', 'devuelto')
    .eq('reingresa_stock', false)
    .eq('devolucion.estado', 'activa')

  if (error || !data) return { data: [] as DefectuosoPendiente[], error }

  const porProducto = new Map<string, DefectuosoPendiente>()
  for (const row of data as unknown as { producto_id: string; cantidad: number; producto: { nombre: string } | null }[]) {
    const actual = porProducto.get(row.producto_id) ?? {
      productoId: row.producto_id,
      nombre: row.producto?.nombre ?? 'Producto',
      cantidad: 0,
    }
    actual.cantidad += row.cantidad
    porProducto.set(row.producto_id, actual)
  }
  return { data: [...porProducto.values()].sort((a, b) => b.cantidad - a.cantidad), error: null }
}
