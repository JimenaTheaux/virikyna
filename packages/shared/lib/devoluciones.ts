import type { SupabaseClient } from '@supabase/supabase-js'
import type { FormaPagoVenta, MotivoDevolucion, ResolucionDevolucion } from '../types/database'
import { fechaISO, fechaLocalDeISO } from './format'

// Devoluciones / cambios (docs/24_devoluciones_cambios.sql). Los precios y las validaciones reales
// (plazo, cantidad disponible, motivo) las hace el RPC `crear_devolucion`; lo de acá es solo lo
// que la pantalla necesita para mostrar el total en vivo y avisar antes de que el RPC rechace.

export const DIAS_LIMITE_DEVOLUCION = 15

export const MENSAJE_PLAZO_DEVOLUCION = `Esta venta supera los ${DIAS_LIMITE_DEVOLUCION} días permitidos para devolución/cambio`

export const MOTIVO_DEVOLUCION_LABEL: Record<MotivoDevolucion, string> = {
  regalo: 'Regalo',
  defectuoso: 'Defectuoso',
  arrepentimiento: 'Arrepentimiento',
  otro: 'Otro',
}

export const MOTIVOS_DEVOLUCION = Object.keys(MOTIVO_DEVOLUCION_LABEL) as MotivoDevolucion[]

// Mismo criterio que el RPC (created_at::date >= current_date - 15, con crear_devolucion en hora
// AR — docs/28): compara días de calendario argentinos, así una venta de hace exactamente 15 días
// todavía entra y la pantalla nunca contradice al RPC en el borde.
export function ventaDentroDePlazoDevolucion(createdAtISO: string): boolean {
  return fechaLocalDeISO(createdAtISO) >= fechaISO(-DIAS_LIMITE_DEVOLUCION)
}

export function redondear2(valor: number): number {
  return Math.round(valor * 100) / 100
}

// Precio que el cliente realmente pagó por unidad de un producto en una venta: importe de las
// líneas ÷ cantidad, reescalado por total/subtotal (descuento/recargo global + redondeo manual).
// Espeja el cálculo del RPC — es solo para la vista previa, el valor guardado lo calcula la base.
export function precioEfectivoUnitario(
  lineas: { cantidad: number; importe: number }[],
  venta: { subtotal: number; total: number },
): number {
  const cantidad = lineas.reduce((acc, l) => acc + l.cantidad, 0)
  if (cantidad === 0) return 0
  const importe = lineas.reduce((acc, l) => acc + l.importe, 0)
  const factor = venta.subtotal > 0 ? venta.total / venta.subtotal : 1
  return redondear2((importe / cantidad) * factor)
}

export function totalLineas(lineas: { cantidad: number; precioUnitario: number }[]): number {
  return redondear2(lineas.reduce((acc, l) => acc + redondear2(l.cantidad * l.precioUnitario), 0))
}

export type CrearDevolucionInput = {
  ventaId: string
  motivo: MotivoDevolucion
  motivoDetalle: string | null
  observaciones: string | null
  itemsDevueltos: { productoId: string; cantidad: number }[]
  itemsNuevos: { productoId: string; cantidad: number }[]
  // Solo con diferencia ≠ 0. `pagos` (1 o 2 elementos) es el pago combinado; si va vacío se usa formaPago.
  formaPago: FormaPagoVenta | null
  pagos: { formaPago: FormaPagoVenta; monto: number }[] | null
}

// Único punto de llamada al RPC `crear_devolucion` — cajero y admin por igual.
export function crearDevolucion(supabase: SupabaseClient, input: CrearDevolucionInput) {
  return supabase.rpc('crear_devolucion', {
    p_venta_id: input.ventaId,
    p_motivo: input.motivo,
    p_motivo_detalle: input.motivoDetalle,
    p_observaciones: input.observaciones,
    p_items_devueltos: input.itemsDevueltos.map((i) => ({ producto_id: i.productoId, cantidad: i.cantidad })),
    p_items_nuevos: input.itemsNuevos.map((i) => ({ producto_id: i.productoId, cantidad: i.cantidad })),
    p_forma_pago: input.pagos && input.pagos.length > 0 ? null : input.formaPago,
    p_pagos: input.pagos && input.pagos.length > 0
      ? input.pagos.map((p) => ({ forma_pago: p.formaPago, monto: p.monto }))
      : null,
  })
}

// ── docs/74: devolución con 1 a 3 tickets ────────────────────────────────────────────────────────

export const MAX_TICKETS_DEVOLUCION = 3

// Cómo se resolvió la diferencia: etiqueta corta para listados y detalle.
export const RESOLUCION_DEVOLUCION_LABEL: Record<ResolucionDevolucion, string> = {
  sin_diferencia: 'Saldado justo',
  cobro: 'Cobro',
  reintegro: 'Reintegro',
  a_favor: 'Queda a favor',
  cuenta_corriente: 'Cuenta corriente',
}

// Precio que el cliente pagó por unidad de UNA línea de venta: importe ÷ cantidad, reescalado por
// total/subtotal de su venta. Espeja crear_devolucion_tickets (solo para la vista previa).
export function precioPagadoLinea(
  linea: { cantidad: number; importe: number },
  venta: { subtotal: number; total: number },
): number {
  return precioEfectivoUnitario([linea], venta)
}

// Venta neta: solo descuenta la plata que se movió (cobro / reintegro). Un saldo a favor o una
// devolución imputada a la cuenta corriente no cambia la venta neta (docs/74, decisión 10).
export function diferenciaQueMueveDinero(d: { resolucion: ResolucionDevolucion; diferencia_monto: number }): number {
  return d.resolucion === 'cobro' || d.resolucion === 'reintegro' ? d.diferencia_monto : 0
}

export type CrearDevolucionTicketsInput = {
  tickets: string[] // ids de venta, en el orden en que se agregaron (1 a 3)
  motivo: MotivoDevolucion
  motivoDetalle: string | null
  observaciones: string | null
  itemsDevueltos: { ventaItemId: string; cantidad: number; defectuoso: boolean }[]
  itemsNuevos: { productoId: string; cantidad: number }[]
  // Lo que mostró la pantalla. Si la base calcula otra cosa, rechaza (no guarda algo distinto).
  resolucion: ResolucionDevolucion | null
  // Solo con cobro / reintegro. `pagos` (1 o 2) es el combinado; si va vacío se usa formaPago.
  // Ticket único a cta. cte. con diferencia a pagar: formaPago = 'cuenta_corriente' la carga a la cuenta.
  formaPago: FormaPagoVenta | null
  pagos: { formaPago: FormaPagoVenta; monto: number }[] | null
  notaAFavor: string | null
}

export type ResultadoDevolucionTickets = {
  devolucion_id: string
  numero: number
  total_devuelto: number
  total_nuevo: number
  diferencia: number
  resolucion: ResolucionDevolucion
  tickets: { venta_id: string; numero: number; orden: number; total_devuelto: number }[]
}

// Único punto de llamada al RPC `crear_devolucion_tickets` (docs/74) — cajero y admin por igual.
export function crearDevolucionTickets(supabase: SupabaseClient, input: CrearDevolucionTicketsInput) {
  const conPagos = input.pagos && input.pagos.length > 0
  return supabase.rpc('crear_devolucion_tickets', {
    p_tickets: input.tickets,
    p_motivo: input.motivo,
    p_motivo_detalle: input.motivoDetalle,
    p_observaciones: input.observaciones,
    p_items_devueltos: input.itemsDevueltos.map((i) => ({
      venta_item_id: i.ventaItemId,
      cantidad: i.cantidad,
      defectuoso: i.defectuoso,
    })),
    p_items_nuevos: input.itemsNuevos.map((i) => ({ producto_id: i.productoId, cantidad: i.cantidad })),
    p_resolucion: input.resolucion,
    p_forma_pago: conPagos ? null : input.formaPago,
    p_pagos: conPagos ? input.pagos!.map((p) => ({ forma_pago: p.formaPago, monto: p.monto })) : null,
    p_nota_a_favor: input.notaAFavor,
  })
}

// Único punto de llamada al RPC `anular_devolucion` — solo admin (el RPC lo valida).
export function anularDevolucion(supabase: SupabaseClient, devolucionId: string, motivo: string) {
  return supabase.rpc('anular_devolucion', { p_devolucion_id: devolucionId, p_motivo: motivo })
}
