import { useEffect, useState } from 'react'
import type { Producto, Proveedor, UbicacionStock } from '@virikyna/shared'
import {
  formatCurrency,
  totalItemFacturaCompra,
  armarFiltroBusquedaProducto,
  useDebouncedValue,
  nuevoItemFacturaCompra,
  type ItemFacturaCompra,
} from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { usePerfil } from '../../auth/AuthContext'
import { selectClass } from '../../components/FormField'
import { ProductoFormSheet } from '../Inventario/ProductoFormSheet'

// Extiende el ítem "real" (el que viaja al RPC `cargar_factura_compra`) con dos campos que
// solo existen para la UI de esta planilla y nunca se envían al backend:
// - marca: para ítems vinculados al catálogo es puramente informativa (ya vive en producto.marca,
//   recuperable vía producto_id); para ítems libres se pega dentro de `descripcion` recién al
//   guardar (ver CargarFacturaCompraModal), porque no existe una columna de marca por ítem.
// - codigoBarras: solo dispara la búsqueda de producto, no se persiste (un ítem libre no tiene
//   código de barras propio en el catálogo).
export type ItemFacturaCompraUI = ItemFacturaCompra & { marca: string; codigoBarras: string }

export function nuevoItemFacturaCompraUI(): ItemFacturaCompraUI {
  return { ...nuevoItemFacturaCompra(), marca: '', codigoBarras: '' }
}

type ProductoBusquedaItem = Pick<Producto, 'id' | 'nombre' | 'marca' | 'costo' | 'codigo_barras'>

type Props = {
  item: ItemFacturaCompraUI
  index: number
  puedeEliminar: boolean
  proveedores: Proveedor[]
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
// usan la misma búsqueda unificada (packages/shared/lib/productoBusqueda.ts) y comparten un único
// dropdown de sugerencias que aparece debajo de la celda que la disparó. Sin match, el ítem queda
// "libre" (sin producto_id) y Producto/Marca se cargan a mano, sin bloquear.
export function ItemFacturaRow({ item, index, puedeEliminar, proveedores, onChange, onEliminar }: Props) {
  const { rol } = usePerfil()
  const [resultados, setResultados] = useState<ProductoBusquedaItem[]>([])
  const [query, setQuery] = useState('')
  const [campoActivo, setCampoActivo] = useState<'codigo' | 'producto' | null>(null)
  const [creandoProducto, setCreandoProducto] = useState(false)
  const queryDebounced = useDebouncedValue(query, 200)

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

  const nombreNuevoProducto = query.trim() || item.descripcion.trim()
  const mostrarDropdownCodigo = campoActivo === 'codigo' && (resultados.length > 0 || query.trim().length >= 2)
  const mostrarDropdownProducto = campoActivo === 'producto' && (resultados.length > 0 || query.trim().length >= 2)

  function Sugerencias() {
    return (
      <div className="absolute left-0 z-10 mt-1 w-64 overflow-hidden rounded-lg border border-line bg-surface shadow-sm">
        {resultados.map((p) => (
          <button
            key={p.id}
            type="button"
            onClick={() => seleccionarProducto(p)}
            className="flex w-full flex-col items-start px-3 py-2 text-left font-sans hover:bg-bg"
          >
            <span className="text-body-md text-ink">{p.nombre}</span>
            <span className="font-sans text-label-md text-ink-soft">
              {p.marca ? `${p.marca} · ` : ''}Costo actual: {formatCurrency(p.costo)}
            </span>
          </button>
        ))}
        <button
          type="button"
          onClick={() => setCreandoProducto(true)}
          className="flex w-full items-center px-3 py-2 text-left font-sans text-label-md text-accent-dark hover:bg-accent-light"
        >
          + Crear producto nuevo{nombreNuevoProducto ? ` "${nombreNuevoProducto}"` : ''}
        </button>
      </div>
    )
  }

  return (
    <tr className="border-b border-line last:border-b-0 hover:bg-bg/60">
      <td className="relative px-2 py-1.5 align-top">
        <input
          value={item.codigoBarras}
          onChange={(e) => buscarPorCodigo(e.target.value)}
          onFocus={() => setCampoActivo('codigo')}
          placeholder="Escaneá o tipeá"
          className={cellInputClass}
        />
        {mostrarDropdownCodigo && <Sugerencias />}
      </td>
      <td className="relative px-2 py-1.5 align-top">
        <input
          value={item.descripcion}
          onChange={(e) => buscarPorProducto(e.target.value)}
          onFocus={() => setCampoActivo('producto')}
          placeholder="Buscar por código, nombre o marca..."
          className={cellInputClass}
        />
        {mostrarDropdownProducto && <Sugerencias />}
      </td>
      <td className="px-2 py-1.5 align-top">
        <input
          value={item.marca}
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

      {creandoProducto && rol && (
        <ProductoFormSheet
          proveedores={proveedores}
          rol={rol}
          nombreInicial={nombreNuevoProducto}
          onClose={() => setCreandoProducto(false)}
          onSaved={(creado) => {
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
          }}
          onStockChanged={() => {}}
        />
      )}
    </tr>
  )
}
