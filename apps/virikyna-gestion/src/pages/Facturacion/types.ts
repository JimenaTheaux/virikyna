import type { Cliente, FacturaC, Venta } from '@virikyna/shared'

export type VentaConFactura = Venta & {
  factura_c: FacturaC | null
  cliente: Pick<Cliente, 'razon_social' | 'nombre_fantasia' | 'mail' | 'celular' | 'cuit'> | null
}

