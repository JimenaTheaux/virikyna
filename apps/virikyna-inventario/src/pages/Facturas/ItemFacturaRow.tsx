import { useEffect, useRef, useState, type RefObject } from 'react'
import type { Producto, Proveedor, RolUsuario, UbicacionStock } from '@virikyna/shared'
import {
  armarFiltroBusquedaProducto,
  DropdownFlotante,
  formatCurrency,
  ScanButton,
  totalItemFacturaCompra,
  useDebouncedValue,
  type ItemFacturaCompraUI,
} from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { buscarProductoPorCodigoBarras } from '../../lib/productos'
import { Field, inputClass, selectClass } from '../../components/FormField'
import { IconPapelera } from '../../components/icons'
import { ProductoFormSheet } from '../Inventario/ProductoFormSheet'

type ProductoBusquedaItem = Pick<Producto, 'id' | 'nombre' | 'marca' | 'costo' | 'codigo_barras'>

type Props = {
  item: ItemFacturaCompraUI
  index: number
  puedeEliminar: boolean
  proveedores: Proveedor[]
  rol: RolUsuario
  onChange: (cambios: Partial<ItemFacturaCompraUI>) => void
  onEliminar: () => void
}

// Botón de escaneo con la altura de los inputs (~56px) para que sea cómodo de tocar con el dedo.
// Mismo criterio de tamaño táctil que el resto de los botones de esta app (mínimo 44px).
const SCAN_BUTTON_CLASS =
  'flex w-14 flex-shrink-0 items-center justify-center rounded border border-accent/40 bg-accent-light text-accent-darker active:bg-accent active:text-white'

// Tarjeta de ítem de una factura de compra en el celular — mismos campos y mismo orden que la
// planilla de Virikyna Local/Gestión (Cód. barras → Producto → Marca → Cant. → Precio → Desc. →
// Depósito → Subtotal), pero apilados: una planilla no entra en 360px.
//
// La búsqueda de producto se dispara desde "Cód. barras" (tipeado o escaneando con la cámara) o
// desde "Producto" (nombre/marca); ambas usan la misma búsqueda unificada y comparten un único
// dropdown de sugerencias anclado al campo que la disparó. Sin match el ítem queda "libre" (sin
// producto_id) y Producto/Marca se cargan a mano. El escaneo de un código que todavía no existe
// pasa directo a "crear producto nuevo" con el código ya cargado.
export function ItemFacturaRow({ item, index, puedeEliminar, proveedores, rol, onChange, onEliminar }: Props) {
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
        // codigo_barras de un solo producto, se selecciona directo — el escaneo ya fue la confirmación.
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

  async function handleEscaneo(codigo: string) {
    setResultados([])
    setQuery('')
    setCampoActivo(null)

    const producto = await buscarProductoPorCodigoBarras(codigo)
    if (producto) {
      seleccionarProducto(producto)
      return
    }

    // No existe todavía: en vez de un error que obliga a completar todo a mano, pasamos directo a
    // "crear producto nuevo" con el código ya cargado — un solo escaneo alcanza para el caso más
    // común: mercadería nueva que nunca se cargó al catálogo.
    onChange({ codigoBarras: codigo, productoId: null })
    abrirCrear({ nombre: item.descripcion.trim(), codigoBarras: codigo })
  }

  function abrirCrear(inicial: { nombre: string; codigoBarras?: string }) {
    setCrearInicial(inicial)
    setCreandoProducto(true)
    setCampoActivo(null)
  }

  // Desde el campo de código el texto tipeado es el código (no el nombre); desde el de producto,
  // es el nombre.
  function crearDesdeCampo(campo: 'codigo' | 'producto') {
    const texto = query.trim()
    abrirCrear(
      campo === 'codigo'
        ? { nombre: item.descripcion.trim(), codigoBarras: texto || undefined }
        : { nombre: texto || item.descripcion.trim(), codigoBarras: item.codigoBarras.trim() || undefined },
    )
  }

  const mostrarDropdownCodigo = campoActivo === 'codigo' && (resultados.length > 0 || query.trim().length >= 2)
  const mostrarDropdownProducto = campoActivo === 'producto' && (resultados.length > 0 || query.trim().length >= 2)

  function sugerencias(campo: 'codigo' | 'producto', anchorRef: RefObject<HTMLElement>) {
    const textoCrear = query.trim()
    return (
      <DropdownFlotante anchorRef={anchorRef} ancho="ancla">
        {resultados.map((p) => (
          <button
            key={p.id}
            type="button"
            onClick={() => seleccionarProducto(p)}
            className="flex min-h-11 w-full flex-col items-start justify-center border-b border-line px-4 py-2 text-left font-sans active:bg-bg"
          >
            <span className="text-body-md text-ink">{p.nombre}</span>
            <span className="font-sans text-label-md text-ink-soft">
              {p.marca ? `${p.marca} · ` : ''}Costo actual: {formatCurrency(p.costo)}
            </span>
          </button>
        ))}
        <button
          type="button"
          onClick={() => crearDesdeCampo(campo)}
          className="flex min-h-11 w-full items-center px-4 py-2 text-left font-sans text-label-bold text-accent-dark active:bg-accent-light"
        >
          + Crear producto nuevo{textoCrear ? ` ${campo === 'codigo' ? 'con código ' : ''}"${textoCrear}"` : ''}
        </button>
      </DropdownFlotante>
    )
  }

  return (
    <div className="rounded-lg border border-line bg-surface p-4 shadow-sm">
      <div className="flex items-center justify-between">
        <span className="font-sans text-label-bold text-ink-soft">Ítem {index + 1}</span>
        {puedeEliminar && (
          <button
            type="button"
            onClick={onEliminar}
            aria-label={`Quitar ítem ${index + 1}`}
            className="-mr-2 flex h-11 w-11 items-center justify-center rounded text-error active:bg-error/10"
          >
            <IconPapelera className="h-5 w-5" />
          </button>
        )}
      </div>

      <div className="mt-1 flex flex-col gap-stack-sm">
        <Field label="Cód. barras">
          <div className="flex items-stretch gap-2">
            <input
              ref={codigoRef}
              value={item.codigoBarras}
              onChange={(e) => buscarPorCodigo(e.target.value)}
              onFocus={() => setCampoActivo('codigo')}
              onBlur={() => setCampoActivo(null)}
              onKeyDown={(e) => {
                if (e.key === 'Escape') setCampoActivo(null)
                // El lector físico manda Enter al terminar: no debe enviar la factura.
                if (e.key === 'Enter') e.preventDefault()
              }}
              placeholder="Escaneá o tipeá el código"
              className={`${inputClass} min-w-0 flex-1`}
            />
            <ScanButton
              onDetect={handleEscaneo}
              onFocusCampo={() => codigoRef.current?.focus()}
              className={SCAN_BUTTON_CLASS}
            />
          </div>
        </Field>
        {mostrarDropdownCodigo && sugerencias('codigo', codigoRef)}

        <Field
          label="Producto"
          hint={item.productoId ? 'Vinculado a un producto del catálogo' : 'Ítem libre — escribí nombre o marca para buscar'}
        >
          <input
            ref={productoRef}
            value={item.descripcion}
            onChange={(e) => buscarPorProducto(e.target.value)}
            onFocus={() => setCampoActivo('producto')}
            onBlur={() => setCampoActivo(null)}
            onKeyDown={(e) => {
              if (e.key === 'Escape') setCampoActivo(null)
              if (e.key === 'Enter') e.preventDefault()
            }}
            placeholder="Buscar por nombre o marca"
            className={inputClass}
          />
        </Field>
        {mostrarDropdownProducto && sugerencias('producto', productoRef)}

        <Field label="Marca">
          <input
            value={item.marca}
            onChange={(e) => onChange({ marca: e.target.value })}
            placeholder="—"
            className={inputClass}
          />
        </Field>

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
        <ProductoFormSheet
          proveedores={proveedores}
          rol={rol}
          nombreInicial={crearInicial.nombre}
          codigoBarrasInicial={crearInicial.codigoBarras}
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
            }
          }}
          onStockChanged={() => {}}
        />
      )}
    </div>
  )
}
