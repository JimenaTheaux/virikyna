import type { Producto } from '@virikyna/shared'
import { friendlyError, isNetworkError, normalizarCodigoBarras, variantesCodigoBarras } from '@virikyna/shared'
import { supabase } from './supabaseClient'

export type ResultadoCodigo =
  | { tipo: 'encontrado'; producto: Producto }
  | { tipo: 'inactivo'; producto: Producto }
  | { tipo: 'no_encontrado' }
  | { tipo: 'error'; mensaje: string }

// Busca un producto por código de barras (o código interno) — usado al escanear en la carga de
// factura y para el aviso de "código duplicado" del formulario de producto. Tolera las variantes
// del mismo código (con/sin 0 inicial, ver variantesCodigoBarras) y distingue "no existe" de "no
// se pudo consultar": antes un error de red se tomaba como "no existe" y abría el alta.
export async function resolverCodigoBarras(codigo: string): Promise<ResultadoCodigo> {
  const variantes = variantesCodigoBarras(codigo)
  if (variantes.length === 0) return { tipo: 'no_encontrado' }

  for (const columna of ['codigo_barras', 'codigo_interno'] as const) {
    const { data, error, status } = await supabase.from('productos').select('*').in(columna, variantes)
    if (error) {
      return {
        tipo: 'error',
        mensaje: isNetworkError(status)
          ? 'Sin conexión — no se pudo buscar el código. Probá de nuevo cuando vuelva internet.'
          : friendlyError(error),
      }
    }
    const encontrados = (data ?? []) as Producto[]
    if (encontrados.length === 0) continue
    // Si hay más de uno (ej. el mismo producto cargado con y sin el 0), primero el que coincide
    // exacto y está activo.
    const exacto = normalizarCodigoBarras(codigo)
    const ordenados = [...encontrados].sort(
      (a, b) =>
        Number(b.estado === 'activo') - Number(a.estado === 'activo') ||
        Number(b[columna] === exacto) - Number(a[columna] === exacto),
    )
    const producto = ordenados[0]
    return producto.estado === 'activo' ? { tipo: 'encontrado', producto } : { tipo: 'inactivo', producto }
  }
  return { tipo: 'no_encontrado' }
}

// Versión simple para el aviso de duplicado: cualquier producto (activo o no) con ese código.
export async function buscarProductoPorCodigoBarras(codigo: string): Promise<Producto | null> {
  const r = await resolverCodigoBarras(codigo)
  return r.tipo === 'encontrado' || r.tipo === 'inactivo' ? r.producto : null
}
