import type { ComprobanteCompraExistente } from '../../types/database'
import { formatCurrency, formatFechaCorta } from '../../lib/format'

// Avisos de la carga de factura de compra relacionados con copiar (docs/33). Compartidos por la
// planilla de escritorio y la tarjeta de celular — 'compact' / 'touch' como AvisoCodigoFactura.
type Tamano = 'compact' | 'touch'

// "Ya existe este comprobante" (useComprobanteDuplicado). La región role="status" está siempre
// montada, vacía si no hay coincidencias: un lector de pantalla solo anuncia cambios dentro de una
// región que ya existía. No bloquea: se puede guardar igual.
export function AvisoComprobanteDuplicado({
  coincidencias,
  size = 'compact',
}: {
  coincidencias: ComprobanteCompraExistente[]
  size?: Tamano
}) {
  const hay = coincidencias.length > 0
  return (
    <div
      role="status"
      className={
        hay
          ? `rounded border border-badge-amber-text/40 bg-badge-amber-bg font-sans text-body-md text-ink ${
              size === 'touch' ? 'px-3 py-3' : 'px-3 py-2'
            }`
          : 'sr-only'
      }
    >
      {hay && (
        <>
          <p>
            <strong>{coincidencias.length === 1 ? 'Ya existe este comprobante' : `Este comprobante ya está cargado ${coincidencias.length} veces`}</strong>{' '}
            para este proveedor — podés guardarlo igual.
          </p>
          <ul className="mt-1 text-label-md text-ink-soft">
            {coincidencias.map((c) => (
              <li key={c.id}>
                {formatFechaCorta(c.fecha_comprobante)} · <span className="tabular-nums">{formatCurrency(Number(c.total))}</span>
                {c.anulada && ' · anulada'}
              </li>
            ))}
          </ul>
        </>
      )}
    </div>
  )
}

// Ítem copiado cuyo producto hoy está inactivo: bloquea el guardado (problemasItemsFacturaCompra)
// hasta "Usarlo igual" o "Buscar otro" (desvincula el ítem y lleva el foco a "Producto").
export function AvisoProductoInactivoFactura({
  nombre,
  onUsar,
  onBuscarOtro,
  size = 'compact',
}: {
  nombre: string
  onUsar: () => void
  onBuscarOtro: () => void
  size?: Tamano
}) {
  const touch = size === 'touch'
  const boton = `${touch ? 'min-h-11 px-3' : 'px-2.5 py-1'} rounded border font-sans text-label-bold active:opacity-80`
  return (
    <div
      role="status"
      className={`rounded border border-error/40 bg-error/10 font-sans text-body-md ${touch ? 'px-3 py-3' : 'px-3 py-2'}`}
    >
      <p className="text-ink">
        <strong>{nombre}</strong> está <strong>inactivo</strong> en el inventario.
      </p>
      <div className="mt-2 flex flex-wrap gap-2">
        <button type="button" onClick={onUsar} className={`${boton} border-error/50 text-error hover:bg-error/10`}>
          Usarlo igual
        </button>
        <button type="button" onClick={onBuscarOtro} className={`${boton} border-line text-ink-soft hover:bg-bg`}>
          Buscar otro
        </button>
      </div>
    </div>
  )
}
