// Cuenta corriente de clientes (docs/68): lecturas de las vistas, cobros con varios medios e
// imputación, y cobros a cuenta. La base calcula saldos y estados (ventas_cuenta_corriente_saldo,
// clientes_saldo, pagos_cliente_a_cuenta): las pantallas no los recalculan.
import type { QueryClient } from '@tanstack/react-query'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import type {
  ClienteSaldo,
  CondicionIvaCliente,
  FormaPagoCobro,
  FormaPagoVenta,
  OrigenEgreso,
  PagoCliente,
  PagoClienteAplicacion,
  PagoClienteMedio,
  VentaCuentaCorrienteSaldo,
} from '../types/database'
import { ErrorRegistrarPago } from './facturasCompra'
import { nombresPorId } from './perfiles'
import { payloadMediosCobro, type MedioPagoForm } from './mediosPago'
import {
  FORMA_PAGO_LABEL,
  itemsComprobanteDesdeVenta,
  SELECT_ITEMS_COMPROBANTE,
  type DatosComprobante,
  type VentaItemComprobanteRow,
} from './comprobante'

export const FORMAS_PAGO_COBRO: FormaPagoCobro[] = ['efectivo', 'transferencia', 'qr', 'tarjeta_debito', 'tarjeta_credito']
export const OPCIONES_MEDIO_COBRO = FORMAS_PAGO_COBRO.map((f) => ({ value: f, label: FORMA_PAGO_LABEL[f] }))

// Necesaria para Factura C (RG 5616): sin este dato ARCA rechaza el comprobante para cualquier
// cliente que no sea Consumidor Final. Ver supabase/functions/arca-emitir-factura.
export const CONDICION_IVA_LABEL: Record<CondicionIvaCliente, string> = {
  consumidor_final: 'Consumidor Final',
  responsable_inscripto: 'Responsable Inscripto',
  monotributista: 'Monotributista',
  exento: 'Exento',
  no_categorizado: 'No categorizado',
}

export function nombreCliente(c: { razon_social: string | null; nombre_fantasia: string | null }): string {
  return c.razon_social ?? c.nombre_fantasia ?? 'Cliente'
}

export function etiquetaVenta(v: { numero: number }): string {
  return `Venta N° ${v.numero}`
}

export const clienteQueryKeys = {
  cliente: (id: string) => ['cliente', id] as const,
  comprobantes: (id: string) => ['cliente', id, 'comprobantes'] as const,
  cobros: (id: string) => ['cliente', id, 'cobros'] as const,
  aCuenta: (id: string) => ['cliente', id, 'a-cuenta'] as const,
  saldos: ['clientes-saldo'] as const,
}

// Todo lo que cambia con un cobro o una aplicación: cuelga de ['cliente', id] + el listado.
export function invalidarCuentaCliente(queryClient: QueryClient, clienteId: string) {
  return Promise.all([
    queryClient.invalidateQueries({ queryKey: clienteQueryKeys.cliente(clienteId) }),
    queryClient.invalidateQueries({ queryKey: clienteQueryKeys.saldos }),
  ])
}

export function useClientesSaldo(supabase: SupabaseClient) {
  return useQuery({
    queryKey: clienteQueryKeys.saldos,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('clientes_saldo')
        .select('*')
        .order('razon_social', { ascending: true, nullsFirst: false })
      if (error) throw error
      return (data ?? []) as ClienteSaldo[]
    },
  })
}

export function useCliente(supabase: SupabaseClient, clienteId: string) {
  return useQuery({
    queryKey: clienteQueryKeys.cliente(clienteId),
    queryFn: async () => {
      const { data, error } = await supabase.from('clientes_saldo').select('*').eq('id', clienteId).maybeSingle()
      if (error) throw error
      return data as ClienteSaldo | null
    },
  })
}

// Todas las ventas a cta. cte. del cliente (anuladas incluidas): los filtros son del lado de la
// pantalla, un cliente tiene decenas de comprobantes, no miles.
export function useComprobantesCliente(supabase: SupabaseClient, clienteId: string) {
  return useQuery({
    queryKey: clienteQueryKeys.comprobantes(clienteId),
    queryFn: async () => {
      const { data, error } = await supabase
        .from('ventas_cuenta_corriente_saldo')
        .select('*')
        .eq('cliente_id', clienteId)
        .order('created_at', { ascending: false })
      if (error) throw error
      return (data ?? []) as VentaCuentaCorrienteSaldo[]
    },
  })
}

export type AplicacionDeCobro = Pick<PagoClienteAplicacion, 'id' | 'venta_id' | 'monto' | 'revertida_at'>
export type MedioDeCobro = Pick<PagoClienteMedio, 'id' | 'forma_pago' | 'monto' | 'orden'>

export type CobroClienteConDetalle = PagoCliente & {
  usuario_nombre: string | null
  aplicaciones: AplicacionDeCobro[] // las de este cobro (al cobrar o aplicadas después), vigentes o quitadas
  medios: MedioDeCobro[]
  revertido: boolean
}

export function useCobrosCliente(supabase: SupabaseClient, clienteId: string) {
  return useQuery({
    queryKey: clienteQueryKeys.cobros(clienteId),
    queryFn: async (): Promise<CobroClienteConDetalle[]> => {
      const { data, error } = await supabase
        .from('pagos_cliente')
        .select(
          '*, aplicaciones:pagos_cliente_aplicaciones!pagos_cliente_aplicaciones_pago_cliente_id_fkey(id, venta_id, monto, revertida_at), medios:pagos_cliente_medios!pagos_cliente_medios_pago_cliente_id_fkey(id, forma_pago, monto, orden)',
        )
        .eq('cliente_id', clienteId)
        .order('fecha', { ascending: false })
        .order('created_at', { ascending: false })
      if (error) throw error
      const cobros = (data ?? []) as (PagoCliente & { aplicaciones: AplicacionDeCobro[] | null; medios: MedioDeCobro[] | null })[]
      const revertidos = new Set(cobros.map((c) => c.revierte_pago_cliente_id).filter(Boolean))
      const nombres = await nombresPorId(
        supabase,
        cobros.map((c) => c.usuario_id),
      )
      return cobros.map((c) => ({
        ...c,
        aplicaciones: c.aplicaciones ?? [],
        medios: [...(c.medios ?? [])].sort((a, b) => a.orden - b.orden),
        usuario_nombre: nombres.get(c.usuario_id) ?? null,
        revertido: revertidos.has(c.id),
      }))
    },
  })
}

// Lo a cuenta de cada cobro y el total aplicable. docs/69 agrega a_cuenta_libre (lo que queda
// después de cancelar el saldo inicial): si la columna existe se usa esa, si no a_cuenta.
export function useCobrosACuenta(supabase: SupabaseClient, clienteId: string) {
  return useQuery({
    queryKey: clienteQueryKeys.aCuenta(clienteId),
    queryFn: async () => {
      const { data, error } = await supabase.from('pagos_cliente_a_cuenta').select('*').eq('cliente_id', clienteId)
      if (error) throw error
      const filas = (data ?? []) as { id: string; a_cuenta: number; a_cuenta_libre?: number }[]
      const libre = (f: (typeof filas)[number]) => Number(f.a_cuenta_libre ?? f.a_cuenta)
      const porPago = new Map(filas.map((f) => [f.id, libre(f)]))
      const total = Math.round(filas.reduce((acc, f) => acc + libre(f), 0) * 100) / 100
      return { porPago, total }
    },
  })
}

export type RegistrarCobroClienteInput = {
  clienteId: string
  monto: number
  medios: MedioPagoForm<FormaPagoCobro>[]
  ventaIds?: string[]
  origen: OrigenEgreso // Local → turno (entra al Cierre); Gestión → general (cuenta mapeada)
  fecha?: string | null // solo general; turno es siempre hoy
  nota?: string | null
}

export type RegistrarCobroClienteResultado = {
  pago_id: string
  monto: number
  aplicado: number
  a_cuenta: number
  aplicaciones: { id: string; venta_id: string; monto: number }[]
}

// Único punto de llamada a `registrar_cobro_cliente`.
export function registrarCobroCliente(supabase: SupabaseClient, input: RegistrarCobroClienteInput) {
  return supabase.rpc('registrar_cobro_cliente', {
    p_cliente_id: input.clienteId,
    p_medios: payloadMediosCobro(input.medios),
    p_venta_ids: input.ventaIds?.length ? input.ventaIds : null,
    p_origen: input.origen,
    p_fecha: input.origen === 'general' ? input.fecha || null : null,
    p_nota: input.nota?.trim() || null,
    p_monto: input.monto,
  })
}

export function useRegistrarCobroCliente(supabase: SupabaseClient) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (input: RegistrarCobroClienteInput) => {
      const { data, error, status } = await registrarCobroCliente(supabase, input)
      if (error) throw new ErrorRegistrarPago(error, status)
      return data as RegistrarCobroClienteResultado
    },
    onSuccess: (_data, input) => invalidarCuentaCliente(queryClient, input.clienteId),
  })
}

export type AplicarCobrosACuentaResultado = {
  aplicado: number
  a_cuenta_restante: number
  aplicaciones: { id: string; pago_cliente_id: string; venta_id: string; monto: number }[]
}

// Único punto de llamada a `aplicar_cobros_a_cuenta`. Sin ventas: las pendientes más viejas.
export function useAplicarCobrosACuenta(supabase: SupabaseClient) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (input: { clienteId: string; ventaIds?: string[] }) => {
      const { data, error, status } = await supabase.rpc('aplicar_cobros_a_cuenta', {
        p_cliente_id: input.clienteId,
        p_venta_ids: input.ventaIds?.length ? input.ventaIds : null,
        p_pago_ids: null,
      })
      if (error) throw new ErrorRegistrarPago(error, status)
      return data as AplicarCobrosACuentaResultado
    },
    onSuccess: (_data, input) => invalidarCuentaCliente(queryClient, input.clienteId),
  })
}

// Datos para reabrir el Comprobante X (o la Factura C) de una venta desde la cuenta corriente.
export async function datosComprobanteVenta(
  supabase: SupabaseClient,
  ventaId: string,
  cliente: Pick<ClienteSaldo, 'razon_social' | 'nombre_fantasia' | 'mail' | 'celular'>,
): Promise<DatosComprobante> {
  const { data, error } = await supabase
    .from('ventas')
    .select(
      `id, numero, created_at, forma_pago, subtotal, descuento_porcentaje, recargo_porcentaje, precio_oficial, total, nota,
       factura_c:facturas_c(cae, numero_factura, punto_venta, fecha_emision), items:venta_items(${SELECT_ITEMS_COMPROBANTE})`,
    )
    .eq('id', ventaId)
    .single()
  if (error) throw error
  const v = data as unknown as {
    numero: number
    created_at: string
    forma_pago: FormaPagoVenta
    subtotal: number
    descuento_porcentaje: number
    recargo_porcentaje: number
    precio_oficial: number
    total: number
    nota: string | null
    factura_c: { cae: string | null; numero_factura: string | null; punto_venta: string | null; fecha_emision: string | null } | null
    items: VentaItemComprobanteRow[]
  }
  const factura = Array.isArray(v.factura_c) ? v.factura_c[0] ?? null : v.factura_c
  return {
    tipo: factura ? 'factura_c' : 'comprobante_x',
    numero: factura ? `${factura.punto_venta}-${factura.numero_factura}` : String(v.numero),
    fecha: factura?.fecha_emision ?? v.created_at,
    clienteNombre: nombreCliente(cliente),
    clienteMail: cliente.mail ?? null,
    clienteCelular: cliente.celular ?? null,
    formaPago: v.forma_pago,
    items: itemsComprobanteDesdeVenta(v.items),
    subtotal: Number(v.subtotal),
    descuentoPorcentaje: Number(v.descuento_porcentaje),
    recargoPorcentaje: Number(v.recargo_porcentaje),
    precioOficial: Number(v.precio_oficial),
    total: Number(v.total),
    cae: factura?.cae ?? null,
    nota: v.nota,
  }
}

// ── Comprobantes internos (docs/68, fase 3): revisar con descuento por ítem, finalizar, reabrir ──

export type ItemVentaInternaRow = {
  id: string
  producto_id: string
  cantidad: number
  precio_unitario: number
  descuento_porcentaje: number
  importe: number
  producto_nombre: string | null
  producto_marca: string | null
  costo_unitario: number | null
  producto_con_iva: boolean | null
  precio_unitario_original: number | null
  descuento_porcentaje_original: number | null
  producto: { nombre: string; marca: string | null; costo: number | null; iva_porcentaje: number } | null
}

export const ventaQueryKeys = {
  items: (ventaId: string) => ['venta', ventaId, 'items'] as const,
  venta: (ventaId: string) => ['venta', ventaId] as const,
}

export function useItemsVenta(supabase: SupabaseClient, ventaId: string) {
  return useQuery({
    queryKey: ventaQueryKeys.items(ventaId),
    queryFn: async () => {
      const { data, error } = await supabase
        .from('venta_items')
        .select(
          'id, producto_id, cantidad, precio_unitario, descuento_porcentaje, importe, producto_nombre, producto_marca, costo_unitario, producto_con_iva, precio_unitario_original, descuento_porcentaje_original, producto:productos(nombre, marca, costo, iva_porcentaje)',
        )
        .eq('venta_id', ventaId)
        .order('id')
      if (error) throw error
      return (data ?? []) as unknown as ItemVentaInternaRow[]
    },
  })
}

// Una venta a cta. cte. leída de nuevo (después de un conflicto de versión, o para el modal).
export function useVentaCuentaCorriente(supabase: SupabaseClient, ventaId: string) {
  return useQuery({
    queryKey: ventaQueryKeys.venta(ventaId),
    queryFn: async () => {
      const { data, error } = await supabase.from('ventas_cuenta_corriente_saldo').select('*').eq('id', ventaId).maybeSingle()
      if (error) throw error
      return data as VentaCuentaCorrienteSaldo | null
    },
  })
}

// El RPC rechaza con este texto si la versión no coincide (otra pantalla la cambió).
export function esConflictoDeVersion(err: unknown): boolean {
  const msg = err instanceof ErrorRegistrarPago ? err.causa.message : err instanceof Error ? err.message : ''
  return /cambió mientras/.test(msg)
}

function invalidarVentaInterna(queryClient: QueryClient, clienteId: string, ventaId: string) {
  return Promise.all([
    invalidarCuentaCliente(queryClient, clienteId),
    queryClient.invalidateQueries({ queryKey: ['venta', ventaId] }),
    queryClient.invalidateQueries({ queryKey: ['consumo-interno'] }),
  ])
}

type Rpc = { data: unknown; error: import('@supabase/supabase-js').PostgrestError | null; status: number }
async function llamar(p: PromiseLike<Rpc>) {
  const { data, error, status } = await p
  if (error) throw new ErrorRegistrarPago(error, status)
  return data
}

export function useEditarVentaInterna(supabase: SupabaseClient) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (input: { clienteId: string; ventaId: string; version: number; descuentos: { itemId: string; descuento: number }[] }) =>
      llamar(
        supabase.rpc('editar_venta_interna', {
          p_venta_id: input.ventaId,
          p_items: input.descuentos.map((d) => ({ item_id: d.itemId, descuento_porcentaje: Math.round(d.descuento * 100) / 100 })),
          p_version: input.version,
        }),
      ) as Promise<{ venta_id: string; subtotal: number; total: number; total_original: number; version: number }>,
    onSettled: (_d, _e, input) => invalidarVentaInterna(queryClient, input.clienteId, input.ventaId),
  })
}

export function useFinalizarVentaInterna(supabase: SupabaseClient) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (input: { clienteId: string; ventaId: string; version: number }) =>
      llamar(supabase.rpc('finalizar_venta_interna', { p_venta_id: input.ventaId, p_version: input.version })),
    onSettled: (_d, _e, input) => invalidarVentaInterna(queryClient, input.clienteId, input.ventaId),
  })
}

export function useReabrirVentaInterna(supabase: SupabaseClient) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (input: { clienteId: string; ventaId: string; motivo: string }) =>
      llamar(supabase.rpc('reabrir_venta_interna', { p_venta_id: input.ventaId, p_motivo: input.motivo.trim() })),
    onSettled: (_d, _e, input) => invalidarVentaInterna(queryClient, input.clienteId, input.ventaId),
  })
}

// D11: total mensual por fecha de finalización (vista consumo_interno_mensual).
export type ConsumoInternoMes = { cliente_id: string; cliente_nombre: string; mes: string; cantidad_comprobantes: number; total: number; total_original: number }

export function useConsumoInternoMensual(supabase: SupabaseClient, clienteId?: string) {
  return useQuery({
    queryKey: ['consumo-interno', 'mensual', clienteId ?? 'todos'],
    queryFn: async () => {
      let q = supabase.from('consumo_interno_mensual').select('*').order('mes', { ascending: false })
      if (clienteId) q = q.eq('cliente_id', clienteId)
      const { data, error } = await q
      if (error) throw error
      return (data ?? []) as ConsumoInternoMes[]
    },
  })
}

// dashboard_consumo_interno: una fila por día × cliente × producto × estado (D8).
export type ConsumoInternoFila = {
  fecha: string
  cliente_id: string
  cliente_nombre: string
  producto_id: string
  nombre: string
  marca: string | null
  estado_interno: 'pendiente' | 'finalizado'
  unidades: number
  importe: number
}

export function useDashboardConsumoInterno(supabase: SupabaseClient, desde: string, hasta: string) {
  return useQuery({
    queryKey: ['consumo-interno', 'dashboard', desde, hasta],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('dashboard_consumo_interno', { p_desde: desde, p_hasta: hasta })
      if (error) throw error
      return ((data ?? []) as ConsumoInternoFila[]).map((f) => ({ ...f, unidades: Number(f.unidades), importe: Number(f.importe) }))
    },
  })
}
