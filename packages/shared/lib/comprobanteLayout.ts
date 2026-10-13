// Layout del comprobante tipo ticket (80 mm) — una sola definición para el PDF (jsPDF) y la imagen
// JPG (canvas). Cada uno aporta cómo cortar un texto en renglones con su propia medición; acá se
// decide qué va dónde y cuánto mide en alto, así los dos salen iguales.
//
// Ítems en dos renglones (formato de ticket de mostrador):
//   SILLA DE COMER CARESTINO OSAKA          ← nombre · marca, con salto de línea, nunca cortado
//   TRIPLE POSICIÓN · CARESTINO
//     2 × $ 25.000,00          $ 50.000,00  ← cantidad × precio unitario | importe
// Así cantidad, precio e importe nunca se pisan con el nombre, por largo que sea. El alto total se
// calcula con los renglones reales (sin alto fijo por ítem).
import { formatCurrency, formatFechaHora } from './format'
import { lineasFormaPago, type DatosComprobante } from './comprobante'

export const ANCHO_TICKET_MM = 80
const MARGEN = 5
const ANCHO_UTIL = ANCHO_TICKET_MM - MARGEN * 2
const SANGRIA_DETALLE = 2
export const LOGO_ANCHO_MM = 26

export type Fuente = { puntos: number; negrita?: boolean }

export type OperacionTicket =
  | { tipo: 'texto'; texto: string; x: number; y: number; alinear: 'left' | 'center' | 'right'; fuente: Fuente }
  | { tipo: 'linea'; y: number }
  | { tipo: 'logo'; x: number; y: number; ancho: number; alto: number }

// Corta `texto` en renglones que entren en `anchoMm` con esa fuente (palabras largas incluidas).
export type PartirTexto = (texto: string, anchoMm: number, fuente: Fuente) => string[]

const F_TITULO: Fuente = { puntos: 10, negrita: true }
const F_CUERPO: Fuente = { puntos: 8 }
const F_CUERPO_NEGRITA: Fuente = { puntos: 8, negrita: true }
const F_DETALLE: Fuente = { puntos: 7.5 }
const F_TOTAL: Fuente = { puntos: 10, negrita: true }
const F_CHICA: Fuente = { puntos: 7 }

// Distancia entre renglones (mm) según el tamaño de letra.
const RENGLON = { cuerpo: 4, nombre: 3.6, detalle: 3.6, chica: 3 }

const formatCantidad = new Intl.NumberFormat('es-AR', { maximumFractionDigits: 2 })

export function armarLayoutTicket(
  datos: DatosComprobante,
  partir: PartirTexto,
  logoAltoMm: number,
): { altoMm: number; operaciones: OperacionTicket[] } {
  const ops: OperacionTicket[] = []
  const centro = ANCHO_TICKET_MM / 2
  const derecha = ANCHO_TICKET_MM - MARGEN
  let y = 4

  const texto = (t: string, x: number, alinear: 'left' | 'center' | 'right', fuente: Fuente) =>
    ops.push({ tipo: 'texto', texto: t, x, y, alinear, fuente })
  // Texto que puede no entrar en un renglón: uno debajo del otro.
  const parrafo = (t: string, x: number, ancho: number, alinear: 'left' | 'center', fuente: Fuente, renglon: number) => {
    for (const linea of partir(t, ancho, fuente)) {
      texto(linea, x, alinear, fuente)
      y += renglon
    }
  }
  const separador = (antes: number, despues: number) => {
    y += antes
    ops.push({ tipo: 'linea', y })
    y += despues
  }

  // Encabezado
  ops.push({ tipo: 'logo', x: centro - LOGO_ANCHO_MM / 2, y, ancho: LOGO_ANCHO_MM, alto: logoAltoMm })
  y += logoAltoMm + 4
  texto(datos.tipo === 'factura_c' ? 'FACTURA C' : 'COMPROBANTE X', centro, 'center', F_TITULO)
  y += 5
  texto(`N°: ${datos.numero}`, MARGEN, 'left', F_CUERPO)
  y += RENGLON.cuerpo
  texto(`Fecha: ${formatFechaHora(datos.fecha)}`, MARGEN, 'left', F_CUERPO)
  y += RENGLON.cuerpo
  parrafo(`Cliente: ${datos.clienteNombre}`, MARGEN, ANCHO_UTIL, 'left', F_CUERPO, RENGLON.cuerpo)
  for (const linea of lineasFormaPago(datos)) {
    texto(linea, MARGEN, 'left', F_CUERPO)
    y += RENGLON.cuerpo
  }
  if (datos.tipo === 'factura_c' && datos.cae) {
    texto(`CAE: ${datos.cae}`, MARGEN, 'left', F_CUERPO)
    y += RENGLON.cuerpo
  }

  // Ítems
  separador(1, 4)
  texto('Producto', MARGEN, 'left', F_CUERPO_NEGRITA)
  texto('Importe', derecha, 'right', F_CUERPO_NEGRITA)
  separador(1.5, 4)

  datos.items.forEach((item, i) => {
    if (i > 0) y += 1.6
    parrafo(item.nombre, MARGEN, ANCHO_UTIL, 'left', F_CUERPO, RENGLON.nombre)
    texto(
      `${formatCantidad.format(item.cantidad)} × ${formatCurrency(item.precioUnitario)}`,
      MARGEN + SANGRIA_DETALLE,
      'left',
      F_DETALLE,
    )
    texto(formatCurrency(item.importe), derecha, 'right', F_DETALLE)
    y += RENGLON.detalle
  })

  // Totales
  separador(0.4, 5)
  const hayDiferencia = datos.precioOficial !== datos.total
  const lineaTotal = (t: string) => {
    texto(t, derecha, 'right', F_CUERPO)
    y += RENGLON.cuerpo
  }
  lineaTotal(`Subtotal: ${formatCurrency(datos.subtotal)}`)
  if (datos.descuentoPorcentaje > 0) lineaTotal(`Descuento: ${datos.descuentoPorcentaje}%`)
  if (datos.recargoPorcentaje > 0) lineaTotal(`Recargo: ${datos.recargoPorcentaje}%`)
  if (hayDiferencia) lineaTotal(`Precio oficial: ${formatCurrency(datos.precioOficial)}`)
  y += 0.5
  texto(`TOTAL: ${formatCurrency(datos.total)}`, derecha, 'right', F_TOTAL)
  y += 7

  if (hayDiferencia) {
    const diferencia = datos.total - datos.precioOficial
    texto(`Diferencia (redondeo): ${diferencia > 0 ? '+' : ''}${formatCurrency(diferencia)}`, derecha, 'right', F_CHICA)
    y += RENGLON.cuerpo
  }

  parrafo(
    datos.tipo === 'comprobante_x'
      ? 'Comprobante interno — no válido como factura ante ARCA.'
      : 'Factura electrónica emitida ante ARCA.',
    centro,
    ANCHO_UTIL,
    'center',
    F_CHICA,
    RENGLON.chica,
  )

  return { altoMm: Math.ceil(y + 2), operaciones: ops }
}

// Corte en renglones por palabras para un medidor cualquiera (lo usa la imagen; jsPDF trae el suyo).
// Una palabra más ancha que el renglón (ej. un código largo sin espacios) se corta por letras.
export function partirConMedidor(texto: string, anchoMax: number, medir: (t: string) => number): string[] {
  const renglones: string[] = []
  let actual = ''
  for (const palabra of texto.split(/\s+/).filter(Boolean)) {
    const prueba = actual ? `${actual} ${palabra}` : palabra
    if (medir(prueba) <= anchoMax) {
      actual = prueba
      continue
    }
    if (actual) renglones.push(actual)
    if (medir(palabra) <= anchoMax) {
      actual = palabra
      continue
    }
    actual = ''
    for (const letra of palabra) {
      if (actual && medir(actual + letra) > anchoMax) {
        renglones.push(actual)
        actual = letra
      } else {
        actual += letra
      }
    }
  }
  if (actual) renglones.push(actual)
  return renglones.length > 0 ? renglones : ['']
}
