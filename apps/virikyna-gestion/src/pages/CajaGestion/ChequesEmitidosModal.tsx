import { useEffect, useState } from 'react'
import { formatCurrency, formatFechaCorta, friendlyError } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { Modal } from '../../components/Modal'

type ChequeEmitido = {
  id: string
  monto: number
  cheque_numero: string | null
  cheque_fecha_vencimiento: string | null
  proveedor: { razon_social: string } | null
}

type Props = {
  onClose: () => void
}

// Detalle de la card "Cheques emitidos" de Resumen Cuentas — todos los pagos a proveedor con
// forma_pago cheque/echeq, ordenados por fecha de vencimiento. Una reversión (docs/10,
// revertir_movimiento) trae sus propios cheque_numero/vencimiento copiados de la fila original,
// así que también aparece acá con el importe en negativo, mismo criterio que el detalle de
// pagos de una factura puntual (FacturaCompraDetalleModal).
export function ChequesEmitidosModal({ onClose }: Props) {
  const [cheques, setCheques] = useState<ChequeEmitido[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    supabase
      .from('pagos_proveedor')
      .select('id, monto, cheque_numero, cheque_fecha_vencimiento, proveedor:proveedores(razon_social)')
      .in('forma_pago', ['cheque', 'echeq'])
      .order('cheque_fecha_vencimiento', { ascending: true })
      .then(({ data, error: dbError }) => {
        if (dbError) {
          setError(friendlyError(dbError))
        } else {
          setCheques((data ?? []) as unknown as ChequeEmitido[])
        }
        setLoading(false)
      })
  }, [])

  return (
    <Modal title="Cheques emitidos" onClose={onClose} widthClassName="max-w-[640px]">
      <div className="flex flex-col gap-stack-md">
        <p className="font-sans text-body-md text-ink-soft">Cheques y e-cheques entregados a proveedores, por fecha de vencimiento.</p>

        {error && <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>}

        <div className="max-h-[420px] overflow-auto rounded-lg border border-line">
          <table className="w-full text-left font-sans text-body-md leading-5">
            <thead>
              <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
                <th className="whitespace-nowrap px-3 py-2">Vencimiento</th>
                <th className="whitespace-nowrap px-3 py-2">Nro.</th>
                <th className="whitespace-nowrap px-3 py-2">Proveedor</th>
                <th className="whitespace-nowrap px-3 py-2 text-right">Importe</th>
              </tr>
            </thead>
            <tbody>
              {loading && (
                <tr>
                  <td className="px-4 py-4 text-ink-soft" colSpan={4}>
                    Cargando...
                  </td>
                </tr>
              )}
              {!loading && cheques.length === 0 && (
                <tr>
                  <td className="px-4 py-4 text-ink-soft" colSpan={4}>
                    Todavía no se emitió ningún cheque.
                  </td>
                </tr>
              )}
              {cheques.map((c) => (
                <tr key={c.id} className="border-b border-line last:border-0">
                  <td className="px-3 py-2 text-ink">
                    {c.cheque_fecha_vencimiento ? formatFechaCorta(c.cheque_fecha_vencimiento) : '—'}
                  </td>
                  <td className="px-3 py-2 text-ink">{c.cheque_numero ?? '—'}</td>
                  <td className="px-3 py-2 text-ink">{c.proveedor?.razon_social ?? '—'}</td>
                  <td className="px-3 py-2 text-right text-ink">{formatCurrency(c.monto)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </Modal>
  )
}
