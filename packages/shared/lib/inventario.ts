// Reglas de negocio de Inventario y Stock compartidas entre Virikyna Local (Caja) y
// Virikyna Inventario (celular) — ver docs/04_modulos_y_funciones.md, módulos 5 y 5.1.

import type { PostgrestError, SupabaseClient } from '@supabase/supabase-js'
import type { Producto, Proveedor, StockUbicacion } from '../types/database'

export const IVA_DEFAULT = 21

// Producto con lo que traen los listados de Inventario de las tres apps (SELECT_PRODUCTOS_INVENTARIO).
export type ProductoConRelaciones = Producto & {
  proveedor: Pick<Proveedor, 'razon_social' | 'margen_1_default' | 'margen_2_default'> | null
  stock_ubicaciones: Pick<StockUbicacion, 'ubicacion' | 'cantidad'>[]
}

export const SELECT_PRODUCTOS_INVENTARIO =
  '*, proveedor:proveedores(razon_social, margen_1_default, margen_2_default), stock_ubicaciones(ubicacion, cantidad)'

const PAGINA_PRODUCTOS = 1000

// Todos los productos para los listados de Inventario de las tres apps. La API de Supabase devuelve
// como máximo 1000 filas por consulta ("Max rows"): pedirlos de una sola vez cortaba la lista en la
// L y los demás no aparecían ni en el buscador (2164 productos al 2026-10-19). Se piden de a páginas,
// avanzando según lo que devuelve el servidor, hasta llegar al total. Orden por nombre y, para
// empates, por id: así una página nunca repite ni saltea filas.
export async function cargarProductosInventario(
  supabase: SupabaseClient,
): Promise<{ data: ProductoConRelaciones[]; error: PostgrestError | null }> {
  const todos: ProductoConRelaciones[] = []
  let total: number | null = null
  while (total === null || todos.length < total) {
    const { data, error, count } = await supabase
      .from('productos')
      .select(SELECT_PRODUCTOS_INVENTARIO, { count: total === null ? 'exact' : undefined })
      .order('nombre')
      .order('id')
      .range(todos.length, todos.length + PAGINA_PRODUCTOS - 1)
    if (error) return { data: todos, error }
    if (total === null) total = count ?? 0
    const pagina = (data ?? []) as unknown as ProductoConRelaciones[]
    if (pagina.length === 0) break
    todos.push(...pagina)
  }
  return { data: todos, error: null }
}

// Stock total = suma de todas las ubicaciones (mismo criterio que Stock bajo, docs/26).
export function stockTotal(p: Pick<ProductoConRelaciones, 'stock_ubicaciones'>): number {
  return p.stock_ubicaciones.reduce((acc, s) => acc + Number(s.cantidad), 0)
}

export function stockEnUbicacion(p: Pick<ProductoConRelaciones, 'stock_ubicaciones'>, ubicacion: StockUbicacion['ubicacion']): number {
  return Number(p.stock_ubicaciones.find((s) => s.ubicacion === ubicacion)?.cantidad ?? 0)
}

// Lista cerrada + "Otro" con detalle libre — ver skill pos-inventory-architecture,
// sección "Ajustes manuales: siempre con motivo y siempre auditados".
export const MOTIVOS_AJUSTE_STOCK = ['Rotura', 'Pérdida', 'Corrección de conteo físico', 'Otro'] as const

export type MotivoAjusteStock = (typeof MOTIVOS_AJUSTE_STOCK)[number]
