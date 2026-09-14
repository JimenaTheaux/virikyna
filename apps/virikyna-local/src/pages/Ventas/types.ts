export type CartItem = {
  productoId: string
  nombre: string
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
