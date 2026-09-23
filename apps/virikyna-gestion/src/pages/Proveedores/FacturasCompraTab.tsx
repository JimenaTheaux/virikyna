import { useEffect, useState } from 'react'
import type { FacturaCompraSaldo, Proveedor } from '@virikyna/shared'
import { formatCurrency, formatFechaCorta, friendlyError } from '@virikyna/shared'
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

// Facturas de compra vistas desde Virikyna Gestión — la carga usa el mismo RPC atómico
// `cargar_factura_compra` que Virikyna Local e Inventario (ver CargarFacturaCompraModal), así
// que un admin puede cargar una factura de mostrador sin ir a la caja. Lo exclusivo de esta app
// siguen siendo los dos botones del detalle: Editar (solo campos descriptivos) y Anular
// (docs/06_estructura_de_datos.md, RPCs 10 y 11) — ninguno de los dos existe en Virikyna Local.
export function FacturasCompraTab() {
  const [facturas, setFacturas] = useState<FacturaCompraConProveedor[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [detalle, setDetalle] = useState<FacturaCompraConProveedor | null>(null)
  const [nuevaFactura, setNuevaFactura] = useState(false)

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
      <div className="flex items-center justify-between gap-3">
        <p className="font-sans text-body-md text-ink-soft">
          Facturas, remitos y otros comprobantes de compra.
        </p>
        <button
          type="button"
          onClick={() => setNuevaFactura(true)}
          className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark"
        >
          + Nueva factura
        </button>
      </div>

      {error && (
        <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>
      )}

      <div className="mt-stack-md flex-1 overflow-auto rounded-lg border border-line">
        <table className="w-full text-left font-sans text-body-md leading-5">
          <thead>
            <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
              <th className="min-w-[100px] whitespace-nowrap px-3 py-2">Fecha</th>
              <th className="min-w-[180px] whitespace-nowrap px-3 py-2">Proveedor</th>
              <th className="whitespace-nowrap px-3 py-2">Comprobante</th>
              <th className="whitespace-nowrap px-3 py-2 text-right">Total</th>
              <th className="whitespace-nowrap px-3 py-2 text-right">Saldo pendiente</th>
              <th className="whitespace-nowrap px-3 py-2"></th>
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
            {!loading && facturas.length === 0 && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={6}>
                  No hay facturas de compra cargadas todavía.
                </td>
              </tr>
            )}
            {facturas.map((f) => (
              <tr
                key={f.id}
                onClick={() => setDetalle(f)}
                className={`cursor-pointer border-b border-line last:border-0 hover:bg-bg ${
                  f.anulada ? 'text-ink-soft line-through' : ''
                }`}
              >
                <td className="whitespace-nowrap px-3 py-1.5 text-ink-soft">{formatFechaCorta(f.fecha_comprobante)}</td>
                <td className={`px-3 py-1.5 ${f.anulada ? '' : 'text-ink'}`}>{f.proveedor?.razon_social ?? '—'}</td>
                <td className="px-3 py-1.5 text-ink-soft">
                  {TIPO_LABEL[f.tipo_comprobante] ?? f.tipo_comprobante}
                  {f.letra ? ` ${f.letra}` : ''}
                  {f.numero_comprobante ? ` · ${f.numero_comprobante}` : ''}
                </td>
                <td className={`px-3 py-1.5 text-right ${f.anulada ? '' : 'text-ink'}`}>{formatCurrency(f.total)}</td>
                <td
                  className={`px-3 py-1.5 text-right ${
                    f.anulada ? '' : f.saldo_pendiente > 0 ? 'text-error' : 'text-success'
                  }`}
                >
                  {formatCurrency(f.saldo_pendiente)}
                </td>
                <td className="px-3 py-1.5 text-right">
                  {f.anulada && (
                    <span className="rounded-full bg-error/10 px-2 py-1 font-sans text-label-md text-error no-underline">
                      Anulada
                    </span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {detalle && (
        <FacturaCompraDetalleModal
          factura={detalle}
          proveedorNombre={detalle.proveedor?.razon_social ?? '—'}
          onClose={() => setDetalle(null)}
          onChanged={cargar}
        />
      )}

      {nuevaFactura && (
        <CargarFacturaCompraModal
          onClose={() => setNuevaFactura(false)}
          onSaved={() => {
            setNuevaFactura(false)
            cargar()
          }}
        />
      )}
    </div>
  )
}
