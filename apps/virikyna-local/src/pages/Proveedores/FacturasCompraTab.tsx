import { useEffect, useState } from 'react'
import type { FacturaCompraSaldo, Proveedor } from '@virikyna/shared'
import { formatCurrency, formatFecha, friendlyError } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { CargarFacturaCompraModal } from './CargarFacturaCompraModal'
import { FacturaCompraDetalleModal } from './FacturaCompraDetalleModal'
import type { FacturaCompraConProveedor } from './types'

const TIPO_LABEL: Record<string, string> = {
  factura: 'Factura',
  remito: 'Remito',
  cupon: 'Cupón',
  nota_credito: 'Nota de crédito',
  nota_debito: 'Nota de débito',
}

export function FacturasCompraTab() {
  const [facturas, setFacturas] = useState<FacturaCompraConProveedor[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [modalNueva, setModalNueva] = useState(false)
  const [detalle, setDetalle] = useState<FacturaCompraConProveedor | null>(null)

  async function cargar() {
    setLoading(true)
    setError(null)

    const [facturasRes, proveedoresRes] = await Promise.all([
      supabase.from('facturas_compra_saldo').select('*').order('fecha_comprobante', { ascending: false }),
      supabase.from('proveedores').select('id, razon_social'),
    ])

    if (facturasRes.error) {
      setError(friendlyError(facturasRes.error))
      setLoading(false)
      return
    }

    const proveedoresPorId = new Map(
      ((proveedoresRes.data ?? []) as Pick<Proveedor, 'id' | 'razon_social'>[]).map((p) => [p.id, p.razon_social]),
    )
    const conProveedor = ((facturasRes.data ?? []) as FacturaCompraSaldo[]).map((f) => ({
      ...f,
      proveedor: { razon_social: proveedoresPorId.get(f.proveedor_id) ?? '—' },
    }))
    setFacturas(conProveedor)
    setLoading(false)
  }

  useEffect(() => {
    cargar()
  }, [])

  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center justify-between">
        <p className="font-sans text-body-md text-ink-soft">
          Facturas, remitos y otros comprobantes de compra cargados — con saldo pendiente por factura.
        </p>
        <button
          type="button"
          onClick={() => setModalNueva(true)}
          className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark"
        >
          + Nueva factura
        </button>
      </div>

      {error && (
        <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>
      )}

      <div className="mt-stack-md flex-1 overflow-auto rounded-lg border border-line">
        <table className="w-full text-left font-sans text-body-md">
          <thead>
            <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
              <th className="min-w-[180px] whitespace-nowrap px-4 py-3">Fecha</th>
              <th className="px-4 py-3">Proveedor</th>
              <th className="px-4 py-3">Comprobante</th>
              <th className="px-4 py-3 text-right">Total</th>
              <th className="px-4 py-3 text-right">Saldo pendiente</th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr>
                <td className="px-4 py-6 text-ink-soft" colSpan={5}>
                  Cargando...
                </td>
              </tr>
            )}
            {!loading && facturas.length === 0 && (
              <tr>
                <td className="px-4 py-6 text-ink-soft" colSpan={5}>
                  No hay facturas de compra cargadas todavía.
                </td>
              </tr>
            )}
            {facturas.map((f) => (
              <tr
                key={f.id}
                onClick={() => setDetalle(f)}
                className="cursor-pointer border-b border-line last:border-0 hover:bg-bg"
              >
                <td className="whitespace-nowrap px-4 py-2.5 text-ink-soft">{formatFecha(f.fecha_comprobante)}</td>
                <td className="px-4 py-2.5 text-ink">{f.proveedor?.razon_social ?? '—'}</td>
                <td className="px-4 py-2.5 text-ink-soft">
                  {TIPO_LABEL[f.tipo_comprobante] ?? f.tipo_comprobante}
                  {f.letra ? ` ${f.letra}` : ''}
                  {f.numero_comprobante ? ` · ${f.numero_comprobante}` : ''}
                </td>
                <td className="px-4 py-2.5 text-right text-ink">{formatCurrency(f.total)}</td>
                <td className={`px-4 py-2.5 text-right ${f.saldo_pendiente > 0 ? 'text-error' : 'text-success'}`}>
                  {formatCurrency(f.saldo_pendiente)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {modalNueva && (
        <CargarFacturaCompraModal
          onClose={() => setModalNueva(false)}
          onSaved={() => {
            setModalNueva(false)
            cargar()
          }}
        />
      )}

      {detalle && (
        <FacturaCompraDetalleModal
          factura={detalle}
          proveedorNombre={detalle.proveedor?.razon_social ?? '—'}
          onClose={() => setDetalle(null)}
          onPagoRegistrado={cargar}
        />
      )}
    </div>
  )
}
