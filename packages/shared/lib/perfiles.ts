// Nombre de OTROS usuarios (quién hizo un cierre, quién lo validó, quién registró un pago) —
// `perfiles` solo expone la fila propia por RLS (ver docs/06_estructura_de_datos.md, "regla de
// oro, sin recursión"), así que nunca sirve un embed tipo `usuario:perfiles(nombre)` para mostrar
// el nombre de alguien más: vuelve null para cualquiera que no sea el usuario logueado.
// `perfiles_publico` (id + nombre) sí es legible por cualquier usuario autenticado — se resuelve
// acá con un lookup aparte en vez de un embed por foreign key, porque PostgREST no puede embeber
// una vista por nombre de constraint como hace con una tabla.
import type { SupabaseClient } from '@supabase/supabase-js'

export async function nombresPorId(
  supabase: SupabaseClient,
  ids: (string | null | undefined)[],
): Promise<Map<string, string>> {
  const idsUnicos = Array.from(new Set(ids.filter((id): id is string => Boolean(id))))
  if (idsUnicos.length === 0) return new Map()

  const { data } = await supabase.from('perfiles_publico').select('id, nombre').in('id', idsUnicos)
  return new Map((data ?? []).map((p) => [p.id as string, p.nombre as string]))
}
