// Pagos "a cuenta" de proveedores (docs/52): plata pagada que todavía no cancela ningún
// comprobante, y cómo aplicarla después o quitar una aplicación. Lo a cuenta lo calcula la base
// (vistas pagos_proveedor_a_cuenta / proveedores_a_cuenta): las pantallas no lo recalculan.
// Aplicar o quitar no mueve plata: no hay egreso, ni movimiento de cuenta, ni cambia la caja.

import type { SupabaseClient } from '@supabase/supabase-js'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ErrorRegistrarPago, invalidarCuentaProveedor } from './facturasCompra'

export type PagoACuenta = {
  id: string // pagos_proveedor.id
  proveedor_id: string
  fecha: string
  created_at: string
  monto: number
  aplicado: number // de la plata de este pago, lo aplicado vigente
  vigente: boolean // monto > 0, no es una reversión y no fue revertido
  a_cuenta: number // monto − aplicado (0 si no está vigente)
}

export type AplicarPagosACuentaResultado = {
  aplicado: number
  a_cuenta_restante: number
  aplicaciones: { id: string; pago_proveedor_id: string; factura_compra_id: string; monto: number }[]
}

// Cuelga de ['proveedor', id]: invalidarCuentaProveedor (y toda invalidación de ['proveedor'])
// también la refresca, sin tener que acordarse en cada pantalla.
export const pagosACuentaQueryKey = (proveedorId: string) => ['proveedor', proveedorId, 'a-cuenta'] as const

// Lo a cuenta de cada pago del proveedor y el total. `porPago` incluye todos sus pagos (0 en
// reversiones, revertidos y operaciones solo de NC).
export function usePagosACuenta(supabase: SupabaseClient, proveedorId: string) {
  return useQuery({
    queryKey: pagosACuentaQueryKey(proveedorId),
    queryFn: async () => {
      const { data, error } = await supabase.from('pagos_proveedor_a_cuenta').select('*').eq('proveedor_id', proveedorId)
      if (error) throw error
      const pagos = (data ?? []) as PagoACuenta[]
      const porPago = new Map(pagos.map((p) => [p.id, Number(p.a_cuenta)]))
      const total = Math.round(pagos.reduce((acc, p) => acc + Number(p.a_cuenta), 0) * 100) / 100
      return { porPago, total }
    },
  })
}

// Total a cuenta de un proveedor, sin react-query (para después de cargar una factura).
export async function obtenerACuentaProveedor(supabase: SupabaseClient, proveedorId: string): Promise<number> {
  const { data, error } = await supabase
    .from('proveedores_a_cuenta')
    .select('a_cuenta')
    .eq('proveedor_id', proveedorId)
    .maybeSingle()
  if (error) throw error
  return Number((data as { a_cuenta: number } | null)?.a_cuenta ?? 0)
}

// Único punto de llamada a `aplicar_pagos_a_cuenta`. Sin comprobantes: los pendientes más viejos.
// Sin pagos: todos los que tienen saldo a cuenta, más viejos primero.
export function aplicarPagosACuenta(
  supabase: SupabaseClient,
  input: { proveedorId: string; facturaIds?: string[]; pagoIds?: string[] },
) {
  return supabase.rpc('aplicar_pagos_a_cuenta', {
    p_proveedor_id: input.proveedorId,
    p_factura_ids: input.facturaIds?.length ? input.facturaIds : null,
    p_pago_ids: input.pagoIds?.length ? input.pagoIds : null,
  })
}

// Único punto de llamada a `desaplicar_pago` (solo admin: el RPC lo valida).
export function desaplicarPago(supabase: SupabaseClient, aplicacionId: string) {
  return supabase.rpc('desaplicar_pago', { p_aplicacion_id: aplicacionId })
}

export function useAplicarPagosACuenta(supabase: SupabaseClient) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (input: { proveedorId: string; facturaIds?: string[] }) => {
      const { data, error, status } = await aplicarPagosACuenta(supabase, input)
      // Mismo error con status que el pago: la pantalla distingue "sin conexión" (mensajeErrorGuardado).
      if (error) throw new ErrorRegistrarPago(error, status)
      return data as AplicarPagosACuentaResultado
    },
    onSuccess: (_data, input) => invalidarCuentaProveedor(queryClient, input.proveedorId),
  })
}
