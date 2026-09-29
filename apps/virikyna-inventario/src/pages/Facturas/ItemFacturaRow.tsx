import { useEffect, useRef, useState, type RefObject } from 'react'
import type { Producto, Proveedor, RolUsuario, UbicacionStock } from '@virikyna/shared'
import {
  armarFiltroBusquedaProducto,
  codigoBarrasCoincide,
  DropdownFlotante,
  formatCurrency,
  ScanButton,
  totalItemFacturaCompra,
  useDebouncedValue,
  type ItemFacturaCompraUI,
} from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { resolverCodigoBarras } from '../../lib/productos'
import { Field, inputClass, selectClass } from '../../components/FormField'
import { IconPapelera } from '../../components/icons'
import { ProductoFormSheet } from '../Inventario/ProductoFormSheet'

type ProductoBusquedaItem = Pick<Producto, 'id' | 'nombre' | 'marca' | 'costo' | 'codigo_barras'>

// Resultado de buscar un código escaneado que NO terminó vinculando el ítem a un producto: se
// muestra dentro de la tarjeta y la persona elige qué hacer (nunca se abre el alta sola).
type AvisoCodigo =
  | { tipo: 'no_encontrado'; codigo: string }
  | { tipo: 'inactivo'; codigo: string; producto: ProductoBusquedaItem }
  | { tipo: 'error'; codigo: string; mensaje: string }

type Props = {
  item: ItemFacturaCompraUI
  index: number
  puedeEliminar: boolean
  proveedores: Proveedor[]
  rol: RolUsuario
  // Marcado por la validación de "Guardar factura" (ej. sin producto seleccionado).
  error?: string
  // Cada vez que cambia (> 0) enfoca "Cód. barras" y trae la tarjeta a la vista — ítem recién
  // agregado o siguiente ítem tras un escaneo con lector, para seguir sin tocar la pantalla.
  focoCodigo?: number
  onChange: (cambios: Partial<ItemFacturaCompraUI>) => void
  onEliminar: () => void
  // Lector físico: el Enter al final de una lectura que encontró el producto pasa al ítem
  // siguiente (o crea uno nuevo), así se escanean varios seguidos sin tocar la pantalla.
  onAvanzar: () => void
}

// Botón de escaneo con la altura de los inputs (~56px) para que sea cómodo de tocar con el dedo.
// Mismo criterio de tamaño táctil que el resto de los botones de esta app (mínimo 44px).
const SCAN_BUTTON_CLASS =
  'flex w-14 flex-shrink-0 items-center justify-center rounded border border-accent/40 bg-accent-light text-accent-darker active:bg-accent active:text-white'

const BOTON_AVISO_CLASS =
  'min-h-11 rounded border px-3 font-sans text-label-bold active:opacity-80'

// Tarjeta de ítem de una factura de compra en el celular — mismos campos y mismo orden que la
// planilla de Virikyna Local/Gestión (Cód. barras → Producto → Marca → Cant. → Precio → Desc. →
// Depósito → Subtotal), pero apilados: una planilla no entra en 360px.
//
// DEUDA TÉCNICA: esta tarjeta es una copia casi idéntica (búsqueda, autoselección por código,
// "+ Crear producto nuevo") de packages/shared/src/components/ItemFacturaRow.tsx, que usan Local y
// Gestión como fila de planilla. Un arreglo en una no llega sola a la otra — evaluar extraer la
// lógica común (hook useItemFacturaBusqueda) y dejar en cada app solo el markup.
//
// La búsqueda de producto se dispara desde "Cód. barras" (tipeado, lector o cámara) o desde
// "Producto" (nombre/marca); ambas usan la misma búsqueda unificada y comparten un único
// dropdown de sugerencias anclado al campo que la disparó. Sin match el ítem queda "libre" (sin
// producto_id) y Producto/Marca se cargan a mano. Un código escaneado que no aparece NO abre el
// alta directo: se avisa en la tarjeta y se ofrece crear, buscar por nombre o reintentar — antes
// una lectura errónea de la cámara terminaba dando de alta de nuevo un producto ya cargado.
export function ItemFacturaRow({
  item,
  index,
  puedeEliminar,
  proveedores,
  rol,
  error,
  focoCodigo = 0,
  onChange,
  onEliminar,
  onAvanzar,
}: Props) {
  const [resultados, setResultados] = useState<ProductoBusquedaItem[]>([])
  const [query, setQuery] = useState('')
  const [campoActivo, setCampoActivo] = useState<'codigo' | 'producto' | null>(null)
  const [creandoProducto, setCreandoProducto] = useState(false)
  const [crearInicial, setCrearInicial] = useState<{ nombre: string; codigoBarras?: string }>({ nombre: '' })
  const [avisoCodigo, setAvisoCodigo] = useState<AvisoCodigo | null>(null)
  const [buscandoCodigo, setBuscandoCodigo] = useState(false)
  const queryDebounced = useDebouncedValue(query, 200)
  const tarjetaRef = useRef<HTMLDivElement>(null)
  const codigoRef = useRef<HTMLInputElement>(null)
  const productoRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (!focoCodigo) return
    tarjetaRef.current?.scrollIntoView({ behavior: 'smooth', block: 'center' })
    codigoRef.current?.focus({ preventScroll: true })
  }, [focoCodigo])

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
    setAvisoCodigo(null)
  }

  function buscarPorCodigo(texto: string) {
    onChange({ codigoBarras: texto, productoId: null })
    setQuery(texto)
    setCampoActivo('codigo')
    setAvisoCodigo(null)
  }

  function buscarPorProducto(texto: string) {
    onChange({ descripcion: texto, productoId: null })
    setQuery(texto)
    setCampoActivo('producto')
    setAvisoCodigo(null)
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

        // Lector de código de barras (teclado emulado): si lo que se tipeó matchea el
        // codigo_barras de un solo producto, se selecciona directo — el escaneo ya fue la confirmación.
        const matchExacto = encontrados.find((p) => codigoBarrasCoincide(p.codigo_barras, q))
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

  // Cámara, o Enter del lector físico en "Cód. barras": busca el código (con sus variantes) y
  // decide. Devuelve true si el ítem quedó vinculado a un producto.
  async function resolverCodigo(codigo: string): Promise<boolean> {
    const c = codigo.trim()
    if (!c) return false
    setResultados([])
    setQuery('')
    setCampoActivo(null)
    onChange({ codigoBarras: c, productoId: null })
    setBuscandoCodigo(true)
    const r = await resolverCodigoBarras(c)
    setBuscandoCodigo(false)

    if (r.tipo === 'encontrado') {
      seleccionarProducto(r.producto)
      return true
    }
    if (r.tipo === 'inactivo') setAvisoCodigo({ tipo: 'inactivo', codigo: c, producto: r.producto })
    else if (r.tipo === 'error') setAvisoCodigo({ tipo: 'error', codigo: c, mensaje: r.mensaje })
    else setAvisoCodigo({ tipo: 'no_encontrado', codigo: c })
    return false
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

  // "Usar este producto existente" desde el aviso de código duplicado del alta.
  async function usarExistente(id: string) {
    const { data } = await supabase
      .from('productos')
      .select('id, nombre, marca, costo, codigo_barras')
      .eq('id', id)
      .maybeSingle()
    setCreandoProducto(false)
    if (data) seleccionarProducto(data as ProductoBusquedaItem)
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
    <div
      ref={tarjetaRef}
      data-item-key={item.key}
      className={`scroll-mt-4 rounded-lg border bg-surface p-4 shadow-sm ${error ? 'border-2 border-error' : 'border-line'}`}
    >
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

      {error && (
        <p role="alert" className="mt-1 rounded bg-error/10 px-3 py-2 font-sans text-label-bold text-error">
          {error}
        </p>
      )}

      <div className="mt-1 flex flex-col gap-stack-sm">
        <Field label="Cód. barras">
          <div className="flex items-stretch gap-2">
            <input
              ref={codigoRef}
              value={item.codigoBarras}
              onChange={(e) => buscarPorCodigo(e.target.value)}
              onFocus={() => setCampoActivo('codigo')}
              onBlur={() => setCampoActivo(null)}
              onKeyDown={async (e) => {
                if (e.key === 'Escape') setCampoActivo(null)
                // El lector físico manda Enter al terminar: nunca envía la factura (lo frena también
                // el <form>); acá resuelve el código y, si lo encontró, pasa al ítem siguiente.
                if (e.key === 'Enter') {
                  e.preventDefault()
                  if (await resolverCodigo(e.currentTarget.value)) onAvanzar()
                }
              }}
              placeholder="Escaneá o tipeá el código"
              className={`${inputClass} min-w-0 flex-1`}
            />
            <ScanButton
              onDetect={(codigo) => {
                resolverCodigo(codigo)
              }}
              onFocusCampo={() => codigoRef.current?.focus()}
              className={SCAN_BUTTON_CLASS}
            />
          </div>
        </Field>
        {mostrarDropdownCodigo && sugerencias('codigo', codigoRef)}

        {buscandoCodigo && <p className="font-sans text-label-md text-ink-soft">Buscando código…</p>}

        {avisoCodigo && (
          <div
            role="status"
            className={`rounded border px-3 py-3 font-sans text-body-md ${
              avisoCodigo.tipo === 'no_encontrado' ? 'border-accent/50 bg-accent-light/40' : 'border-error/40 bg-error/10'
            }`}
          >
            {avisoCodigo.tipo === 'no_encontrado' && (
              <>
                <p className="text-ink">
                  No encontramos el código <strong className="break-all">{avisoCodigo.codigo}</strong> en el
                  inventario.
                </p>
                <p className="mt-1 font-sans text-label-md text-ink-soft">
                  Si el producto ya está cargado, compará este número con el de la etiqueta o buscalo por nombre.
                </p>
                <div className="mt-2 flex flex-wrap gap-2">
                  <button
                    type="button"
                    onClick={() => {
                      setAvisoCodigo(null)
                      productoRef.current?.focus()
                    }}
                    className={`${BOTON_AVISO_CLASS} border-accent/60 text-accent-dark`}
                  >
                    Buscar por nombre
                  </button>
                  <button
                    type="button"
                    onClick={() => {
                      setAvisoCodigo(null)
                      abrirCrear({ nombre: item.descripcion.trim(), codigoBarras: avisoCodigo.codigo })
                    }}
                    className={`${BOTON_AVISO_CLASS} border-accent/60 text-accent-dark`}
                  >
                    Crear producto nuevo
                  </button>
                </div>
              </>
            )}

            {avisoCodigo.tipo === 'inactivo' && (
              <>
                <p className="text-ink">
                  El código corresponde a <strong>{avisoCodigo.producto.nombre}</strong>, que está{' '}
                  <strong>inactivo</strong> en el inventario.
                </p>
                <div className="mt-2 flex flex-wrap gap-2">
                  <button
                    type="button"
                    onClick={() => seleccionarProducto(avisoCodigo.producto)}
                    className={`${BOTON_AVISO_CLASS} border-error/50 text-error`}
                  >
                    Usarlo igual
                  </button>
                  <button
                    type="button"
                    onClick={() => {
                      setAvisoCodigo(null)
                      productoRef.current?.focus()
                    }}
                    className={`${BOTON_AVISO_CLASS} border-line text-ink-soft`}
                  >
                    Buscar otro
                  </button>
                </div>
              </>
            )}

            {avisoCodigo.tipo === 'error' && (
              <>
                <p className="text-error">{avisoCodigo.mensaje}</p>
                <div className="mt-2 flex flex-wrap gap-2">
                  <button
                    type="button"
                    onClick={() => resolverCodigo(avisoCodigo.codigo)}
                    className={`${BOTON_AVISO_CLASS} border-error/50 text-error`}
                  >
                    Reintentar
                  </button>
                </div>
              </>
            )}
          </div>
        )}

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
          accionExistente="usar"
          onEditarExistente={usarExistente}
          onClose={() => setCreandoProducto(false)}
          onSaved={(creado) => {
            setCreandoProducto(false)
            if (creado) seleccionarProducto(creado)
          }}
          onStockChanged={() => {}}
        />
      )}
    </div>
  )
}
