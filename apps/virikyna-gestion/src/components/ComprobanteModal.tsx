import { useState, type ReactNode } from 'react'
import { Modal } from './Modal'
import { Field, inputClass } from './FormField'
import { formatCurrency } from '@virikyna/shared'
import { lineasFormaPago, linkGmail, linkWhatsApp, mensajeEnvio, type DatosComprobante } from '../lib/comprobante'
import { generarPdfComprobante, nombreArchivoPdf } from '../lib/pdf'

type Props = {
  datos: DatosComprobante
  onClose: () => void
  footer?: ReactNode
}

export function ComprobanteModal({ datos, onClose, footer }: Props) {
  const [mail, setMail] = useState(datos.clienteMail?.trim() ?? '')
  const [celular, setCelular] = useState(datos.clienteCelular?.trim() || '+54 ')

  const titulo = datos.tipo === 'factura_c' ? 'Factura C' : 'Comprobante X'
  const asunto = `${titulo} ${datos.numero} — Virikyna`

  async function descargarPdf() {
    const doc = await generarPdfComprobante(datos)
    doc.save(nombreArchivoPdf(datos))
  }

  function enviarPorGmail() {
    if (!mail.trim()) return
    window.open(linkGmail(mail.trim(), asunto, mensajeEnvio(datos)), '_blank')
  }

  function enviarPorWhatsApp() {
    if (!celular.replace(/\D/g, '')) return
    window.open(linkWhatsApp(celular, mensajeEnvio(datos)), '_blank')
  }

  return (
    <Modal title={titulo} onClose={onClose} widthClassName="max-w-[520px]">
      <div className="flex flex-col gap-stack-md">
        <div className="flex items-start justify-between font-sans text-body-md text-ink-soft">
          <div>
            <p>N°: {datos.numero}</p>
            <p>Cliente: {datos.clienteNombre}</p>
            {lineasFormaPago(datos).map((linea, i) => (
              <p key={i}>{linea}</p>
            ))}
            {datos.tipo === 'factura_c' && datos.cae && <p>CAE: {datos.cae}</p>}
          </div>
          <p>{new Date(datos.fecha).toLocaleString('es-AR')}</p>
        </div>

        <div className="max-h-52 overflow-auto rounded-lg border border-line">
          <table className="w-full text-left font-sans text-body-md">
            <thead>
              <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
                <th className="px-3 py-2">Producto</th>
                <th className="px-3 py-2 text-center">Cant.</th>
                <th className="px-3 py-2 text-right">Importe</th>
              </tr>
            </thead>
            <tbody>
              {datos.items.map((item, i) => (
                <tr key={i} className="border-b border-line last:border-0">
                  <td className="px-3 py-2 text-ink">{item.nombre}</td>
                  <td className="px-3 py-2 text-center text-ink-soft">{item.cantidad}</td>
                  <td className="px-3 py-2 text-right text-ink">{formatCurrency(item.importe)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="flex flex-col items-end gap-1 font-sans text-body-md text-ink-soft">
          <p>Subtotal: {formatCurrency(datos.subtotal)}</p>
          {datos.descuentoPorcentaje > 0 && <p>Descuento: {datos.descuentoPorcentaje}%</p>}
          {datos.recargoPorcentaje > 0 && <p>Recargo: {datos.recargoPorcentaje}%</p>}
          <p className="font-display text-headline-md text-accent-darker">Total: {formatCurrency(datos.total)}</p>
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
            Descargá el PDF y adjuntalo en el mail o chat que se abre — el envío automático de archivos no está
            disponible desde acá.
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
