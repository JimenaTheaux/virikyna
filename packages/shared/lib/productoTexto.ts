// Cómo se muestra un producto en pantallas, carrito y comprobantes — una sola regla para las tres
// apps. El formato del texto (nombre y marca en MAYÚSCULAS, descripción "Así") lo pone la base con
// un trigger (docs/42, docs/06 sección 27): acá solo se arma, nunca se convierte.

export type ProductoTexto = {
  nombre: string | null | undefined
  marca?: string | null
  descripcion?: string | null
  codigo_barras?: string | null
  codigo_interno?: string | null
}

// Clase para los inputs de nombre y marca: se VEN en mayúsculas mientras se tipea, pero el valor
// viaja tal cual y la base lo convierte (sin conversión en JS: la base es la fuente de verdad). El
// placeholder sigue en minúsculas.
export const MAYUSCULAS = 'uppercase placeholder:normal-case'

const SEPARADOR = ' · '

function unir(partes: (string | null | undefined)[]): string {
  return partes
    .map((p) => p?.trim())
    .filter(Boolean)
    .join(SEPARADOR)
}

// "SILLA DE COMER · CARESTINO"; sin marca, solo el nombre.
export function nombreConMarca(p: Pick<ProductoTexto, 'nombre' | 'marca'>): string {
  return unir([p.nombre, p.marca])
}

// "Con bandeja · 7791234567890"; omite lo que falte. Código de barras o, si no tiene, el interno.
export function lineaSecundaria(p: Omit<ProductoTexto, 'nombre' | 'marca'>): string {
  return unir([p.descripcion, p.codigo_barras || p.codigo_interno])
}

// Ítem de venta o devolución: el nombre y la marca guardados al vender (snapshot, docs/42) y, si la
// fila es anterior y no los tiene, los actuales del producto.
export function nombreItemVendido(
  item: { producto_nombre?: string | null; producto_marca?: string | null },
  producto: Pick<ProductoTexto, 'nombre' | 'marca'> | null | undefined,
): string {
  if (item.producto_nombre) return nombreConMarca({ nombre: item.producto_nombre, marca: item.producto_marca })
  return producto ? nombreConMarca(producto) : 'Producto'
}
