import type { Ticket } from './types'

export const MAX_TICKETS = 5

const STORAGE_KEY = 'virikyna-local:ventas:tickets:v1'

export type TicketsPersistState = {
  tickets: Ticket[]
  activeTicketId: string
  nextNumero: number
}

export function crearTicketVacio(numero: number): Ticket {
  return {
    id: crypto.randomUUID(),
    numero,
    cart: [],
    cliente: null,
    formaPago: null,
    pagosCombinados: null,
    descuentoPorcentaje: 0,
    recargoPorcentaje: 0,
    nota: '',
  }
}

// Se llama una sola vez al montar VentasPage. Si no hay nada guardado o el JSON quedó corrupto,
// devuelve `null` y el caller arranca con un ticket nuevo — nunca dejamos la pantalla sin tickets.
export function cargarTicketsGuardados(): TicketsPersistState | null {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return null
    const parsed = JSON.parse(raw) as Partial<TicketsPersistState>
    if (!Array.isArray(parsed.tickets) || parsed.tickets.length === 0) return null
    // Compat: tickets guardados antes de pagos combinados (docs/22) no traen pagosCombinados.
    const tickets = (parsed.tickets as Ticket[]).map((t) => ({ ...t, pagosCombinados: t.pagosCombinados ?? null }))
    const activeTicketId = tickets.some((t) => t.id === parsed.activeTicketId)
      ? (parsed.activeTicketId as string)
      : tickets[0].id
    const maxNumero = tickets.reduce((acc, t) => Math.max(acc, t.numero), 0)
    return {
      tickets,
      activeTicketId,
      nextNumero: typeof parsed.nextNumero === 'number' ? parsed.nextNumero : maxNumero + 1,
    }
  } catch {
    return null
  }
}

export function guardarTickets(state: TicketsPersistState) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(state))
  } catch {
    // localStorage puede fallar (cuota llena, modo restringido) — no es crítico para vender,
    // seguimos operando en memoria y se reintenta en el próximo cambio.
  }
}
