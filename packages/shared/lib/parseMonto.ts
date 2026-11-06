// Lectura de un importe tipeado en formato argentino (docs/DIAGNOSTICO_ENTER_Y_FORMATO_IMPORTES.md,
// sección B). Criterio confirmado por la dueña (2026-11-06):
//   "4.500"   = cuatro mil quinientos (un punto seguido de exactamente 3 dígitos: miles)
//   "4500.40" = 4500 con 40 centavos   (un punto seguido de 1 o 2 dígitos: decimal)
// Antes, un <input type="number"> leía "4.500" como 4,50 y "632.250" como 632,25 (Cierre Z del 20/10).
// Sin imports de valores: lo corre node --test directo (tests/parseMonto.test.ts).

export type OpcionesParseMonto = { negativo?: boolean } // por defecto un monto negativo es inválido

const SOLO_DIGITOS = /^\d+$/
const MILES = /^\d{1,3}(\.\d{3})+$/ // "1.250.000", "4.500"

function normalizar(entero: string, decimales: string, negativo: boolean): string {
  const e = entero.replace(/^0+(?=\d)/, '') || '0'
  return `${negativo ? '-' : ''}${e}${decimales ? `.${decimales}` : ''}`
}

// String normalizado con punto decimal ("4500.40"), '' si está vacío o null si no es un monto.
// Acepta "$", espacios y espacios duros. Una coma o un punto al final ("4500," / "4500.") se toman
// como decimales todavía sin escribir: así el valor no salta mientras la persona tipea.
export function parseMonto(entrada: string, { negativo = false }: OpcionesParseMonto = {}): string | null {
  let s = entrada.replace(/[$\s ]/g, '')
  if (s === '') return ''
  let signo = false
  if (s.startsWith('-') || s.startsWith('−')) {
    if (!negativo) return null
    signo = true
    s = s.slice(1)
    if (s === '') return null
  }
  if (/[^\d.,]/.test(s)) return null // letras u otros signos

  let entero: string
  let decimales: string
  const comas = (s.match(/,/g) ?? []).length
  if (comas > 1) return null
  if (comas === 1) {
    // Coma = decimal; puntos = miles (agrupados de a 3).
    ;[entero, decimales] = s.split(',')
    if (entero === '') entero = '0'
    if (!(SOLO_DIGITOS.test(entero) || MILES.test(entero))) return null
    entero = entero.replace(/\./g, '')
  } else {
    const puntos = (s.match(/\./g) ?? []).length
    if (puntos === 0) {
      entero = s
      decimales = ''
    } else if (puntos > 1) {
      if (!MILES.test(s)) return null
      entero = s.replace(/\./g, '')
      decimales = ''
    } else {
      const [izq, der] = s.split('.')
      if (der.length === 3 && izq !== '') {
        entero = izq + der // "4.500" → 4500; "632.250" → 632250
        decimales = ''
      } else {
        entero = izq === '' ? '0' : izq
        decimales = der
      }
    }
  }
  if (!SOLO_DIGITOS.test(entero)) return null
  if (decimales.length > 2 || (decimales !== '' && !SOLO_DIGITOS.test(decimales))) return null
  return normalizar(entero, decimales, signo)
}

// Texto editable de un valor normalizado: "4500.40" → "4500,40" (sin $ ni separador de miles).
export function montoEditable(valor: string): string {
  return valor.replace('.', ',')
}
