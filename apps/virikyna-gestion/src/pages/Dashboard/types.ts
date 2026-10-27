export type VentaDelDia = {
  fecha: string // YYYY-MM-DD
  total: number
  cantidad: number
}

// Fila de dashboard_ventas_por_producto (docs/61): netas de devoluciones, importe prorrateado al
// precio cobrado de cada venta.
export type VentaPorProducto = {
  productoId: string
  nombre: string
  marca: string | null
  unidades: number
  importe: number
  stockActual: number
  stockMinimo: number
  unidadesAnterior: number
  importeAnterior: number
}

// Toggle del Top 10 / resumen por marca.
export type Medida = 'unidades' | 'importe'
