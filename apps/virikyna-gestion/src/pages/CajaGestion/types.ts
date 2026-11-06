import type { MovimientoCuenta } from '@virikyna/shared'

export type MovimientoCuentaConUsuario = MovimientoCuenta & {
  usuario: { nombre: string } | null
}
