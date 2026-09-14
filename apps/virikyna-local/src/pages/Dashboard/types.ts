export type ProductoStockBajo = {
  id: string
  nombre: string
  stockMinimo: number
  stockTotal: number
}

export type VentaDelDia = {
  fecha: string // YYYY-MM-DD
  total: number
  cantidad: number
}
