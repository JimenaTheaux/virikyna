import { useEffect, useMemo, useState, type ReactNode } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Proveedor } from '../../../types/database'
import { friendlyError } from '../../../lib/supabaseErrors'
import { formatCurrency } from '../../../lib/format'
import { coincideBusquedaProducto } from '../../../lib/productoBusqueda'
import { textoParaBuscar } from '../../../lib/texto'
import { cargarProductosInventario, stockTotal, type ProductoConRelaciones } from '../../../lib/inventario'
import {
  cantidadFiltrosAplicados,
  filtrarInventario,
  ordenPorDefecto,
  type CampoOrden,
  type OrdenInventario,
} from '../../../lib/estadoStock'
import { ProductoBuscador } from '../ProductoBuscador'
import { EstadoBadge } from '../EstadoBadge'
import { ControlSegmentado } from '../ControlSegmentado'
import { SelectBuscable } from '../SelectBuscable'
import { BadgeStock, ChipsStock, ESTADO_OPCIONES, mensajeListadoVacio, useFiltrosInventario } from './FiltrosInventario'

export type FormularioProductoRender = (args: {
  producto?: ProductoConRelaciones // undefined = alta
  proveedores: Proveedor[]
  onClose: () => void
  onSaved: () => void
  onStockChanged: () => void
  onEditarExistente: (id: string) => void
  onEliminado: (nombre: string) => void // docs/48: solo lo usa el formulario de un admin
}) => ReactNode

export type ActualizarPreciosRender = (args: {
  productos: ProductoConRelaciones[]
  proveedores: Proveedor[]
  seleccionInicial: string[]
  onClose: () => void
  onSaved: (cantidad: number) => void
}) => ReactNode

export type MarcarIvaRender = (args: {
  productos: ProductoConRelaciones[]
  seleccionInicial: string[]
  onClose: () => void
  onSaved: (cantidad: number) => void
}) => ReactNode

type Props = {
  supabase: SupabaseClient
  // Cada app monta su formulario (Local: ProductoFormSheet con rol; Gestión: ProductoFormModal) y
  // su actualización masiva. Acá vive la lista: carga, filtros, selección y tabla.
  renderFormulario: FormularioProductoRender
  renderActualizarPrecios: ActualizarPreciosRender
  // Acción masiva "Lleva IVA" (docs/47), solo admin: sin esta prop el botón no aparece.
  renderMarcarIva?: MarcarIvaRender
}

// Búsqueda del listado: nombre, marca, códigos (coincideBusquedaProducto) y proveedor.
function coincide(p: ProductoConRelaciones, q: string) {
  return coincideBusquedaProducto(p, q) || textoParaBuscar(p.proveedor?.razon_social).includes(textoParaBuscar(q))
}

const ESTADO_RESUMEN = { activos: ' activos', inactivos: ' inactivos', todos: '' } as const

// Pestaña "Productos" de Inventario en escritorio (Virikyna Local y Virikyna Gestión). Tabla estilo G
// (docs/08 §5.2): Nombre | Marca | Descripción | Precio de venta | Stock (con mínimo). Proveedor,
// costo, márgenes, códigos y stock por ubicación están en el formulario (clic en la fila).
// Filtros (docs/64): estado, marca, proveedor, búsqueda y chips de stock, todos en la URL.
export function ProductosTab({ supabase, renderFormulario, renderActualizarPrecios, renderMarcarIva }: Props) {
  const [productos, setProductos] = useState<ProductoConRelaciones[]>([])
  const [proveedores, setProveedores] = useState<Proveedor[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [modal, setModal] = useState<'nuevo' | ProductoConRelaciones | null>(null)
  const [seleccion, setSeleccion] = useState<Set<string>>(new Set())
  const [actualizandoPrecios, setActualizandoPrecios] = useState(false)
  const [marcandoIva, setMarcandoIva] = useState(false)
  const [resultadoPrecios, setResultadoPrecios] = useState<string | null>(null)
  const { filtros, busqueda, setBusqueda, aplicar, limpiar } = useFiltrosInventario()
  // null = orden por defecto del chip (nombre, o stock ascendente en los de problemas).
  const [orden, setOrden] = useState<OrdenInventario | null>(null)

  const { visibles, totalEstado, contadores } = useMemo(
    () => filtrarInventario(productos, filtros, { stockDe: stockTotal, coincideBusqueda: coincide, orden }),
    // filtros es un objeto nuevo en cada render: dependencias por campo.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [productos, filtros.estado, filtros.stock, filtros.marca, filtros.proveedor, filtros.q, orden],
  )
  const ordenEfectivo = orden ?? ordenPorDefecto(filtros.stock)

  const marcas = useMemo(
    () =>
      [...new Set(productos.map((p) => p.marca).filter((m): m is string => !!m))]
        .sort((a, b) => a.localeCompare(b, 'es'))
        .map((m) => ({ value: m, label: m })),
    [productos],
  )
  const opcionesProveedor = useMemo(() => proveedores.map((p) => ({ value: p.id, label: p.razon_social })), [proveedores])
  const hayFiltros = cantidadFiltrosAplicados(filtros) > 0

  async function cargar() {
    setLoading(true)
    setError(null)

    const [productosRes, proveedoresRes] = await Promise.all([
      cargarProductosInventario(supabase),
      supabase.from('proveedores').select('*').order('razon_social'),
    ])

    if (productosRes.error) {
      setError(friendlyError(productosRes.error))
    } else {
      setProductos(productosRes.data)
    }
    setProveedores((proveedoresRes.data ?? []) as Proveedor[])
    setLoading(false)
  }

  useEffect(() => {
    cargar()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  function toggleSeleccion(id: string) {
    setSeleccion((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  function ordenarPor(campo: CampoOrden) {
    setOrden(
      ordenEfectivo.campo === campo
        ? { campo, dir: ordenEfectivo.dir === 'asc' ? 'desc' : 'asc' }
        : { campo, dir: 'asc' },
    )
  }

  function limpiarTodo() {
    limpiar()
    setOrden(null)
  }

  const celda = 'px-3 py-3 align-top'
  const sinFilas = (contenido: ReactNode) => (
    <tr>
      <td className="px-4 py-4 text-ink-soft" colSpan={6}>
        {contenido}
      </td>
    </tr>
  )
  const vacio = mensajeListadoVacio(filtros)

  // Encabezado ordenable: botón con flecha; aria-sort en el th para el lector de pantalla. Función
  // y no componente: un componente definido acá se remontaría en cada render y perdería el foco.
  function thOrden(campo: CampoOrden, children: ReactNode, derecha = false) {
    const activo = ordenEfectivo.campo === campo
    return (
      <th
        aria-sort={activo ? (ordenEfectivo.dir === 'asc' ? 'ascending' : 'descending') : 'none'}
        className={`sticky top-0 z-10 bg-accent-light px-3 py-2.5 ${derecha ? 'text-right' : ''}`}
      >
        <button
          type="button"
          onClick={() => ordenarPor(campo)}
          className={`inline-flex items-center gap-1 uppercase hover:text-accent-darker ${activo ? 'text-accent-darker' : ''}`}
        >
          {children}
          <span aria-hidden="true" className={activo ? '' : 'opacity-30'}>
            {activo && ordenEfectivo.dir === 'desc' ? '▼' : '▲'}
          </span>
        </button>
      </th>
    )
  }

  return (
    <div className="flex h-full flex-col">
      <div className="flex flex-col gap-2">
        {/* Fila 1: búsqueda, estado, marca y proveedor (el lector de códigos escribe en el buscador). */}
        <div className="flex flex-wrap items-center gap-2">
          <div className="flex min-w-[16rem] flex-1">
            <ProductoBuscador
              value={busqueda}
              onChange={setBusqueda}
              limpiable
              placeholder="Buscar nombre, marca, código o proveedor…"
            />
          </div>
          <ControlSegmentado
            legend="Estado"
            ocultarLegend
            opciones={ESTADO_OPCIONES}
            value={filtros.estado}
            onChange={(estado) => aplicar({ estado })}
          />
          <SelectBuscable
            label="Marca"
            todasLabel="Todas las marcas"
            placeholder="Marca"
            value={filtros.marca}
            opciones={marcas}
            onChange={(marca) => aplicar({ marca })}
            className="w-40"
          />
          <SelectBuscable
            label="Proveedor"
            todasLabel="Todos los proveedores"
            placeholder="Proveedor"
            value={filtros.proveedor}
            opciones={opcionesProveedor}
            onChange={(proveedor) => aplicar({ proveedor })}
            className="w-40"
          />
        </div>

        {/* Fila 2: chips de stock y limpiar. */}
        <div className="flex flex-wrap items-center gap-2">
          <ChipsStock
            value={filtros.stock}
            contadores={contadores}
            onChange={(stock) => {
              aplicar({ stock })
              setOrden(null)
            }}
          />
          {hayFiltros && (
            <button
              type="button"
              onClick={limpiarTodo}
              className="whitespace-nowrap rounded px-3 py-1.5 font-sans text-label-bold text-accent-dark hover:bg-accent-light"
            >
              Limpiar filtros
            </button>
          )}
        </div>

        {/* Fila 3: resumen y acciones. */}
        <div className="flex flex-wrap items-center justify-between gap-2">
          <p className="font-sans text-label-md text-ink-soft" aria-live="polite">
            {loading
              ? 'Cargando productos…'
              : `Mostrando ${visibles.length} de ${totalEstado} productos${ESTADO_RESUMEN[filtros.estado]}`}
          </p>
          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={() => setActualizandoPrecios(true)}
              className="h-10 whitespace-nowrap rounded border border-line bg-surface px-4 font-sans text-label-bold text-ink-soft transition hover:border-accent hover:text-accent-darker"
            >
              Actualizar precios{seleccion.size > 0 ? ` (${seleccion.size})` : ''}
            </button>
            {renderMarcarIva && (
              <button
                type="button"
                onClick={() => setMarcandoIva(true)}
                className="h-10 whitespace-nowrap rounded border border-line bg-surface px-4 font-sans text-label-bold text-ink-soft transition hover:border-accent hover:text-accent-darker"
              >
                IVA{seleccion.size > 0 ? ` (${seleccion.size})` : ''}
              </button>
            )}
            <button
              type="button"
              onClick={() => setModal('nuevo')}
              className="h-10 whitespace-nowrap rounded bg-accent px-4 font-sans text-label-bold text-white transition hover:bg-accent-dark"
            >
              + Nuevo producto
            </button>
          </div>
        </div>
      </div>

      {error && <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>}
      {resultadoPrecios && (
        <p className="mt-stack-md rounded bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">
          {resultadoPrecios}
        </p>
      )}

      <div className="mt-2 flex-1 overflow-auto rounded-xl shadow-sm">
        {/* table-fixed + colgroup: checkbox, precio y stock con ancho fijo; Marca 14% y Nombre y
            Descripción se reparten el resto — sin scroll horizontal (docs/08 §5.2). Encabezado fijo
            al scrollear (sticky en cada th, dentro de este contenedor con scroll). */}
        <table className="w-full table-fixed text-left font-sans text-table-row max-xl:[&_td]:px-2 max-xl:[&_th]:px-2">
          <colgroup>
            <col className="w-8 xl:w-10" />
            <col />
            <col className="w-[14%]" />
            <col />
            <col className="w-[7.5rem] xl:w-[8rem]" />
            <col className="w-[5.5rem] xl:w-[6rem]" />
          </colgroup>
          <thead>
            <tr className="text-table-head uppercase text-accent-dark">
              <th className="sticky top-0 z-10 bg-accent-light px-3 py-2.5">
                <span className="sr-only">Seleccionar</span>
              </th>
              {thOrden('nombre', 'Nombre')}
              <th className="sticky top-0 z-10 bg-accent-light px-3 py-2.5">Marca</th>
              <th className="sticky top-0 z-10 bg-accent-light px-3 py-2.5">Descripción</th>
              {thOrden('precio', 'Precio venta', true)}
              {thOrden('stock', 'Stock', true)}
            </tr>
          </thead>
          <tbody>
            {loading && sinFilas('Cargando...')}
            {!loading && productos.length === 0 && sinFilas('No hay productos cargados todavía.')}
            {!loading &&
              productos.length > 0 &&
              visibles.length === 0 &&
              sinFilas(
                <span className="flex flex-wrap items-center gap-3">
                  {vacio.texto}
                  {vacio.conLimpiar && (
                    <button
                      type="button"
                      onClick={limpiarTodo}
                      className="rounded px-2 py-1 font-sans text-label-bold text-accent-dark hover:bg-accent-light"
                    >
                      Limpiar filtros
                    </button>
                  )}
                </span>,
              )}
            {visibles.map((producto) => {
              const inactivo = producto.estado !== 'activo'
              return (
                <tr
                  key={producto.id}
                  onClick={() => setModal(producto)}
                  className={`cursor-pointer border-b border-table-divider last:border-0 even:bg-table-row-alt hover:bg-accent-light/40 ${
                    inactivo ? 'text-ink-soft [&>td]:opacity-60' : ''
                  }`}
                >
                  {/* El checkbox (Actualizar precios, IVA) no abre el formulario. */}
                  <td className={celda} onClick={(e) => e.stopPropagation()}>
                    <input
                      type="checkbox"
                      checked={seleccion.has(producto.id)}
                      onChange={() => toggleSeleccion(producto.id)}
                      aria-label={`Seleccionar ${producto.nombre}`}
                      className="h-4 w-4 accent-accent"
                    />
                  </td>
                  <td className={`${celda} text-ink [overflow-wrap:anywhere]`}>
                    {/* Botón para teclado y lector de pantalla; con el mouse, la fila entera abre lo mismo. */}
                    <button
                      type="button"
                      onClick={(e) => {
                        e.stopPropagation()
                        setModal(producto)
                      }}
                      className="text-left font-semibold hover:text-accent-darker focus-visible:underline focus-visible:outline-none"
                    >
                      {producto.nombre}
                    </button>
                    {inactivo && (
                      <span className="ml-2 align-middle">
                        <EstadoBadge variant="neutral">INACTIVO</EstadoBadge>
                      </span>
                    )}
                  </td>
                  <td className={`${celda} text-ink-soft [overflow-wrap:anywhere]`}>{producto.marca ?? '—'}</td>
                  <td className={`${celda} text-ink-soft [overflow-wrap:anywhere]`}>{producto.descripcion ?? '—'}</td>
                  <td className={`${celda} whitespace-nowrap text-right font-semibold tabular-nums text-accent-darker`}>
                    {formatCurrency(producto.precio_venta)}
                    {producto.precio_manual !== null && <span className="block font-normal text-ink-soft">manual</span>}
                  </td>
                  <td className={`${celda} text-right`}>
                    <BadgeStock stock={stockTotal(producto)} minimo={Number(producto.stock_minimo)} />
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      {modal &&
        renderFormulario({
          producto: modal === 'nuevo' ? undefined : modal,
          proveedores,
          onClose: () => setModal(null),
          onSaved: () => {
            setModal(null)
            cargar()
          },
          onStockChanged: cargar,
          onEliminado: (nombre) => {
            setModal(null)
            setResultadoPrecios(`Se eliminó ${nombre}.`)
            cargar()
          },
          onEditarExistente: (id) => {
            const existente = productos.find((p) => p.id === id)
            if (existente) setModal(existente)
          },
        })}

      {actualizandoPrecios &&
        renderActualizarPrecios({
          productos,
          proveedores,
          seleccionInicial: Array.from(seleccion),
          onClose: () => setActualizandoPrecios(false),
          onSaved: (cantidad) => {
            setActualizandoPrecios(false)
            setSeleccion(new Set())
            setResultadoPrecios(`${cantidad} producto${cantidad === 1 ? '' : 's'} actualizado${cantidad === 1 ? '' : 's'}.`)
            cargar()
          },
        })}

      {marcandoIva &&
        renderMarcarIva?.({
          productos,
          seleccionInicial: Array.from(seleccion),
          onClose: () => setMarcandoIva(false),
          onSaved: (cantidad) => {
            setMarcandoIva(false)
            setSeleccion(new Set())
            setResultadoPrecios(`IVA cambiado en ${cantidad} producto${cantidad === 1 ? '' : 's'}.`)
            cargar()
          },
        })}
    </div>
  )
}
