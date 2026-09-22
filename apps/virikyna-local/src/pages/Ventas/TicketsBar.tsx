import { useEffect, useRef, useState } from 'react'
import type { Ticket } from './types'
import { MAX_TICKETS } from './ticketsStorage'

type Props = {
  tickets: Ticket[]
  activeTicketId: string
  onSeleccionar: (id: string) => void
  onNuevo: () => void
  onEliminar: (id: string) => void
  onCobrar: (id: string) => void
}

// Barra de tabs de "Tickets en espera" — punto 6. Cada tab es una venta independiente (carrito,
// cliente, descuento/recargo propios, ver Ventas/types.ts#Ticket). Máximo MAX_TICKETS simultáneos.
export function TicketsBar({ tickets, activeTicketId, onSeleccionar, onNuevo, onEliminar, onCobrar }: Props) {
  const [menuAbiertoId, setMenuAbiertoId] = useState<string | null>(null)
  const barRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    function onClickFuera(e: MouseEvent) {
      if (barRef.current && !barRef.current.contains(e.target as Node)) setMenuAbiertoId(null)
    }
    document.addEventListener('mousedown', onClickFuera)
    return () => document.removeEventListener('mousedown', onClickFuera)
  }, [])

  const enLimite = tickets.length >= MAX_TICKETS

  return (
    <div ref={barRef} className="flex items-center gap-2 rounded-lg bg-surface px-3 py-2 shadow-sm">
      <div className="flex flex-1 items-center gap-1.5 overflow-x-auto">
        {tickets.map((ticket) => {
          const activo = ticket.id === activeTicketId
          const unidades = ticket.cart.reduce((acc, it) => acc + it.cantidad, 0)
          return (
            <div key={ticket.id} className="relative flex-shrink-0">
              <button
                type="button"
                onClick={() => onSeleccionar(ticket.id)}
                className={`flex items-center gap-2 rounded-full border px-4 py-2 font-sans text-label-bold transition ${
                  activo
                    ? 'border-accent bg-accent text-white'
                    : 'border-line bg-bg text-ink-soft hover:border-accent hover:text-accent-darker'
                }`}
              >
                <span>Ticket {ticket.numero}</span>
                {unidades > 0 && (
                  <span
                    className={`rounded-full px-1.5 py-0.5 text-label-md ${
                      activo ? 'bg-white/25 text-white' : 'bg-accent-light text-accent-darker'
                    }`}
                  >
                    {unidades}
                  </span>
                )}
                <span
                  role="button"
                  tabIndex={-1}
                  aria-label={`Más acciones para Ticket ${ticket.numero}`}
                  onClick={(e) => {
                    e.stopPropagation()
                    setMenuAbiertoId((prev) => (prev === ticket.id ? null : ticket.id))
                  }}
                  className={`ml-1 rounded px-1 leading-none ${activo ? 'hover:bg-white/20' : 'hover:bg-line'}`}
                >
                  ⋮
                </span>
              </button>

              {menuAbiertoId === ticket.id && (
                <div className="absolute left-0 top-full z-10 mt-1 w-44 overflow-hidden rounded-lg border border-line bg-surface shadow-sm">
                  <button
                    type="button"
                    onClick={() => {
                      setMenuAbiertoId(null)
                      onCobrar(ticket.id)
                    }}
                    className="block w-full px-4 py-2.5 text-left font-sans text-body-md text-ink hover:bg-bg"
                  >
                    Cerrar / Cobrar
                  </button>
                  <button
                    type="button"
                    onClick={() => {
                      setMenuAbiertoId(null)
                      onEliminar(ticket.id)
                    }}
                    className="block w-full px-4 py-2.5 text-left font-sans text-body-md text-error hover:bg-error/10"
                  >
                    Eliminar
                  </button>
                </div>
              )}
            </div>
          )
        })}
      </div>

      <button
        type="button"
        onClick={onNuevo}
        disabled={enLimite}
        title={enLimite ? `Máximo ${MAX_TICKETS} tickets simultáneos — cerrá o eliminá uno para abrir otro.` : undefined}
        className="flex-shrink-0 rounded-full border border-dashed border-line px-4 py-2 font-sans text-label-bold text-ink-soft transition hover:border-accent hover:text-accent-darker disabled:cursor-not-allowed disabled:opacity-40 disabled:hover:border-line disabled:hover:text-ink-soft"
      >
        + Nuevo ticket
      </button>
      {enLimite && (
        <span className="flex-shrink-0 font-sans text-label-md text-ink-soft">Máximo {MAX_TICKETS} tickets</span>
      )}
    </div>
  )
}
