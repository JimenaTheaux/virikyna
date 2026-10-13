import { useEffect, useImperativeHandle, useRef, useState, type KeyboardEvent, type Ref, type RefObject } from 'react'
import type { Producto } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { armarFiltroBusquedaProducto, ProductoLinea, useDebouncedValue } from '@virikyna/shared'

export type ProductoVenta = Pick<
  Producto,
  'id' | 'nombre' | 'marca' | 'descripcion' | 'codigo_barras' | 'codigo_interno' | 'precio_venta'
>

// Lo que el padre puede hacer con el buscador además de enfocarlo: Ventas le pasa las teclas que
// llegan con el foco fuera de los campos (docs/04, módulo 3, "regla del buscador").
export type ProductoBusquedaControl = {
  escribir: (texto: string) => void
}

const SELECT_PRODUCTO_VENTA = 'id, nombre, marca, descripcion, codigo_barras, codigo_interno, precio_venta'

// Valor entre comillas para un filtro .or() de PostgREST: los códigos pueden traer , . : ( ).
function valorFiltro(v: string) {
  return `"${v.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`
}

// Producto activo cuyo código de barras o código interno es exactamente `codigo`. Acepta el código
// tipeado en otra caja (int-00042 → INT-00042), pero si eso da más de uno no elige.
async function buscarPorCodigoExacto(codigo: string): Promise<ProductoVenta | null> {
  const variantes = [...new Set([codigo, codigo.toUpperCase(), codigo.toLowerCase()])].map(valorFiltro).join(',')
  const { data } = await supabase
    .from('productos')
    .select(SELECT_PRODUCTO_VENTA)
    .eq('estado', 'activo')
    .or(`codigo_barras.in.(${variantes}),codigo_interno.in.(${variantes})`)
    .limit(3)
  const filas = (data ?? []) as ProductoVenta[]
  const exacto = filas.filter((p) => p.codigo_barras === codigo || p.codigo_interno === codigo)
  if (exacto.length === 1) return exacto[0]
  if (exacto.length === 0 && filas.length === 1) return filas[0]
  return null
}

type Props = {
  inputRef?: RefObject<HTMLInputElement>
  controlRef?: Ref<ProductoBusquedaControl>
  onElegir: (p: ProductoVenta) => void
  // 'ventas': el buscador grande de la pantalla de Ventas (body-lg). 'compacto': el del cambio en
  // Devolución / Cambio. Los dos toman el foco al montarse.
  variante?: 'ventas' | 'compacto'
}

// Buscador de productos para vender — Ventas y el cambio de una devolución usan este mismo
// componente (misma consulta, mismo renglón de resultado). Recibe tanto texto tipeado como lectura
// de código de barras (el lector envía el código y termina con Enter, igual que un tipeo rápido).
//
// Enter con texto (docs/04, módulo 3):
// - Si se eligió un resultado con ↑ ↓, agrega ese.
// - Si no, busca el código EXACTO en la base, sin esperar el debounce: si existe, lo agrega. Si no,
//   muestra la lista y no agrega nada — nunca el primer resultado parcial (un código que es parte
//   de otro traería el producto equivocado).
// Mientras se resuelve, el texto queda seleccionado: si el lector manda otro código, lo reemplaza.
export function ProductoBusqueda({ inputRef, controlRef, onElegir, variante = 'ventas' }: Props) {
  const ventas = variante === 'ventas'
  const propioRef = useRef<HTMLInputElement>(null)
  const ref = inputRef ?? propioRef
  const [texto, setTexto] = useState('')
  const [resultados, setResultados] = useState<ProductoVenta[]>([])
  // -1 = ninguno elegido: Enter solo agrega lo que se eligió con las flechas o un código exacto.
  const [highlighted, setHighlighted] = useState(-1)
  const [buscando, setBuscando] = useState(false)
  const textoDebounced = useDebouncedValue(texto, 200)
  // Texto actual para las búsquedas que terminan después de que el usuario siguió escribiendo.
  const textoRef = useRef(texto)
  textoRef.current = texto
  // Solo la última búsqueda parcial pisa los resultados.
  const pedidoRef = useRef(0)

  useImperativeHandle(controlRef, () => ({
    escribir(t: string) {
      setTexto((prev) => prev + t)
      ref.current?.focus()
    },
  }))

  // "Buscando..." aparece apenas se tipea (sin esperar el debounce) para que el buscador no se
  // quede mostrando resultados obsoletos mientras el usuario sigue escribiendo.
  useEffect(() => {
    setHighlighted(-1)
    if (texto.trim()) setBuscando(true)
  }, [texto])

  function buscarParcial(q: string) {
    const pedido = ++pedidoRef.current
    supabase
      .from('productos')
      .select(SELECT_PRODUCTO_VENTA)
      .eq('estado', 'activo')
      .or(armarFiltroBusquedaProducto(q))
      .order('nombre')
      .limit(8)
      .then(({ data }) => {
        if (pedido !== pedidoRef.current) return
        setResultados((data ?? []) as ProductoVenta[])
        setHighlighted(-1)
        setBuscando(false)
      })
  }

  useEffect(() => {
    const q = textoDebounced.trim()
    if (!q) {
      pedidoRef.current++
      setResultados([])
      setBuscando(false)
      return
    }
    buscarParcial(q)
  }, [textoDebounced])

  // `resuelto`: el texto con el que se encontró el producto. Si mientras tanto se escribió otra cosa
  // (el lector ya mandó el código siguiente), se agrega igual pero no se borra lo nuevo.
  function elegir(p: ProductoVenta, resuelto?: string) {
    onElegir(p)
    if (resuelto === undefined || textoRef.current.trim() === resuelto) {
      pedidoRef.current++
      setTexto('')
      setResultados([])
    }
    ref.current?.focus()
  }

  async function resolverEnter(q: string) {
    const exacto = await buscarPorCodigoExacto(q)
    if (exacto) {
      elegir(exacto, q)
      return
    }
    // Sin código exacto: la lista, ya (sin esperar el debounce). El cursor vuelve al final para
    // seguir escribiendo.
    if (textoRef.current.trim() !== q) return
    const input = ref.current
    if (input) input.setSelectionRange(input.value.length, input.value.length)
    buscarParcial(q)
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
        setHighlighted((h) => (h <= 0 ? resultados.length - 1 : h - 1))
      }
    } else if (e.key === 'Enter') {
      // Con texto en el buscador, Enter nunca llega al atajo global de "Cobrar". Solo con el
      // buscador vacío burbujea: ahí Enter sí cobra (Ventas).
      const q = texto.trim()
      if (!q) return
      e.preventDefault()
      e.stopPropagation()
      const elegido = highlighted >= 0 ? resultados[highlighted] : undefined
      if (elegido) {
        elegir(elegido)
        return
      }
      e.currentTarget.select()
      void resolverEnter(q)
    } else if (e.key === 'Escape') {
      // Con texto cargado, Escape solo limpia el buscador. Vacío, burbujea: en Ventas saca el foco
      // del buscador (atajos con letras activos); en Devolución / Cambio cierra el modal.
      if (texto.trim()) {
        e.preventDefault()
        e.stopPropagation()
        pedidoRef.current++
        setTexto('')
        setResultados([])
      }
    }
  }

  return (
    <div className="relative">
      <input
        ref={ref}
        autoFocus
        value={texto}
        onChange={(e) => setTexto(e.target.value)}
        onKeyDown={onKeyDown}
        placeholder="Buscar por nombre, marca o código de barras..."
        aria-label="Buscar producto"
        className={
          ventas
            ? 'w-full rounded-lg border-2 border-line bg-surface px-5 py-4 font-sans text-body-lg text-ink outline-none focus:border-accent'
            : 'w-full rounded border border-line bg-surface px-4 py-2.5 font-sans text-body-md text-ink outline-none focus:border-accent'
        }
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
              onClick={() => elegir(p)}
              className={[
                'block w-full px-4 text-left',
                ventas ? 'py-3' : 'py-2.5',
                i === highlighted ? 'bg-accent-light' : 'hover:bg-bg',
              ].join(' ')}
            >
              <ProductoLinea producto={p} precio={p.precio_venta} tamano={ventas ? 'lg' : 'md'} />
            </button>
          ))}
          {!buscando && resultados.length > 0 && (
            <p className="border-t border-line px-4 py-1.5 font-sans text-label-md text-ink-soft">
              Elegí con ↑ ↓ y Enter, o con un clic. Enter solo agrega directo un código exacto.
            </p>
          )}
        </div>
      )}
    </div>
  )
}
