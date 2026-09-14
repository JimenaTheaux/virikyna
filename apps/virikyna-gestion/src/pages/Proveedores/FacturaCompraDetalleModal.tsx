import { useEffect, useState } from 'react'
import type { FacturaCompraItem, FacturaCompraSaldo, PagoProveedor } from '@virikyna/shared'
import { formatCurrency, formatFecha, formatFechaHora, friendlyError, nombresPorId } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { Modal } from '../../components/Modal'
import { ErrorText } from '../../components/FormField'
import { EditarFacturaCompraModal } from './EditarFacturaCompraModal'
import { AnularFacturaCompraModal } from './AnularFacturaCompraModal'
import { RegistrarPagoProveedorModal } from './RegistrarPagoProveedorModal'

type PagoConUsuario = PagoProveedor & { usuario: { nombre: string } | null }

type Props = {
  factura: FacturaCompraSaldo
  proveedorNombre: string
  onClose: () => void
  onChanged: () => void // avisa al listado para refrescar tras editar, anular o pagar
}

const TIPO_LABEL: Record<string, string> = {
  factura: 'Factura',
  remito: 'Remito',
  cupon: 'Cupón',
  nota_credito: 'Nota de crédito',
  nota_debito: 'Nota de débito',
}

// Detalle de una factura de compra desde Virikyna Gestión — misma fuente de datos y mismo RPC
// `registrar_pago_proveedor` que usa Virikyna Local (docs/04_modulos_y_funciones.md, módulo 7.1:
// "registra pagos — mismas acciones y misma función de sistema que usa el cajero desde Virikyna
// Local"), más los dos botones exclusivos de esta app: Editar y Anular (RPCs 10 y 11). El botón
// de pago se oculta si la factura ya está anulada — no tiene sentido pagar algo que se revirtió.
export function FacturaCompraDetalleModal({ factura, proveedorNombre, onClose, onChanged }: Props) {
  const [facturaActual, setFacturaActual] = useState(factura)
  const [items, setItems] = useState<FacturaCompraItem[]>([])
  const [pagos, setPagos] = useState<PagoConUsuario[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [modalEditar, setModalEditar] = useState(false)
  const [modalAnular, setModalAnular] = useState(false)
  const [modalPago, setModalPago] = useState(false)

  async function cargar() {
    setLoading(true)
    setError(null)

    const [facturaRes, itemsRes, pagosRes] = await Promise.all([
      supabase.from('facturas_compra_saldo').select('*').eq('id', factura.id).single(),
      supabase.from('facturas_compra_items').select('*').eq('factura_compra_id', factura.id).order('id'),
      supabase
        .from('pagos_proveedor')
        .select('*')
        .eq('factura_compra_id', factura.id)
        .order('created_at', { ascending: false }),
    ])

    if (facturaRes.error) {
      setError(friendlyError(facturaRes.error))
    } else if (facturaRes.data) {
      setFacturaActual(facturaRes.data as FacturaCompraSaldo)
    }
    setItems((itemsRes.data ?? []) as FacturaCompraItem[])

    const pagosSinUsuario = (pagosRes.data ?? []) as unknown as PagoProveedor[]
    const nombrePorUsuario = await nombresPorId(
      supabase,
      pagosSinUsuario.map((p) => p.usuario_id),
    )
    setPagos(
      pagosSinUsuario.map((p) => ({
        ...p,
        usuario: nombrePorUsuario.has(p.usuario_id) ? { nombre: nombrePorUsuario.get(p.usuario_id)! } : null,
      })),
    )
    setLoading(false)
  }

  useEffect(() => {
    cargar()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [factura.id])

  const encabezado = [
    TIPO_LABEL[facturaActual.tipo_comprobante] ?? facturaActual.tipo_comprobante,
    facturaActual.letra,
    [facturaActual.punto_venta, facturaActual.numero_comprobante].filter(Boolean).join('-') || null,
  ]
    .filter(Boolean)
    .join(' ')

  return (
    <Modal title={encabezado || 'Factura de compra'} onClose={onClose} widthClassName="max-w-[680px]">
      <div className="flex flex-col gap-stack-md">
        {facturaActual.anulada && (
          <div className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">
            Esta factura está anulada — el stock que había sumado ya fue revertido.
          </div>
        )}

        <div className="grid grid-cols-2 gap-stack-sm rounded-lg border border-line bg-bg p-4 font-sans text-body-md">
          <p className="text-ink-soft">
            Proveedor: <span className="text-ink">{proveedorNombre}</span>
          </p>
          <p className="text-ink-soft">
            Fecha: <span className="text-ink">{formatFecha(facturaActual.fecha_comprobante)}</span>
          </p>
          <p className="text-ink-soft">
            Forma de pago:{' '}
            <span className="text-ink">
              {facturaActual.forma_pago === 'contado' ? 'Contado' : 'Cuenta corriente'}
            </span>
          </p>
          <p className="text-ink-soft">
            Total: <span className="text-ink">{formatCurrency(facturaActual.total)}</span>
          </p>
        </div>

        {error && <ErrorText>{error}</ErrorText>}

        <div>
          <p className="font-sans text-label-bold text-ink-soft">Ítems</p>
          <div className="mt-2 overflow-auto rounded-lg border border-line">
            <table className="w-full text-left font-sans text-body-md">
              <thead>
                <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
                  <th className="px-4 py-2">Descripción</th>
                  <th className="px-4 py-2 text-right">Cant.</th>
                  <th className="px-4 py-2 text-right">Precio unit.</th>
                  <th className="px-4 py-2 text-right">Subtotal</th>
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
                {!loading &&
                  items.map((it) => (
                    <tr key={it.id} className="border-b border-line last:border-0">
                      <td className="px-4 py-2 text-ink">{it.descripcion}</td>
                      <td className="px-4 py-2 text-right text-ink-soft">{it.cantidad}</td>
                      <td className="px-4 py-2 text-right text-ink-soft">
                        {formatCurrency(it.precio_unitario_sin_iva)}
                      </td>
                      <td className="px-4 py-2 text-right text-ink">{formatCurrency(it.precio_total_sin_iva)}</td>
                    </tr>
                  ))}
              </tbody>
            </table>
          </div>
        </div>

        <div className="rounded-lg border border-line p-4">
          <div className="flex items-center justify-between">
            <div>
              <p className="font-sans text-label-md text-ink-soft">Saldo pendiente</p>
              <p
                className={`font-display text-headline-md ${
                  facturaActual.saldo_pendiente > 0 ? 'text-error' : 'text-success'
                }`}
              >
                {formatCurrency(facturaActual.saldo_pendiente)}
              </p>
            </div>
            {facturaActual.saldo_pendiente > 0 && !facturaActual.anulada && (
              <button
                type="button"
                onClick={() => setModalPago(true)}
                className="rounded-lg bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark"
              >
                + Registrar pago
              </button>
            )}
          </div>
        </div>

        <div>
          <p className="font-sans text-label-bold text-ink-soft">Historial de pagos</p>
          <div className="mt-2 overflow-auto rounded-lg border border-line">
            <table className="w-full text-left font-sans text-body-md">
              <thead>
                <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
                  <th className="min-w-[120px] whitespace-nowrap px-4 py-2">Fecha</th>
                  <th className="px-4 py-2">Usuario</th>
                  <th className="px-4 py-2 text-right">Monto</th>
                </tr>
              </thead>
              <tbody>
                {!loading && pagos.length === 0 && (
                  <tr>
                    <td className="px-4 py-4 text-ink-soft" colSpan={3}>
                      Todavía no se registró ningún pago para esta factura.
                    </td>
                  </tr>
                )}
                {pagos.map((pago) => (
                  <tr key={pago.id} className="border-b border-line last:border-0">
                    <td className="whitespace-nowrap px-4 py-2 text-ink-soft">{formatFechaHora(pago.created_at)}</td>
                    <td className="px-4 py-2 text-ink-soft">{pago.usuario?.nombre ?? '—'}</td>
                    <td className="px-4 py-2 text-right text-ink">{formatCurrency(pago.monto)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>

        {!facturaActual.anulada && (
          <div className="flex justify-end gap-3 border-t border-line pt-stack-md">
            <button
              type="button"
              onClick={() => setModalAnular(true)}
              className="rounded border border-error px-4 py-3 font-sans text-label-bold text-error transition hover:bg-error/10"
            >
              Anular
            </button>
            <button
              type="button"
              onClick={() => setModalEditar(true)}
              className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark"
            >
              Editar
            </button>
          </div>
        )}
      </div>

      {modalEditar && (
        <EditarFacturaCompraModal
          factura={facturaActual}
          onClose={() => setModalEditar(false)}
          onSaved={() => {
            setModalEditar(false)
            cargar()
            onChanged()
          }}
        />
      )}

      {modalAnular && (
        <AnularFacturaCompraModal
          factura={facturaActual}
          onClose={() => setModalAnular(false)}
          onAnulada={() => {
            setModalAnular(false)
            cargar()
            onChanged()
          }}
        />
      )}

      {modalPago && (
        <RegistrarPagoProveedorModal
          proveedorId={facturaActual.proveedor_id}
          proveedorNombre={proveedorNombre}
          facturaCompraId={facturaActual.id}
          saldoPendiente={facturaActual.saldo_pendiente}
          onClose={() => setModalPago(false)}
          onSaved={() => {
            setModalPago(false)
            cargar()
            onChanged()
          }}
        />
      )}
    </Modal>
  )
}
