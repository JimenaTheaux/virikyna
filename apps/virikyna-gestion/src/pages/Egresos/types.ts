import type { Egreso } from '@virikyna/shared'

export type EgresoConUsuario = Egreso & {
  usuario: { nombre: string } | null
}
