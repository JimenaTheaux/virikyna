import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
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

type MenuPos = { top: number; left: number }

// Menú "⋮" de cada ticket — portal a document.body, posicionado con las coordenadas reales del
// botón (getBoundingClientRect). Sin portal quedaba anidado dentro de la fila con overflow-x-auto
// de la barra de tickets: como esa fila fija overflow-x, el navegador también recorta overflow-y
// (regla CSS: si un eje no es "visible" y el otro sí, el "visible" pasa a computarse como "auto"),
// así que el menú se veía cortado/con scroll en vez de flotar libre — exactamente el bug reportado.
function TicketMenu({ pos, onCerrar, onCobrar, onEliminar }: {
  pos: MenuPos
  onCerrar: () => void
  onCobrar: () => void
  onEliminar: () => void
}) {
  return createPortal(
    <div
      style={{ position: 'fixed', top: pos.top, left: pos.left }}
      className="z-50 w-44 overflow-hidden rounded-lg border border-line bg-surface shadow-lg"
    >
      <button
        type="button"
        onClick={() => {
          onCerrar()
          onCobrar()
        }}
        className="block w-full px-4 py-2.5 text-left font-sans text-body-md text-ink hover:bg-bg"
      >
        Cerrar / Cobrar
      </button>
      <button
        type="button"
        onClick={() => {
          onCerrar()
          onEliminar()
        }}
        className="block w-full px-4 py-2.5 text-left font-sans text-body-md text-error hover:bg-error/10"
      >
        Eliminar
      </button>
    </div>,
    document.body,
  )
}

// Barra de tabs de "Tickets en espera" — punto 6. Cada tab es una venta independiente (carrito,
// cliente, descuento/recargo propios, ver Ventas/types.ts#Ticket). Máximo MAX_TICKETS simultáneos.
export function TicketsBar({ tickets, activeTicketId, onSeleccionar, onNuevo, onEliminar, onCobrar }: Props) {
  const [menuAbiertoId, setMenuAbiertoId] = useState<string | null>(null)
  const [menuPos, setMenuPos] = useState<MenuPos | null>(null)
  const barRef = useRef<HTMLDivElement>(null)

  function cerrarMenu() {
    setMenuAbiertoId(null)
    setMenuPos(null)
  }

  function toggleMenu(id: string, e: React.MouseEvent<HTMLElement>) {
    e.stopPropagation()
    if (menuAbiertoId === id) {
      cerrarMenu()
      return
    }
    const rect = e.currentTarget.getBoundingClientRect()
    // w-44 = 176px — alineado a la derecha del botón "⋮" para no salirse de la ventana.
    setMenuPos({ top: rect.bottom + 4, left: Math.min(rect.right - 176, window.innerWidth - 184) })
    setMenuAbiertoId(id)
  }

  useEffect(() => {
    if (!menuAbiertoId) return
    function onClickFuera(e: MouseEvent) {
      const target = e.target as Node
      if (barRef.current?.contains(target)) return
      cerrarMenu()
    }
    function onScrollOrResize() {
      cerrarMenu()
    }
    document.addEventListener('mousedown', onClickFuera)
    window.addEventListener('resize', onScrollOrResize)
    window.addEventListener('scroll', onScrollOrResize, true)
    return () => {
      document.removeEventListener('mousedown', onClickFuera)
      window.removeEventListener('resize', onScrollOrResize)
      window.removeEventListener('scroll', onScrollOrResize, true)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [menuAbiertoId])

  const enLimite = tickets.length >= MAX_TICKETS

  return (
    <div ref={barRef} className="flex items-center gap-2 rounded-lg bg-surface px-3 py-1.5 shadow-sm">
      <div className="flex flex-1 items-center gap-1.5 overflow-x-auto">
        {tickets.map((ticket) => {
          const activo = ticket.id === activeTicketId
          const unidades = ticket.cart.reduce((acc, it) => acc + it.cantidad, 0)
          return (
            <button
              key={ticket.id}
              type="button"
              onClick={() => onSeleccionar(ticket.id)}
              className={`flex flex-shrink-0 items-center gap-2 rounded-full border px-3 py-1.5 font-sans text-label-bold transition ${
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
                onClick={(e) => toggleMenu(ticket.id, e)}
                className={`ml-1 rounded px-1 leading-none ${activo ? 'hover:bg-white/20' : 'hover:bg-line'}`}
              >
                ⋮
              </span>
            </button>
          )
        })}
      </div>

      <button
        type="button"
        onClick={onNuevo}
        disabled={enLimite}
        title={enLimite ? `Máximo ${MAX_TICKETS} tickets simultáneos — cerrá o eliminá uno para abrir otro.` : undefined}
        className="flex-shrink-0 rounded-full border border-dashed border-line px-3 py-1.5 font-sans text-label-bold text-ink-soft transition hover:border-accent hover:text-accent-darker disabled:cursor-not-allowed disabled:opacity-40 disabled:hover:border-line disabled:hover:text-ink-soft"
      >
        + Nuevo ticket
      </button>
      {enLimite && (
        <span className="flex-shrink-0 font-sans text-label-md text-ink-soft">Máximo {MAX_TICKETS} tickets</span>
      )}

      {menuAbiertoId && menuPos && (
        <TicketMenu
          pos={menuPos}
          onCerrar={cerrarMenu}
          onCobrar={() => onCobrar(menuAbiertoId)}
          onEliminar={() => onEliminar(menuAbiertoId)}
        />
      )}
    </div>
  )
}
