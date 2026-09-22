import { cargarImagen, formatCurrency } from '@virikyna/shared'
import virikynaWordmark from '@virikyna/shared/src/assets/virikyna-wordmark.png'
import { lineasFormaPago, type DatosComprobante } from './comprobante'

// Formato angosto tipo ticket (80mm) — el negocio no tiene impresora fiscal,
// este PDF es para descargar/enviar, pero mantiene el aspecto de comprobante de mostrador.
const ANCHO_MM = 80
const MARGEN = 5

// jsPDF trae de arrastre html2canvas/dompurify (para su método .html(), que acá no se usa) y agrega
// ~400kb al bundle — se carga solo cuando hace falta un PDF, no en el chunk principal de la app.
export async function generarPdfComprobante(datos: DatosComprobante) {
  const { jsPDF } = await import('jspdf')
  const lineasPago = lineasFormaPago(datos)
  const alto = 62 + datos.items.length * 5 + 29 + (lineasPago.length - 1) * 4
  const doc = new jsPDF({ unit: 'mm', format: [ANCHO_MM, alto] })
  const centro = ANCHO_MM / 2
  let y = 4

  const logo = await cargarImagen(virikynaWordmark)
  const logoAncho = 26
  const logoAlto = logoAncho / (logo.naturalWidth / logo.naturalHeight)
  doc.addImage(logo, 'PNG', centro - logoAncho / 2, y, logoAncho, logoAlto)
  y += logoAlto + 4

  doc.setFont('helvetica', 'bold')
  doc.setFontSize(10)
  doc.text(datos.tipo === 'factura_c' ? 'FACTURA C' : 'COMPROBANTE X', centro, y, { align: 'center' })
  y += 5

  doc.setFont('helvetica', 'normal')
  doc.setFontSize(8)
  doc.text(`N°: ${datos.numero}`, MARGEN, y)
  y += 4
  doc.text(`Fecha: ${new Date(datos.fecha).toLocaleString('es-AR')}`, MARGEN, y)
  y += 4
  doc.text(`Cliente: ${datos.clienteNombre}`, MARGEN, y)
  y += 4
  for (const linea of lineasPago) {
    doc.text(linea, MARGEN, y)
    y += 4
  }
  if (datos.tipo === 'factura_c' && datos.cae) {
    doc.text(`CAE: ${datos.cae}`, MARGEN, y)
    y += 4
  }
  y += 1
  doc.line(MARGEN, y, ANCHO_MM - MARGEN, y)
  y += 4

  doc.setFont('helvetica', 'bold')
  doc.text('Cant.', MARGEN, y)
  doc.text('Producto', MARGEN + 12, y)
  doc.text('Importe', ANCHO_MM - MARGEN, y, { align: 'right' })
  y += 4
  doc.setFont('helvetica', 'normal')

  for (const item of datos.items) {
    const nombreCorto = item.nombre.length > 24 ? `${item.nombre.slice(0, 24)}…` : item.nombre
    doc.text(String(item.cantidad), MARGEN, y)
    doc.text(nombreCorto, MARGEN + 12, y)
    doc.text(formatCurrency(item.importe), ANCHO_MM - MARGEN, y, { align: 'right' })
    y += 5
  }

  y += 1
  doc.line(MARGEN, y, ANCHO_MM - MARGEN, y)
  y += 5

  doc.text(`Subtotal: ${formatCurrency(datos.subtotal)}`, ANCHO_MM - MARGEN, y, { align: 'right' })
  y += 4
  if (datos.descuentoPorcentaje > 0) {
    doc.text(`Descuento: ${datos.descuentoPorcentaje}%`, ANCHO_MM - MARGEN, y, { align: 'right' })
    y += 4
  }
  if (datos.recargoPorcentaje > 0) {
    doc.text(`Recargo: ${datos.recargoPorcentaje}%`, ANCHO_MM - MARGEN, y, { align: 'right' })
    y += 4
  }
  doc.setFont('helvetica', 'bold')
  doc.setFontSize(10)
  doc.text(`TOTAL: ${formatCurrency(datos.total)}`, ANCHO_MM - MARGEN, y, { align: 'right' })
  y += 7

  doc.setFont('helvetica', 'normal')
  doc.setFontSize(7)
  doc.text(
    datos.tipo === 'comprobante_x'
      ? 'Comprobante interno — no válido como factura ante ARCA.'
      : 'Factura electrónica emitida ante ARCA.',
    centro,
    y,
    { align: 'center', maxWidth: ANCHO_MM - MARGEN * 2 },
  )

  return doc
}

export function nombreArchivoPdf(datos: DatosComprobante): string {
  const prefijo = datos.tipo === 'factura_c' ? 'factura-c' : 'comprobante-x'
  const numeroLimpio = datos.numero.replace(/[^\w-]+/g, '')
  return `${prefijo}-${numeroLimpio}.pdf`
}
