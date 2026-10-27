import { useEffect, useState } from 'react'
import type { ChequeEmitido } from '@virikyna/shared'
import { FORMA_PAGO_EGRESO_LABEL, formatCurrency, formatFechaCorta, friendlyError, hoyAR } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { Modal } from '../../components/Modal'

type Props = {
  onClose: () => void
}

// Detalle de la card "Cheques emitidos" de Resumen Cuentas: la cartera de cheques y eCheqs
// entregados a proveedores que siguen vigentes (vista cartera_cheques_emitidos, docs/65 — un
// renglón por cheque, también los de un pago con varios medios), por fecha de pago. Un cheque cuyo
// pago se revirtió desde el Historial ya no aparece. Los que se cobran hoy o ya pasaron van marcados.
export function ChequesEmitidosModal({ onClose }: Props) {
  const [cheques, setCheques] = useState<ChequeEmitido[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const hoy = hoyAR(0)

  useEffect(() => {
    supabase
      .from('cartera_cheques_emitidos')
      .select('*')
      .eq('es_reversion', false)
      .eq('revertido', false)
      .order('fecha_pago', { ascending: true })
      .order('numero', { ascending: true })
      .then(({ data, error: dbError }) => {
        if (dbError) {
          setError(friendlyError(dbError))
        } else {
          setCheques((data ?? []) as ChequeEmitido[])
        }
        setLoading(false)
      })
  }, [])

  const total = cheques.reduce((acc, c) => acc + Number(c.monto), 0)

  return (
    <Modal title="Cheques emitidos" onClose={onClose} dialogo={{ onEscape: onClose }} widthClassName="max-w-[760px]">
      <div className="flex flex-col gap-stack-md">
        <p className="font-sans text-body-md text-ink-soft">
          Cheques y eCheqs entregados a proveedores, por fecha de pago.
          {!loading && cheques.length > 0 && (
            <>
              {' '}
              {cheques.length} en cartera ·{' '}
              <span className="font-semibold tabular-nums text-ink">{formatCurrency(total)}</span>
            </>
          )}
        </p>

        {error && <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>}

        <div className="max-h-[60vh] overflow-auto rounded-lg border border-line">
          <table className="w-full text-left font-sans text-body-md leading-5">
            <thead className="sticky top-0">
              <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
                <th className="whitespace-nowrap px-3 py-2">Fecha de pago</th>
                <th className="whitespace-nowrap px-3 py-2">Tipo</th>
                <th className="whitespace-nowrap px-3 py-2">Nro.</th>
                <th className="whitespace-nowrap px-3 py-2">Banco</th>
                <th className="whitespace-nowrap px-3 py-2">Proveedor</th>
                <th className="whitespace-nowrap px-3 py-2 text-right">Importe</th>
              </tr>
            </thead>
            <tbody>
              {loading && (
                <tr>
                  <td className="px-4 py-4 text-ink-soft" colSpan={6}>
                    Cargando...
                  </td>
                </tr>
              )}
              {!loading && cheques.length === 0 && (
                <tr>
                  <td className="px-4 py-4 text-ink-soft" colSpan={6}>
                    No hay cheques en cartera.
                  </td>
                </tr>
              )}
              {cheques.map((c) => {
                const vencido = !!c.fecha_pago && c.fecha_pago <= hoy
                return (
                  <tr key={c.id} className="border-b border-line last:border-0">
                    <td className="whitespace-nowrap px-3 py-2 tabular-nums text-ink">
                      {c.fecha_pago ? formatFechaCorta(c.fecha_pago) : '—'}
                      {vencido && (
                        <span className="ml-2 rounded-[6px] bg-badge-amber-bg px-1.5 py-0.5 font-sans text-label-md font-semibold text-badge-amber-text">
                          {c.fecha_pago === hoy ? 'Hoy' : 'Ya se cobra'}
                        </span>
                      )}
                    </td>
                    <td className="px-3 py-2 text-ink-soft">{FORMA_PAGO_EGRESO_LABEL[c.medio]}</td>
                    <td className="px-3 py-2 text-ink">{c.numero ?? '—'}</td>
                    <td className="px-3 py-2 text-ink-soft">{c.banco ?? '—'}</td>
                    <td className="px-3 py-2 text-ink">{c.proveedor}</td>
                    <td className="whitespace-nowrap px-3 py-2 text-right tabular-nums text-ink">{formatCurrency(Number(c.monto))}</td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      </div>
    </Modal>
  )
}
