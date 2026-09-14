import type { FacturaCompraSaldo } from '@virikyna/shared'

export type FacturaCompraConProveedor = FacturaCompraSaldo & {
  proveedor: { razon_social: string } | null
}
