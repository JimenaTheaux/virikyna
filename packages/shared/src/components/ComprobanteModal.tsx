import { useState, type ReactNode } from 'react'
import { formatCurrency, formatFechaHora } from '../../lib/format'
import { lineasFormaPago, linkGmail, linkWhatsApp, mensajeEnvio, type DatosComprobante } from '../../lib/comprobante'
import { generarPdfComprobante, nombreArchivoPdf } from '../../lib/comprobantePdf'
import { generarJpgComprobante, nombreArchivoJpg } from '../../lib/comprobanteImagen'
import { Modal } from './Modal'
import { Field, inputClass } from './FormField'

export type ComprobanteModalProps = {
  datos: DatosComprobante
  onClose: () => void
  footer?: ReactNode
  // Es un detalle (solo lectura + envío): Esc cierra y el foco queda atrapado (Modal → useFocoAtrapado).
  // Activo por defecto en todas las pantallas (docs/auditoria-2026-10-19.md, B.2).
  dialogo?: boolean
}

type Opciones = {
  // Cómo se abre el link de Gmail / WhatsApp. Local (Tauri) usa el plugin shell: dentro del WebView
  // window.open no dispara el navegador ni las apps del sistema operativo. Gestión (web): window.open.
  abrirUrl?: (url: string) => void | Promise<void>
  // Local: al enviar descarga el archivo que corresponde a cada canal (PDF para Gmail, JPG para
  // WhatsApp) para que solo haya que adjuntarlo. Gestión: solo abre el mail o chat.
  descargarAlEnviar?: boolean
  onAviso?: (mensaje: string) => void
}

function abrirEnPestana(url: string) {
  window.open(url, '_blank')
}

// Ver, descargar y enviar el Comprobante X (Ventas) y la Factura C (Facturación) — docs/04 módulos 3
// y 4. Cada app lo envuelve con sus opciones (apps/*/src/components/ComprobanteModal.tsx).
export function ComprobanteModal({
  datos,
  onClose,
  footer,
  dialogo = true,
  abrirUrl = abrirEnPestana,
  descargarAlEnviar = false,
  onAviso,
}: ComprobanteModalProps & Opciones) {
  const [mail, setMail] = useState(datos.clienteMail?.trim() ?? '')
  const [celular, setCelular] = useState(datos.clienteCelular?.trim() || '+54 ')

  const titulo = datos.tipo === 'factura_c' ? 'Factura C' : 'Comprobante X'
  const asunto = `${titulo} ${datos.numero} — Virikyna`

  async function descargarPdf() {
    const doc = await generarPdfComprobante(datos)
    doc.save(nombreArchivoPdf(datos))
    onAviso?.('Se descargó el PDF')
  }

  async function descargarJpg() {
    const blob = await generarJpgComprobante(datos)
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = nombreArchivoJpg(datos)
    a.click()
    URL.revokeObjectURL(url)
    onAviso?.('Se descargó la imagen')
  }

  // Gmail y wa.me no permiten adjuntar un archivo local por URL (restricción de seguridad de ambas
  // plataformas): por eso, con descargarAlEnviar, se baja antes el formato de cada canal.
  async function enviarPorGmail() {
    if (!mail.trim()) return
    if (descargarAlEnviar) await descargarPdf()
    await abrirUrl(linkGmail(mail.trim(), asunto, mensajeEnvio(datos)))
  }

  async function enviarPorWhatsApp() {
    if (!celular.replace(/\D/g, '')) return
    if (descargarAlEnviar) await descargarJpg()
    await abrirUrl(linkWhatsApp(celular, mensajeEnvio(datos)))
  }

  return (
    <Modal
      title={titulo}
      onClose={onClose}
      widthClassName="max-w-[560px]"
      dialogo={dialogo ? { onEscape: onClose } : undefined}
    >
      <div className="flex flex-col gap-stack-md">
        <div className="flex items-start justify-between gap-3 font-sans text-body-md text-ink-soft">
          <div className="min-w-0">
            <p>N°: {datos.numero}</p>
            <p className="[overflow-wrap:anywhere]">Cliente: {datos.clienteNombre}</p>
            {lineasFormaPago(datos).map((linea, i) => (
              <p key={i}>{linea}</p>
            ))}
            {datos.tipo === 'factura_c' && datos.cae && <p>CAE: {datos.cae}</p>}
          </div>
          <p className="whitespace-nowrap">{formatFechaHora(datos.fecha)}</p>
        </div>

        {datos.nota?.trim() && (
          <div className="rounded-lg border border-line bg-bg px-4 py-3">
            <p className="font-sans text-label-bold text-ink">Nota</p>
            <p className="mt-1 whitespace-pre-wrap font-sans text-body-md text-ink [overflow-wrap:anywhere]">
              {datos.nota}
            </p>
          </div>
        )}

        <div className="rounded-lg border border-line">
          <table className="w-full table-fixed text-left font-sans text-body-md">
            <colgroup>
              <col />
              <col className="w-16" />
              <col className="w-32" />
            </colgroup>
            <thead>
              <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
                <th className="px-3 py-2">Producto</th>
                <th className="px-3 py-2 text-center">Cant.</th>
                <th className="px-3 py-2 text-right">Importe</th>
              </tr>
            </thead>
            <tbody>
              {datos.items.map((item, i) => (
                <tr key={i} className="border-b border-line align-top last:border-0">
                  <td className="px-3 py-2 text-ink [overflow-wrap:anywhere]">
                    {item.nombre}
                    <span className="block font-sans text-label-md tabular-nums text-ink-soft">
                      {formatCurrency(item.precioUnitario)} c/u
                    </span>
                  </td>
                  <td className="px-3 py-2 text-center tabular-nums text-ink-soft">{item.cantidad}</td>
                  <td className="px-3 py-2 text-right tabular-nums text-ink">{formatCurrency(item.importe)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="flex flex-col items-end gap-1 font-sans text-body-md tabular-nums text-ink-soft">
          <p>Subtotal: {formatCurrency(datos.subtotal)}</p>
          {datos.descuentoPorcentaje > 0 && <p>Descuento: {datos.descuentoPorcentaje}%</p>}
          {datos.recargoPorcentaje > 0 && <p>Recargo: {datos.recargoPorcentaje}%</p>}
          {datos.precioOficial !== datos.total && <p>Precio oficial: {formatCurrency(datos.precioOficial)}</p>}
          <p className="font-display text-headline-md text-accent-darker">Total: {formatCurrency(datos.total)}</p>
          {datos.precioOficial !== datos.total && (
            <p className={datos.total > datos.precioOficial ? 'text-success' : 'text-error'}>
              Diferencia (redondeo): {datos.total > datos.precioOficial ? '+' : ''}
              {formatCurrency(datos.total - datos.precioOficial)}
            </p>
          )}
        </div>

        <button
          type="button"
          onClick={descargarPdf}
          className="rounded border border-line px-4 py-3 font-sans text-label-bold text-ink hover:border-accent hover:text-accent-darker"
        >
          Descargar PDF
        </button>

        <div className="rounded-lg border border-line p-4">
          <p className="font-sans text-label-bold text-ink">Enviar comprobante</p>
          <p className="mt-1 font-sans text-label-md text-ink-soft">
            {descargarAlEnviar
              ? 'Al enviar se descarga el comprobante (PDF para Gmail, imagen JPG para WhatsApp) y se abre el mail o chat — adjuntalo ahí, el envío automático de archivos no está disponible desde acá.'
              : 'Descargá el PDF y adjuntalo en el mail o chat que se abre — el envío automático de archivos no está disponible desde acá.'}
          </p>

          <div className="mt-stack-md grid grid-cols-[1fr_auto] items-end gap-3">
            <Field label="Mail">
              <input
                type="email"
                value={mail}
                onChange={(e) => setMail(e.target.value)}
                placeholder="cliente@mail.com"
                className={inputClass}
              />
            </Field>
            <button
              type="button"
              onClick={enviarPorGmail}
              disabled={!mail.trim()}
              className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white hover:bg-accent-dark disabled:opacity-50"
            >
              Enviar por Gmail
            </button>
          </div>

          <div className="mt-3 grid grid-cols-[1fr_auto] items-end gap-3">
            <Field label="WhatsApp">
              <input value={celular} onChange={(e) => setCelular(e.target.value)} className={inputClass} />
            </Field>
            <button
              type="button"
              onClick={enviarPorWhatsApp}
              disabled={!celular.replace(/\D/g, '')}
              className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white hover:bg-accent-dark disabled:opacity-50"
            >
              Enviar por WhatsApp
            </button>
          </div>
        </div>

        {footer}
      </div>
    </Modal>
  )
}
