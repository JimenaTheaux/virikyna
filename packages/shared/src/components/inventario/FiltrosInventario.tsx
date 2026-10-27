import { useEffect, useRef, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { formatCantidad } from '../../../lib/cargaInicial'
import type { ProductoConRelaciones } from '../../../lib/inventario'
import { coincideBusquedaProducto } from '../../../lib/productoBusqueda'
import { textoParaBuscar } from '../../../lib/texto'
import {
  clasificarStock,
  escribirFiltrosInventario,
  FILTROS_INVENTARIO_DEFAULT,
  FILTROS_STOCK,
  leerFiltrosInventario,
  type FiltroEstado,
  type FiltroStock,
  type FiltrosInventario,
} from '../../../lib/estadoStock'

// Piezas del listado de Inventario que comparten Local/Gestión (tabla) y la app Inventario (cards).

// Búsqueda del listado: nombre, marca, códigos (coincideBusquedaProducto) y proveedor.
export function coincideBusquedaInventario(p: ProductoConRelaciones, q: string): boolean {
  return coincideBusquedaProducto(p, q) || textoParaBuscar(p.proveedor?.razon_social).includes(textoParaBuscar(q))
}

export const ESTADO_OPCIONES: { value: FiltroEstado; label: string }[] = [
  { value: 'activos', label: 'Activos' },
  { value: 'inactivos', label: 'Inactivos' },
  { value: 'todos', label: 'Todos' },
]

const CHIP: Record<FiltroStock, { label: string; punto: string | null; vacio: string }> = {
  todos: { label: 'Todos', punto: null, vacio: 'No hay productos para mostrar.' },
  sin_stock: { label: 'Sin stock', punto: 'bg-error', vacio: 'No hay productos sin stock 🎉' },
  negativo: { label: 'Negativo', punto: 'bg-error-dark', vacio: 'No hay productos con stock negativo 🎉' },
  bajo: { label: 'Stock bajo', punto: 'bg-badge-amber-text', vacio: 'No hay productos con stock bajo 🎉' },
  sin_minimo: { label: 'Sin mínimo', punto: 'bg-ink-soft/50', vacio: 'Todos los productos tienen mínimo cargado 🎉' },
}

// Texto del listado vacío: si solo está el chip, un mensaje "todo en orden"; si hay más filtros,
// "ninguno coincide" (con Limpiar filtros al lado, lo pone quien lo usa).
export function mensajeListadoVacio(f: FiltrosInventario): { texto: string; conLimpiar: boolean } {
  const otros = f.estado !== 'activos' || !!f.marca || !!f.proveedor || !!f.q.trim()
  if (!otros && f.stock !== 'todos') return { texto: CHIP[f.stock].vacio, conLimpiar: false }
  return { texto: 'Ningún producto coincide con los filtros.', conLimpiar: true }
}

// Chips de estado de stock con contador. En 'touch' (Inventario, celular): una sola fila con
// scroll horizontal y 44px de alto.
export function ChipsStock({
  value,
  contadores,
  onChange,
  size = 'compact',
}: {
  value: FiltroStock
  contadores: Record<FiltroStock, number>
  onChange: (f: FiltroStock) => void
  size?: 'compact' | 'touch'
}) {
  const touch = size === 'touch'
  return (
    <div
      role="group"
      aria-label="Filtrar por stock"
      className={`flex gap-2 ${touch ? '-mx-stack-md overflow-x-auto px-stack-md pb-1 [scrollbar-width:none]' : 'flex-wrap'}`}
    >
      {FILTROS_STOCK.map((f) => {
        const activo = value === f
        const { label, punto } = CHIP[f]
        return (
          <button
            key={f}
            type="button"
            aria-pressed={activo}
            onClick={() => onChange(f)}
            className={[
              'flex shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full border px-3.5 font-sans text-label-bold transition',
              'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-1',
              touch ? 'min-h-11' : 'py-1.5',
              activo
                ? 'border-accent bg-accent-light text-accent-darker'
                : 'border-line bg-surface text-ink-soft hover:border-accent hover:text-accent-darker',
            ].join(' ')}
          >
            {punto && <span aria-hidden="true" className={`h-2 w-2 rounded-full ${punto}`} />}
            {label}
            <span className="tabular-nums font-normal">({contadores[f]})</span>
          </button>
        )
      })}
    </div>
  )
}

const BADGE: Record<'negativo' | 'sin_stock' | 'bajo', { clase: string; sr: string }> = {
  negativo: { clase: 'bg-error-dark text-white', sr: 'stock negativo' },
  sin_stock: { clase: 'bg-badge-red-bg text-error', sr: 'sin stock' },
  bajo: { clase: 'bg-badge-amber-bg text-badge-amber-text', sr: 'stock bajo' },
}

// Stock con color según estado (rojo oscuro negativo, rojo sin stock, ámbar bajo) y el mínimo:
// 'celda' (tabla) con el mínimo debajo; 'linea' (cards de Inventario) "Stock N · min N" en un renglón.
export function BadgeStock({ stock, minimo, variante = 'celda' }: { stock: number; minimo: number; variante?: 'celda' | 'linea' }) {
  const estado = clasificarStock(stock, minimo)
  const badge = estado === 'negativo' || estado === 'sin_stock' || estado === 'bajo' ? BADGE[estado] : null
  const numero = (
    <span className={`tabular-nums ${badge ? `rounded-[6px] px-2 py-0.5 font-semibold ${badge.clase}` : 'text-ink'}`}>
      {formatCantidad(stock)}
      {badge && <span className="sr-only"> ({badge.sr})</span>}
    </span>
  )
  const textoMinimo = minimo > 0 ? `min ${formatCantidad(minimo)}` : 'sin min'
  if (variante === 'linea') {
    return (
      <span className="inline-flex items-center gap-1.5 whitespace-nowrap">
        Stock {numero}
        <span className="text-ink-soft">· {textoMinimo}</span>
      </span>
    )
  }
  return (
    <span className="inline-flex flex-col items-end">
      {numero}
      <span className="mt-0.5 whitespace-nowrap font-sans text-[11px] leading-tight text-ink-soft">{textoMinimo}</span>
    </span>
  )
}

const CLAVES_FILTRO = Object.keys(FILTROS_INVENTARIO_DEFAULT)
const CLAVE_GUARDADO = 'virikyna:inventario:filtros'

function leerGuardado(): string | null {
  try {
    return sessionStorage.getItem(CLAVE_GUARDADO)
  } catch {
    return null
  }
}

function guardar(params: URLSearchParams) {
  try {
    const propios = new URLSearchParams()
    for (const c of CLAVES_FILTRO) if (params.get(c)) propios.set(c, params.get(c)!)
    sessionStorage.setItem(CLAVE_GUARDADO, propios.toString())
  } catch {
    // Sin storage (ventana privada, bloqueado): los filtros siguen en la URL, solo no se recuerdan.
  }
}

// Filtros en la URL (?estado=&stock=&marca=&proveedor=&q=): recargar o "Atrás" los conserva. Además
// se recuerdan en la sesión: entrar de nuevo desde el menú (link sin parámetros) vuelve a los
// últimos; un link que trae filtros (Dashboard → ?stock=bajo) manda sobre lo recordado.
// La búsqueda filtra al tipear y se escribe en la URL con 200 ms de espera.
export function useFiltrosInventario() {
  const [params, setParams] = useSearchParams()
  // Lo recordado se usa solo hasta que queda escrito en la URL (el primer efecto); después manda
  // siempre la URL, también cuando se limpian todos los filtros.
  const pendiente = useRef<URLSearchParams | null>(null)
  const [iniciado, setIniciado] = useState(false)
  if (!iniciado && pendiente.current === null && !CLAVES_FILTRO.some((c) => params.has(c))) {
    const guardado = leerGuardado()
    if (guardado) pendiente.current = new URLSearchParams(guardado)
  }
  const enUrl = leerFiltrosInventario(pendiente.current ?? params)
  const [busqueda, setBusqueda] = useState(enUrl.q)

  useEffect(() => {
    const restaurar = pendiente.current
    if (restaurar) setParams((prev) => escribirFiltrosInventario(prev, leerFiltrosInventario(restaurar)), { replace: true })
    pendiente.current = null
    setIniciado(true)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    if (iniciado) guardar(params)
  }, [params, iniciado])

  function aplicar(cambios: Partial<FiltrosInventario>) {
    setParams((prev) => escribirFiltrosInventario(prev, { ...leerFiltrosInventario(prev), ...cambios }), { replace: true })
  }

  useEffect(() => {
    if (busqueda.trim() === enUrl.q) return
    const t = setTimeout(() => aplicar({ q: busqueda.trim() }), 200)
    return () => clearTimeout(t)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [busqueda])

  function limpiar() {
    setBusqueda('')
    setParams((prev) => escribirFiltrosInventario(prev, FILTROS_INVENTARIO_DEFAULT), { replace: true })
  }

  return { filtros: { ...enUrl, q: busqueda } as FiltrosInventario, busqueda, setBusqueda, aplicar, limpiar }
}
