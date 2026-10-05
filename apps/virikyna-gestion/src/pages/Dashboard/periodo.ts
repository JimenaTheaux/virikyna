import { formatFechaCorta, hoyAR } from '@virikyna/shared'

// Períodos del filtro del Dashboard. Todas las fechas son 'YYYY-MM-DD' en hora argentina (hoyAR)
// y la aritmética se hace sobre la fecha de calendario en UTC — nunca con el reloj de la PC.

export type TipoPeriodo = 'hoy' | 'semana' | 'mes' | 'rango'

export const OPCIONES_PERIODO: { id: TipoPeriodo; label: string }[] = [
  { id: 'hoy', label: 'Hoy' },
  { id: 'semana', label: 'Esta semana' },
  { id: 'mes', label: 'Este mes' },
  { id: 'rango', label: 'Rango personalizado' },
]

type Rango = { desde: string; hasta: string }

export type Periodo = {
  tipo: TipoPeriodo
  actual: Rango // lo que suman los KPIs
  anterior: Rango // período equivalente para la comparación
  grafico: Rango // días con barra (en "Hoy": últimos 7 días)
  consulta: Rango // una sola llamada a la RPC que cubre los tres rangos de arriba
  descripcion: string // período escrito debajo de los KPIs
  comparacion: string // "ayer", "el mismo tramo de la semana pasada"…
}

// Tope del rango personalizado: un año. Más que eso no entra como barras por día.
export const MAX_DIAS_RANGO = 366

function aFecha(fecha: string): Date {
  return new Date(`${fecha}T00:00:00Z`)
}

export function sumarDias(fecha: string, dias: number): string {
  const d = aFecha(fecha)
  d.setUTCDate(d.getUTCDate() + dias)
  return d.toISOString().slice(0, 10)
}

// Cantidad de días entre dos fechas, ambas incluidas.
export function diasEntre(desde: string, hasta: string): number {
  return Math.round((aFecha(hasta).getTime() - aFecha(desde).getTime()) / 86_400_000) + 1
}

function ultimoDiaDelMes(anio: number, mes0: number): number {
  return new Date(Date.UTC(anio, mes0 + 1, 0)).getUTCDate()
}

function fechaDe(anio: number, mes0: number, dia: number): string {
  return new Date(Date.UTC(anio, mes0, dia)).toISOString().slice(0, 10)
}

export function esFechaValida(valor: string | null): valor is string {
  return !!valor && /^\d{4}-\d{2}-\d{2}$/.test(valor) && !Number.isNaN(aFecha(valor).getTime())
}

const nombreMes = new Intl.DateTimeFormat('es-AR', { month: 'long', year: 'numeric', timeZone: 'UTC' })
const nombreDia = new Intl.DateTimeFormat('es-AR', { weekday: 'long', timeZone: 'UTC' })
const capitalizar = (s: string) => s.charAt(0).toUpperCase() + s.slice(1)

// Semana de lunes a domingo, mes calendario. La comparación de semana y mes es contra el mismo
// tramo ya transcurrido del período anterior (lunes a hoy vs. lunes al mismo día de la semana
// pasada; 1 a hoy vs. 1 al mismo día del mes pasado) — comparar una semana a medio andar contra
// una semana completa daría siempre "en baja". Rango personalizado: misma cantidad de días hacia atrás.
export function calcularPeriodo(tipo: TipoPeriodo, rango?: Rango): Periodo {
  const hoy = hoyAR(0)

  if (tipo === 'semana') {
    const diaSemana = (aFecha(hoy).getUTCDay() + 6) % 7 // lunes = 0 … domingo = 6
    const lunes = sumarDias(hoy, -diaSemana)
    const domingo = sumarDias(lunes, 6)
    const lunesPasado = sumarDias(lunes, -7)
    return {
      tipo,
      actual: { desde: lunes, hasta: hoy },
      anterior: { desde: lunesPasado, hasta: sumarDias(hoy, -7) },
      grafico: { desde: lunes, hasta: domingo },
      consulta: { desde: lunesPasado, hasta: domingo },
      descripcion: `Semana del ${formatFechaCorta(lunes)} al ${formatFechaCorta(domingo)}`,
      comparacion: 'el mismo tramo de la semana pasada',
    }
  }

  if (tipo === 'mes') {
    const d = aFecha(hoy)
    const anio = d.getUTCFullYear()
    const mes0 = d.getUTCMonth()
    const dia = d.getUTCDate()
    const primero = fechaDe(anio, mes0, 1)
    const ultimo = fechaDe(anio, mes0, ultimoDiaDelMes(anio, mes0))
    const primeroPasado = fechaDe(anio, mes0 - 1, 1)
    // Mismo día del mes pasado, sin pasarse de su último día (31/03 → 28 o 29/02).
    const mismoDiaPasado = fechaDe(anio, mes0 - 1, Math.min(dia, ultimoDiaDelMes(anio, mes0 - 1)))
    return {
      tipo,
      actual: { desde: primero, hasta: hoy },
      anterior: { desde: primeroPasado, hasta: mismoDiaPasado },
      grafico: { desde: primero, hasta: ultimo },
      consulta: { desde: primeroPasado, hasta: ultimo },
      descripcion: capitalizar(nombreMes.format(aFecha(hoy))),
      comparacion: 'el mismo tramo del mes pasado',
    }
  }

  if (tipo === 'rango' && rango) {
    const dias = diasEntre(rango.desde, rango.hasta)
    const anteriorDesde = sumarDias(rango.desde, -dias)
    return {
      tipo,
      actual: rango,
      anterior: { desde: anteriorDesde, hasta: sumarDias(rango.desde, -1) },
      grafico: rango,
      consulta: { desde: anteriorDesde, hasta: rango.hasta },
      descripcion:
        dias === 1
          ? formatFechaCorta(rango.desde)
          : `Del ${formatFechaCorta(rango.desde)} al ${formatFechaCorta(rango.hasta)} (${dias} días)`,
      comparacion: dias === 1 ? 'el día anterior' : `los ${dias} días anteriores`,
    }
  }

  // Hoy (default): KPIs del día, comparación con ayer, gráfico de los últimos 7 días.
  const hace6 = sumarDias(hoy, -6)
  return {
    tipo: 'hoy',
    actual: { desde: hoy, hasta: hoy },
    anterior: { desde: sumarDias(hoy, -1), hasta: sumarDias(hoy, -1) },
    grafico: { desde: hace6, hasta: hoy },
    consulta: { desde: hace6, hasta: hoy },
    descripcion: `Hoy, ${nombreDia.format(aFecha(hoy))} ${formatFechaCorta(hoy)}`,
    comparacion: 'ayer',
  }
}

// Lee el período de la URL (?periodo=semana, ?periodo=rango&desde=…&hasta=…). Cualquier valor
// inválido cae en "Hoy". Un rango invertido se da vuelta y uno de más de un año se recorta desde
// `hasta` hacia atrás.
export function periodoDesdeParams(params: URLSearchParams): Periodo {
  const tipo = params.get('periodo')
  if (tipo === 'semana' || tipo === 'mes') return calcularPeriodo(tipo)
  if (tipo === 'rango') {
    let desde = params.get('desde')
    let hasta = params.get('hasta')
    if (esFechaValida(desde) && esFechaValida(hasta)) {
      if (desde > hasta) [desde, hasta] = [hasta, desde]
      if (diasEntre(desde, hasta) > MAX_DIAS_RANGO) desde = sumarDias(hasta, -(MAX_DIAS_RANGO - 1))
      return calcularPeriodo('rango', { desde, hasta })
    }
  }
  return calcularPeriodo('hoy')
}

// Todos los días de un rango, en orden.
export function diasDelRango({ desde, hasta }: Rango): string[] {
  return Array.from({ length: diasEntre(desde, hasta) }, (_, i) => sumarDias(desde, i))
}
