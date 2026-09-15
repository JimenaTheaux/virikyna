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

// postgrest-js pone status 0 cuando el fetch en sí falla (sin conexión, DNS, etc.) —
// nunca pasa con un error real de Postgres, que siempre trae un HTTP status. Es la
// única señal confiable para distinguir "no hay internet" de un error de negocio.
export function isNetworkError(status: number | null | undefined): boolean {
  return status === 0
}

// Mensaje para acciones de escritura (venta, factura, pago, cierre) que fallan a mitad
// de camino: si fue por falta de conexión, mensaje claro y específico de qué no se guardó
// y qué queda intacto para reintentar — nunca el "TypeError: fetch failed" crudo.
export function mensajeErrorGuardado(
  error: PostgrestError | Error | null | undefined,
  status: number | null | undefined,
  accionFallida: string,
  queQuedaIntacto: string,
): string {
  if (isNetworkError(status)) {
    return `Sin conexión — no se pudo ${accionFallida}, ${queQuedaIntacto}. Reintentá cuando vuelva internet.`
  }
  return friendlyError(error)
}
