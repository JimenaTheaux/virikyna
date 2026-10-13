// Cómo se muestra un producto en pantallas, carrito y comprobantes — una sola regla para las tres
// apps. El formato del texto (nombre y marca en MAYÚSCULAS, descripción "Así") lo pone la base con
// un trigger (docs/42, docs/06 sección 27): acá solo se arma, nunca se convierte.

import { formatCurrency } from './format'

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

// Renglón 2 de una lista de productos (ProductoLinea): [marca, código, descripción], sin las partes
// vacías. Código de barras o, si no tiene, el interno. Cada parte se muestra separada por espacio.
export function lineaSecundaria(p: Omit<ProductoTexto, 'nombre'>): string[] {
  return [p.marca, p.codigo_barras || p.codigo_interno, p.descripcion]
    .map((parte) => parte?.trim() ?? '')
    .filter(Boolean)
}

// Lo que anuncia un lector de pantalla: "NOMBRE, MARCA, $ 25.000,00" (o ", Costo $ …").
export function etiquetaAccesibleProducto(
  p: Pick<ProductoTexto, 'nombre' | 'marca'>,
  precio?: number | null,
  etiquetaPrecio?: string,
): string {
  const partes = [p.nombre?.trim(), p.marca?.trim()].filter(Boolean) as string[]
  if (precio !== undefined) {
    const monto = precio === null ? 'sin precio' : formatCurrency(precio)
    partes.push(etiquetaPrecio ? `${etiquetaPrecio} ${monto}` : monto)
  }
  return partes.join(', ')
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
