import { useEffect, useState } from 'react'
import type { ClienteSaldo, PagoCliente, Venta } from '@virikyna/shared'
import { formatCurrency, formatFechaHora, friendlyError, nombresPorId } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { Modal } from '../../components/Modal'
import { RegistrarPagoClienteModal } from './RegistrarPagoClienteModal'

type PagoConUsuario = PagoCliente & { usuario: { nombre: string } | null }
type VentaResumen = Pick<Venta, 'id' | 'numero' | 'total' | 'created_at' | 'estado'>

const ESTADO_VENTA_LABEL: Record<VentaResumen['estado'], string> = {
  sin_facturar: 'Sin facturar',
  facturado: 'Facturada',
  anulada: 'Anulada',
}

type Props = {
  cliente: ClienteSaldo
  onClose: () => void
  onChanged: () => void // avisa al listado para refrescar el saldo mostrado ahí
}

// Historial de cuenta corriente de un cliente (docs/04_modulos_y_funciones.md, módulo 8):
// ventas a cta. cte. + pagos recibidos, y desde acá se cobra. El saldo se lee de la vista
// `clientes_saldo` (nunca se recalcula a mano en el frontend).
export function ClienteDetalleModal({ cliente, onClose, onChanged }: Props) {
  const [saldoActual, setSaldoActual] = useState(cliente.saldo_actual)
  const [ventas, setVentas] = useState<VentaResumen[]>([])
  const [pagos, setPagos] = useState<PagoConUsuario[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [modalPago, setModalPago] = useState(false)

  async function cargar() {
    setLoading(true)
    setError(null)

    const [saldoRes, ventasRes, pagosRes] = await Promise.all([
      supabase.from('clientes_saldo').select('saldo_actual').eq('id', cliente.id).single(),
      supabase
        .from('ventas')
        .select('id, numero, total, created_at, estado')
        .eq('cliente_id', cliente.id)
        .eq('forma_pago', 'cuenta_corriente')
        .order('created_at', { ascending: false }),
      supabase
        .from('pagos_cliente')
        .select('*')
        .eq('cliente_id', cliente.id)
        .order('created_at', { ascending: false }),
    ])

    if (saldoRes.error || ventasRes.error || pagosRes.error) {
      setError(friendlyError(saldoRes.error || ventasRes.error || pagosRes.error))
      setLoading(false)
      return
    }

    setSaldoActual((saldoRes.data?.saldo_actual as number | undefined) ?? cliente.saldo_actual)
    setVentas((ventasRes.data ?? []) as VentaResumen[])

    const pagosSinUsuario = (pagosRes.data ?? []) as PagoCliente[]
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
  }, [cliente.id])

  const numeroVentaPorId = new Map(ventas.map((v) => [v.id, v.numero]))

  return (
    <Modal
      title={cliente.razon_social ?? cliente.nombre_fantasia ?? 'Cliente'}
      onClose={onClose}
      widthClassName="max-w-[680px]"
    >
      <div className="flex flex-col gap-stack-md">
        <div className="flex items-center justify-between rounded-lg border border-line p-4">
          <div>
            <p className="font-sans text-label-md text-ink-soft">Saldo de cuenta corriente</p>
            <p
              className={`font-display text-headline-md ${saldoActual > 0 ? 'text-error' : 'text-accent-darker'}`}
            >
              {formatCurrency(saldoActual)}
            </p>
          </div>
          <button
            type="button"
            onClick={() => setModalPago(true)}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark"
          >
            Cobrar
          </button>
        </div>

        {error && <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>}
        {loading && <p className="font-sans text-body-md text-ink-soft">Cargando...</p>}

        {!loading && (
          <>
            <div>
              <p className="font-sans text-label-bold text-ink-soft">Ventas a cuenta corriente</p>
              <div className="mt-2 max-h-[220px] overflow-auto rounded-lg border border-line">
                <table className="w-full text-left font-sans text-body-md leading-5">
                  <tbody>
                    {ventas.length === 0 && (
                      <tr>
                        <td className="px-3 py-2 text-ink-soft">Sin ventas a cuenta corriente todavía.</td>
                      </tr>
                    )}
                    {ventas.map((v) => (
                      <tr key={v.id} className="border-b border-line last:border-0">
                        <td className="whitespace-nowrap px-3 py-2 text-ink-soft">{formatFechaHora(v.created_at)}</td>
                        <td className="px-3 py-2 text-ink">N° {v.numero}</td>
                        <td className="px-3 py-2 text-ink-soft">{ESTADO_VENTA_LABEL[v.estado]}</td>
                        <td className="px-3 py-2 text-right text-ink">{formatCurrency(v.total)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>

            <div>
              <p className="font-sans text-label-bold text-ink-soft">Pagos recibidos</p>
              <div className="mt-2 max-h-[220px] overflow-auto rounded-lg border border-line">
                <table className="w-full text-left font-sans text-body-md leading-5">
                  <tbody>
                    {pagos.length === 0 && (
                      <tr>
                        <td className="px-3 py-2 text-ink-soft">Sin pagos registrados todavía.</td>
                      </tr>
                    )}
                    {pagos.map((p) => (
                      <tr key={p.id} className="border-b border-line last:border-0">
                        <td className="whitespace-nowrap px-3 py-2 text-ink-soft">{formatFechaHora(p.created_at)}</td>
                        <td className="px-3 py-2 text-ink-soft">
                          {p.venta_id ? `Venta N° ${numeroVentaPorId.get(p.venta_id) ?? '—'}` : 'Cuenta general'}
                        </td>
                        <td className="px-3 py-2 text-ink-soft">{p.usuario?.nombre ?? '—'}</td>
                        <td className="px-3 py-2 text-right text-success">{formatCurrency(p.monto)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          </>
        )}
      </div>

      {modalPago && (
        <RegistrarPagoClienteModal
          cliente={cliente}
          ventasCuentaCorriente={ventas}
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
