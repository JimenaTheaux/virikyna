import type { SupabaseClient } from '@supabase/supabase-js'
import type { FormaPagoVenta, MotivoDevolucion } from '../types/database'
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

// Mismo criterio que el RPC (created_at::date >= current_date - 15): compara días de calendario
// locales, así una venta de hace exactamente 15 días todavía entra.
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

// Único punto de llamada al RPC `anular_devolucion` — solo admin (el RPC lo valida).
export function anularDevolucion(supabase: SupabaseClient, devolucionId: string, motivo: string) {
  return supabase.rpc('anular_devolucion', { p_devolucion_id: devolucionId, p_motivo: motivo })
}
