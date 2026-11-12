import { useEffect, useState } from 'react'
import { Copy, Eye } from 'lucide-react'
import type { FacturaCompraSaldo, PayloadBorradorFactura, Proveedor } from '@virikyna/shared'
import {
  ChipTipoCompra,
  EstadoBadge,
  etiquetaComprobanteCompra,
  formatCurrency,
  formatFechaCorta,
  friendlyError,
  RowActionsMenu,
  TIPO_COMPROBANTE_COMPRA_LABEL as TIPO_LABEL,
  ListaBorradores,
  useBorradores,
} from '@virikyna/shared'
import { useAlCambiarDatos } from '@virikyna/shared/lib/cambiosDatos'
import { useBandeja } from '@virikyna/shared/src/components/documentos/DocumentosAbiertos'
import { supabase } from '../../lib/supabaseClient'
import { abrirCargaFactura, abrirDetalleFactura } from './documentosFactura'
import type { FacturaCompraConProveedor } from './types'

export function FacturasCompraTab() {
  const [facturas, setFacturas] = useState<FacturaCompraConProveedor[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  // Detalle, carga nueva, copia (docs/33) y borrador retomado se abren como documentos de la
  // bandeja (docs/73): se pueden minimizar e ir a otra pantalla.
  const bandeja = useBandeja()
  const verDetalle = (f: FacturaCompraConProveedor) => abrirDetalleFactura(bandeja, f, f.proveedor?.razon_social ?? '—')
  // Borradores de factura/NC (docs/54): arriba del listado; no cuentan en saldos.
  const borradores = useBorradores<PayloadBorradorFactura>(supabase, 'factura_compra', 'local')
  // Lo que se guarda o se cierra en un documento de la bandeja refresca el listado montado.
  useAlCambiarDatos('facturas_compra', () => void cargar())
  useAlCambiarDatos('borradores_factura', () => borradores.recargar())

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
          onClick={() => abrirCargaFactura(bandeja)}
          className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark"
        >
          + Nueva factura
        </button>
      </div>

      {error && (
        <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>
      )}

      {borradores.borradores.length > 0 && (
        <div className="mt-stack-md">
          <ListaBorradores
            supabase={supabase}
            sistema="local"
            lista={borradores}
            onRetomar={(b) => abrirCargaFactura(bandeja, { borrador: b })}
          />
        </div>
      )}

      <div className="mt-stack-md flex-1 overflow-auto rounded-xl shadow-sm">
        <table className="w-full text-left font-sans text-table-row">
          <thead>
            <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
              <th className="min-w-[100px] whitespace-nowrap px-3 py-2.5">Fecha</th>
              <th className="min-w-[180px] whitespace-nowrap px-3 py-2.5">Proveedor</th>
              <th className="whitespace-nowrap px-3 py-2.5">Comprobante</th>
              <th className="whitespace-nowrap px-3 py-2.5 text-right">Total</th>
              <th className="whitespace-nowrap px-3 py-2.5 text-right">Saldo pendiente</th>
              <th className="whitespace-nowrap px-3 py-2.5"></th>
              <th className="w-[3rem] px-3 py-2.5">
                <span className="sr-only">Acciones</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={7}>
                  Cargando...
                </td>
              </tr>
            )}
            {!loading && facturas.length === 0 && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={7}>
                  No hay facturas de compra cargadas todavía.
                </td>
              </tr>
            )}
            {facturas.map((f) => (
              <tr
                key={f.id}
                onClick={() => verDetalle(f)}
                className={`cursor-pointer border-b border-table-divider last:border-0 even:bg-table-row-alt hover:bg-accent-light/40 ${
                  f.anulada ? 'text-ink-soft line-through' : ''
                }`}
              >
                <td className="whitespace-nowrap px-3 py-3 text-ink-soft">{formatFechaCorta(f.fecha_comprobante)}</td>
                <td className={`px-3 py-3 ${f.anulada ? '' : 'text-ink'}`}>{f.proveedor?.razon_social ?? '—'}</td>
                <td className="px-3 py-3 text-ink-soft">
                  {TIPO_LABEL[f.tipo_comprobante] ?? f.tipo_comprobante}
                  {f.letra ? ` ${f.letra}` : ''}
                  {f.numero_comprobante ? ` · ${f.numero_comprobante}` : ''}
                  <ChipTipoCompra tipo={f.tipo_compra} className="ml-2" />
                </td>
                <td className={`px-3 py-3 text-right ${f.anulada ? '' : 'text-ink'}`}>{formatCurrency(f.total)}</td>
                <td
                  className={`px-3 py-3 text-right font-semibold ${
                    f.anulada ? '' : f.saldo_pendiente > 0 ? 'text-error' : 'text-success'
                  }`}
                >
                  {formatCurrency(f.saldo_pendiente)}
                </td>
                <td className="px-3 py-3 text-right">
                  {f.anulada && (
                    <span className="no-underline">
                      <EstadoBadge variant="red">Anulada</EstadoBadge>
                    </span>
                  )}
                </td>
                <td className="px-3 py-3 text-right" onClick={(e) => e.stopPropagation()}>
                  <RowActionsMenu
                    ariaLabel={`Acciones para ${etiquetaComprobanteCompra(f)}`}
                    items={[
                      { label: 'Ver detalle', icon: Eye, onClick: () => verDetalle(f) },
                      { label: 'Copiar', icon: Copy, onClick: () => abrirCargaFactura(bandeja, { copiadaDeId: f.id }) },
                    ]}
                  />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
