import type { PostgrestError } from '@supabase/supabase-js'

export function friendlyError(
  error: PostgrestError | Error | null | undefined,
  fallback = 'Ocurrió un error inesperado.',
): string {
  if (!error) return fallback

  const code = 'code' in error ? error.code : undefined
  if (code === '23505') return 'Ya existe un registro con ese dato único (nombre o código repetido).'
  if (code === '23514') return 'Los datos no cumplen una regla obligatoria del sistema.'
  if (code === '23503') return 'No se puede completar la operación: hay datos relacionados que lo impiden.'

  return error.message || fallback
}
