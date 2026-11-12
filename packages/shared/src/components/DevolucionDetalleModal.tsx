import { useEffect, useState, type ComponentType } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Devolucion, DevolucionItem, DevolucionPago, DevolucionTicket } from '../../types/database'
import { MOTIVO_DEVOLUCION_LABEL, RESOLUCION_DEVOLUCION_LABEL } from '../../lib/devoluciones'
import { formatCurrency, formatFechaCortaLocal, formatFechaHora } from '../../lib/format'
import { nombreItemVendido } from '../../lib/productoTexto'
import { FORMA_PAGO_LABEL, cargarComprobanteVenta, type DatosComprobante } from '../../lib/comprobante'
import { friendlyError } from '../../lib/supabaseErrors'
import { nombresPorId } from '../../lib/perfiles'
import { EstadoBadge } from './EstadoBadge'
import { Modal } from './Modal'

// producto: respaldo para devoluciones anteriores a docs/42, sin producto_nombre/producto_marca guardados.
export type ItemDevolucionConProducto = DevolucionItem & { producto: { nombre: string; marca: string | null } | null }

export type TicketDeDevolucion = DevolucionTicket & { venta: { numero: number; created_at: string } | null }

export type DevolucionConDetalle = Devolucion & {
  tickets: TicketDeDevolucion[]
  items: ItemDevolucionConProducto[]
  usuarioNombre: string | null
}

// Mismo select para el listado de Devoluciones y para una devolución suelta (historial del producto,
// docs/70). docs/74: los tickets salen de devolucion_tickets (con 2–3 tickets devoluciones.venta_id es
// null). El embed de ventas lleva la FK explícita: hay dos caminos entre las tablas.
export const SELECT_DEVOLUCION_DETALLE =
  '*, tickets:devolucion_tickets(devolucion_id, venta_id, orden, total_devuelto, venta:ventas!devolucion_tickets_venta_id_fkey(numero, created_at)), ' +
  'items:devolucion_items(*, producto:productos(nombre, marca))'

export function ordenarTickets<T extends { tickets: TicketDeDevolucion[] }>(d: T): T {
  return { ...d, tickets: [...(d.tickets ?? [])].sort((a, b) => a.orden - b.orden) }
}

// "1234 · 1301" — los N° de ticket de una devolución, en orden.
export function numerosDeTickets(d: { tickets: TicketDeDevolucion[] }): string {
  return d.tickets.map((t) => t.venta?.numero ?? '—').join(' · ')
}

export async function cargarDevolucionDetalle(supabase: SupabaseClient, devolucionId: string): Promise<DevolucionConDetalle> {
  const { data, error } = await supabase.from('devoluciones').select(SELECT_DEVOLUCION_DETALLE).eq('id', devolucionId).single()
  if (error) throw error
  const base = ordenarTickets(data as unknown as Omit<DevolucionConDetalle, 'usuarioNombre'>)
  const nombres = await nombresPorId(supabase, [base.usuario_id])
  return { ...base, usuarioNombre: nombres.get(base.usuario_id) ?? null }
}

// diferencia_monto = nuevos − devueltos: > 0 paga el cliente, < 0 queda a favor del cliente.
export function sentidoDiferencia(monto: number): string {
  if (monto > 0) return 'Paga el cliente'
  if (monto < 0) return 'A favor del cliente'
  return 'Sin diferencia'
}

// Detalle completo de una devolución/cambio: tickets (con su subtotal y acceso al comprobante
// original), ítems devueltos por ticket, lo que se llevó, motivo, cómo se resolvió la diferencia y
// notas. `ComprobanteModal`: cada app enchufa el suyo (sin él, no se ofrece "Ver ticket").
export function DevolucionDetalleModal({
  supabase,
  devolucion: d,
  onClose,
  ComprobanteModal,
}: {
  supabase: SupabaseClient
  devolucion: DevolucionConDetalle
  onClose: () => void
  ComprobanteModal?: ComponentType<{ datos: DatosComprobante; onClose: () => void }>
}) {
  const [pagos, setPagos] = useState<Pick<DevolucionPago, 'forma_pago' | 'monto'>[]>([])
  const [comprobante, setComprobante] = useState<DatosComprobante | null>(null)
  const [abriendo, setAbriendo] = useState<string | null>(null)
  const [errorTicket, setErrorTicket] = useState<string | null>(null)

  useEffect(() => {
    if (d.diferencia_forma_pago !== 'combinado') return
    supabase
      .from('devolucion_pagos')
      .select('forma_pago, monto')
      .eq('devolucion_id', d.id)
      .then(({ data }) => setPagos((data ?? []) as Pick<DevolucionPago, 'forma_pago' | 'monto'>[]))
  }, [supabase, d.id, d.diferencia_forma_pago])

  async function verTicket(ventaId: string) {
    setErrorTicket(null)
    setAbriendo(ventaId)
    try {
      setComprobante(await cargarComprobanteVenta(supabase, ventaId))
    } catch (e) {
      setErrorTicket(friendlyError(e as Error))
    } finally {
      setAbriendo(null)
    }
  }

  const devueltos = d.items.filter((it) => it.tipo === 'devuelto')
  const nuevos = d.items.filter((it) => it.tipo !== 'devuelto')
  const tickets = d.tickets ?? []
  // Devueltos sin ticket (no debería haber después de docs/74): se listan aparte para no perderlos.
  const sinTicket = devueltos.filter((it) => !tickets.some((t) => t.venta_id === it.venta_id))

  return (
    <Modal title={`Devolución ${d.numero}`} onClose={onClose} dialogo={{ onEscape: onClose }} widthClassName="max-w-[680px]">
      <div className="flex flex-col gap-stack-md font-sans text-body-md text-ink">
        <dl className="grid grid-cols-2 gap-x-stack-md gap-y-2">
          <Dato label="Fecha">{formatFechaHora(d.created_at)}</Dato>
          <Dato label="Registró">{d.usuarioNombre ?? '—'}</Dato>
          <Dato label="Estado">
            {d.estado === 'anulada' ? (
              <EstadoBadge variant="red">Anulada</EstadoBadge>
            ) : (
              <EstadoBadge variant="green">Activa</EstadoBadge>
            )}
          </Dato>
          <Dato label="Motivo">
            {MOTIVO_DEVOLUCION_LABEL[d.motivo]}
            {d.motivo_detalle && <span className="text-ink-soft"> — {d.motivo_detalle}</span>}
          </Dato>
          {d.estado === 'anulada' && d.motivo_anulacion && (
            <div className="col-span-2">
              <Dato label="Motivo de la anulación">{d.motivo_anulacion}</Dato>
            </div>
          )}
        </dl>

        {tickets.map((t, i) => {
          const items = devueltos.filter((it) => it.venta_id === t.venta_id)
          return (
            <section key={t.venta_id} className="rounded-lg border border-line">
              <header className="flex flex-wrap items-center justify-between gap-2 border-b border-line bg-accent-light/60 px-3 py-2">
                <p className="font-sans text-label-bold text-accent-darker">
                  {tickets.length > 1 ? `Ticket ${i + 1} — ` : 'Ticket '}N° {t.venta?.numero ?? '—'}
                  {t.venta?.created_at && (
                    <span className="font-normal text-ink-soft"> · {formatFechaCortaLocal(t.venta.created_at)}</span>
                  )}
                </p>
                {ComprobanteModal && (
                  <button
                    type="button"
                    onClick={() => void verTicket(t.venta_id)}
                    disabled={abriendo !== null}
                    className="min-h-9 rounded border border-accent px-3 py-1 font-sans text-label-bold text-accent-dark transition hover:bg-white disabled:opacity-60"
                  >
                    {abriendo === t.venta_id ? 'Abriendo...' : 'Ver ticket'}
                  </button>
                )}
              </header>
              <div className="px-3">
                <ListaItems items={items} total={t.total_devuelto} etiquetaTotal="Subtotal devuelto" />
              </div>
            </section>
          )
        })}
        {errorTicket && <p className="rounded bg-error/10 px-4 py-2 text-error">{errorTicket}</p>}
        {sinTicket.length > 0 && (
          <div>
            <p className="font-sans text-label-bold text-accent-darker">Ítems devueltos</p>
            <ListaItems items={sinTicket} />
          </div>
        )}

        {nuevos.length > 0 && (
          <div>
            <p className="font-sans text-label-bold text-accent-darker">Se llevó (cambio)</p>
            <ListaItems items={nuevos} />
          </div>
        )}

        <div className="rounded bg-bg px-4 py-3">
          <div className="flex items-baseline justify-between gap-3">
            <span className="font-sans text-label-bold text-ink-soft">
              Diferencia · {sentidoDiferencia(d.diferencia_monto)}
            </span>
            <span className="font-display text-headline-md text-ink">{formatCurrency(Math.abs(d.diferencia_monto))}</span>
          </div>
          <p className="mt-1 text-ink-soft">
            {RESOLUCION_DEVOLUCION_LABEL[d.resolucion] ?? '—'}
            {d.diferencia_forma_pago &&
              ` · ${d.diferencia_monto < 0 ? 'Devuelto en' : 'Cobrado en'} ${FORMA_PAGO_LABEL[d.diferencia_forma_pago]}`}
          </p>
          {pagos.length > 0 && (
            <ul className="mt-1 text-ink-soft">
              {pagos.map((p, i) => (
                <li key={i} className="flex justify-between gap-3">
                  <span>{FORMA_PAGO_LABEL[p.forma_pago]}</span>
                  <span>{formatCurrency(p.monto)}</span>
                </li>
              ))}
            </ul>
          )}
        </div>

        {d.resolucion === 'a_favor' && d.nota_a_favor && (
          <div className="rounded-lg border border-amarillo bg-amarillo/20 px-4 py-3">
            <p className="font-sans text-label-bold text-ink">Queda a favor del cliente (vale manual)</p>
            <p className="mt-0.5 whitespace-pre-line [overflow-wrap:anywhere]">{d.nota_a_favor}</p>
            <p className="mt-1 text-label-md text-ink-soft">Registro interno: no movió la caja ni se usa después en el sistema.</p>
          </div>
        )}

        {d.observaciones && (
          <div>
            <p className="font-sans text-label-md text-ink-soft">Observaciones</p>
            <p className="mt-0.5 whitespace-pre-line">{d.observaciones}</p>
          </div>
        )}
      </div>

      {comprobante && ComprobanteModal && <ComprobanteModal datos={comprobante} onClose={() => setComprobante(null)} />}
    </Modal>
  )
}

function Dato({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="min-w-0">
      <dt className="font-sans text-label-md text-ink-soft">{label}</dt>
      <dd className="[overflow-wrap:anywhere]">{children}</dd>
    </div>
  )
}

function ListaItems({
  items,
  total,
  etiquetaTotal = 'Total',
}: {
  items: ItemDevolucionConProducto[]
  total?: number
  etiquetaTotal?: string
}) {
  const suma = total ?? items.reduce((acc, it) => acc + it.cantidad * it.precio_unitario, 0)
  if (items.length === 0) return <p className="py-2 text-ink-soft">—</p>
  return (
    <ul className="divide-y divide-table-divider">
      {items.map((it) => (
        <li key={it.id} className="flex items-start justify-between gap-3 py-2">
          <div className="min-w-0">
            <p className="[overflow-wrap:anywhere]">
              {it.cantidad} × {nombreItemVendido(it, it.producto)}
            </p>
            <p className="text-label-md text-ink-soft">
              {formatCurrency(it.precio_unitario)} c/u
              {it.tipo === 'devuelto' &&
                (it.reingresa_stock ? ' · Reingresa al stock' : (
                  <span className="text-error"> · Defectuoso, no reingresa al stock</span>
                ))}
            </p>
          </div>
          <span className="whitespace-nowrap font-semibold">{formatCurrency(it.cantidad * it.precio_unitario)}</span>
        </li>
      ))}
      <li className="flex justify-between gap-3 py-2 text-ink-soft">
        <span>{etiquetaTotal}</span>
        <span className="whitespace-nowrap font-semibold text-ink">{formatCurrency(suma)}</span>
      </li>
    </ul>
  )
}
