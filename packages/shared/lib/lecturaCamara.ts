// Lecturas de la cámara (BarcodeScanner): solo dígitos. Sin imports a propósito: lo corre también
// `node --test` (packages/shared/tests). El lector físico (HID) no pasa por acá: escribe directo en
// el campo y conserva su comportamiento.

// Identificador de simbología AIM: "]" + letra de simbología + 1 carácter de modificador. Algunos
// decoders lo anteponen al contenido: "]C1" = Code 128 con FNC1 (GS1-128), "]E0" = EAN-13. El "1"
// o el "0" son parte del prefijo, no del código (docs/auditoria-2026-10-19.md, C.2).
const PREFIJO_AIM = /^\][A-Za-z][0-9A-Za-z]/

// Código de una lectura de cámara: sin espacios, sin prefijo AIM y solo dígitos. null = descartar la
// lectura y seguir escaneando (texto, QR con URL, una lectura parcial con letras).
export function limpiarLecturaCamara(raw: string): string | null {
  const codigo = raw.replace(/\s+/g, '').replace(PREFIJO_AIM, '')
  return /^\d+$/.test(codigo) ? codigo : null
}

// Entrada a mano dentro del escáner: solo se pueden tipear dígitos.
export function soloDigitos(texto: string): string {
  return texto.replace(/\D+/g, '')
}
