import type { FormaPagoVenta } from '@virikyna/shared'

export type CartItem = {
  productoId: string
  nombre: string
  marca: string // '' si no tiene (y en tickets guardados antes de que existiera, ver ticketsStorage)
  descripcion: string // ídem
  codigo: string
  precioUnitario: number
  cantidad: number
}

export type ClienteSeleccionado = {
  id: string
  nombre: string
  mail: string | null
  celular: string | null
}

// Una parte de un pago combinado (docs/22) — hasta 2 por venta, sin cuenta corriente.
export type PagoParcial = {
  formaPago: FormaPagoVenta
  monto: number
}

// Un ticket = una venta en curso e independiente — ver Ventas/ticketsStorage.ts (persistencia)
// y Ventas/TicketsBar.tsx (barra de tabs). `numero` es correlativo y no se reutiliza al eliminar
// un ticket, para que la etiqueta "Ticket N" no salte de identidad si se borra uno del medio.
export type Ticket = {
  id: string
  numero: number
  cart: CartItem[]
  cliente: ClienteSeleccionado | null
  formaPago: FormaPagoVenta | null
  pagosCombinados: PagoParcial[] | null // solo con formaPago === 'combinado'
  descuentoPorcentaje: number
  recargoPorcentaje: number
  nota: string
  // Idempotencia del cobro (docs/43): id del intento en curso (`<id>:<intento>`), guardado ANTES de
  // llamar a confirmar_venta. Si la app se cierra o pierde la respuesta, al volver se busca la venta
  // con ese client_id: si existe, el ticket ya se cobró. Null = ningún intento pendiente.
  cobroClientId: string | null
  intentosCobro: number
}
