// Lógica de búsqueda de productos compartida entre los buscadores manuales de las tres apps
// (ventas, inventario, carga de facturas de compra) — todos deben matchear por nombre, marca o
// código de barras/interno, sin distinguir mayúsculas y por coincidencia parcial (contains).

export type ProductoBuscable = {
  nombre: string
  marca?: string | null
  codigo_barras?: string | null
  codigo_interno?: string | null
}

function normalizar(texto: string): string {
  return texto.trim().toLowerCase()
}

export function coincideBusquedaProducto(producto: ProductoBuscable, query: string): boolean {
  const q = normalizar(query)
  if (!q) return true
  return [producto.nombre, producto.marca, producto.codigo_barras, producto.codigo_interno].some((campo) =>
    campo?.toLowerCase().includes(q),
  )
}

export function filtrarProductosPorBusqueda<T extends ProductoBuscable>(productos: T[], query: string): T[] {
  const q = normalizar(query)
  if (!q) return productos
  return productos.filter((p) => coincideBusquedaProducto(p, q))
}

// Para búsquedas contra Supabase (.or + ilike): arma la condición OR sobre nombre, marca y
// códigos, escapando los caracteres que rompen el patrón de ilike (% y la coma, que en el string
// de .or() separa condiciones).
const CAMPOS_BUSQUEDA_PRODUCTO_SERVIDOR = ['nombre', 'marca', 'codigo_barras', 'codigo_interno'] as const

export function armarFiltroBusquedaProducto(
  query: string,
  campos: readonly string[] = CAMPOS_BUSQUEDA_PRODUCTO_SERVIDOR,
): string {
  const qEscaped = query.trim().replace(/[%,]/g, '')
  return campos.map((campo) => `${campo}.ilike.%${qEscaped}%`).join(',')
}
