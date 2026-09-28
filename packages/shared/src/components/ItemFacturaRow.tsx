import { useEffect, useRef, useState, type ReactNode, type RefObject } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Producto, Proveedor, UbicacionStock } from '../../types/database'
import { formatCurrency } from '../../lib/format'
import { totalItemFacturaCompra, type ItemFacturaCompraUI } from '../../lib/facturasCompra'
import { armarFiltroBusquedaProducto } from '../../lib/productoBusqueda'
import { useDebouncedValue } from '../../lib/useDebouncedValue'
import { selectClass } from './FormField'
import { DropdownFlotante } from './DropdownFlotante'

// Lo que necesita la planilla de un producto recién creado para dejar el ítem vinculado.
export type ProductoCreadoFactura = {
  id: string
  nombre: string
  costo: number
  marca: string | null
  codigo_barras: string | null
}

// Cada app aporta su propio formulario de producto (Local: ProductoFormSheet con rol; Gestión:
// ProductoFormModal) — la planilla solo lo monta cuando se elige "+ Crear producto nuevo".
export type CrearProductoRender = (args: {
  proveedores: Proveedor[]
  nombreInicial: string
  // Al crear desde la celda "Cód. barras" el código tipeado/escaneado va acá — nunca como nombre.
  codigoBarrasInicial?: string
  onClose: () => void
  onSaved: (creado?: ProductoCreadoFactura) => void
}) => ReactNode

type ProductoBusquedaItem = Pick<Producto, 'id' | 'nombre' | 'marca' | 'costo' | 'codigo_barras'>

type Props = {
  supabase: SupabaseClient
  item: ItemFacturaCompraUI
  index: number
  puedeEliminar: boolean
  proveedores: Proveedor[]
  crearProducto: CrearProductoRender
  onChange: (cambios: Partial<ItemFacturaCompraUI>) => void
  onEliminar: () => void
}

const cellInputClass =
  'w-full rounded border border-transparent bg-transparent px-2 py-1.5 font-sans text-body-md text-ink outline-none focus:border-accent focus:bg-surface disabled:text-ink-soft'
const cellInputRightClass = `${cellInputClass} text-right`
const cellSelectClass = `${selectClass} !rounded !border-transparent !bg-transparent !px-2 !py-1.5 focus:!border-accent focus:!bg-surface`

// Fila de ítem de una factura de compra, en formato planilla (una <tr>, celdas editables inline).
// La búsqueda de producto puede dispararse desde la celda "Cód. barras" (pensada para un lector
// USB/Bluetooth que "tipea" el código y Enter) o desde la celda "Producto" (nombre/marca) — ambas
// usan la misma búsqueda unificada (lib/productoBusqueda.ts) y comparten un único
// dropdown de sugerencias que aparece debajo de la celda que la disparó. Sin match, el ítem queda
// "libre" (sin producto_id) y Producto/Marca se cargan a mano, sin bloquear.
export function ItemFacturaRow({
  supabase,
  item,
  index,
  puedeEliminar,
  proveedores,
  crearProducto,
  onChange,
  onEliminar,
}: Props) {
  const [resultados, setResultados] = useState<ProductoBusquedaItem[]>([])
  const [query, setQuery] = useState('')
  const [campoActivo, setCampoActivo] = useState<'codigo' | 'producto' | null>(null)
  const [creandoProducto, setCreandoProducto] = useState(false)
  const [crearInicial, setCrearInicial] = useState<{ nombre: string; codigoBarras?: string }>({ nombre: '' })
  const queryDebounced = useDebouncedValue(query, 200)
  const codigoRef = useRef<HTMLInputElement>(null)
  const productoRef = useRef<HTMLInputElement>(null)

  function seleccionarProducto(p: ProductoBusquedaItem) {
    onChange({
      productoId: p.id,
      descripcion: p.nombre,
      marca: p.marca ?? '',
      codigoBarras: p.codigo_barras ?? item.codigoBarras,
      precioUnitarioSinIva: String(p.costo),
    })
    setResultados([])
    setQuery('')
    setCampoActivo(null)
  }

  function buscarPorCodigo(texto: string) {
    onChange({ codigoBarras: texto, productoId: null })
    setQuery(texto)
    setCampoActivo('codigo')
  }

  function buscarPorProducto(texto: string) {
    onChange({ descripcion: texto, productoId: null })
    setQuery(texto)
    setCampoActivo('producto')
  }

  useEffect(() => {
    const q = queryDebounced.trim()
    if (!campoActivo || q.length < 2) {
      setResultados([])
      return
    }
    let cancelado = false
    supabase
      .from('productos')
      .select('id, nombre, marca, costo, codigo_barras')
      .eq('estado', 'activo')
      .or(armarFiltroBusquedaProducto(q))
      .order('nombre')
      .limit(6)
      .then(({ data }) => {
        if (cancelado) return
        const encontrados = (data ?? []) as ProductoBusquedaItem[]

        // Lector de código de barras (teclado emulado): si lo que se tipeó matchea EXACTO el
        // codigo_barras de un solo producto, seleccionalo directo — no tiene sentido pedirle al
        // cajero que además clickee el resultado, el escaneo ya fue la confirmación.
        const matchExacto = encontrados.find((p) => p.codigo_barras === q)
        if (campoActivo === 'codigo' && matchExacto && encontrados.length === 1) {
          seleccionarProducto(matchExacto)
          return
        }

        setResultados(encontrados)
      })
    return () => {
      cancelado = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [queryDebounced, campoActivo])

  // Desde la celda de código, lo tipeado es el código: el nombre queda vacío (o el que ya se hubiera
  // escrito en "Producto") para que se complete en el formulario. Desde la celda de producto, lo
  // tipeado es el nombre y el código se toma del ítem si ya lo tiene.
  function abrirCrear(campo: 'codigo' | 'producto') {
    const codigo = item.codigoBarras.trim() || undefined
    setCrearInicial(
      campo === 'codigo'
        ? { nombre: item.descripcion.trim(), codigoBarras: codigo }
        : { nombre: query.trim() || item.descripcion.trim(), codigoBarras: codigo },
    )
    setCreandoProducto(true)
    setCampoActivo(null)
  }

  const mostrarDropdownCodigo = campoActivo === 'codigo' && (resultados.length > 0 || query.trim().length >= 2)
  const mostrarDropdownProducto = campoActivo === 'producto' && (resultados.length > 0 || query.trim().length >= 2)

  function sugerencias(campo: 'codigo' | 'producto', anchorRef: RefObject<HTMLElement>) {
    const textoCrear = query.trim()
    return (
      <DropdownFlotante anchorRef={anchorRef}>
        {resultados.map((p) => (
          <button
            key={p.id}
            type="button"
            onClick={() => seleccionarProducto(p)}
            className="flex w-full flex-col items-start px-3 py-1.5 text-left font-sans hover:bg-bg"
          >
            <span className="text-body-md text-ink">{p.nombre}</span>
            <span className="font-sans text-label-md text-ink-soft">
              {p.marca ? `${p.marca} · ` : ''}Costo actual: {formatCurrency(p.costo)}
            </span>
          </button>
        ))}
        <button
          type="button"
          onClick={() => abrirCrear(campo)}
          className="flex w-full items-center px-3 py-1.5 text-left font-sans text-label-md text-accent-dark hover:bg-accent-light"
        >
          + Crear producto nuevo{textoCrear ? ` ${campo === 'codigo' ? 'con código ' : ''}"${textoCrear}"` : ''}
        </button>
      </DropdownFlotante>
    )
  }

  return (
    <tr className="border-b border-line last:border-b-0 hover:bg-bg/60">
      <td className="relative px-2 py-1.5 align-top">
        <input
          ref={codigoRef}
          value={item.codigoBarras}
          title={item.codigoBarras}
          onChange={(e) => buscarPorCodigo(e.target.value)}
          onFocus={() => setCampoActivo('codigo')}
          onBlur={() => setCampoActivo(null)}
          onKeyDown={(e) => e.key === 'Escape' && setCampoActivo(null)}
          placeholder="Escaneá o tipeá"
          className={cellInputClass}
        />
        {mostrarDropdownCodigo && sugerencias('codigo', codigoRef)}
      </td>
      <td className="relative px-2 py-1.5 align-top">
        <input
          ref={productoRef}
          value={item.descripcion}
          title={item.descripcion}
          onChange={(e) => buscarPorProducto(e.target.value)}
          onFocus={() => setCampoActivo('producto')}
          onBlur={() => setCampoActivo(null)}
          onKeyDown={(e) => e.key === 'Escape' && setCampoActivo(null)}
          placeholder="Buscar por código, nombre o marca..."
          className={cellInputClass}
        />
        {mostrarDropdownProducto && sugerencias('producto', productoRef)}
      </td>
      <td className="px-2 py-1.5 align-top">
        <input
          value={item.marca}
          title={item.marca}
          onChange={(e) => onChange({ marca: e.target.value })}
          placeholder="—"
          className={cellInputClass}
        />
      </td>
      <td className="px-2 py-1.5 align-top">
        <input
          type="number"
          inputMode="decimal"
          min="0"
          step="0.01"
          value={item.cantidad}
          onChange={(e) => onChange({ cantidad: e.target.value })}
          className={cellInputRightClass}
        />
      </td>
      <td className="px-2 py-1.5 align-top">
        <input
          type="number"
          inputMode="decimal"
          min="0"
          step="0.01"
          value={item.precioUnitarioSinIva}
          onChange={(e) => onChange({ precioUnitarioSinIva: e.target.value })}
          className={cellInputRightClass}
        />
      </td>
      <td className="px-2 py-1.5 align-top">
        <input
          type="number"
          inputMode="decimal"
          min="0"
          max="100"
          step="0.01"
          value={item.descuentoPorcentaje}
          onChange={(e) => onChange({ descuentoPorcentaje: e.target.value })}
          className={cellInputRightClass}
        />
      </td>
      <td className="px-2 py-1.5 align-top">
        <select
          value={item.ubicacion}
          title={item.ubicacion === 'deposito' ? 'Depósito' : 'Local'}
          onChange={(e) => onChange({ ubicacion: e.target.value as UbicacionStock })}
          className={cellSelectClass}
        >
          <option value="local">Local</option>
          <option value="deposito">Depósito</option>
        </select>
      </td>
      <td className="px-2 py-1.5 text-right align-top">
        <span className="font-sans text-label-bold text-ink">{formatCurrency(totalItemFacturaCompra(item))}</span>
      </td>
      <td className="px-2 py-1.5 text-center align-top">
        {puedeEliminar && (
          <button
            type="button"
            onClick={onEliminar}
            aria-label={`Quitar ítem ${index + 1}`}
            className="rounded p-1 font-sans text-body-md text-ink-soft hover:bg-error/10 hover:text-error"
          >
            ✕
          </button>
        )}
      </td>

      {creandoProducto &&
        crearProducto({
          proveedores,
          nombreInicial: crearInicial.nombre,
          codigoBarrasInicial: crearInicial.codigoBarras,
          onClose: () => setCreandoProducto(false),
          onSaved: (creado) => {
            setCreandoProducto(false)
            if (creado) {
              onChange({
                productoId: creado.id,
                descripcion: creado.nombre,
                marca: creado.marca ?? '',
                codigoBarras: creado.codigo_barras ?? item.codigoBarras,
                precioUnitarioSinIva: String(creado.costo),
              })
              setResultados([])
              setQuery('')
              setCampoActivo(null)
            }
          },
        })}
    </tr>
  )
}
