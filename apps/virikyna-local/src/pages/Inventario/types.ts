import type { Producto, Proveedor, StockUbicacion } from '@virikyna/shared'

export type ProductoConRelaciones = Producto & {
  proveedor: Pick<Proveedor, 'razon_social' | 'margen_1_default' | 'margen_2_default'> | null
  stock_ubicaciones: Pick<StockUbicacion, 'ubicacion' | 'cantidad'>[]
}
