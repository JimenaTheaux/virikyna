import type { Egreso } from '@virikyna/shared'

export type EgresoConUsuario = Egreso & {
  usuario: { nombre: string } | null
  // Solo para categoría 'pago_proveedor': se resuelve por pago_proveedor_id → pagos_proveedor.
  proveedorNombre: string | null
}
