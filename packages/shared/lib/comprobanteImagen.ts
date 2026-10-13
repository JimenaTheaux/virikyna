import virikynaWordmark from '../src/assets/virikyna-wordmark.png'
import { cargarImagen } from './cargarImagen'
import { nombreArchivoComprobante, type DatosComprobante } from './comprobante'
import {
  ANCHO_TICKET_MM,
  armarLayoutTicket,
  LOGO_ANCHO_MM,
  partirConMedidor,
  type Fuente,
} from './comprobanteLayout'

// Mismo layout tipo ticket que el PDF (comprobanteLayout.ts), dibujado en un canvas 2D y exportado
// como JPG — para WhatsApp el comprobante se manda como imagen, no como PDF.
const ESCALA = 8 // px por mm — resolución suficiente para leerse bien en el chat
const MM_POR_PUNTO = 25.4 / 72

const px = (mm: number) => mm * ESCALA

function fuenteCanvas(f: Fuente): string {
  return `${f.negrita ? 'bold ' : ''}${px(f.puntos * MM_POR_PUNTO)}px helvetica, arial, sans-serif`
}

export async function generarJpgComprobante(datos: DatosComprobante, logoSrc: string = virikynaWordmark): Promise<Blob> {
  const logo = await cargarImagen(logoSrc)
  const logoAlto = LOGO_ANCHO_MM / (logo.naturalWidth / logo.naturalHeight)

  const canvas = document.createElement('canvas')
  const ctx = canvas.getContext('2d')
  if (!ctx) throw new Error('No se pudo crear el contexto de canvas')

  const { altoMm, operaciones } = armarLayoutTicket(
    datos,
    (texto, ancho, fuente) => {
      ctx.font = fuenteCanvas(fuente)
      return partirConMedidor(texto, ancho, (t) => ctx.measureText(t).width / ESCALA)
    },
    logoAlto,
  )

  // Cambiar el tamaño del canvas lo resetea (incluida la fuente): se dimensiona después de medir.
  canvas.width = px(ANCHO_TICKET_MM)
  canvas.height = px(altoMm)
  ctx.fillStyle = '#ffffff'
  ctx.fillRect(0, 0, canvas.width, canvas.height)
  ctx.fillStyle = '#000000'
  ctx.strokeStyle = '#000000'
  ctx.lineWidth = 1

  for (const op of operaciones) {
    if (op.tipo === 'logo') {
      ctx.drawImage(logo, px(op.x), px(op.y), px(op.ancho), px(op.alto))
    } else if (op.tipo === 'linea') {
      ctx.beginPath()
      ctx.moveTo(px(5), px(op.y))
      ctx.lineTo(px(ANCHO_TICKET_MM - 5), px(op.y))
      ctx.stroke()
    } else {
      ctx.font = fuenteCanvas(op.fuente)
      ctx.textAlign = op.alinear
      ctx.fillText(op.texto, px(op.x), px(op.y))
    }
  }

  return await new Promise<Blob>((resolve, reject) => {
    canvas.toBlob(
      (blob) => (blob ? resolve(blob) : reject(new Error('No se pudo generar la imagen del comprobante'))),
      'image/jpeg',
      0.92,
    )
  })
}

export function nombreArchivoJpg(datos: DatosComprobante): string {
  return nombreArchivoComprobante(datos, 'jpg')
}
