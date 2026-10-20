import { useEffect, useMemo, useState, type ReactNode } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Proveedor } from '../../../types/database'
import { friendlyError } from '../../../lib/supabaseErrors'
import { formatCurrency } from '../../../lib/format'
import { formatCantidad } from '../../../lib/cargaInicial'
import { coincideBusquedaProducto } from '../../../lib/productoBusqueda'
import { cargarProductosInventario, stockTotal, type ProductoConRelaciones } from '../../../lib/inventario'
import { ProductoBuscador } from '../ProductoBuscador'
import { EstadoBadge } from '../EstadoBadge'

export type FormularioProductoRender = (args: {
  producto?: ProductoConRelaciones // undefined = alta
  proveedores: Proveedor[]
  onClose: () => void
  onSaved: () => void
  onStockChanged: () => void
  onEditarExistente: (id: string) => void
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
  // su actualización masiva. Acá vive la lista: carga, búsqueda, selección y tabla.
  renderFormulario: FormularioProductoRender
  renderActualizarPrecios: ActualizarPreciosRender
  // Acción masiva "Lleva IVA" (docs/47), solo admin: sin esta prop el botón no aparece.
  renderMarcarIva?: MarcarIvaRender
}

// Pestaña "Productos" de Inventario en escritorio (Virikyna Local y Virikyna Gestión). Tabla estilo G
// (docs/08 §5.2): Nombre | Marca | Descripción | Precio de venta | Stock | Estado. Proveedor, costo,
// márgenes, códigos y stock por ubicación están en el formulario, que se abre con un clic en la fila.
export function ProductosTab({ supabase, renderFormulario, renderActualizarPrecios, renderMarcarIva }: Props) {
  const [productos, setProductos] = useState<ProductoConRelaciones[]>([])
  const [proveedores, setProveedores] = useState<Proveedor[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [modal, setModal] = useState<'nuevo' | ProductoConRelaciones | null>(null)
  const [busqueda, setBusqueda] = useState('')
  const [seleccion, setSeleccion] = useState<Set<string>>(new Set())
  const [actualizandoPrecios, setActualizandoPrecios] = useState(false)
  const [marcandoIva, setMarcandoIva] = useState(false)
  const [resultadoPrecios, setResultadoPrecios] = useState<string | null>(null)

  // La columna Proveedor ya no está, pero se sigue pudiendo buscar por proveedor.
  const productosFiltrados = useMemo(() => {
    const q = busqueda.trim().toLowerCase()
    if (!q) return productos
    return productos.filter(
      (p) => coincideBusquedaProducto(p, q) || (p.proveedor?.razon_social ?? '').toLowerCase().includes(q),
    )
  }, [productos, busqueda])

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

  const celda = 'px-3 py-3 align-top'
  const sinFilas = (texto: string) => (
    <tr>
      <td className="px-4 py-4 text-ink-soft" colSpan={7}>
        {texto}
      </td>
    </tr>
  )

  return (
    <div className="flex h-full flex-col">
      <div className="flex flex-col gap-2">
        <div className="flex items-center gap-3">
          <ProductoBuscador value={busqueda} onChange={setBusqueda} />
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
        <p className="font-sans text-label-md text-ink-soft">
          Catálogo de productos, precios y stock. El campo de búsqueda acepta lector físico de código de barras
          (enfoca y escanea) o el botón de escaneo con cámara — busca por código, nombre, marca o proveedor. Tocá una
          fila para ver el detalle completo y editar.
        </p>
      </div>

      {error && <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>}
      {resultadoPrecios && (
        <p className="mt-stack-md rounded bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">
          {resultadoPrecios}
        </p>
      )}

      <div className="mt-stack-md flex-1 overflow-auto rounded-xl shadow-sm">
        {/* table-fixed + colgroup: checkbox, precio, stock y estado con ancho fijo; Marca 14% y Nombre
            y Descripción se reparten el resto en partes iguales — sin scroll horizontal en ningún ancho
            (docs/08 §5.2). */}
        <table className="w-full table-fixed text-left font-sans text-table-row max-xl:[&_td]:px-2 max-xl:[&_th]:px-2">
          <colgroup>
            <col className="w-8 xl:w-10" />
            <col />
            <col className="w-[14%]" />
            <col />
            <col className="w-[7rem] xl:w-[7.5rem]" />
            <col className="w-14 xl:w-16" />
            <col className="w-[5rem] xl:w-[5.5rem]" />
          </colgroup>
          <thead>
            <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
              <th className="px-3 py-2.5">
                <span className="sr-only">Seleccionar</span>
              </th>
              <th className="px-3 py-2.5">Nombre</th>
              <th className="px-3 py-2.5">Marca</th>
              <th className="px-3 py-2.5">Descripción</th>
              <th className="px-3 py-2.5 text-right">Precio venta</th>
              <th className="px-3 py-2.5 text-right">Stock</th>
              <th className="px-3 py-2.5">Estado</th>
            </tr>
          </thead>
          <tbody>
            {loading && sinFilas('Cargando...')}
            {!loading && productos.length > 0 && productosFiltrados.length === 0 && sinFilas(`Sin resultados para "${busqueda}".`)}
            {!loading && productos.length === 0 && sinFilas('No hay productos cargados todavía.')}
            {productosFiltrados.map((producto) => (
              <tr
                key={producto.id}
                onClick={() => setModal(producto)}
                className="cursor-pointer border-b border-table-divider last:border-0 even:bg-table-row-alt hover:bg-accent-light/40"
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
                </td>
                <td className={`${celda} text-ink-soft [overflow-wrap:anywhere]`}>{producto.marca ?? '—'}</td>
                <td className={`${celda} text-ink-soft [overflow-wrap:anywhere]`}>{producto.descripcion ?? '—'}</td>
                <td className={`${celda} whitespace-nowrap text-right font-semibold tabular-nums text-accent-darker`}>
                  {formatCurrency(producto.precio_venta)}
                  {producto.precio_manual !== null && <span className="block font-normal text-ink-soft">manual</span>}
                </td>
                <td className={`${celda} text-right tabular-nums text-ink`}>{formatCantidad(stockTotal(producto))}</td>
                <td className={celda}>
                  <EstadoBadge variant={producto.estado === 'activo' ? 'green' : 'neutral'}>
                    {producto.estado === 'activo' ? 'Activo' : 'Inactivo'}
                  </EstadoBadge>
                </td>
              </tr>
            ))}
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
