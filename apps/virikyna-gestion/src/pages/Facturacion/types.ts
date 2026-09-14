import type { Cliente, FacturaC, Producto, Venta, VentaItem } from '@virikyna/shared'

export type VentaConFactura = Venta & {
  factura_c: FacturaC | null
  cliente: Pick<Cliente, 'razon_social' | 'nombre_fantasia' | 'mail' | 'celular'> | null
}

export type VentaItemConProducto = Pick<VentaItem, 'cantidad' | 'precio_unitario' | 'importe'> & {
  producto: Pick<Producto, 'nombre' | 'codigo_barras' | 'codigo_interno'> | null
}
