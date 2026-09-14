import { useRef, useState } from 'react'
import type { Producto, Proveedor, UbicacionStock } from '@virikyna/shared'
import { formatCurrency, totalItemFacturaCompra, type ItemFacturaCompra } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { Field, inputClass, selectClass } from '../../components/FormField'
import { ProductoFormModal } from '../Inventario/ProductoFormModal'

type ProductoBusquedaItem = Pick<Producto, 'id' | 'nombre' | 'costo' | 'codigo_barras'>

type Props = {
  item: ItemFacturaCompra
  index: number
  puedeEliminar: boolean
  proveedores: Proveedor[]
  onChange: (cambios: Partial<ItemFacturaCompra>) => void
  onEliminar: () => void
}

// Fila de ítem de una factura de compra en Virikyna Gestión — búsqueda de producto por nombre O
// por código de barras (un lector USB/Bluetooth de mostrador "tipea" el código seguido de Enter,
// como si fuera un teclado — mismo criterio que en Virikyna Local, ver ItemFacturaRow ahí). Sin
// selección, el ítem queda "libre" (sin producto_id).
export function ItemFacturaRow({ item, index, puedeEliminar, proveedores, onChange, onEliminar }: Props) {
  const [resultados, setResultados] = useState<ProductoBusquedaItem[]>([])
  const [query, setQuery] = useState('')
  const [creandoProducto, setCreandoProducto] = useState(false)
  const debounceRef = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)

  function seleccionarProducto(p: ProductoBusquedaItem) {
    onChange({ productoId: p.id, descripcion: p.nombre, precioUnitarioSinIva: String(p.costo) })
    setResultados([])
    setQuery('')
  }

  function cambiarDescripcion(texto: string) {
    onChange({ descripcion: texto, productoId: null })
    setQuery(texto)

    if (debounceRef.current) clearTimeout(debounceRef.current)
    const q = texto.trim()
    if (q.length < 2) {
      setResultados([])
      return
    }
    debounceRef.current = setTimeout(async () => {
      const qEscaped = q.replace(/[%,]/g, '')
      const { data } = await supabase
        .from('productos')
        .select('id, nombre, costo, codigo_barras')
        .eq('estado', 'activo')
        .or(`nombre.ilike.%${qEscaped}%,codigo_barras.ilike.%${qEscaped}%`)
        .order('nombre')
        .limit(6)
      const encontrados = (data ?? []) as ProductoBusquedaItem[]

      const matchExacto = encontrados.find((p) => p.codigo_barras === q)
      if (matchExacto && encontrados.length === 1) {
        seleccionarProducto(matchExacto)
        return
      }

      setResultados(encontrados)
    }, 200)
  }

  const nombreNuevoProducto = query.trim() || item.descripcion.trim()
  const mostrarDropdown = resultados.length > 0 || query.trim().length >= 2

  return (
    <div className="rounded-lg border border-line bg-surface p-4">
      <div className="flex items-center justify-between">
        <span className="font-sans text-label-md text-ink-soft">Ítem {index + 1}</span>
        {puedeEliminar && (
          <button
            type="button"
            onClick={onEliminar}
            aria-label={`Quitar ítem ${index + 1}`}
            className="rounded p-1 font-sans text-body-md text-error hover:bg-error/10"
          >
            ✕
          </button>
        )}
      </div>

      <div className="mt-2 flex flex-col gap-stack-sm">
        <div className="relative">
          <Field
            label="Descripción"
            hint={
              item.productoId
                ? 'Vinculado a un producto del catálogo'
                : 'Ítem libre — o escribí el nombre / código de barras para buscar en el catálogo'
            }
          >
            <input
              value={item.descripcion}
              onChange={(e) => cambiarDescripcion(e.target.value)}
              className={inputClass}
            />
          </Field>
          {mostrarDropdown && (
            <div className="absolute z-10 mt-1 w-full overflow-hidden rounded-lg border border-line bg-surface shadow-sm">
              {resultados.map((p) => (
                <button
                  key={p.id}
                  type="button"
                  onClick={() => seleccionarProducto(p)}
                  className="flex w-full items-center justify-between px-4 py-2 text-left font-sans hover:bg-bg"
                >
                  <span className="text-body-md text-ink">{p.nombre}</span>
                  <span className="font-sans text-label-md text-ink-soft">Costo actual: {formatCurrency(p.costo)}</span>
                </button>
              ))}
              <button
                type="button"
                onClick={() => setCreandoProducto(true)}
                className="flex w-full items-center justify-between border-t border-line px-4 py-2 text-left font-sans text-accent-dark hover:bg-accent-light"
              >
                + Crear producto nuevo{nombreNuevoProducto ? ` "${nombreNuevoProducto}"` : ''}
              </button>
            </div>
          )}
        </div>

        <div className="grid grid-cols-2 gap-stack-sm">
          <Field label="Cantidad">
            <input
              type="number"
              inputMode="decimal"
              min="0"
              step="0.01"
              value={item.cantidad}
              onChange={(e) => onChange({ cantidad: e.target.value })}
              className={inputClass}
            />
          </Field>
          <Field label="Precio unit. sin IVA">
            <input
              type="number"
              inputMode="decimal"
              min="0"
              step="0.01"
              value={item.precioUnitarioSinIva}
              onChange={(e) => onChange({ precioUnitarioSinIva: e.target.value })}
              className={inputClass}
            />
          </Field>
        </div>

        <div className="grid grid-cols-2 gap-stack-sm">
          <Field label="Descuento %">
            <input
              type="number"
              inputMode="decimal"
              min="0"
              max="100"
              step="0.01"
              value={item.descuentoPorcentaje}
              onChange={(e) => onChange({ descuentoPorcentaje: e.target.value })}
              className={inputClass}
            />
          </Field>
          <Field label="Depósito">
            <select
              value={item.ubicacion}
              onChange={(e) => onChange({ ubicacion: e.target.value as UbicacionStock })}
              className={selectClass}
            >
              <option value="local">Local</option>
              <option value="deposito">Depósito</option>
            </select>
          </Field>
        </div>

        <p className="text-right font-sans text-label-bold text-ink">
          Subtotal: {formatCurrency(totalItemFacturaCompra(item))}
        </p>
      </div>

      {creandoProducto && (
        <ProductoFormModal
          proveedores={proveedores}
          nombreInicial={nombreNuevoProducto}
          onClose={() => setCreandoProducto(false)}
          onSaved={(creado) => {
            setCreandoProducto(false)
            if (creado) {
              onChange({ productoId: creado.id, descripcion: creado.nombre, precioUnitarioSinIva: String(creado.costo) })
              setResultados([])
              setQuery('')
            }
          }}
          onStockChanged={() => {}}
        />
      )}
    </div>
  )
}
