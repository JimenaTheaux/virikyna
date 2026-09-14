// Carga de factura de compra y pago a proveedor — lógica compartida entre Virikyna Local
// (escritorio) y Virikyna Inventario (celular), ver docs/04_modulos_y_funciones.md módulo 6
// y los RPCs `cargar_factura_compra` / `registrar_pago_proveedor` (docs/06_estructura_de_datos.md).
// Cada app solo arma la UI y llama a estas funciones con su propio cliente de Supabase —
// el cálculo de totales y el mapeo de payload viven acá una sola vez.

import type { SupabaseClient } from '@supabase/supabase-js'
import type {
  CategoriaEgreso,
  FormaPagoCompra,
  FormaPagoEgreso,
  LetraComprobanteCompra,
  OrigenEgreso,
  TipoComprobanteCompra,
  UbicacionStock,
} from '../types/database'
import { IVA_DEFAULT } from './inventario'
import { fechaHoyISO } from './format'

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

export function calcularTotalesFacturaCompra(items: ItemFacturaCompra[]): {
  subtotalSinIva: number
  iva: number
  total: number
} {
  const subtotalSinIva = itemsValidosFacturaCompra(items).reduce((acc, it) => acc + totalItemFacturaCompra(it), 0)
  const iva = Math.round(subtotalSinIva * (IVA_DEFAULT / 100) * 100) / 100
  return { subtotalSinIva, iva, total: subtotalSinIva + iva }
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
