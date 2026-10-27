import type { FormaPagoCabecera } from '../../types/database'
import { etiquetaFormaPago, etiquetaMedio, ordenarMedios, type MedioDePago } from '../../lib/facturasCompra'
import { formatCurrency, formatFechaCorta } from '../../lib/format'

// Forma de pago de un pago a proveedor en un listado (cuenta corriente, detalle de factura,
// Historial). Un medio: como siempre ("Cheque N° 123"). Varios (docs/65): "Mixto (N medios)" que se
// despliega con cada medio, su monto y, en los cheques, el banco y cuándo se cobran.
export function FormaPagoConDetalle({
  pago,
  className = '',
}: {
  pago: { forma_pago: FormaPagoCabecera; cheque_numero: string | null; medios?: MedioDePago[] | null }
  className?: string
}) {
  const medios = ordenarMedios(pago.medios)
  if (pago.forma_pago !== 'mixto' || medios.length === 0) {
    return <span className={className}>{etiquetaFormaPago(pago)}</span>
  }
  return (
    // El clic en el desplegable no abre lo que haya detrás (filas clickeables).
    <details className={`group ${className}`} onClick={(e) => e.stopPropagation()}>
      <summary className="inline-flex cursor-pointer list-none items-center gap-1 rounded font-semibold text-accent-dark hover:text-accent-darker focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent [&::-webkit-details-marker]:hidden">
        {etiquetaFormaPago({ ...pago, medios })}
        <span aria-hidden="true" className="text-label-md transition group-open:rotate-90">
          ›
        </span>
      </summary>
      <ul className="mt-1 flex flex-col gap-0.5 font-normal text-ink-soft">
        {medios.map((m) => (
          <li key={m.id} className="flex flex-wrap justify-between gap-x-3">
            <span>
              {etiquetaMedio(m)}
              {m.fecha_pago && ` · cobra ${formatFechaCorta(m.fecha_pago)}`}
            </span>
            <span className="tabular-nums text-ink">{formatCurrency(Number(m.monto))}</span>
          </li>
        ))}
      </ul>
    </details>
  )
}
