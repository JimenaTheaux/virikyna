import { useEffect, useRef, useState, type KeyboardEvent, type RefObject } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Producto } from '../../types/database'
import { formatCurrencyOpcional } from '../../lib/format'
import type { ItemFacturaCompraUI } from '../../lib/facturasCompra'
import { armarFiltroBusquedaProducto, codigoBarrasCoincide, resolverCodigoBarras } from '../../lib/productoBusqueda'
import { useDebouncedValue } from '../../lib/useDebouncedValue'
import { DropdownFlotante } from './DropdownFlotante'

// Lógica de búsqueda de producto de UN ítem de factura de compra — una sola copia para las dos
// presentaciones: la fila de planilla de escritorio (ItemFacturaRow, Local y Gestión) y la tarjeta
// de celular (apps/virikyna-inventario/src/pages/Facturas/ItemFacturaRow.tsx). Antes cada una
// tenía su copia y los arreglos no llegaban solos a la otra (ej. el Enter del lector se arregló
// primero en una y seguía roto en la otra). Acá vive todo lo que decide QUÉ pasa; cada pantalla
// solo pone el markup.
//
// La búsqueda se dispara desde "Cód. barras" (tipeado, lector físico o cámara) o desde "Producto"
// (nombre/marca); ambas usan la búsqueda unificada y comparten un único dropdown de sugerencias
// anclado al campo que la disparó. Sin match el ítem queda "libre" (sin producto_id). Un código
// que no aparece NUNCA abre el alta solo: se avisa (AvisoCodigoFactura) y la persona elige — antes
// una lectura errónea de la cámara terminaba dando de alta de nuevo un producto ya cargado.

// Incluye lo necesario para anticipar el precio de venta al guardar (ItemFacturaCompraUI.productoPrecio).
export type ProductoBusquedaItem = Pick<
  Producto,
  | 'id'
  | 'nombre'
  | 'marca'
  | 'costo'
  | 'codigo_barras'
  | 'margen_1'
  | 'margen_2'
  | 'iva_porcentaje'
  | 'proveedor_id'
  | 'precio_venta'
  | 'precio_manual'
>

const SELECT_PRODUCTO_ITEM =
  'id, nombre, marca, costo, codigo_barras, margen_1, margen_2, iva_porcentaje, proveedor_id, precio_venta, precio_manual'

export type AvisoCodigo =
  | { tipo: 'no_encontrado'; codigo: string }
  | { tipo: 'inactivo'; codigo: string; producto: ProductoBusquedaItem }
  | { tipo: 'error'; codigo: string; mensaje: string }

type CampoBusqueda = 'codigo' | 'producto'

type Opciones = {
  supabase: SupabaseClient
  item: ItemFacturaCompraUI
  onChange: (cambios: Partial<ItemFacturaCompraUI>) => void
  // Lector físico: el Enter al final de una lectura que encontró el producto pasa al ítem
  // siguiente (o crea uno), para escanear varios seguidos sin tocar la pantalla.
  onAvanzar?: () => void
  // Cada vez que cambia (> 0) enfoca "Cód. barras" y trae el ítem a la vista (ítem recién agregado
  // o siguiente tras un escaneo). `contenedorRef` es lo que se scrollea (la fila o la tarjeta).
  focoCodigo?: number
  contenedorRef?: RefObject<HTMLElement>
}

export function useItemFacturaBusqueda({ supabase, item, onChange, onAvanzar, focoCodigo = 0, contenedorRef }: Opciones) {
  const [resultados, setResultados] = useState<ProductoBusquedaItem[]>([])
  const [query, setQuery] = useState('')
  const [campoActivo, setCampoActivo] = useState<CampoBusqueda | null>(null)
  const [creandoProducto, setCreandoProducto] = useState(false)
  const [crearInicial, setCrearInicial] = useState<{ nombre: string; codigoBarras?: string }>({ nombre: '' })
  const [avisoCodigo, setAvisoCodigo] = useState<AvisoCodigo | null>(null)
  const [buscandoCodigo, setBuscandoCodigo] = useState(false)
  const queryDebounced = useDebouncedValue(query, 200)
  const codigoRef = useRef<HTMLInputElement>(null)
  const productoRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (!focoCodigo) return
    contenedorRef?.current?.scrollIntoView({ behavior: 'smooth', block: 'center' })
    codigoRef.current?.focus({ preventScroll: true })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [focoCodigo])

  function seleccionarProducto(p: ProductoBusquedaItem) {
    onChange({
      productoId: p.id,
      descripcion: p.nombre,
      marca: p.marca ?? '',
      codigoBarras: p.codigo_barras ?? item.codigoBarras,
      // Sin costo (producto de la carga inicial, docs/34): precio unitario vacío para cargarlo.
      precioUnitarioSinIva: p.costo === null ? '' : String(p.costo),
      // Elegir un producto (también "Usarlo igual" de un código inactivo) es la confirmación.
      productoInactivo: false,
      productoPrecio: {
        costo: p.costo === null ? null : Number(p.costo),
        margen_1: Number(p.margen_1),
        margen_2: Number(p.margen_2),
        iva_porcentaje: Number(p.iva_porcentaje),
        proveedor_id: p.proveedor_id,
        precio_venta: Number(p.precio_venta),
        precio_manual: p.precio_manual === null ? null : Number(p.precio_manual),
      },
    })
    setResultados([])
    setQuery('')
    setCampoActivo(null)
    setAvisoCodigo(null)
  }

  function buscarPorCodigo(texto: string) {
    onChange({ codigoBarras: texto, productoId: null, productoPrecio: null, productoInactivo: false })
    setQuery(texto)
    setCampoActivo('codigo')
    setAvisoCodigo(null)
  }

  function buscarPorProducto(texto: string) {
    onChange({ descripcion: texto, productoId: null, productoPrecio: null, productoInactivo: false })
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
      .select(SELECT_PRODUCTO_ITEM)
      .eq('estado', 'activo')
      .or(armarFiltroBusquedaProducto(q))
      .order('nombre')
      .limit(6)
      .then(({ data }) => {
        if (cancelado) return
        const encontrados = (data ?? []) as ProductoBusquedaItem[]

        // Lector de código de barras (teclado emulado): si lo tipeado matchea el código de un solo
        // producto, se selecciona directo — el escaneo ya fue la confirmación.
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

  // Cámara, o Enter del lector en "Cód. barras": busca el código (con sus variantes) y decide.
  // Devuelve true si el ítem quedó vinculado a un producto.
  async function resolverCodigo(codigo: string): Promise<boolean> {
    const c = codigo.trim()
    if (!c) return false
    setResultados([])
    setQuery('')
    setCampoActivo(null)
    onChange({ codigoBarras: c, productoId: null, productoPrecio: null, productoInactivo: false })
    setBuscandoCodigo(true)
    const r = await resolverCodigoBarras(supabase, c)
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
    setAvisoCodigo(null)
  }

  // Desde el campo de código lo tipeado es el código (nunca el nombre); desde el de producto, es
  // el nombre y el código se toma del ítem si ya lo tiene.
  function crearDesdeCampo(campo: CampoBusqueda) {
    const texto = query.trim()
    abrirCrear(
      campo === 'codigo'
        ? { nombre: item.descripcion.trim(), codigoBarras: texto || item.codigoBarras.trim() || undefined }
        : { nombre: texto || item.descripcion.trim(), codigoBarras: item.codigoBarras.trim() || undefined },
    )
  }

  // "Crear producto nuevo" desde el aviso de código no encontrado: el código va como código y el
  // nombre queda con lo que ya se hubiera escrito en "Producto".
  function crearDesdeAviso() {
    if (avisoCodigo) abrirCrear({ nombre: item.descripcion.trim(), codigoBarras: avisoCodigo.codigo })
  }

  function buscarPorNombre() {
    setAvisoCodigo(null)
    productoRef.current?.focus()
  }

  function cerrarCrear() {
    setCreandoProducto(false)
  }

  // Producto recién creado desde el formulario de alta. Se vuelve a leer: el formulario devuelve
  // solo lo básico y el ítem necesita también márgenes, IVA y precio de venta (productoPrecio).
  function alCrear(creado?: { id: string }) {
    if (creado) usarExistente(creado.id)
    else setCreandoProducto(false)
  }

  // "Usar este producto existente" desde el aviso de código duplicado del alta.
  async function usarExistente(id: string) {
    const { data } = await supabase.from('productos').select(SELECT_PRODUCTO_ITEM).eq('id', id).maybeSingle()
    setCreandoProducto(false)
    if (data) seleccionarProducto(data as ProductoBusquedaItem)
  }

  function onKeyDownCodigo(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'Escape') setCampoActivo(null)
    // El lector manda Enter al terminar: nunca envía la factura (lo frena también el <form>); acá
    // resuelve el código y, si lo encontró, pasa al ítem siguiente.
    if (e.key === 'Enter') {
      e.preventDefault()
      const valor = e.currentTarget.value
      resolverCodigo(valor).then((vinculado) => {
        if (vinculado) onAvanzar?.()
      })
    }
  }

  function onKeyDownProducto(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'Escape') setCampoActivo(null)
    if (e.key === 'Enter') e.preventDefault()
  }

  const hayTexto = query.trim().length >= 2
  return {
    codigoRef,
    productoRef,
    resultados,
    query,
    campoActivo,
    setCampoActivo,
    mostrarDropdownCodigo: campoActivo === 'codigo' && (resultados.length > 0 || hayTexto),
    mostrarDropdownProducto: campoActivo === 'producto' && (resultados.length > 0 || hayTexto),
    avisoCodigo,
    buscandoCodigo,
    creandoProducto,
    crearInicial,
    seleccionarProducto,
    buscarPorCodigo,
    buscarPorProducto,
    resolverCodigo,
    abrirCrear,
    crearDesdeCampo,
    crearDesdeAviso,
    buscarPorNombre,
    cerrarCrear,
    alCrear,
    usarExistente,
    onKeyDownCodigo,
    onKeyDownProducto,
  }
}

export type ItemFacturaBusqueda = ReturnType<typeof useItemFacturaBusqueda>

// 'compact': planilla de escritorio. 'touch': tarjeta de celular (targets de 44px).
type Tamano = 'compact' | 'touch'

// Dropdown de sugerencias de producto anclado al campo que disparó la búsqueda.
export function SugerenciasProductoFactura({
  busqueda,
  campo,
  anchorRef,
  size = 'compact',
}: {
  busqueda: ItemFacturaBusqueda
  campo: CampoBusqueda
  anchorRef: RefObject<HTMLElement>
  size?: Tamano
}) {
  const touch = size === 'touch'
  const textoCrear = busqueda.query.trim()
  return (
    <DropdownFlotante anchorRef={anchorRef} ancho={touch ? 'ancla' : 'fijo'}>
      {busqueda.resultados.map((p) => (
        <button
          key={p.id}
          type="button"
          onClick={() => busqueda.seleccionarProducto(p)}
          className={
            touch
              ? 'flex min-h-11 w-full flex-col items-start justify-center border-b border-line px-4 py-2 text-left font-sans active:bg-bg'
              : 'flex w-full flex-col items-start px-3 py-1.5 text-left font-sans hover:bg-bg'
          }
        >
          <span className="text-body-md text-ink">{p.nombre}</span>
          <span className="font-sans text-label-md text-ink-soft">
            {p.marca ? `${p.marca} · ` : ''}Costo actual: {formatCurrencyOpcional(p.costo)}
          </span>
        </button>
      ))}
      <button
        type="button"
        onClick={() => busqueda.crearDesdeCampo(campo)}
        className={
          touch
            ? 'flex min-h-11 w-full items-center px-4 py-2 text-left font-sans text-label-bold text-accent-dark active:bg-accent-light'
            : 'flex w-full items-center px-3 py-1.5 text-left font-sans text-label-md text-accent-dark hover:bg-accent-light'
        }
      >
        + Crear producto nuevo{textoCrear ? ` ${campo === 'codigo' ? 'con código ' : ''}"${textoCrear}"` : ''}
      </button>
    </DropdownFlotante>
  )
}

// Aviso de un código escaneado que no terminó vinculando el ítem: no existe, está inactivo, o no
// se pudo consultar. La persona elige qué hacer (nunca se abre el alta sola).
export function AvisoCodigoFactura({ busqueda, size = 'compact' }: { busqueda: ItemFacturaBusqueda; size?: Tamano }) {
  const aviso = busqueda.avisoCodigo
  if (busqueda.buscandoCodigo) {
    return <p className="font-sans text-label-md text-ink-soft">Buscando código…</p>
  }
  if (!aviso) return null

  const touch = size === 'touch'
  const boton = `${touch ? 'min-h-11 px-3' : 'px-2.5 py-1'} rounded border font-sans text-label-bold active:opacity-80`
  const botonAccent = `${boton} border-accent/60 text-accent-dark hover:bg-accent-light`
  const botonError = `${boton} border-error/50 text-error hover:bg-error/10`

  return (
    <div
      role="status"
      className={`rounded border font-sans text-body-md ${touch ? 'px-3 py-3' : 'px-3 py-2'} ${
        aviso.tipo === 'no_encontrado' ? 'border-accent/50 bg-accent-light/40' : 'border-error/40 bg-error/10'
      }`}
    >
      {aviso.tipo === 'no_encontrado' && (
        <>
          <p className="text-ink">
            No encontramos el código <strong className="break-all">{aviso.codigo}</strong> en el inventario.
          </p>
          <p className="mt-1 font-sans text-label-md text-ink-soft">
            Si el producto ya está cargado, compará este número con el de la etiqueta o buscalo por nombre.
          </p>
          <div className="mt-2 flex flex-wrap gap-2">
            <button type="button" onClick={busqueda.buscarPorNombre} className={botonAccent}>
              Buscar por nombre
            </button>
            <button type="button" onClick={busqueda.crearDesdeAviso} className={botonAccent}>
              Crear producto nuevo
            </button>
          </div>
        </>
      )}

      {aviso.tipo === 'inactivo' && (
        <>
          <p className="text-ink">
            El código corresponde a <strong>{aviso.producto.nombre}</strong>, que está <strong>inactivo</strong> en el
            inventario.
          </p>
          <div className="mt-2 flex flex-wrap gap-2">
            <button type="button" onClick={() => busqueda.seleccionarProducto(aviso.producto)} className={botonError}>
              Usarlo igual
            </button>
            <button type="button" onClick={busqueda.buscarPorNombre} className={`${boton} border-line text-ink-soft`}>
              Buscar otro
            </button>
          </div>
        </>
      )}

      {aviso.tipo === 'error' && (
        <>
          <p className="text-error">{aviso.mensaje}</p>
          <div className="mt-2 flex flex-wrap gap-2">
            <button type="button" onClick={() => busqueda.resolverCodigo(aviso.codigo)} className={botonError}>
              Reintentar
            </button>
          </div>
        </>
      )}
    </div>
  )
}
