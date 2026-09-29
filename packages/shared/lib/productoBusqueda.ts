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
  return (
    [producto.nombre, producto.marca, producto.codigo_barras, producto.codigo_interno].some((campo) =>
      campo?.toLowerCase().includes(q),
    ) || codigoBarrasCoincide(producto.codigo_barras, q)
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

// --- Códigos de barras -------------------------------------------------------------------------
// Un mismo producto puede llegar con el código escrito de dos formas: el lector de la caja suele
// mandar un UPC-A (12 dígitos) como EAN-13 con un 0 adelante, y la cámara del celular lo devuelve
// sin ese 0 (o al revés). Buscando por igualdad exacta, "0012345678905" y "012345678905" eran
// productos distintos: el celular no lo encontraba y ofrecía darlo de alta de nuevo.

export function normalizarCodigoBarras(codigo: string): string {
  return codigo.replace(/\s+/g, '')
}

// Todas las formas equivalentes de un código: tal cual, y para numéricos de 12/13 dígitos con y
// sin el 0 inicial.
export function variantesCodigoBarras(codigo: string): string[] {
  const c = normalizarCodigoBarras(codigo)
  if (!c) return []
  const variantes = new Set([c])
  if (/^\d{12}$/.test(c)) variantes.add(`0${c}`)
  if (/^0\d{12}$/.test(c)) variantes.add(c.slice(1))
  return [...variantes]
}

export function codigoBarrasCoincide(guardado: string | null | undefined, leido: string): boolean {
  if (!guardado) return false
  const g = normalizarCodigoBarras(guardado)
  return variantesCodigoBarras(leido).includes(g)
}

// Dígito verificador de EAN-8 / UPC-A / EAN-13 (misma regla: pesos 3-1 desde la derecha). Sirve
// para descartar lecturas parciales o erróneas de la cámara antes de buscarlas.
export function digitoVerificadorEanValido(codigo: string): boolean {
  if (!/^(\d{8}|\d{12}|\d{13})$/.test(codigo)) return false
  const digitos = codigo.split('').map(Number)
  const verificador = digitos.pop()!
  const suma = digitos.reverse().reduce((acc, d, i) => acc + d * (i % 2 === 0 ? 3 : 1), 0)
  return (10 - (suma % 10)) % 10 === verificador
}

export function armarFiltroBusquedaProducto(
  query: string,
  campos: readonly string[] = CAMPOS_BUSQUEDA_PRODUCTO_SERVIDOR,
): string {
  const qEscaped = query.trim().replace(/[%,]/g, '')
  return campos.map((campo) => `${campo}.ilike.%${qEscaped}%`).join(',')
}
