import { useEffect, useState } from 'react'
import type { FacturaCompra, FacturaCompraItem, FacturaCompraSaldo, PagoProveedor } from '@virikyna/shared'
import {
  ChipTipoCompra,
  EstadoBadge,
  esNotaCredito,
  etiquetaAlicuotaIva,
  etiquetaComprobanteCompra,
  etiquetaFormaPago,
  FormaPagoConDetalle,
  formatCurrency,
  formatFechaCorta,
  friendlyError,
  nombresPorId,
  SELECT_MEDIOS_PAGO,
  tipoCompraDe,
  VincularItemFacturaModal,
  type MedioDePago,
} from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { usePerfil } from '../../auth/AuthContext'
import { Modal } from '../../components/Modal'
import { ErrorText } from '../../components/FormField'
import { RegistrarPagoProveedorModal } from './RegistrarPagoProveedorModal'

type ComprobanteRef = Pick<FacturaCompra, 'tipo_comprobante' | 'letra' | 'punto_venta' | 'numero_comprobante'>

// Una aplicación (docs/31) con lo necesario para mostrarla: de qué pago salió (fecha, medio) o de
// qué NC, y — si este comprobante es una NC — a qué comprobante se aplicó su crédito.
type AplicacionDetalle = {
  id: string
  monto: number
  usuario_id: string
  revertida_at: string | null
  created_at: string
  operacion: Pick<PagoProveedor, 'fecha'> | null
  pago: (Pick<PagoProveedor, 'forma_pago' | 'cheque_numero'> & { medios: MedioDePago[] | null }) | null
  nc: ComprobanteRef | null
  factura: ComprobanteRef | null
  usuario: string | null
}

type Props = {
  factura: FacturaCompraSaldo
  proveedorNombre: string
  onClose: () => void
  onPagoRegistrado: () => void // avisa al listado para refrescar saldos
  // Botón "Copiar" (docs/33), también en anuladas. Sin esta prop no aparece — así el detalle
  // abierto desde una copia no ofrece copiar otra vez.
  onCopiar?: () => void
}

const ESTADO: Record<FacturaCompraSaldo['estado'], { label: string; variant: 'amber' | 'green' | 'red' }> = {
  pendiente: { label: 'Pendiente', variant: 'amber' },
  parcial: { label: 'Parcial', variant: 'amber' },
  pagada: { label: 'Pagada', variant: 'green' },
  anulada: { label: 'Anulada', variant: 'red' },
}

// Detalle de un comprobante de compra en Local. El historial sale de pagos_proveedor_aplicaciones
// (docs/31), no de pagos_proveedor.factura_compra_id (deprecated): un pago puede cubrir varios
// comprobantes y una NC cancelar parte de uno. Misma lectura que el detalle de Gestión, sin
// Editar/Anular (exclusivos de Gestión). El pago se oculta en anuladas y en notas de crédito —
// una NC no se paga, se aplica.
export function FacturaCompraDetalleModal({ factura, proveedorNombre, onClose, onPagoRegistrado, onCopiar }: Props) {
  const [facturaActual, setFacturaActual] = useState(factura)
  const [items, setItems] = useState<FacturaCompraItem[]>([])
  const [aplicaciones, setAplicaciones] = useState<AplicacionDetalle[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [modalPago, setModalPago] = useState(false)
  // Ítem libre a vincular a un producto (docs/50): solo admin (lo valida también el RPC).
  const { rol } = usePerfil()
  const [itemAVincular, setItemAVincular] = useState<FacturaCompraItem | null>(null)

  const nc = esNotaCredito(facturaActual)
  // docs/53: servicios no tiene cantidad (es 1) ni producto — no se ofrece vincular.
  const servicios = tipoCompraDe(facturaActual) === 'servicios'

  async function cargar() {
    setLoading(true)
    setError(null)

    const [facturaRes, itemsRes, aplicacionesRes] = await Promise.all([
      supabase.from('facturas_compra_saldo').select('*').eq('id', factura.id).single(),
      supabase.from('facturas_compra_items').select('*').eq('factura_compra_id', factura.id).order('id'),
      supabase
        .from('pagos_proveedor_aplicaciones')
        .select(
          `id, monto, usuario_id, revertida_at, created_at,
           operacion:pagos_proveedor!pagos_proveedor_aplicaciones_operacion_id_fkey(fecha),
           pago:pagos_proveedor!pagos_proveedor_aplicaciones_pago_proveedor_id_fkey(forma_pago, cheque_numero, ${SELECT_MEDIOS_PAGO}),
           nc:facturas_compra!pagos_proveedor_aplicaciones_nota_credito_id_fkey(tipo_comprobante, letra, punto_venta, numero_comprobante),
           factura:facturas_compra!pagos_proveedor_aplicaciones_factura_compra_id_fkey(tipo_comprobante, letra, punto_venta, numero_comprobante)`,
        )
        .or(`factura_compra_id.eq.${factura.id},nota_credito_id.eq.${factura.id}`)
        .order('created_at', { ascending: false }),
    ])

    if (facturaRes.error) {
      setError(friendlyError(facturaRes.error))
    } else if (facturaRes.data) {
      setFacturaActual(facturaRes.data as FacturaCompraSaldo)
    }
    if (aplicacionesRes.error) setError(friendlyError(aplicacionesRes.error))
    setItems((itemsRes.data ?? []) as FacturaCompraItem[])

    const filas = (aplicacionesRes.data ?? []) as unknown as Omit<AplicacionDetalle, 'usuario'>[]
    const nombres = await nombresPorId(
      supabase,
      filas.map((a) => a.usuario_id),
    )
    setAplicaciones(filas.map((a) => ({ ...a, monto: Number(a.monto), usuario: nombres.get(a.usuario_id) ?? null })))
    setLoading(false)
  }

  useEffect(() => {
    cargar()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [factura.id])

  const estado = ESTADO[facturaActual.estado]

  // Para un comprobante: de dónde salió la plata. Para una NC: a qué comprobante se aplicó.
  function origenAplicacion(a: AplicacionDetalle): string {
    if (nc) return a.factura ? `Aplicada a ${etiquetaComprobanteCompra(a.factura)}` : 'Aplicada'
    if (a.nc) return etiquetaComprobanteCompra(a.nc)
    if (a.pago) return etiquetaFormaPago(a.pago)
    return '—'
  }

  return (
    <Modal
      title={etiquetaComprobanteCompra(facturaActual)}
      onClose={onClose}
      widthClassName="max-w-[680px]"
      dialogo={{ onEscape: onClose }}
      // Acciones en el pie fijo: con subtotal e IVA (docs/45) el detalle ya no entra en 720 px.
      footer={
        onCopiar ? (
          <div className="flex justify-end">
            <button
              type="button"
              onClick={onCopiar}
              className="rounded border border-accent px-4 py-3 font-sans text-label-bold text-accent-darker transition hover:bg-accent-light"
            >
              Copiar
            </button>
          </div>
        ) : undefined
      }
    >
      <div className="flex flex-col gap-stack-md">
        {facturaActual.anulada && (
          <div className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">
            {nc
              ? facturaActual.devuelve_mercaderia
                ? 'Esta nota de crédito está anulada — la mercadería devuelta volvió a sumarse al stock.'
                : 'Esta nota de crédito está anulada.'
              : servicios
                ? 'Esta factura está anulada.'
                : 'Esta factura está anulada — el stock que había sumado ya fue revertido.'}
          </div>
        )}

        <div className="grid grid-cols-2 gap-stack-sm rounded-lg border border-line bg-bg p-4 font-sans text-body-md">
          <p className="text-ink-soft">
            Proveedor: <span className="text-ink">{proveedorNombre}</span>
          </p>
          <p className="text-ink-soft">
            Fecha: <span className="text-ink">{formatFechaCorta(facturaActual.fecha_comprobante)}</span>
          </p>
          <p className="text-ink-soft">
            Forma de pago:{' '}
            <span className="text-ink">
              {facturaActual.forma_pago === 'contado' ? 'Contado' : 'Cuenta corriente'}
            </span>
          </p>
          <p className="text-ink-soft">
            Subtotal sin IVA: <span className="tabular-nums text-ink">{formatCurrency(facturaActual.total_sin_iva)}</span>
          </p>
          <p className="text-ink-soft">
            {etiquetaAlicuotaIva(facturaActual.iva_alicuota)}
            {Number(facturaActual.iva_alicuota) > 0 && (
              <>
                : <span className="tabular-nums text-ink">{formatCurrency(facturaActual.iva)}</span>
              </>
            )}
          </p>
          <p className="text-ink-soft">
            Total:{' '}
            <span className={`tabular-nums ${nc ? 'text-success' : 'text-ink'}`}>
              {nc ? '−' : ''}
              {formatCurrency(facturaActual.total)}
            </span>
          </p>
          {/* docs/55: una NC de artículos solo toca el stock con devolución de mercadería. */}
          {nc && !servicios && (
            <p className="col-span-2 text-ink-soft">
              Stock:{' '}
              <span className="text-ink">
                {facturaActual.devuelve_mercaderia ? 'devolución de mercadería (restó stock)' : 'no mueve stock'}
              </span>
            </p>
          )}
        </div>

        {error && <ErrorText>{error}</ErrorText>}

        <div>
          <p className="font-sans text-label-bold text-ink-soft">{servicios ? 'Servicios' : 'Ítems'}</p>
          <div className="mt-2 overflow-auto rounded-lg border border-line">
            <table className="w-full text-left font-sans text-body-md leading-5">
              <thead>
                <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
                  <th className="px-4 py-2">Descripción</th>
                  {!servicios && <th className="px-4 py-2 text-right">Cant.</th>}
                  <th className="px-4 py-2 text-right">{servicios ? 'Importe' : 'Precio unit.'}</th>
                  <th className="px-4 py-2 text-right">Subtotal</th>
                </tr>
              </thead>
              <tbody>
                {loading && (
                  <tr>
                    <td className="px-4 py-4 text-ink-soft" colSpan={servicios ? 3 : 4}>
                      Cargando...
                    </td>
                  </tr>
                )}
                {!loading &&
                  items.map((it) => (
                    <tr key={it.id} className="border-b border-line last:border-0">
                      <td className="px-4 py-2 text-ink">
                        {it.descripcion}
                        {!servicios && !nc && !it.producto_id && !facturaActual.anulada && (
                          <ItemSinProducto onVincular={rol === 'admin' ? () => setItemAVincular(it) : undefined} />
                        )}
                      </td>
                      {!servicios && <td className="px-4 py-2 text-right text-ink-soft">{it.cantidad}</td>}
                      <td className="px-4 py-2 text-right tabular-nums text-ink-soft">
                        {formatCurrency(it.precio_unitario_sin_iva)}
                      </td>
                      <td className="px-4 py-2 text-right tabular-nums text-ink">{formatCurrency(it.precio_total_sin_iva)}</td>
                    </tr>
                  ))}
              </tbody>
            </table>
          </div>
        </div>

        <div className="rounded-lg border border-line p-4">
          <div className="flex items-center justify-between gap-stack-md">
            <div>
              <p className="flex items-center gap-2 font-sans text-label-md text-ink-soft">
                {nc ? 'Crédito disponible' : 'Saldo pendiente'}
                <EstadoBadge variant={estado.variant}>
                  {nc && facturaActual.estado === 'pagada' ? 'Agotada' : estado.label}
                </EstadoBadge>
                <ChipTipoCompra tipo={facturaActual.tipo_compra} />
              </p>
              <p
                className={`font-display text-headline-md tabular-nums ${
                  nc ? 'text-success' : facturaActual.saldo_pendiente > 0 ? 'text-error' : 'text-success'
                }`}
              >
                {formatCurrency(nc ? facturaActual.credito_disponible : facturaActual.saldo_pendiente)}
              </p>
            </div>
            {!nc && facturaActual.saldo_pendiente > 0 && !facturaActual.anulada && (
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
          <p className="font-sans text-label-bold text-ink-soft">{nc ? 'Dónde se usó el crédito' : 'Pagos y créditos aplicados'}</p>
          <div className="mt-2 overflow-auto rounded-lg border border-line">
            <table className="w-full text-left font-sans text-body-md leading-5">
              <thead>
                <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
                  <th className="min-w-[110px] whitespace-nowrap px-4 py-2">Fecha</th>
                  <th className="px-4 py-2">{nc ? 'Comprobante' : 'Origen'}</th>
                  <th className="px-4 py-2">Usuario</th>
                  <th className="px-4 py-2 text-right">Monto</th>
                </tr>
              </thead>
              <tbody>
                {!loading && aplicaciones.length === 0 && (
                  <tr>
                    <td className="px-4 py-4 text-ink-soft" colSpan={4}>
                      {nc ? 'El crédito de esta nota todavía no se usó.' : 'Todavía no se registró ningún pago para esta factura.'}
                    </td>
                  </tr>
                )}
                {aplicaciones.map((a) => (
                  <tr key={a.id} className={`border-b border-line last:border-0 ${a.revertida_at ? 'text-ink-soft' : ''}`}>
                    <td className="whitespace-nowrap px-4 py-2 text-ink-soft">
                      {a.operacion ? formatFechaCorta(a.operacion.fecha) : '—'}
                    </td>
                    <td className={`px-4 py-2 ${a.revertida_at ? 'line-through' : a.nc || nc ? 'text-success' : 'text-ink'}`}>
                      {/* docs/65: un pago mixto (registrado en Gestión) se despliega con sus medios. */}
                      {!nc && a.pago?.forma_pago === 'mixto' ? <FormaPagoConDetalle pago={a.pago} /> : origenAplicacion(a)}
                      {a.revertida_at && <span className="ml-2 no-underline">(revertida)</span>}
                    </td>
                    <td className="px-4 py-2 text-ink-soft">{a.usuario ?? '—'}</td>
                    <td className={`px-4 py-2 text-right tabular-nums ${a.revertida_at ? 'line-through' : 'text-ink'}`}>
                      {formatCurrency(a.monto)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      </div>

      {itemAVincular && (
        <VincularItemFacturaModal
          supabase={supabase}
          item={itemAVincular}
          onClose={() => setItemAVincular(null)}
          onVinculado={() => {
            setItemAVincular(null)
            cargar()
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
            onPagoRegistrado()
          }}
        />
      )}
    </Modal>
  )
}

// Ítem libre (docs/50): no sumó stock al cargar el comprobante. Si es mercadería, un admin lo vincula.
function ItemSinProducto({ onVincular }: { onVincular?: () => void }) {
  return (
    <span className="mt-1 flex flex-wrap items-center gap-2 text-label-md text-ink-soft">
      Sin producto: no sumó stock
      {onVincular && (
        <button
          type="button"
          onClick={onVincular}
          className="rounded border border-accent/60 px-2 py-0.5 font-sans text-label-bold text-accent-dark hover:bg-accent-light"
        >
          Vincular a producto
        </button>
      )}
    </span>
  )
}
