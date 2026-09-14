import { lazy, Suspense, useRef, useState } from 'react'
import type { Producto, Proveedor, RolUsuario, UbicacionStock } from '@virikyna/shared'
import { formatCurrency, totalItemFacturaCompra, type ItemFacturaCompra } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { buscarProductoPorCodigoBarras } from '../../lib/productos'
import { Field, inputClass, selectClass } from '../../components/FormField'
import { IconCamara, IconPapelera } from '../../components/icons'
import { ProductoFormSheet } from '../Inventario/ProductoFormSheet'

const BarcodeScanner = lazy(() => import('../../components/BarcodeScanner'))

type ProductoBusquedaItem = Pick<Producto, 'id' | 'nombre' | 'costo' | 'codigo_barras'>

type Props = {
  item: ItemFacturaCompra
  index: number
  puedeEliminar: boolean
  proveedores: Proveedor[]
  rol: RolUsuario
  onChange: (cambios: Partial<ItemFacturaCompra>) => void
  onEliminar: () => void
}

// Fila de ítem de una factura de compra en el celular — buscar por nombre O código de barras
// tipeando en el campo de descripción (igual que en Virikyna Local/Gestión), o escanear con la
// cámara. El escaneo vive ACÁ (no en la página) para que, si el código no existe todavía, se
// pueda pasar directo a "crear producto nuevo" con el código ya cargado — antes, un código no
// encontrado solo mostraba un error y pedía completar todo a mano de nuevo.
export function ItemFacturaRow({ item, index, puedeEliminar, proveedores, rol, onChange, onEliminar }: Props) {
  const [resultados, setResultados] = useState<ProductoBusquedaItem[]>([])
  const [query, setQuery] = useState('')
  const [creandoProducto, setCreandoProducto] = useState(false)
  const [codigoBarrasParaCrear, setCodigoBarrasParaCrear] = useState<string | undefined>(undefined)
  const [escaneando, setEscaneando] = useState(false)
  const [errorEscaneo, setErrorEscaneo] = useState<string | null>(null)
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

  async function handleEscaneo(codigo: string) {
    setEscaneando(false)
    setErrorEscaneo(null)

    const producto = await buscarProductoPorCodigoBarras(codigo)
    if (producto) {
      onChange({ productoId: producto.id, descripcion: producto.nombre, precioUnitarioSinIva: String(producto.costo) })
      setResultados([])
      setQuery('')
      return
    }

    // No existe todavía: en vez de un error que obliga a completar todo a mano, pasamos directo
    // a "crear producto nuevo" con el código ya cargado (ProductoFormSheet lo toma como
    // codigoBarrasInicial) — un solo escaneo alcanza para el caso más común: mercadería nueva
    // que nunca se cargó al catálogo.
    setCodigoBarrasParaCrear(codigo)
    setCreandoProducto(true)
  }

  const nombreNuevoProducto = query.trim() || item.descripcion.trim()
  const mostrarDropdown = resultados.length > 0 || query.trim().length >= 2

  return (
    <div className="rounded-lg border border-line bg-surface p-4">
      <div className="flex items-center justify-between">
        <span className="font-sans text-label-md text-ink-soft">Ítem {index + 1}</span>
        <div className="flex items-center gap-1">
          <button
            type="button"
            onClick={() => {
              setErrorEscaneo(null)
              setEscaneando(true)
            }}
            aria-label="Escanear código de barras del producto"
            className="rounded p-2 text-accent-dark hover:bg-accent-light"
          >
            <IconCamara className="h-5 w-5" />
          </button>
          {puedeEliminar && (
            <button
              type="button"
              onClick={onEliminar}
              aria-label="Quitar ítem"
              className="rounded p-2 text-error hover:bg-error/10"
            >
              <IconPapelera className="h-5 w-5" />
            </button>
          )}
        </div>
      </div>

      <div className="mt-2 flex flex-col gap-stack-sm">
        {errorEscaneo && (
          <p className="rounded bg-error/10 px-3 py-2 font-sans text-label-md text-error">{errorEscaneo}</p>
        )}

        <div className="relative">
          <Field
            label="Descripción"
            hint={
              item.productoId
                ? 'Vinculado a un producto del catálogo'
                : 'Ítem libre — escribí el nombre / código de barras, o escaneá con la cámara'
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
                onClick={() => {
                  setCodigoBarrasParaCrear(undefined)
                  setCreandoProducto(true)
                }}
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

      {escaneando && (
        <Suspense fallback={null}>
          <BarcodeScanner onDetect={handleEscaneo} onClose={() => setEscaneando(false)} />
        </Suspense>
      )}

      {creandoProducto && (
        <ProductoFormSheet
          proveedores={proveedores}
          rol={rol}
          nombreInicial={nombreNuevoProducto}
          codigoBarrasInicial={codigoBarrasParaCrear}
          onClose={() => {
            setCreandoProducto(false)
            setCodigoBarrasParaCrear(undefined)
          }}
          onSaved={(creado) => {
            setCreandoProducto(false)
            setCodigoBarrasParaCrear(undefined)
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
