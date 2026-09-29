import type { Producto } from '@virikyna/shared'
import { resolverCodigoBarras } from '@virikyna/shared'
import { supabase } from './supabaseClient'

// Para el aviso de código duplicado del formulario de producto: cualquier producto (activo o no)
// con ese código o una variante equivalente (ver resolverCodigoBarras en @virikyna/shared).
export async function buscarProductoPorCodigoBarras(codigo: string): Promise<Producto | null> {
  const r = await resolverCodigoBarras(supabase, codigo)
  return r.tipo === 'encontrado' || r.tipo === 'inactivo' ? r.producto : null
}
