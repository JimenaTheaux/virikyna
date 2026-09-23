// Datos y helpers para mostrar y enviar la Factura C ya emitida — Virikyna Gestión no genera
// Comprobantes X (eso pasa en la venta, en Virikyna Local), solo ve/emite/envía Factura C.
import type { FormaPagoVenta } from '@virikyna/shared'
import { formatCurrency } from '@virikyna/shared'

export type ItemComprobante = {
  nombre: string
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

// Una línea si es pago simple ("Forma de pago: Efectivo"), o el encabezado + una línea por
// cada parte si es combinado — usado por pantalla y PDF del comprobante.
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
