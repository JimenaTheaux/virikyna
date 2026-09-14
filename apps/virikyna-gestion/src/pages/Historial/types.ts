import type { Auditoria } from '@virikyna/shared'

export type AuditoriaConUsuario = Auditoria & {
  usuario: { nombre: string } | null
}
