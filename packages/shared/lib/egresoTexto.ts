// Descripción de un egreso para mostrar en tablas, sin repetir la categoría. Sin imports a
// propósito: lo corre también `node --test` (packages/shared/tests).
//
// `registrar_pago_proveedor_v2` (docs/31) guarda la descripción como 'Pago a proveedor' o
// 'Pago a proveedor — <nota>': la parte de la categoría ya está en su columna, solo vale la nota.

function comparable(texto: string): string {
  return texto
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .trim()
    .toLowerCase()
}

// null = no agrega nada a la categoría (vacía o igual a ella) → la tabla muestra "—".
export function descripcionSinCategoria(descripcion: string | null, categoriaLabel: string): string | null {
  const texto = (descripcion ?? '').trim()
  if (!texto) return null
  const categoria = comparable(categoriaLabel)
  if (comparable(texto) === categoria) return null
  if (comparable(texto.slice(0, categoriaLabel.length)) === categoria) {
    const resto = texto.slice(categoriaLabel.length)
    const separador = /^\s*[—–:-]\s*/.exec(resto)
    if (separador) return resto.slice(separador[0].length).trim() || null
  }
  return texto
}
