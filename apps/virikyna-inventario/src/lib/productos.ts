import type { Producto } from '@virikyna/shared'
import { supabase } from './supabaseClient'

// Busca un producto por código de barras exacto — usado tanto al escanear en Inventario
// (¿ya existe, o es de alta?) como al cargar una factura de proveedor ítem por ítem.
export async function buscarProductoPorCodigoBarras(codigo: string): Promise<Producto | null> {
  const { data } = await supabase.from('productos').select('*').eq('codigo_barras', codigo).maybeSingle()
  return (data as Producto | null) ?? null
}
