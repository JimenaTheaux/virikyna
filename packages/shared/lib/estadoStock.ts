// Estado de stock y filtros del listado de Inventario (Local, Gestión y la app Inventario).
// Mismas definiciones que resumen_stock_inventario (docs/64) — si cambia una, cambia la otra:
//   sin_stock  = stock total <= 0           negativo = stock total < 0 (subconjunto, para corregir)
//   bajo       = mínimo > 0, stock > 0 y <= mínimo
//   sin_minimo = mínimo 0 (no cargado: docs/64 decidió 0 = sin definir, no NULL)
// Sin imports de valores: lo corre node --test directo (tests/estadoStock.test.ts). El stock y la
// búsqueda de texto se reciben como funciones.

export type EstadoStock = 'negativo' | 'sin_stock' | 'bajo' | 'sin_minimo' | 'ok'

// El más grave que aplica: un producto sin stock y sin mínimo es 'sin_stock', no 'sin_minimo'.
export function clasificarStock(stock: number, minimo: number): EstadoStock {
  if (stock < 0) return 'negativo'
  if (stock <= 0) return 'sin_stock'
  if (minimo > 0 && stock <= minimo) return 'bajo'
  if (minimo <= 0) return 'sin_minimo'
  return 'ok'
}

// Texto del campo "Stock mínimo" en los formularios de producto de las tres apps.
export const STOCK_MINIMO_LABEL = 'Stock mínimo (alerta)'
export const STOCK_MINIMO_AYUDA = 'Cantidad a partir de la cual avisa que hay que reponer. Dejá 0 si no querés alerta.'

// Aviso suave (no bloquea) contra un error que pasó al dar de alta (20 y 21/10/2026): la cantidad que
// entraba se escribió en el mínimo. El alta no tiene campo de stock (entra con la factura o un ajuste),
// así que ahí cualquier mínimo > 0 se pregunta; en una edición, si es igual al stock que hay.
export function avisoStockMinimo({ minimo, stockActual, esAlta }: { minimo: number; stockActual: number; esAlta: boolean }): string | null {
  if (!(minimo > 0)) return null
  if (esAlta) return '¿Seguro? El stock mínimo no es la cantidad que entra: el stock se suma con la factura o con un ajuste.'
  if (minimo === stockActual) return '¿Seguro? El mínimo es igual al stock cargado.'
  return null
}

export type FiltroStock = 'todos' | 'sin_stock' | 'negativo' | 'bajo' | 'sin_minimo'
export type FiltroEstado = 'activos' | 'inactivos' | 'todos'

export const FILTROS_STOCK: FiltroStock[] = ['todos', 'sin_stock', 'negativo', 'bajo', 'sin_minimo']
const FILTROS_ESTADO: FiltroEstado[] = ['activos', 'inactivos', 'todos']

export function cumpleFiltroStock(stock: number, minimo: number, filtro: FiltroStock): boolean {
  switch (filtro) {
    case 'todos':
      return true
    case 'sin_stock':
      return stock <= 0
    case 'negativo':
      return stock < 0
    case 'bajo':
      return minimo > 0 && stock > 0 && stock <= minimo
    case 'sin_minimo':
      return minimo <= 0
  }
}

export type FiltrosInventario = {
  estado: FiltroEstado
  stock: FiltroStock
  marca: string // '' = todas
  proveedor: string // proveedor_id; '' = todos
  q: string
}

export const FILTROS_INVENTARIO_DEFAULT: FiltrosInventario = { estado: 'activos', stock: 'todos', marca: '', proveedor: '', q: '' }

// ?estado=&stock=&marca=&proveedor=&q= — un valor desconocido (link viejo, typo) vuelve al default.
export function leerFiltrosInventario(params: URLSearchParams): FiltrosInventario {
  const estado = params.get('estado') as FiltroEstado | null
  const stock = params.get('stock') as FiltroStock | null
  return {
    estado: estado && FILTROS_ESTADO.includes(estado) ? estado : 'activos',
    stock: stock && FILTROS_STOCK.includes(stock) ? stock : 'todos',
    marca: params.get('marca') ?? '',
    proveedor: params.get('proveedor') ?? '',
    q: params.get('q') ?? '',
  }
}

// Escribe solo lo que difiere del default (la URL limpia = sin filtros) y conserva otros params.
export function escribirFiltrosInventario(prev: URLSearchParams, filtros: FiltrosInventario): URLSearchParams {
  const next = new URLSearchParams(prev)
  for (const clave of Object.keys(FILTROS_INVENTARIO_DEFAULT) as (keyof FiltrosInventario)[]) {
    const valor = filtros[clave].trim()
    if (valor && valor !== FILTROS_INVENTARIO_DEFAULT[clave]) next.set(clave, valor)
    else next.delete(clave)
  }
  return next
}

// Filtros distintos del default sin contar el chip de stock (para "Filtros (N)" en mobile) y en total.
export function cantidadFiltrosAplicados(f: FiltrosInventario, { conStock = true } = {}): number {
  return (
    Number(f.estado !== 'activos') +
    Number(conStock && f.stock !== 'todos') +
    Number(!!f.marca) +
    Number(!!f.proveedor) +
    Number(!!f.q.trim())
  )
}

export type ProductoFiltrable = {
  id: string
  nombre: string
  marca: string | null
  proveedor_id: string | null
  estado: string // 'activo' | 'inactivo'
  stock_minimo: number
  precio_venta: number | null
}

export type CampoOrden = 'nombre' | 'stock' | 'precio'
export type OrdenInventario = { campo: CampoOrden; dir: 'asc' | 'desc' }

// Sin orden elegido: por nombre, salvo en los chips de problemas de stock (lo más crítico primero).
export function ordenPorDefecto(stock: FiltroStock): OrdenInventario {
  return stock === 'sin_stock' || stock === 'negativo' || stock === 'bajo'
    ? { campo: 'stock', dir: 'asc' }
    : { campo: 'nombre', dir: 'asc' }
}

export type ResultadoFiltro<T> = {
  visibles: T[]
  // Productos del estado elegido (Activos / Inactivos / Todos): el "de N" del resumen.
  totalEstado: number
  // Por chip, sobre estado + marca + proveedor + búsqueda (no sobre el chip elegido).
  contadores: Record<FiltroStock, number>
}

export function filtrarInventario<T extends ProductoFiltrable>(
  productos: T[],
  filtros: FiltrosInventario,
  {
    stockDe,
    coincideBusqueda,
    orden,
  }: {
    stockDe: (p: T) => number
    coincideBusqueda: (p: T, q: string) => boolean
    orden?: OrdenInventario | null
  },
): ResultadoFiltro<T> {
  const enEstado = productos.filter((p) =>
    filtros.estado === 'todos' ? true : filtros.estado === 'activos' ? p.estado === 'activo' : p.estado !== 'activo',
  )
  const q = filtros.q.trim()
  const base = enEstado.filter(
    (p) =>
      (!filtros.marca || p.marca === filtros.marca) &&
      (!filtros.proveedor || p.proveedor_id === filtros.proveedor) &&
      (!q || coincideBusqueda(p, q)),
  )

  const contadores = { todos: base.length, sin_stock: 0, negativo: 0, bajo: 0, sin_minimo: 0 } as Record<FiltroStock, number>
  const stockCache = new Map<string, number>()
  for (const p of base) {
    const s = stockDe(p)
    stockCache.set(p.id, s)
    for (const f of FILTROS_STOCK) if (f !== 'todos' && cumpleFiltroStock(s, Number(p.stock_minimo), f)) contadores[f]++
  }

  const o = orden ?? ordenPorDefecto(filtros.stock)
  const signo = o.dir === 'asc' ? 1 : -1
  const porNombre = (a: T, b: T) => a.nombre.localeCompare(b.nombre, 'es')
  const visibles = base
    .filter((p) => cumpleFiltroStock(stockCache.get(p.id)!, Number(p.stock_minimo), filtros.stock))
    .sort((a, b) => {
      if (o.campo === 'nombre') return signo * porNombre(a, b)
      const va = o.campo === 'stock' ? stockCache.get(a.id)! : (a.precio_venta ?? 0)
      const vb = o.campo === 'stock' ? stockCache.get(b.id)! : (b.precio_venta ?? 0)
      return signo * (va - vb) || porNombre(a, b)
    })

  return { visibles, totalEstado: enEstado.length, contadores }
}
