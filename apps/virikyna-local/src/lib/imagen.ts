import { cargarImagen, formatCurrency } from '@virikyna/shared'
import virikynaWordmark from '@virikyna/shared/src/assets/virikyna-wordmark.png'
import { lineasFormaPago, type DatosComprobante } from './comprobante'

// Mismo layout tipo ticket que el PDF (ver pdf.ts), pero dibujado en un canvas 2D y exportado
// como JPG — para WhatsApp el comprobante se manda como imagen, no como PDF, así que se genera
// acá aparte en vez de reusar el documento de jsPDF.
const ESCALA = 8 // px por mm — resolución suficiente para leerse bien en el chat
const ANCHO_MM = 80
const MARGEN_MM = 5
const ANCHO_PX = ANCHO_MM * ESCALA
const MARGEN_PX = MARGEN_MM * ESCALA

function mm(valor: number): number {
  return valor * ESCALA
}

export async function generarJpgComprobante(datos: DatosComprobante): Promise<Blob> {
  const lineasPago = lineasFormaPago(datos)
  const altoMm = 62 + datos.items.length * 5 + 29 + (lineasPago.length - 1) * 4
  const canvas = document.createElement('canvas')
  canvas.width = ANCHO_PX
  canvas.height = mm(altoMm)

  const ctx = canvas.getContext('2d')
  if (!ctx) throw new Error('No se pudo crear el contexto de canvas')

  ctx.fillStyle = '#ffffff'
  ctx.fillRect(0, 0, canvas.width, canvas.height)
  ctx.fillStyle = '#000000'

  const centroPx = ANCHO_PX / 2
  let y = mm(4)

  const logo = await cargarImagen(virikynaWordmark)
  const logoAnchoPx = mm(26)
  const logoAltoPx = logoAnchoPx / (logo.naturalWidth / logo.naturalHeight)
  ctx.drawImage(logo, centroPx - logoAnchoPx / 2, y, logoAnchoPx, logoAltoPx)
  y += logoAltoPx + mm(4)

  ctx.font = `bold ${mm(3.5)}px helvetica, sans-serif`
  ctx.textAlign = 'center'
  ctx.fillText(datos.tipo === 'factura_c' ? 'FACTURA C' : 'COMPROBANTE X', centroPx, y)
  y += mm(5)

  ctx.textAlign = 'left'
  ctx.font = `${mm(2.8)}px helvetica, sans-serif`
  ctx.fillText(`N°: ${datos.numero}`, MARGEN_PX, y)
  y += mm(4)
  ctx.fillText(`Fecha: ${new Date(datos.fecha).toLocaleString('es-AR')}`, MARGEN_PX, y)
  y += mm(4)
  ctx.fillText(`Cliente: ${datos.clienteNombre}`, MARGEN_PX, y)
  y += mm(4)
  for (const linea of lineasPago) {
    ctx.fillText(linea, MARGEN_PX, y)
    y += mm(4)
  }
  if (datos.tipo === 'factura_c' && datos.cae) {
    ctx.fillText(`CAE: ${datos.cae}`, MARGEN_PX, y)
    y += mm(4)
  }
  y += mm(1)
  dibujarLinea(ctx, y)
  y += mm(4)

  ctx.font = `bold ${mm(2.8)}px helvetica, sans-serif`
  ctx.fillText('Cant.', MARGEN_PX, y)
  ctx.fillText('Producto', MARGEN_PX + mm(12), y)
  ctx.textAlign = 'right'
  ctx.fillText('Importe', ANCHO_PX - MARGEN_PX, y)
  ctx.textAlign = 'left'
  y += mm(4)
  ctx.font = `${mm(2.8)}px helvetica, sans-serif`

  for (const item of datos.items) {
    const nombreCorto = item.nombre.length > 24 ? `${item.nombre.slice(0, 24)}…` : item.nombre
    ctx.fillText(String(item.cantidad), MARGEN_PX, y)
    ctx.fillText(nombreCorto, MARGEN_PX + mm(12), y)
    ctx.textAlign = 'right'
    ctx.fillText(formatCurrency(item.importe), ANCHO_PX - MARGEN_PX, y)
    ctx.textAlign = 'left'
    y += mm(5)
  }

  y += mm(1)
  dibujarLinea(ctx, y)
  y += mm(5)

  ctx.textAlign = 'right'
  ctx.fillText(`Subtotal: ${formatCurrency(datos.subtotal)}`, ANCHO_PX - MARGEN_PX, y)
  y += mm(4)
  if (datos.descuentoPorcentaje > 0) {
    ctx.fillText(`Descuento: ${datos.descuentoPorcentaje}%`, ANCHO_PX - MARGEN_PX, y)
    y += mm(4)
  }
  if (datos.recargoPorcentaje > 0) {
    ctx.fillText(`Recargo: ${datos.recargoPorcentaje}%`, ANCHO_PX - MARGEN_PX, y)
    y += mm(4)
  }
  ctx.font = `bold ${mm(3.5)}px helvetica, sans-serif`
  ctx.fillText(`TOTAL: ${formatCurrency(datos.total)}`, ANCHO_PX - MARGEN_PX, y)
  y += mm(7)

  ctx.font = `${mm(2.4)}px helvetica, sans-serif`
  ctx.textAlign = 'center'
  const leyenda =
    datos.tipo === 'comprobante_x'
      ? 'Comprobante interno — no válido como factura ante ARCA.'
      : 'Factura electrónica emitida ante ARCA.'
  dibujarTextoConSalto(ctx, leyenda, centroPx, y, ANCHO_PX - MARGEN_PX * 2, mm(3))

  return await new Promise<Blob>((resolve, reject) => {
    canvas.toBlob(
      (blob) => (blob ? resolve(blob) : reject(new Error('No se pudo generar la imagen del comprobante'))),
      'image/jpeg',
      0.92,
    )
  })
}

function dibujarLinea(ctx: CanvasRenderingContext2D, y: number): void {
  ctx.beginPath()
  ctx.moveTo(MARGEN_PX, y)
  ctx.lineTo(ANCHO_PX - MARGEN_PX, y)
  ctx.strokeStyle = '#000000'
  ctx.lineWidth = 1
  ctx.stroke()
}

// Canvas 2D no tiene una opción nativa de maxWidth como jsPDF — corta el texto en líneas a mano.
function dibujarTextoConSalto(
  ctx: CanvasRenderingContext2D,
  texto: string,
  x: number,
  yInicial: number,
  anchoMaximo: number,
  alturaLinea: number,
): void {
  const palabras = texto.split(' ')
  let linea = ''
  let y = yInicial
  for (const palabra of palabras) {
    const lineaPrueba = linea ? `${linea} ${palabra}` : palabra
    if (linea && ctx.measureText(lineaPrueba).width > anchoMaximo) {
      ctx.fillText(linea, x, y)
      linea = palabra
      y += alturaLinea
    } else {
      linea = lineaPrueba
    }
  }
  if (linea) ctx.fillText(linea, x, y)
}

export function nombreArchivoJpg(datos: DatosComprobante): string {
  const prefijo = datos.tipo === 'factura_c' ? 'factura-c' : 'comprobante-x'
  const numeroLimpio = datos.numero.replace(/[^\w-]+/g, '')
  return `${prefijo}-${numeroLimpio}.jpg`
}
