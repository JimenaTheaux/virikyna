// Filtros en cliente de la tab Facturación (chip "Con notas" + buscador) — sobre las ventas ya
// traídas con los filtros de servidor (fechas, estado, medio de pago). Sin dependencias de React
// para poder probarlo aislado.

type VentaFiltrable = {
  numero: number
  nota: string | null
  cliente: { razon_social: string | null; nombre_fantasia: string | null } | null
}

// Minúsculas y sin acentos: "Pérez" y "PEREZ" quedan iguales.
export function normalizar(texto: string): string {
  return texto.normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase()
}

export function tieneNota(nota: string | null): nota is string {
  return nota !== null && nota.trim() !== ''
}

export function esBusquedaPorNumero(q: string): boolean {
  return /^\d+$/.test(q.trim())
}

// Solo dígitos = número de venta exacto. Texto = nota, razón social o nombre fantasía.
export function filtrarVentas<T extends VentaFiltrable>(ventas: T[], soloConNotas: boolean, q: string): T[] {
  const busqueda = q.trim()
  const porNumero = esBusquedaPorNumero(busqueda) ? Number(busqueda) : null
  const aguja = porNumero === null ? normalizar(busqueda) : ''

  return ventas.filter((v) => {
    if (soloConNotas && !tieneNota(v.nota)) return false
    if (porNumero !== null) return v.numero === porNumero
    if (!aguja) return true
    const campos = [v.nota, v.cliente?.razon_social, v.cliente?.nombre_fantasia]
    return campos.some((campo) => campo && normalizar(campo).includes(aguja))
  })
}

export type Segmento = { texto: string; coincide: boolean }

// Parte el texto en tramos para envolver en <mark> las coincidencias. La comparación es sobre el
// texto normalizado, pero los tramos salen del original (con sus acentos y mayúsculas): por eso se
// arma un mapa posición normalizada → carácter original.
export function segmentosResaltados(texto: string, q: string): Segmento[] {
  const aguja = esBusquedaPorNumero(q) ? '' : normalizar(q.trim())
  if (!aguja) return [{ texto, coincide: false }]

  const caracteres = Array.from(texto.normalize('NFC'))
  let normalizado = ''
  const origen: number[] = []
  // Una entrada por unidad UTF-16 (no por carácter), igual que cuenta indexOf — si no, un emoji
  // en la nota corre el resaltado.
  caracteres.forEach((c, i) => {
    const n = normalizar(c)
    normalizado += n
    for (let k = 0; k < n.length; k++) origen.push(i)
  })

  const segmentos: Segmento[] = []
  let cursor = 0
  let desde = normalizado.indexOf(aguja)
  while (desde !== -1) {
    const inicio = origen[desde]
    const fin = origen[desde + aguja.length - 1] + 1
    if (inicio > cursor) segmentos.push({ texto: caracteres.slice(cursor, inicio).join(''), coincide: false })
    segmentos.push({ texto: caracteres.slice(inicio, fin).join(''), coincide: true })
    cursor = fin
    desde = normalizado.indexOf(aguja, desde + aguja.length)
  }
  if (cursor < caracteres.length) segmentos.push({ texto: caracteres.slice(cursor).join(''), coincide: false })
  return segmentos
}
