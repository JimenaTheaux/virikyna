import { useEffect, useState } from 'react'
import { Eye } from 'lucide-react'
import type { ProveedorSaldo } from '@virikyna/shared'
import { formatCurrency, friendlyError } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { Modal } from '../../components/Modal'
import { ProveedorFacturasPendientesModal } from './ProveedorFacturasPendientesModal'

type Props = {
  onClose: () => void
  onChanged: () => void // avisa a Resumen Cuentas para refrescar el total de la card
}

// Listado de proveedores con saldo pendiente, abierto desde la card "Pendiente de pago" de
// Resumen Cuentas. El detalle por factura y el pago en sí viven en componentes ya existentes
// (ProveedorFacturasPendientesModal → FacturaCompraDetalleModal) — acá solo se arma la lista.
export function PendientePagoModal({ onClose, onChanged }: Props) {
  const [proveedores, setProveedores] = useState<ProveedorSaldo[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [detalle, setDetalle] = useState<ProveedorSaldo | null>(null)

  async function cargar() {
    setLoading(true)
    setError(null)
    const { data, error: dbError } = await supabase
      .from('proveedores_saldo')
      .select('*')
      .gt('saldo_actual', 0)
      .order('saldo_actual', { ascending: false })

    if (dbError) {
      setError(friendlyError(dbError))
      setLoading(false)
      return
    }

    const proveedoresData = (data ?? []) as ProveedorSaldo[]
    setProveedores(proveedoresData)
    // El proveedor en detalle puede haber cambiado de saldo (o saldado del todo) tras un pago —
    // se sincroniza con la lista recién traída en vez de quedar con el snapshot con el que se abrió.
    setDetalle((actual) => (actual ? (proveedoresData.find((p) => p.id === actual.id) ?? null) : actual))
    setLoading(false)
  }

  useEffect(() => {
    cargar()
  }, [])

  return (
    <Modal title="Pendiente de pago" onClose={onClose} widthClassName="max-w-[560px]">
      <div className="flex flex-col gap-stack-md">
        <p className="font-sans text-body-md text-ink-soft">Proveedores con saldo pendiente, de mayor a menor.</p>

        {error && <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>}

        <div className="max-h-[420px] overflow-auto rounded-lg border border-line">
          <table className="w-full text-left font-sans text-body-md leading-5">
            <thead>
              <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
                <th className="px-3 py-2">Proveedor</th>
                <th className="px-3 py-2 text-right">Saldo</th>
                <th className="px-3 py-2"></th>
              </tr>
            </thead>
            <tbody>
              {loading && (
                <tr>
                  <td className="px-4 py-4 text-ink-soft" colSpan={3}>
                    Cargando...
                  </td>
                </tr>
              )}
              {!loading && proveedores.length === 0 && (
                <tr>
                  <td className="px-4 py-4 text-ink-soft" colSpan={3}>
                    No hay saldo pendiente con proveedores.
                  </td>
                </tr>
              )}
              {proveedores.map((p) => (
                <tr key={p.id} className="border-b border-line last:border-0">
                  <td className="px-3 py-2 text-ink">{p.razon_social}</td>
                  <td className="px-3 py-2 text-right text-error">{formatCurrency(p.saldo_actual)}</td>
                  <td className="px-3 py-2 text-right">
                    <button
                      type="button"
                      onClick={() => setDetalle(p)}
                      title="Ver detalle"
                      aria-label="Ver detalle"
                      className="rounded px-3 py-1.5 text-accent-dark hover:bg-accent-light"
                    >
                      <Eye size={18} strokeWidth={1.5} />
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {detalle && (
        <ProveedorFacturasPendientesModal
          proveedor={detalle}
          onClose={() => setDetalle(null)}
          onChanged={() => {
            cargar()
            onChanged()
          }}
        />
      )}
    </Modal>
  )
}
