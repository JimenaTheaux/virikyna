// Datos y helpers del Comprobante X (Ventas, Local) y la Factura C (Facturación, Local y Gestión) —
// ambos se muestran y se envían con el mismo componente (src/components/ComprobanteModal.tsx) y se
// generan con el mismo layout en PDF (comprobantePdf.ts) e imagen JPG (comprobanteImagen.ts).
import type { FormaPagoVenta, Producto, VentaItem } from '../types/database'
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
  return [
    `${titulo} ${datos.numero} — Virikyna`,
    `Total: ${formatCurrency(datos.total)}`,
    'Te comparto el comprobante de tu compra. Cualquier consulta, escribinos por acá.',
  ].join('\n')
}

export function nombreArchivoComprobante(datos: DatosComprobante, extension: 'pdf' | 'jpg'): string {
  const prefijo = datos.tipo === 'factura_c' ? 'factura-c' : 'comprobante-x'
  const numeroLimpio = datos.numero.replace(/[^\w-]+/g, '')
  return `${prefijo}-${numeroLimpio}.${extension}`
}
