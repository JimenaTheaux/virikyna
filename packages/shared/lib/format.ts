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

// Espeja la columna generada productos.precio_venta (docs/06_estructura_de_datos.md) —
// se usa solo para la vista previa en vivo del formulario, el valor real siempre lo calcula la base.
export function calcularPrecioVenta(costo: number, margen1: number, margen2: number, ivaPorcentaje: number): number {
  const precio = costo * (1 + margen1 / 100) * (1 + margen2 / 100) * (1 + ivaPorcentaje / 100)
  return Math.round(precio * 100) / 100
}

export function generarCodigoInterno(): string {
  const timestamp = Date.now().toString(36).toUpperCase()
  const random = Math.random().toString(36).slice(2, 5).toUpperCase()
  return `INT-${timestamp}${random}`
}

export function formatFechaHora(iso: string): string {
  return new Date(iso).toLocaleString('es-AR', { dateStyle: 'short', timeStyle: 'short' })
}

// `fecha` es una columna DATE de Postgres ('YYYY-MM-DD') — se arma con hora fija para evitar
// que el navegador la interprete en UTC y muestre el día anterior según la zona horaria local.
export function formatFecha(fecha: string): string {
  return new Date(`${fecha}T00:00:00`).toLocaleDateString('es-AR', { dateStyle: 'long' })
}

// DD/MM/AAAA — formato corto estándar para columnas de fecha en tablas y vistas de detalle
// (mismo dato que formatFecha, sin el texto largo "15 de septiembre de 2026").
// Reordena el string 'YYYY-MM-DD' directo, sin pasar por Date, así no hay riesgo de UTC.
export function formatFechaCorta(fecha: string): string {
  const [anio, mes, dia] = fecha.split('-')
  return `${dia}/${mes}/${anio}`
}

// `offsetDias` negativo = días hacia atrás desde hoy (ej. -1 = ayer, -6 = hace 6 días).
export function fechaISO(offsetDias = 0): string {
  const fecha = new Date()
  fecha.setDate(fecha.getDate() + offsetDias)
  const tz = fecha.getTimezoneOffset()
  return new Date(fecha.getTime() - tz * 60000).toISOString().slice(0, 10)
}

export function fechaHoyISO(): string {
  return fechaISO(0)
}

// Misma normalización de zona horaria que fechaISO, aplicada a un timestamp (created_at)
// en vez de "ahora" — para agrupar filas por su día local real.
export function fechaLocalDeISO(iso: string): string {
  const fecha = new Date(iso)
  const tz = fecha.getTimezoneOffset()
  return new Date(fecha.getTime() - tz * 60000).toISOString().slice(0, 10)
}
