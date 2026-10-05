import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { Wallet } from 'lucide-react'
import type { FacturaCompraSaldo, ProveedorSaldo } from '@virikyna/shared'
import {
  formatCurrency,
  formatFechaCorta,
  friendlyError,
  TIPO_COMPROBANTE_COMPRA_LABEL as TIPO_LABEL,
} from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { Modal } from '../../components/Modal'
import { FacturaCompraDetalleModal } from '../Proveedores/FacturaCompraDetalleModal'

type Props = {
  proveedor: ProveedorSaldo
  onClose: () => void
  onChanged: () => void // avisa al listado de "Pendiente de pago" para refrescar el total
}

// Facturas con saldo pendiente de un proveedor puntual, abierto desde la card "Pendiente de
// pago" de Resumen Cuentas. El pago en sí se registra desde el mismo FacturaCompraDetalleModal
// de Proveedores (registrar_pago_proveedor_v2, origen 'general'). Para pagar varias juntas o usar
// notas de crédito, "Ver cuenta corriente" lleva a /proveedores/:id.
export function ProveedorFacturasPendientesModal({ proveedor, onClose, onChanged }: Props) {
  const [facturas, setFacturas] = useState<FacturaCompraSaldo[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [detalle, setDetalle] = useState<FacturaCompraSaldo | null>(null)

  async function cargar() {
    setLoading(true)
    setError(null)
    const { data, error: dbError } = await supabase
      .from('facturas_compra_saldo')
      .select('*')
      .eq('proveedor_id', proveedor.id)
      .eq('anulada', false)
      .gt('saldo_pendiente', 0)
      .order('fecha_comprobante', { ascending: true })

    if (dbError) {
      setError(friendlyError(dbError))
    } else {
      setFacturas((data ?? []) as FacturaCompraSaldo[])
    }
    setLoading(false)
  }

  useEffect(() => {
    cargar()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [proveedor.id])

  return (
    <Modal title={proveedor.razon_social} onClose={onClose} widthClassName="max-w-[600px]" dialogo={{ onEscape: onClose }}>
      <div className="flex flex-col gap-stack-md">
        <div className="flex items-center justify-between rounded-lg border border-line p-4">
          <div>
            <p className="font-sans text-label-md text-ink-soft">Saldo total pendiente</p>
            <p className="font-display text-headline-md text-error tabular-nums">{formatCurrency(proveedor.saldo_actual)}</p>
          </div>
          <Link
            to={`/proveedores/${proveedor.id}`}
            className="rounded font-sans text-label-bold text-accent-dark hover:underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
          >
            Ver cuenta corriente →
          </Link>
        </div>

        {error && <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>}

        <div className="overflow-auto rounded-lg border border-line">
          <table className="w-full text-left font-sans text-body-md leading-5">
            <thead>
              <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
                <th className="min-w-[100px] whitespace-nowrap px-3 py-2">Fecha</th>
                <th className="whitespace-nowrap px-3 py-2">Comprobante</th>
                <th className="whitespace-nowrap px-3 py-2 text-right">Saldo pendiente</th>
                <th className="whitespace-nowrap px-3 py-2"></th>
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
              {!loading && facturas.length === 0 && (
                <tr>
                  <td className="px-4 py-4 text-ink-soft" colSpan={4}>
                    No hay facturas con saldo pendiente para este proveedor.
                  </td>
                </tr>
              )}
              {facturas.map((f) => (
                <tr key={f.id} className="border-b border-line last:border-0">
                  <td className="whitespace-nowrap px-3 py-2 text-ink-soft">{formatFechaCorta(f.fecha_comprobante)}</td>
                  <td className="px-3 py-2 text-ink">
                    {TIPO_LABEL[f.tipo_comprobante] ?? f.tipo_comprobante}
                    {f.letra ? ` ${f.letra}` : ''}
                    {f.numero_comprobante ? ` · ${f.numero_comprobante}` : ''}
                  </td>
                  <td className="px-3 py-2 text-right text-error">{formatCurrency(f.saldo_pendiente)}</td>
                  <td className="px-3 py-2 text-right">
                    <button
                      type="button"
                      onClick={() => setDetalle(f)}
                      title="Pagar"
                      aria-label="Pagar"
                      className="rounded bg-accent px-3 py-1.5 text-white transition hover:bg-accent-dark"
                    >
                      <Wallet size={18} strokeWidth={1.5} />
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {detalle && (
        <FacturaCompraDetalleModal
          factura={detalle}
          proveedorNombre={proveedor.razon_social}
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
