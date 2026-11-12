// Datos y helpers del Comprobante X (Ventas, Local) y la Factura C (Facturación, Local y Gestión) —
// ambos se muestran y se envían con el mismo componente (src/components/ComprobanteModal.tsx) y se
// generan con el mismo layout en PDF (comprobantePdf.ts) e imagen JPG (comprobanteImagen.ts).
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Cliente, FacturaC, FormaPagoVenta, Producto, Venta, VentaItem } from '../types/database'
import { formatCurrency } from './format'
import { nombreItemVendido } from './productoTexto'

export type ItemComprobante = {
  nombre: string // nombre · marca, tal como se imprime (nombreConMarca / nombreItemVendido)
  codigo: string
  cantidad: number
  precioUnitario: number
  importe: number
}

export type DatosComprobante = {
  tipo: 'comprobante_x' | 'factura_c'
  numero: string
  fecha: string
  clienteNombre: string
  clienteMail: string | null
  clienteCelular: string | null
  formaPago: FormaPagoVenta
  pagos?: { formaPago: FormaPagoVenta; monto: number }[] // solo con más de 1 elemento = pago combinado
  items: ItemComprobante[]
  subtotal: number
  descuentoPorcentaje: number
  recargoPorcentaje: number
  precioOficial: number // calculado por el sistema, antes del redondeo manual del cajero
  total: number // = precio cobrado (puede diferir de precioOficial por redondeo)
  cae: string | null
  // ventas.nota, la que carga el cajero. Solo se muestra en pantalla (no va al PDF, a la imagen ni
  // al mensaje de envío: es interna). Opcional porque el comprobante recién cobrado en Ventas y
  // "Ventas del día" arman su DatosComprobante sin nota.
  nota?: string | null
}

export const FORMA_PAGO_LABEL: Record<FormaPagoVenta, string> = {
  efectivo: 'Efectivo',
  transferencia: 'Transferencia',
  qr: 'QR',
  tarjeta_debito: 'Tarjeta débito',
  tarjeta_credito: 'Tarjeta crédito',
  cuenta_corriente: 'Cuenta corriente',
  combinado: 'Pago combinado',
}

// Ítems de una venta ya registrada, para reabrir su comprobante: el nombre y la marca guardados al
// vender (docs/42) y, en ventas anteriores sin ese dato, los actuales del producto.
export const SELECT_ITEMS_COMPROBANTE =
  'cantidad, precio_unitario, importe, producto_nombre, producto_marca, producto:productos(nombre, marca, codigo_barras, codigo_interno)'

export type VentaItemComprobanteRow = Pick<
  VentaItem,
  'cantidad' | 'precio_unitario' | 'importe' | 'producto_nombre' | 'producto_marca'
> & {
  producto: Pick<Producto, 'nombre' | 'marca' | 'codigo_barras' | 'codigo_interno'> | null
}

export function itemsComprobanteDesdeVenta(rows: VentaItemComprobanteRow[]): ItemComprobante[] {
  return rows.map((it) => ({
    nombre: nombreItemVendido(it, it.producto),
    codigo: it.producto?.codigo_barras ?? it.producto?.codigo_interno ?? '',
    cantidad: Number(it.cantidad),
    precioUnitario: Number(it.precio_unitario),
    importe: Number(it.importe),
  }))
}

// Venta ya registrada con lo necesario para su comprobante (la consulta de Facturación y de Ventas
// del día: factura_c, cliente e ítems embebidos).
export type VentaConComprobante = Pick<
  Venta,
  | 'id'
  | 'numero'
  | 'forma_pago'
  | 'created_at'
  | 'subtotal'
  | 'descuento_porcentaje'
  | 'recargo_porcentaje'
  | 'precio_oficial'
  | 'total'
  | 'nota'
> & {
  factura_c: Pick<FacturaC, 'punto_venta' | 'numero_factura' | 'fecha_emision' | 'cae'> | null
  cliente: Pick<Cliente, 'razon_social' | 'nombre_fantasia' | 'mail' | 'celular'> | null
  items: VentaItemComprobanteRow[] | null
}

// Comprobante X / Factura C de una venta ya cargada en la lista — una sola vez para Facturación
// (Local y Gestión) y Ventas del día (docs/73). Si solo se tiene el id: cargarComprobanteVenta, más
// abajo. `conNota`: Ventas del día arma el comprobante sin la nota interna (como siempre).
export async function armarDatosComprobanteVenta(
  supabase: SupabaseClient,
  venta: VentaConComprobante,
  { conNota = true }: { conNota?: boolean } = {},
): Promise<DatosComprobante> {
  let pagos: { formaPago: FormaPagoVenta; monto: number }[] | undefined
  if (venta.forma_pago === 'combinado') {
    const { data: pagosData } = await supabase.from('venta_pagos').select('forma_pago, monto').eq('venta_id', venta.id)
    pagos = ((pagosData ?? []) as { forma_pago: FormaPagoVenta; monto: number }[]).map((p) => ({
      formaPago: p.forma_pago,
      monto: p.monto,
    }))
  }
  return {
    tipo: venta.factura_c ? 'factura_c' : 'comprobante_x',
    numero: venta.factura_c ? `${venta.factura_c.punto_venta}-${venta.factura_c.numero_factura}` : String(venta.numero),
    fecha: venta.factura_c?.fecha_emision ?? venta.created_at,
    clienteNombre: venta.cliente ? venta.cliente.razon_social ?? venta.cliente.nombre_fantasia ?? 'Cliente' : 'Consumidor final',
    clienteMail: venta.cliente?.mail ?? null,
    clienteCelular: venta.cliente?.celular ?? null,
    formaPago: venta.forma_pago,
    pagos,
    items: itemsComprobanteDesdeVenta(venta.items ?? []),
    subtotal: venta.subtotal,
    descuentoPorcentaje: venta.descuento_porcentaje,
    recargoPorcentaje: venta.recargo_porcentaje,
    precioOficial: venta.precio_oficial,
    total: venta.total,
    cae: venta.factura_c?.cae ?? null,
    ...(conNota ? { nota: venta.nota } : {}),
  }
}

// Una línea si es pago simple ("Forma de pago: Efectivo"), o el encabezado + una línea por
// cada parte si es combinado — usado por pantalla, PDF e imagen del comprobante.
export function lineasFormaPago(datos: DatosComprobante): string[] {
  if (datos.pagos && datos.pagos.length > 1) {
    return [
      `Forma de pago: ${FORMA_PAGO_LABEL[datos.formaPago]}`,
      ...datos.pagos.map((p) => `  ${FORMA_PAGO_LABEL[p.formaPago]}: ${formatCurrency(p.monto)}`),
    ]
  }
  return [`Forma de pago: ${FORMA_PAGO_LABEL[datos.formaPago]}`]
}

// wa.me exige solo dígitos con código de país, sin "+" — Argentina es 54.
export function normalizarCelularArg(valor: string): string {
  const digits = valor.replace(/\D/g, '')
  if (!digits) return ''
  return digits.startsWith('54') ? digits : `54${digits}`
}

export function linkWhatsApp(celular: string, mensaje: string): string {
  return `https://wa.me/${normalizarCelularArg(celular)}?text=${encodeURIComponent(mensaje)}`
}

// Compone directo a Gmail Web (en vez de mailto:) para que abra listo para enviar, con adjunto pendiente.
export function linkGmail(mail: string, asunto: string, cuerpo: string): string {
  const params = new URLSearchParams({ view: 'cm', fs: '1', to: mail, su: asunto, body: cuerpo })
  return `https://mail.google.com/mail/?${params.toString()}`
}

export function mensajeEnvio(datos: DatosComprobante): string {
  const titulo = datos.tipo === 'factura_c' ? 'Factura C' : 'Comprobante X'
  // "2 x Lavandina · Ayudín — $ 2.400,00 ($ 1.200,00 c/u)": el nombre ya trae la marca.
  const detalle = datos.items.map((it) => {
    const cantidad = it.cantidad.toLocaleString('es-AR', { maximumFractionDigits: 3 })
    const unitario = it.cantidad !== 1 ? ` (${formatCurrency(it.precioUnitario)} c/u)` : ''
    return `${cantidad} x ${it.nombre} — ${formatCurrency(it.importe)}${unitario}`
  })
  return [
    'Gracias por tu compra!!!',
    '',
    'Compraste:',
    ...detalle,
    '',
    `${titulo} ${datos.numero} — Virikyna`,
    `Total: ${formatCurrency(datos.total)}`,
    '',
    'Cualquier consulta, escribinos por acá.',
  ].join('\n')
}

export function nombreArchivoComprobante(datos: DatosComprobante, extension: 'pdf' | 'jpg'): string {
  const prefijo = datos.tipo === 'factura_c' ? 'factura-c' : 'comprobante-x'
  const numeroLimpio = datos.numero.replace(/[^\w-]+/g, '')
  return `${prefijo}-${numeroLimpio}.${extension}`
}

// Comprobante de una venta de la que solo se tiene el id (historial del producto, docs/70): el mismo
// armado que Facturación y Ventas del día (Factura C si la tiene; si no, Comprobante X, con la nota).
type VentaParaComprobante = Venta & {
  factura_c: FacturaC | FacturaC[] | null
  cliente: Pick<Cliente, 'razon_social' | 'nombre_fantasia' | 'mail' | 'celular'> | null
  items: VentaItemComprobanteRow[]
}

export async function cargarComprobanteVenta(supabase: SupabaseClient, ventaId: string): Promise<DatosComprobante> {
  const { data, error } = await supabase
    .from('ventas')
    .select(
      `*, factura_c:facturas_c(*), cliente:clientes(razon_social, nombre_fantasia, mail, celular), items:venta_items(${SELECT_ITEMS_COMPROBANTE})`,
    )
    .eq('id', ventaId)
    .single()
  if (error) throw error
  const venta = data as unknown as VentaParaComprobante
  const factura = Array.isArray(venta.factura_c) ? (venta.factura_c[0] ?? null) : venta.factura_c

  let pagos: { formaPago: FormaPagoVenta; monto: number }[] | undefined
  if (venta.forma_pago === 'combinado') {
    const { data: pagosData, error: errorPagos } = await supabase
      .from('venta_pagos')
      .select('forma_pago, monto')
      .eq('venta_id', venta.id)
    if (errorPagos) throw errorPagos
    pagos = (pagosData ?? []).map((p) => ({ formaPago: p.forma_pago as FormaPagoVenta, monto: Number(p.monto) }))
  }

  return {
    tipo: factura ? 'factura_c' : 'comprobante_x',
    numero: factura ? `${factura.punto_venta}-${factura.numero_factura}` : String(venta.numero),
    fecha: factura?.fecha_emision ?? venta.created_at,
    clienteNombre: venta.cliente
      ? venta.cliente.razon_social ?? venta.cliente.nombre_fantasia ?? 'Cliente'
      : 'Consumidor final',
    clienteMail: venta.cliente?.mail ?? null,
    clienteCelular: venta.cliente?.celular ?? null,
    formaPago: venta.forma_pago,
    pagos,
    items: itemsComprobanteDesdeVenta(venta.items ?? []),
    subtotal: venta.subtotal,
    descuentoPorcentaje: venta.descuento_porcentaje,
    recargoPorcentaje: venta.recargo_porcentaje,
    precioOficial: venta.precio_oficial,
    total: venta.total,
    cae: factura?.cae ?? null,
    nota: venta.nota,
  }
}
