export function formatCurrency(value: number): string {
  return new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(value)
}

// Versión compacta ("$12,3 mil") para espacios chicos como etiquetas de barras de un gráfico.
export function formatCurrencyCompact(value: number): string {
  return new Intl.NumberFormat('es-AR', {
    style: 'currency',
    currency: 'ARS',
    notation: 'compact',
    maximumFractionDigits: 1,
  }).format(value)
}

// Ajuste de redondeo con signo explícito: "−$ 48,37" / "+$ 51,63" (signo menos tipográfico).
export function formatAjuste(valor: number): string {
  return `${valor < 0 ? '−' : '+'}${formatCurrency(Math.abs(valor))}`
}

// Resumen de la vista previa de actualización masiva: "12 productos · 3 sin cambio de precio ·
// +7,5 % sobre el costo". Lo anuncia el aria-live del modal (escritorio) y del sheet (Inventario).
export function resumenVistaPreviaPrecios(productos: number, sinCambio: number, porcentaje: number): string {
  const pct = new Intl.NumberFormat('es-AR', { maximumFractionDigits: 4, signDisplay: 'always' }).format(porcentaje)
  const partes = [`${productos} producto${productos === 1 ? '' : 's'}`]
  if (sinCambio > 0) partes.push(`${sinCambio} sin cambio de precio`)
  partes.push(`${pct} % sobre el costo`)
  return partes.join(' · ')
}

export function generarCodigoInterno(): string {
  const timestamp = Date.now().toString(36).toUpperCase()
  const random = Math.random().toString(36).slice(2, 5).toUpperCase()
  return `INT-${timestamp}${random}`
}

const dos = (n: number) => String(n).padStart(2, '0')

// Formato único de fecha con hora en toda la app: DD/MM/AAAA HH:mm (24 hs), en la hora local del
// dispositivo. Se arma a mano en vez de con toLocaleString/Intl porque esos dan un resultado
// distinto según opciones y motor ("5/9/26, 2:07 p. m." vs "5/9/2026, 02:07:00") y ya divergió
// una vez entre pantallas, PDF y comprobantes. Cualquier lugar que muestre un timestamp
// (created_at, abierta_at…) debe usar esta función o sus dos partes (formatFechaCortaLocal +
// formatHora), nunca toLocale*String.
export function formatFechaHora(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return '—'
  return `${formatFechaCortaLocal(iso)} ${formatHora(iso)}`
}

// DD/MM/AAAA de un timestamp (día local) — para columnas que separan fecha y hora.
export function formatFechaCortaLocal(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return '—'
  return `${dos(d.getDate())}/${dos(d.getMonth() + 1)}/${d.getFullYear()}`
}

// HH:mm (24 hs) de un timestamp (hora local).
export function formatHora(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return '—'
  return `${dos(d.getHours())}:${dos(d.getMinutes())}`
}

// DD/MM/AAAA — formato corto estándar para columnas de fecha (DATE de Postgres, 'YYYY-MM-DD') en
// tablas y vistas de detalle. Reordena el string directo, sin pasar por Date, así no hay riesgo de
// que el navegador lo interprete en UTC y muestre el día anterior según la zona horaria local.
export function formatFechaCorta(fecha: string): string {
  const [anio, mes, dia] = fecha.split('-')
  return `${dia}/${mes}/${anio}`
}

// Día de negocio = día en hora argentina, en todas las apps y en la base (docs/28): nunca el
// reloj/zona de la PC ni el UTC de Supabase. Las RPCs usan el mismo día con
// AT TIME ZONE 'America/Argentina/Buenos_Aires' o SET timezone.
const ZONA_AR = 'America/Argentina/Buenos_Aires'

const fechaEnAR = new Intl.DateTimeFormat('en-CA', {
  timeZone: ZONA_AR,
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
})

// "Hoy" en hora argentina (YYYY-MM-DD). `offsetDias` negativo = días hacia atrás (-1 = ayer).
// El corrimiento se hace sobre la fecha de calendario en UTC, así no lo afecta ningún cambio de horario.
export function hoyAR(offsetDias = 0): string {
  const fecha = new Date(`${fechaEnAR.format(new Date())}T00:00:00Z`)
  fecha.setUTCDate(fecha.getUTCDate() + offsetDias)
  return fecha.toISOString().slice(0, 10)
}

// Alias históricos de hoyAR — antes calculaban con la zona de la PC (docs/28).
export function fechaISO(offsetDias = 0): string {
  return hoyAR(offsetDias)
}

export function fechaHoyISO(): string {
  return hoyAR(0)
}

// Día argentino (YYYY-MM-DD) de un timestamp (created_at) — para agrupar filas por día de negocio.
// (El nombre es histórico: antes usaba la zona de la PC.)
export function fechaLocalDeISO(iso: string): string {
  return fechaEnAR.format(new Date(iso))
}

// Offset de Argentina para una fecha ("-03:00"). Hoy es fijo, pero se calcula por si vuelve el
// horario de verano.
function offsetAR(fecha: string): string {
  const nombre = new Intl.DateTimeFormat('en-US', { timeZone: ZONA_AR, timeZoneName: 'longOffset' })
    .formatToParts(new Date(`${fecha}T12:00:00Z`))
    .find((p) => p.type === 'timeZoneName')?.value
  return nombre?.match(/[+-]\d{2}:\d{2}/)?.[0] ?? '-03:00'
}

// Rango de timestamps (con zona) que cubre días argentinos completos, para filtrar columnas
// timestamptz (created_at) con .gte(desde).lte(hasta). Un texto sin zona como `${dia}T23:59:59`
// la base lo lee en UTC = 20:59:59 AR, y deja afuera lo de después de las 21:00.
export function rangoTimestampsAR(desdeDia: string, hastaDia: string): { desde: string; hasta: string } {
  return {
    desde: `${desdeDia}T00:00:00${offsetAR(desdeDia)}`,
    hasta: `${hastaDia}T23:59:59.999${offsetAR(hastaDia)}`,
  }
}
