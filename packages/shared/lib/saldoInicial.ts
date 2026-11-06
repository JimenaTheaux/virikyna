// Saldo inicial de proveedores y clientes (docs/69). Es ÚNICO por cuenta: se carga una vez desde
// Caja Gestión → Carga inicial (cargar_saldos_iniciales) y, si está mal, se corrige con motivo
// (corregir_saldo_inicial). No suma: si falta deuda, se carga como comprobante.
// Los pagos (o cobros) sin comprobante cancelan primero el saldo inicial; lo calcula la base
// (saldo_inicial_pendiente / a_cuenta_libre en proveedores_saldo y clientes_saldo).

import type { SupabaseClient } from '@supabase/supabase-js'

export const AYUDA_SALDO_INICIAL = 'El saldo inicial se carga una sola vez. Deudas nuevas se cargan como comprobante.'

// Cargado = tiene fecha (aunque una corrección lo haya llevado a 0) o un monto distinto de cero.
export function tieneSaldoInicial(c: { saldo_inicial: number | string; saldo_inicial_fecha?: string | null }): boolean {
  return Boolean(c.saldo_inicial_fecha) || Number(c.saldo_inicial) !== 0
}

export type EstadoSaldoInicial = { label: string; variant: 'amber' | 'green' | 'neutral' }

// Estado de la línea "Saldo inicial" en la cuenta corriente, con la misma lógica que un comprobante.
export function estadoSaldoInicial(saldoInicial: number, pendiente: number): EstadoSaldoInicial {
  if (saldoInicial < 0) return { label: 'A favor', variant: 'green' }
  if (saldoInicial === 0) return { label: 'En cero', variant: 'neutral' }
  if (pendiente <= 0) return { label: 'Cancelado', variant: 'green' }
  if (pendiente < saldoInicial) return { label: 'Parcial', variant: 'amber' }
  return { label: 'Pendiente', variant: 'amber' }
}

export type TipoCuentaSaldoInicial = 'proveedor' | 'cliente'

// Único punto de llamada a `corregir_saldo_inicial` (solo admin: el RPC lo valida).
export function corregirSaldoInicial(
  supabase: SupabaseClient,
  input: { tipo: TipoCuentaSaldoInicial; id: string; montoNuevo: number; motivo: string },
) {
  return supabase.rpc('corregir_saldo_inicial', {
    p_tipo: input.tipo,
    p_id: input.id,
    p_monto_nuevo: input.montoNuevo,
    p_motivo: input.motivo,
  })
}
