// Textos sin acentos (docs/51). La base guarda todo sin tildes ni diéresis (trigger fn_sin_acentos,
// conservando la Ñ), así que lo que se TIPEA en un buscador también se limpia: "línea" encuentra
// "LINEA". Mismo mapa que quitar_acentos() en SQL — si cambia uno, cambiar el otro.
// Sin imports, para los tests (node --test).

const CON_ACENTO = 'áéíóúüàèìòùäëïöâêîôûÁÉÍÓÚÜÀÈÌÒÙÄËÏÖÂÊÎÔÛ'
const SIN_ACENTO = 'aeiouuaeiouaeioaeiouAEIOUUAEIOUAEIOAEIOU'
const MAPA = new Map(Array.from(CON_ACENTO, (c, i) => [c, SIN_ACENTO[i]]))

export function quitarAcentos(texto: string): string {
  return Array.from(texto.normalize('NFC'), (c) => MAPA.get(c) ?? c).join('')
}

// Para comparar en el cliente: sin acentos, minúsculas y sin espacios en los extremos. Se aplica
// a los dos lados (lo tipeado y el campo) para no depender de que el dato ya esté limpio.
export function textoParaBuscar(texto: string | null | undefined): string {
  return quitarAcentos(texto ?? '').trim().toLowerCase()
}
