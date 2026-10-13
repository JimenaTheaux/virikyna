import virikynaWordmark from '../src/assets/virikyna-wordmark.png'
import { cargarImagen } from './cargarImagen'
import { nombreArchivoComprobante, type DatosComprobante } from './comprobante'
import { ANCHO_TICKET_MM, armarLayoutTicket, LOGO_ANCHO_MM, type Fuente } from './comprobanteLayout'

// Formato angosto tipo ticket (80mm) — el negocio no tiene impresora fiscal, este PDF es para
// descargar/enviar, pero mantiene el aspecto de comprobante de mostrador. Layout en comprobanteLayout.ts.
//
// jsPDF trae de arrastre html2canvas/dompurify (para su método .html(), que acá no se usa) y agrega
// ~400kb al bundle — se carga solo cuando hace falta un PDF, no en el chunk principal de la app.
export async function generarPdfComprobante(datos: DatosComprobante, logoSrc: string = virikynaWordmark) {
  const { jsPDF } = await import('jspdf')
  const logo = await cargarImagen(logoSrc)
  const logoAlto = LOGO_ANCHO_MM / (logo.naturalWidth / logo.naturalHeight)

  const usarFuente = (doc: InstanceType<typeof jsPDF>, f: Fuente) => {
    doc.setFont('helvetica', f.negrita ? 'bold' : 'normal')
    doc.setFontSize(f.puntos)
  }

  // El alto de la página depende de cuántos renglones ocupa cada nombre: se mide con un documento
  // auxiliar (misma fuente y métrica) y después se crea el real con el alto exacto.
  const medidor = new jsPDF({ unit: 'mm', format: [ANCHO_TICKET_MM, 100] })
  const { altoMm, operaciones } = armarLayoutTicket(
    datos,
    (texto, ancho, fuente) => {
      usarFuente(medidor, fuente)
      return medidor.splitTextToSize(texto, ancho) as string[]
    },
    logoAlto,
  )

  const doc = new jsPDF({ unit: 'mm', format: [ANCHO_TICKET_MM, altoMm] })
  for (const op of operaciones) {
    if (op.tipo === 'logo') {
      // 'FAST' = comprimido: sin esto el logo (3484×588 px) va crudo y el PDF pesa ~8 MB.
      doc.addImage(logo, 'PNG', op.x, op.y, op.ancho, op.alto, undefined, 'FAST')
    } else if (op.tipo === 'linea') {
      doc.line(5, op.y, ANCHO_TICKET_MM - 5, op.y)
    } else {
      usarFuente(doc, op.fuente)
      doc.text(op.texto, op.x, op.y, { align: op.alinear })
    }
  }
  return doc
}

export function nombreArchivoPdf(datos: DatosComprobante): string {
  return nombreArchivoComprobante(datos, 'pdf')
}
