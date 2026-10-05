// Carga de factura de compra y pago a proveedor — lógica compartida entre Virikyna Local
// (escritorio) y Virikyna Inventario (celular), ver docs/04_modulos_y_funciones.md módulo 6
// y los RPCs `cargar_factura_compra` / `registrar_pago_proveedor` (docs/06_estructura_de_datos.md).
// Cada app solo arma la UI y llama a estas funciones con su propio cliente de Supabase —
// el cálculo de totales y el mapeo de payload viven acá una sola vez.

import type { PostgrestError, SupabaseClient } from '@supabase/supabase-js'
import { useMutation, useQuery, useQueryClient, type QueryClient } from '@tanstack/react-query'
import type {
  CategoriaEgreso,
  FacturaCompraSaldo,
  FormaPagoCompra,
  FormaPagoEgreso,
  LetraComprobanteCompra,
  OrigenEgreso,
  PagoProveedor,
  PagoProveedorAplicacion,
  ProveedorSaldo,
  RegistrarPagoProveedorV2Resultado,
  TipoComprobanteCompra,
  UbicacionStock,
} from '../types/database'
import { IVA_DEFAULT } from './inventario'
import type { ProductoPrecioActual } from './precios'
import { fechaHoyISO } from './format'
import { nombresPorId } from './perfiles'

// Etiquetas únicas para tipo de comprobante de compra — todas las pantallas (carga, listados,
// detalle, cuenta corriente) leen de acá, así un tipo nuevo (ej. presupuesto, docs/31) aparece en
// todas a la vez. TIPOS_COMPROBANTE_COMPRA fija el orden de los selects.
export const TIPO_COMPROBANTE_COMPRA_LABEL: Record<TipoComprobanteCompra, string> = {
  factura: 'Factura',
  remito: 'Remito',
  cupon: 'Cupón',
  presupuesto: 'Presupuesto',
  nota_credito: 'Nota de crédito',
  nota_debito: 'Nota de débito',
}

export const TIPOS_COMPROBANTE_COMPRA: TipoComprobanteCompra[] = [
  'factura',
  'remito',
  'cupon',
  'presupuesto',
  'nota_credito',
  'nota_debito',
]

export const FORMA_PAGO_EGRESO_LABEL: Record<FormaPagoEgreso, string> = {
  efectivo: 'Efectivo',
  transferencia: 'Transferencia',
  cheque: 'Cheque',
  echeq: 'E-cheq',
}

export const FORMAS_PAGO_EGRESO = Object.keys(FORMA_PAGO_EGRESO_LABEL) as FormaPagoEgreso[]

export function esCheque(formaPago: FormaPagoEgreso): boolean {
  return formaPago === 'cheque' || formaPago === 'echeq'
}

// "Factura A 0001-00012345" — tipo + letra + punto de venta-número, lo que haya cargado.
export function etiquetaComprobanteCompra(
  c: Pick<FacturaCompraSaldo, 'tipo_comprobante' | 'letra' | 'punto_venta' | 'numero_comprobante'>,
): string {
  const numero = [c.punto_venta, c.numero_comprobante].filter(Boolean).join('-')
  return [TIPO_COMPROBANTE_COMPRA_LABEL[c.tipo_comprobante] ?? c.tipo_comprobante, c.letra, numero || 'sin número']
    .filter(Boolean)
    .join(' ')
}

export type ItemFacturaCompra = {
  key: string
  productoId: string | null
  descripcion: string
  cantidad: string
  precioUnitarioSinIva: string
  descuentoPorcentaje: string
  ubicacion: UbicacionStock
}

export function nuevoItemFacturaCompra(): ItemFacturaCompra {
  return {
    key: crypto.randomUUID(),
    productoId: null,
    descripcion: '',
    cantidad: '1',
    precioUnitarioSinIva: '',
    descuentoPorcentaje: '0',
    ubicacion: 'local',
  }
}

export function totalItemFacturaCompra(item: ItemFacturaCompra): number {
  const cantidad = Number(item.cantidad) || 0
  const precio = Number(item.precioUnitarioSinIva) || 0
  const descuento = Number(item.descuentoPorcentaje) || 0
  return Math.round(cantidad * precio * (1 - descuento / 100) * 100) / 100
}

// Mismo criterio que usa el RPC para descartar filas en blanco: sin descripción o sin
// cantidad no cuenta como ítem cargado.
export function itemsValidosFacturaCompra(items: ItemFacturaCompra[]): ItemFacturaCompra[] {
  return items.filter((it) => it.descripcion.trim() && Number(it.cantidad) > 0)
}

// `descuento` es informativo: lo que restan los % de descuento por ítem, ya descontado del
// subtotal (no se resta de nuevo del total). `saldoPendiente`: al cargar la factura todavía no
// hay pagos (el RPC no registra ninguno, ni siquiera en contado), así que es igual al total.
export function calcularTotalesFacturaCompra(items: ItemFacturaCompra[]): {
  subtotalSinIva: number
  descuento: number
  iva: number
  total: number
  saldoPendiente: number
} {
  const validos = itemsValidosFacturaCompra(items)
  const subtotalSinIva = validos.reduce((acc, it) => acc + totalItemFacturaCompra(it), 0)
  const bruto = validos.reduce((acc, it) => acc + (Number(it.cantidad) || 0) * (Number(it.precioUnitarioSinIva) || 0), 0)
  const descuento = Math.max(0, Math.round((bruto - subtotalSinIva) * 100) / 100)
  const iva = Math.round(subtotalSinIva * (IVA_DEFAULT / 100) * 100) / 100
  const total = subtotalSinIva + iva
  return { subtotalSinIva, descuento, iva, total, saldoPendiente: total }
}

// Extiende el ítem "real" (el que viaja al RPC `cargar_factura_compra`) con campos que
// solo existen para la UI de la planilla/tarjeta de carga y nunca se envían al backend:
// - marca: para ítems vinculados al catálogo es puramente informativa (ya vive en producto.marca,
//   recuperable vía producto_id); para ítems libres se pega dentro de `descripcion` recién al
//   guardar (ver integrarMarcaEnItemsLibres), porque no existe una columna de marca por ítem.
// - codigoBarras: solo dispara la búsqueda de producto, no se persiste (un ítem libre no tiene
//   código de barras propio en el catálogo).
// - productoPrecio: costo, márgenes, IVA, proveedor y precio de venta del producto vinculado, tal
//   como estaban al elegirlo — para avisar cómo cambia el precio de venta al guardar
//   (cambiosPrecioFactura, lib/precios.ts). null en ítems libres.
export type ItemFacturaCompraUI = ItemFacturaCompra & {
  marca: string
  codigoBarras: string
  productoPrecio: ProductoPrecioActual | null
}

export function nuevoItemFacturaCompraUI(): ItemFacturaCompraUI {
  return { ...nuevoItemFacturaCompra(), marca: '', codigoBarras: '', productoPrecio: null }
}

export type ProblemaItemFacturaCompra = { key: string; numero: number; mensaje: string }

// Ítems que el usuario empezó a cargar pero que itemsValidosFacturaCompra descartaría al guardar
// — antes se perdían en silencio (ej. un código escaneado que no existía, con cantidad y precio
// cargados, pero sin producto). Una fila totalmente en blanco (cantidad 1 por defecto) no cuenta:
// esa se ignora como siempre. Se valida antes de guardar y bloquea hasta resolverlo.
export function problemasItemsFacturaCompra(items: ItemFacturaCompraUI[]): ProblemaItemFacturaCompra[] {
  const problemas: ProblemaItemFacturaCompra[] = []
  items.forEach((it, i) => {
    const numero = i + 1
    const tieneProducto = it.descripcion.trim() !== ''
    const empezado =
      tieneProducto ||
      it.codigoBarras.trim() !== '' ||
      it.marca.trim() !== '' ||
      (Number(it.precioUnitarioSinIva) || 0) > 0 ||
      (Number(it.descuentoPorcentaje) || 0) > 0
    if (!empezado) return
    if (!tieneProducto) {
      problemas.push({ key: it.key, numero, mensaje: `El ítem ${numero} no tiene producto seleccionado.` })
    } else if (!(Number(it.cantidad) > 0)) {
      problemas.push({ key: it.key, numero, mensaje: `El ítem ${numero} tiene cantidad 0 — completala o quitá el ítem.` })
    }
  })
  return problemas
}

// Un ítem libre (sin producto_id) no tiene columna propia de marca en la factura — la pegamos
// dentro de la descripción para no perderla. Un ítem vinculado al catálogo no la necesita ahí:
// ya se recupera vía producto_id → producto.marca.
export function integrarMarcaEnItemsLibres<T extends ItemFacturaCompra & { marca: string }>(items: T[]): T[] {
  return items.map((it) =>
    !it.productoId && it.marca.trim() ? { ...it, descripcion: `${it.descripcion.trim()} - ${it.marca.trim()}` } : it,
  )
}

export type CargarFacturaCompraInput = {
  proveedorId: string
  tipoComprobante: TipoComprobanteCompra
  letra: LetraComprobanteCompra | null
  puntoVenta: string | null
  numeroComprobante: string | null
  fechaComprobante: string
  fechaFiscal: string | null
  formaPago: FormaPagoCompra
  items: ItemFacturaCompra[]
}

// Único punto de llamada al RPC `cargar_factura_compra` — arma el payload de ítems, el
// cálculo de totales y la actualización de stock quedan del lado de la función SQL.
export function cargarFacturaCompra(supabase: SupabaseClient, input: CargarFacturaCompraInput) {
  return supabase.rpc('cargar_factura_compra', {
    p_proveedor_id: input.proveedorId,
    p_tipo_comprobante: input.tipoComprobante,
    p_letra: input.letra,
    p_punto_venta: input.puntoVenta,
    p_numero_comprobante: input.numeroComprobante,
    p_fecha_comprobante: input.fechaComprobante,
    p_fecha_fiscal: input.fechaFiscal,
    p_forma_pago: input.formaPago,
    p_items: itemsValidosFacturaCompra(input.items).map((it) => ({
      producto_id: it.productoId,
      descripcion: it.descripcion.trim(),
      cantidad: Number(it.cantidad),
      precio_unitario_sin_iva: Number(it.precioUnitarioSinIva) || 0,
      descuento_porcentaje: Number(it.descuentoPorcentaje) || 0,
      ubicacion: it.ubicacion,
    })),
  })
}

export type EditarFacturaCompraInput = {
  facturaId: string
  tipoComprobante: TipoComprobanteCompra
  numeroComprobante: string | null
  fechaComprobante: string
  formaPago: FormaPagoCompra
}

// Único punto de llamada al RPC `editar_factura_compra` (docs/06_estructura_de_datos.md, RPC 10)
// — exclusivo Virikyna Gestión. Solo campos descriptivos: letra y punto de venta quedan sin
// tocar (el RPC los conserva vía COALESCE al no recibirlos), ítems y montos nunca se editan
// desde acá — si el error está ahí, se anula la factura y se recarga de nuevo.
export function editarFacturaCompra(supabase: SupabaseClient, input: EditarFacturaCompraInput) {
  return supabase.rpc('editar_factura_compra', {
    p_factura_id: input.facturaId,
    p_tipo_comprobante: input.tipoComprobante,
    p_numero_comprobante: input.numeroComprobante,
    p_fecha_comprobante: input.fechaComprobante,
    p_forma_pago: input.formaPago,
  })
}

// Único punto de llamada al RPC `anular_factura_compra` (docs/06_estructura_de_datos.md, RPC 11)
// — exclusivo Virikyna Gestión. Revierte el stock que la carga original había sumado; si la
// factura ya tiene pagos registrados, el RPC rechaza la anulación con su propio mensaje, que se
// muestra tal cual en el cliente (ver friendlyError).
export function anularFacturaCompra(supabase: SupabaseClient, facturaId: string, motivo: string) {
  return supabase.rpc('anular_factura_compra', { p_factura_id: facturaId, p_motivo: motivo })
}

export type RegistrarPagoProveedorInput = {
  proveedorId: string
  facturaCompraId: string | null // null = pago a cuenta general, sin factura puntual
  monto: number
  formaPago: FormaPagoEgreso
  origen?: OrigenEgreso
  cierreCajaId?: string | null
  // Solo aplican (y son obligatorios) cuando formaPago es 'cheque' o 'echeq' — docs/15_cheques_proveedor.sql.
  chequeNumero?: string | null
  chequeFechaSalida?: string | null // DATE 'YYYY-MM-DD'
  chequeFechaVencimiento?: string | null // DATE 'YYYY-MM-DD'
}

// Único punto de llamada al RPC `registrar_pago_proveedor` — usado tanto desde el detalle de
// una factura puntual como desde el registro de egresos (categoría "Pago a proveedor"). Los
// dos puntos de entrada de la UI ejecutan esta misma función, nunca una copia (docs/04, módulo 6).
export function registrarPagoProveedor(supabase: SupabaseClient, input: RegistrarPagoProveedorInput) {
  return supabase.rpc('registrar_pago_proveedor', {
    p_proveedor_id: input.proveedorId,
    p_factura_compra_id: input.facturaCompraId,
    p_monto: input.monto,
    p_forma_pago: input.formaPago,
    p_origen: input.origen ?? 'turno',
    p_cierre_caja_id: input.cierreCajaId ?? null,
    p_cheque_numero: input.chequeNumero ?? null,
    p_cheque_fecha_salida: input.chequeFechaSalida ?? null,
    p_cheque_fecha_vencimiento: input.chequeFechaVencimiento ?? null,
  })
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Cuenta corriente de proveedores (docs/31): pago con imputación a varios comprobantes + NC
// ─────────────────────────────────────────────────────────────────────────────────────────────

export type RegistrarPagoProveedorV2Input = {
  proveedorId: string
  monto: number // 0 = solo aplicar crédito de notas de crédito (sin egreso)
  formaPago: FormaPagoEgreso
  facturaIds?: string[] // vacío/ausente = las pendientes más viejas primero
  notaCreditoIds?: string[]
  // Obligatorio a propósito: 'turno' = caja de Local (entra en su Cierre), 'general' = Gestión
  // (no entra). Sin default para que ninguna pantalla nueva herede 'turno' sin querer.
  origen: OrigenEgreso
  cierreCajaId?: string | null
  fecha?: string | null // DATE; null = hoy AR (lo resuelve el RPC)
  nota?: string | null
  chequeNumero?: string | null
  chequeFechaSalida?: string | null
  chequeFechaVencimiento?: string | null
}

// Único punto de llamada a `registrar_pago_proveedor_v2`.
export function registrarPagoProveedorV2(supabase: SupabaseClient, input: RegistrarPagoProveedorV2Input) {
  const cheque = input.monto > 0 && esCheque(input.formaPago)
  return supabase.rpc('registrar_pago_proveedor_v2', {
    p_proveedor_id: input.proveedorId,
    p_monto: input.monto,
    // Con monto 0 no hay egreso ni movimiento: el RPC igual exige una forma de pago (no puede ser
    // cheque), así que la UI oculta el campo y mandamos efectivo.
    p_forma_pago: input.monto > 0 ? input.formaPago : 'efectivo',
    p_factura_ids: input.facturaIds?.length ? input.facturaIds : null,
    p_nota_credito_ids: input.notaCreditoIds?.length ? input.notaCreditoIds : null,
    p_origen: input.origen,
    p_cierre_caja_id: input.cierreCajaId ?? null,
    p_fecha: input.fecha || null,
    p_nota: input.nota?.trim() || null,
    p_cheque_numero: cheque ? input.chequeNumero?.trim() || null : null,
    p_cheque_fecha_salida: cheque ? input.chequeFechaSalida || null : null,
    p_cheque_fecha_vencimiento: cheque ? input.chequeFechaVencimiento || null : null,
  })
}

// Validaciones de formulario de un pago a proveedor — las mismas en el modal de pago de una
// factura y en el de la cuenta corriente. El RPC vuelve a validar todo; esto evita el viaje.
export function validarPagoProveedor(input: {
  monto: number
  formaPago: FormaPagoEgreso
  permiteMontoCero: boolean // true si hay NC elegidas (pago solo con crédito)
  chequeNumero: string
  chequeFechaSalida: string
  chequeFechaVencimiento: string
}): string | null {
  if (!Number.isFinite(input.monto) || input.monto < 0) return 'Ingresá un monto válido.'
  if (input.monto === 0 && !input.permiteMontoCero) return 'Ingresá un monto mayor a cero.'
  if (input.monto > 0 && esCheque(input.formaPago)) {
    if (!input.chequeNumero.trim()) return 'Ingresá el número de cheque.'
    if (!input.chequeFechaSalida) return 'Ingresá la fecha de salida del cheque.'
    if (!input.chequeFechaVencimiento) return 'Ingresá la fecha de vencimiento del cheque.'
  }
  return null
}

// Error de escritura con el status HTTP, para que la pantalla distinga "sin conexión" de un
// error de negocio (mensajeErrorGuardado).
export class ErrorRegistrarPago extends Error {
  constructor(
    public causa: PostgrestError,
    public status: number,
  ) {
    super(causa.message)
  }
}

export const proveedorQueryKeys = {
  proveedor: (id: string) => ['proveedor', id] as const,
  comprobantes: (id: string) => ['proveedor', id, 'comprobantes'] as const,
  pagos: (id: string) => ['proveedor', id, 'pagos'] as const,
  saldos: ['proveedores-saldo'] as const,
}

// Todo lo que cambia cuando se paga, se edita o se anula un comprobante de un proveedor.
export function invalidarCuentaProveedor(queryClient: QueryClient, proveedorId: string) {
  return Promise.all([
    queryClient.invalidateQueries({ queryKey: proveedorQueryKeys.proveedor(proveedorId) }),
    queryClient.invalidateQueries({ queryKey: proveedorQueryKeys.comprobantes(proveedorId) }),
    queryClient.invalidateQueries({ queryKey: proveedorQueryKeys.pagos(proveedorId) }),
    queryClient.invalidateQueries({ queryKey: proveedorQueryKeys.saldos }),
  ])
}

export function useProveedoresSaldo(supabase: SupabaseClient) {
  return useQuery({
    queryKey: proveedorQueryKeys.saldos,
    queryFn: async () => {
      const { data, error } = await supabase.from('proveedores_saldo').select('*').order('razon_social')
      if (error) throw error
      return (data ?? []) as ProveedorSaldo[]
    },
  })
}

export function useProveedor(supabase: SupabaseClient, proveedorId: string) {
  return useQuery({
    queryKey: proveedorQueryKeys.proveedor(proveedorId),
    queryFn: async () => {
      const { data, error } = await supabase.from('proveedores_saldo').select('*').eq('id', proveedorId).maybeSingle()
      if (error) throw error
      return data as ProveedorSaldo | null
    },
  })
}

// Todos los comprobantes del proveedor (con saldo, aplicado, crédito y estado de la vista). Los
// filtros de la pantalla son del lado del cliente: un proveedor tiene decenas, no miles.
export function useComprobantesProveedor(supabase: SupabaseClient, proveedorId: string) {
  return useQuery({
    queryKey: proveedorQueryKeys.comprobantes(proveedorId),
    queryFn: async () => {
      const { data, error } = await supabase
        .from('facturas_compra_saldo')
        .select('*')
        .eq('proveedor_id', proveedorId)
        .order('fecha_comprobante', { ascending: false })
        .order('created_at', { ascending: false })
      if (error) throw error
      return (data ?? []) as FacturaCompraSaldo[]
    },
  })
}

export type AplicacionDePago = Pick<
  PagoProveedorAplicacion,
  'id' | 'factura_compra_id' | 'monto' | 'pago_proveedor_id' | 'nota_credito_id' | 'revertida_at'
>

export type PagoProveedorConDetalle = PagoProveedor & {
  usuario_nombre: string | null
  aplicaciones: AplicacionDePago[] // todas las de la operación (plata y NC), vigentes o revertidas
  revertido: boolean // existe una fila de reversión que apunta a este pago
}

export function usePagosProveedor(supabase: SupabaseClient, proveedorId: string) {
  return useQuery({
    queryKey: proveedorQueryKeys.pagos(proveedorId),
    queryFn: async (): Promise<PagoProveedorConDetalle[]> => {
      const { data, error } = await supabase
        .from('pagos_proveedor')
        .select(
          '*, aplicaciones:pagos_proveedor_aplicaciones!pagos_proveedor_aplicaciones_operacion_id_fkey(id, factura_compra_id, monto, pago_proveedor_id, nota_credito_id, revertida_at)',
        )
        .eq('proveedor_id', proveedorId)
        .order('fecha', { ascending: false })
        .order('created_at', { ascending: false })
      if (error) throw error

      const pagos = (data ?? []) as (PagoProveedor & { aplicaciones: AplicacionDePago[] | null })[]
      const revertidos = new Set(pagos.map((p) => p.revierte_pago_proveedor_id).filter(Boolean))
      const nombres = await nombresPorId(
        supabase,
        pagos.map((p) => p.usuario_id),
      )
      return pagos.map((p) => ({
        ...p,
        aplicaciones: p.aplicaciones ?? [],
        usuario_nombre: nombres.get(p.usuario_id) ?? null,
        revertido: revertidos.has(p.id),
      }))
    },
  })
}

// Mutation del pago: si falla, tira ErrorRegistrarPago (con status) y no invalida nada. Si sale
// bien, invalida las 4 claves del proveedor — la lista, la cabecera, los comprobantes y los pagos.
export function useRegistrarPagoProveedorV2(supabase: SupabaseClient) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (input: RegistrarPagoProveedorV2Input) => {
      const { data, error, status } = await registrarPagoProveedorV2(supabase, input)
      if (error) throw new ErrorRegistrarPago(error, status)
      return data as RegistrarPagoProveedorV2Resultado
    },
    onSuccess: (_data, input) => invalidarCuentaProveedor(queryClient, input.proveedorId),
  })
}

export type RegistrarEgresoGeneralInput = {
  categoria: CategoriaEgreso
  monto: number
  descripcion: string
  formaPago: FormaPagoEgreso
  origen?: OrigenEgreso
  cierreCajaId?: string | null
  fecha?: string // DATE 'YYYY-MM-DD' — fecha real del egreso, editable desde el módulo Egresos.
  // Sin especificar, hoy: el egreso de turno del cajero (Virikyna Local) nunca la manda.
}

// Único punto de llamada al RPC `registrar_egreso_general` — gasto sin proveedor (sueldo,
// servicio, otro). Misma función tanto para el egreso de turno del cajero (origen='turno')
// como para el egreso general de Caja Gestión (origen='general'); nunca para pago a proveedor,
// que va por `registrarPagoProveedor` (docs/06_estructura_de_datos.md, RPC 5.1).
export function registrarEgresoGeneral(supabase: SupabaseClient, input: RegistrarEgresoGeneralInput) {
  return supabase.rpc('registrar_egreso_general', {
    p_categoria: input.categoria,
    p_monto: input.monto,
    p_descripcion: input.descripcion,
    p_forma_pago: input.formaPago,
    p_origen: input.origen ?? 'general',
    p_cierre_caja_id: input.cierreCajaId ?? null,
    p_fecha: input.fecha ?? fechaHoyISO(),
  })
}
