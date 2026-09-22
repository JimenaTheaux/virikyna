import { useEffect, useState, type KeyboardEvent, type RefObject } from 'react'
import type { Producto } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { formatCurrency, armarFiltroBusquedaProducto, useDebouncedValue } from '@virikyna/shared'
import type { CartItem } from './types'

type ProductoBusquedaItem = Pick<Producto, 'id' | 'nombre' | 'codigo_barras' | 'codigo_interno' | 'precio_venta'>

type Props = {
  inputRef: RefObject<HTMLInputElement>
  onAgregar: (item: Omit<CartItem, 'cantidad'>) => void
}

// Búsqueda con foco automático — recibe tanto texto tipeado como lectura de código de barras
// (el lector envía los dígitos y termina con Enter, igual que un tipeo rápido).
export function ProductoBusqueda({ inputRef, onAgregar }: Props) {
  const [texto, setTexto] = useState('')
  const [resultados, setResultados] = useState<ProductoBusquedaItem[]>([])
  const [highlighted, setHighlighted] = useState(0)
  const [buscando, setBuscando] = useState(false)
  const textoDebounced = useDebouncedValue(texto, 200)

  // "Buscando..." aparece apenas se tipea (sin esperar el debounce) para que el buscador no se
  // quede mostrando resultados obsoletos mientras el usuario sigue escribiendo.
  useEffect(() => {
    if (texto.trim()) setBuscando(true)
  }, [texto])

  useEffect(() => {
    const q = textoDebounced.trim()
    if (!q) {
      setResultados([])
      setBuscando(false)
      return
    }
    let cancelado = false
    supabase
      .from('productos')
      .select('id, nombre, codigo_barras, codigo_interno, precio_venta')
      .eq('estado', 'activo')
      .or(armarFiltroBusquedaProducto(q))
      .order('nombre')
      .limit(8)
      .then(({ data }) => {
        if (cancelado) return
        setResultados((data ?? []) as ProductoBusquedaItem[])
        setHighlighted(0)
        setBuscando(false)
      })
    return () => {
      cancelado = true
    }
  }, [textoDebounced])

  function agregar(p: ProductoBusquedaItem) {
    onAgregar({
      productoId: p.id,
      nombre: p.nombre,
      codigo: p.codigo_barras ?? p.codigo_interno ?? '',
      precioUnitario: p.precio_venta,
    })
    setTexto('')
    setResultados([])
    inputRef.current?.focus()
  }

  function onKeyDown(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'ArrowDown') {
      if (resultados.length) {
        e.preventDefault()
        setHighlighted((h) => (h + 1) % resultados.length)
      }
    } else if (e.key === 'ArrowUp') {
      if (resultados.length) {
        e.preventDefault()
        setHighlighted((h) => (h - 1 + resultados.length) % resultados.length)
      }
    } else if (e.key === 'Enter') {
      // Si hay resultados, este Enter agrega el producto y no debe llegar al atajo global de "Cobrar".
      // Si el buscador está vacío/sin resultados, dejamos que el evento burbujee: ahí Enter sí cobra.
      if (resultados.length) {
        e.preventDefault()
        e.stopPropagation()
        agregar(resultados[highlighted] ?? resultados[0])
      }
    } else if (e.key === 'Escape') {
      // Con texto cargado, Escape solo limpia el buscador. Vacío, burbujea al atajo global (cancela la venta).
      if (texto.trim()) {
        e.preventDefault()
        e.stopPropagation()
        setTexto('')
        setResultados([])
      }
    }
  }

  return (
    <div className="relative">
      <input
        ref={inputRef}
        autoFocus
        value={texto}
        onChange={(e) => setTexto(e.target.value)}
        onKeyDown={onKeyDown}
        placeholder="Buscar por nombre, marca o código de barras..."
        className="w-full rounded-lg border-2 border-line bg-surface px-5 py-4 font-sans text-body-lg text-ink outline-none focus:border-accent"
      />
      {texto.trim() && (
        <div className="absolute z-10 mt-1 w-full overflow-hidden rounded-lg border border-line bg-surface shadow-sm">
          {buscando && <p className="px-4 py-3 font-sans text-body-md text-ink-soft">Buscando...</p>}
          {!buscando && resultados.length === 0 && (
            <p className="px-4 py-3 font-sans text-body-md text-ink-soft">Sin resultados.</p>
          )}
          {resultados.map((p, i) => (
            <button
              key={p.id}
              type="button"
              onClick={() => agregar(p)}
              className={[
                'flex w-full items-center justify-between px-4 py-3 text-left font-sans',
                i === highlighted ? 'bg-accent-light' : 'hover:bg-bg',
              ].join(' ')}
            >
              <span>
                <span className="block text-body-lg text-ink">{p.nombre}</span>
                <span className="block text-label-md text-ink-soft">{p.codigo_barras ?? p.codigo_interno ?? '—'}</span>
              </span>
              <span className="font-sans text-label-bold text-accent-darker">{formatCurrency(p.precio_venta)}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
