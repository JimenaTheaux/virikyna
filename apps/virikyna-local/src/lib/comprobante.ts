// Datos y helpers compartidos entre el Comprobante X (Ventas) y la Factura C (Facturación) —
// ambos se muestran y se envían con el mismo componente (ver components/ComprobanteModal.tsx).
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
  items: ItemComprobante[]
  subtotal: number
  descuentoPorcentaje: number
  total: number
  cae: string | null
}

export const FORMA_PAGO_LABEL: Record<FormaPagoVenta, string> = {
  efectivo: 'Efectivo',
  transferencia: 'Transferencia',
  qr: 'QR',
  tarjeta_debito: 'Tarjeta débito',
  tarjeta_credito: 'Tarjeta crédito',
  cuenta_corriente: 'Cuenta corriente',
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
