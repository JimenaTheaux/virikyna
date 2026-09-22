import type { AperturaCaja, CierreCaja } from '@virikyna/shared'

// `usuario`/`validador` se resuelven en TableroTab vía `nombresPorId` (perfiles_publico),
// no con un embed `perfiles(nombre)` — ese embed vuelve null para cualquiera que no sea el
// propio usuario logueado, porque `perfiles` solo expone la fila propia por RLS.
export type CierreCajaConUsuario = CierreCaja & {
  usuario: { nombre: string } | null
  validador: { nombre: string } | null
  // Apertura vigente al momento de este cierre (docs/21_apertura_caja.sql) — null si no había
  // ninguna caja abierta (turno viejo, previo a este patch).
  apertura: (AperturaCaja & { usuarioNombre: string | null }) | null
}
