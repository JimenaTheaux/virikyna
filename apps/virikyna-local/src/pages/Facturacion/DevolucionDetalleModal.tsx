import { useEffect, useState } from 'react'
import type { Devolucion, DevolucionItem, DevolucionPago } from '@virikyna/shared'
import { MOTIVO_DEVOLUCION_LABEL, EstadoBadge, formatCurrency, formatFechaHora } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { FORMA_PAGO_LABEL } from '../../lib/comprobante'
import { Modal } from '../../components/Modal'

export type ItemDevolucionConProducto = DevolucionItem & { producto: { nombre: string } | null }

export type DevolucionConDetalle = Devolucion & {
  venta: { numero: number } | null
  items: ItemDevolucionConProducto[]
  usuarioNombre: string | null
}

// diferencia_monto = nuevos − devueltos: > 0 paga el cliente, < 0 queda a favor del cliente.
export function sentidoDiferencia(monto: number): string {
  if (monto > 0) return 'Paga el cliente'
  if (monto < 0) return 'A favor del cliente'
  return 'Sin diferencia'
}

// Detalle completo de una devolución/cambio — lo que el listado ya no muestra en la fila para
// mantenerla compacta: ítems devueltos y nuevos, motivo, observaciones y cómo se saldó la diferencia.
export function DevolucionDetalleModal({ devolucion: d, onClose }: { devolucion: DevolucionConDetalle; onClose: () => void }) {
  const [pagos, setPagos] = useState<Pick<DevolucionPago, 'forma_pago' | 'monto'>[]>([])

  useEffect(() => {
    if (d.diferencia_forma_pago !== 'combinado') return
    supabase
      .from('devolucion_pagos')
      .select('forma_pago, monto')
      .eq('devolucion_id', d.id)
      .then(({ data }) => setPagos((data ?? []) as Pick<DevolucionPago, 'forma_pago' | 'monto'>[]))
  }, [d.id, d.diferencia_forma_pago])

  const devueltos = d.items.filter((it) => it.tipo === 'devuelto')
  const nuevos = d.items.filter((it) => it.tipo !== 'devuelto')

  return (
    <Modal title={`Devolución ${d.numero}`} onClose={onClose} widthClassName="max-w-[640px]">
      <div className="flex flex-col gap-stack-md font-sans text-body-md text-ink">
        <dl className="grid grid-cols-2 gap-x-stack-md gap-y-2">
          <Dato label="Fecha">{formatFechaHora(d.created_at)}</Dato>
          <Dato label="Venta original">{d.venta ? `Ticket N° ${d.venta.numero}` : '—'}</Dato>
          <Dato label="Registró">{d.usuarioNombre ?? '—'}</Dato>
          <Dato label="Estado">
            {d.estado === 'anulada' ? (
              <EstadoBadge variant="red">Anulada</EstadoBadge>
            ) : (
              <EstadoBadge variant="green">Activa</EstadoBadge>
            )}
          </Dato>
          {d.estado === 'anulada' && d.motivo_anulacion && (
            <div className="col-span-2">
              <Dato label="Motivo de la anulación">{d.motivo_anulacion}</Dato>
            </div>
          )}
          <div className="col-span-2">
            <Dato label="Motivo">
              {MOTIVO_DEVOLUCION_LABEL[d.motivo]}
              {d.motivo_detalle && <span className="text-ink-soft"> — {d.motivo_detalle}</span>}
            </Dato>
          </div>
        </dl>

        <ListaItems titulo="Ítems devueltos" items={devueltos} />
        {nuevos.length > 0 && <ListaItems titulo="Ítems nuevos (cambio)" items={nuevos} />}

        <div className="rounded bg-bg px-4 py-3">
          <div className="flex items-baseline justify-between gap-3">
            <span className="font-sans text-label-bold text-ink-soft">Diferencia · {sentidoDiferencia(d.diferencia_monto)}</span>
            <span className="font-display text-headline-md text-ink">{formatCurrency(Math.abs(d.diferencia_monto))}</span>
          </div>
          {d.diferencia_forma_pago && (
            <p className="mt-1 text-ink-soft">
              {d.diferencia_monto < 0 ? 'Devuelto en' : 'Cobrado en'} {FORMA_PAGO_LABEL[d.diferencia_forma_pago]}
            </p>
          )}
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

        {d.observaciones && (
          <div>
            <p className="font-sans text-label-md text-ink-soft">Observaciones</p>
            <p className="mt-0.5 whitespace-pre-line">{d.observaciones}</p>
          </div>
        )}
      </div>
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

function ListaItems({ titulo, items }: { titulo: string; items: ItemDevolucionConProducto[] }) {
  const total = items.reduce((acc, it) => acc + it.cantidad * it.precio_unitario, 0)
  return (
    <div>
      <p className="font-sans text-label-bold text-accent-darker">{titulo}</p>
      {items.length === 0 ? (
        <p className="mt-1 text-ink-soft">—</p>
      ) : (
        <ul className="mt-1 divide-y divide-table-divider">
          {items.map((it) => (
            <li key={it.id} className="flex items-start justify-between gap-3 py-2">
              <div className="min-w-0">
                <p className="[overflow-wrap:anywhere]">
                  {it.cantidad} × {it.producto?.nombre ?? 'Producto'}
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
            <span>Total</span>
            <span className="whitespace-nowrap font-semibold text-ink">{formatCurrency(total)}</span>
          </li>
        </ul>
      )}
    </div>
  )
}
