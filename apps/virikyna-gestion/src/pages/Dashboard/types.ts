export type VentaDelDia = {
  fecha: string // YYYY-MM-DD
  total: number
  cantidad: number
}

// VentaPorProducto y Medida viven en @virikyna/shared (dashboard/ventasPorProducto), compartidos
// con el Dashboard de Local.
export type { Medida, VentaPorProducto } from '@virikyna/shared'
