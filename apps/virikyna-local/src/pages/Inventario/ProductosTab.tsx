import { useEffect, useMemo, useState } from 'react'
import { Pencil } from 'lucide-react'
import type { Proveedor } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { friendlyError } from '@virikyna/shared'
import { formatCurrency } from '@virikyna/shared'
import { coincideBusquedaProducto } from '@virikyna/shared'
import { usePerfil } from '../../auth/AuthContext'
import { SearchInput } from '../../components/SearchInput'
import { ProductoFormSheet } from './ProductoFormSheet'
import { ActualizarPreciosSheet } from './ActualizarPreciosSheet'
import type { ProductoConRelaciones } from './types'

const SELECT_PRODUCTOS =
  '*, proveedor:proveedores(razon_social, margen_1_default, margen_2_default), stock_ubicaciones(ubicacion, cantidad)'

export function ProductosTab() {
  const { rol } = usePerfil()
  const [productos, setProductos] = useState<ProductoConRelaciones[]>([])
  const [proveedores, setProveedores] = useState<Proveedor[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [modal, setModal] = useState<'nuevo' | ProductoConRelaciones | null>(null)
  const [busqueda, setBusqueda] = useState('')
  const [seleccion, setSeleccion] = useState<Set<string>>(new Set())
  const [actualizandoPrecios, setActualizandoPrecios] = useState(false)
  const [resultadoPrecios, setResultadoPrecios] = useState<string | null>(null)

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
      supabase.from('productos').select(SELECT_PRODUCTOS).order('nombre'),
      supabase.from('proveedores').select('*').order('razon_social'),
    ])

    if (productosRes.error) {
      setError(friendlyError(productosRes.error))
    } else {
      setProductos((productosRes.data ?? []) as unknown as ProductoConRelaciones[])
    }
    setProveedores((proveedoresRes.data ?? []) as Proveedor[])
    setLoading(false)
  }

  useEffect(() => {
    cargar()
  }, [])

  function toggleSeleccion(id: string) {
    setSeleccion((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  if (!rol) return null

  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center justify-between">
        <p className="font-sans text-body-md text-ink-soft">Catálogo de productos, precios y stock por ubicación.</p>
        <div className="flex items-center gap-3">
          <SearchInput value={busqueda} onChange={setBusqueda} placeholder="Buscar producto..." />
          <button
            type="button"
            onClick={() => setActualizandoPrecios(true)}
            className="rounded border border-accent px-4 py-3 font-sans text-label-bold text-accent-dark transition hover:bg-accent-light"
          >
            Actualizar precios{seleccion.size > 0 ? ` (${seleccion.size})` : ''}
          </button>
          <button
            type="button"
            onClick={() => setModal('nuevo')}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark"
          >
            + Nuevo producto
          </button>
        </div>
      </div>

      {error && (
        <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>
      )}
      {resultadoPrecios && (
        <p className="mt-stack-md rounded bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">
          {resultadoPrecios}
        </p>
      )}

      <div className="mt-stack-md flex-1 overflow-auto rounded-lg border border-line">
        <table className="w-full text-left font-sans text-body-md leading-5">
          <thead>
            <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
              <th className="px-3 py-2"></th>
              <th className="px-3 py-2">Nombre</th>
              <th className="px-3 py-2">Proveedor</th>
              <th className="px-3 py-2">Costo</th>
              <th className="px-3 py-2">Precio venta</th>
              <th className="px-3 py-2">Stock (Local / Depósito)</th>
              <th className="px-3 py-2">Estado</th>
              <th className="px-3 py-2"></th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={8}>
                  Cargando...
                </td>
              </tr>
            )}
            {!loading && productos.length > 0 && productosFiltrados.length === 0 && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={8}>
                  Sin resultados para "{busqueda}".
                </td>
              </tr>
            )}
            {!loading && productos.length === 0 && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={8}>
                  No hay productos cargados todavía.
                </td>
              </tr>
            )}
            {productosFiltrados.map((producto) => {
              const stockLocal = producto.stock_ubicaciones.find((s) => s.ubicacion === 'local')?.cantidad ?? 0
              const stockDeposito =
                producto.stock_ubicaciones.find((s) => s.ubicacion === 'deposito')?.cantidad ?? 0
              return (
                <tr key={producto.id} className="border-b border-line last:border-0">
                  <td className="px-3 py-1.5">
                    <input
                      type="checkbox"
                      checked={seleccion.has(producto.id)}
                      onChange={() => toggleSeleccion(producto.id)}
                      className="h-4 w-4 accent-accent"
                    />
                  </td>
                  <td className="px-3 py-1.5 text-ink">{producto.nombre}</td>
                  <td className="px-3 py-1.5 text-ink-soft">{producto.proveedor?.razon_social ?? '—'}</td>
                  <td className="px-3 py-1.5 text-ink">{formatCurrency(producto.costo)}</td>
                  <td className="px-3 py-1.5 font-sans text-label-bold text-accent-darker">
                    {formatCurrency(producto.precio_venta)}
                  </td>
                  <td className="px-3 py-1.5 text-ink-soft">
                    {stockLocal} / {stockDeposito}
                  </td>
                  <td className="px-3 py-1.5">
                    <span className={producto.estado === 'activo' ? 'text-success' : 'text-ink-soft'}>
                      {producto.estado === 'activo' ? 'Activo' : 'Inactivo'}
                    </span>
                  </td>
                  <td className="px-3 py-1.5 text-right">
                    <button
                      type="button"
                      onClick={() => setModal(producto)}
                      title="Editar"
                      aria-label="Editar"
                      className="rounded px-3 py-1.5 text-accent-dark hover:bg-accent-light"
                    >
                      <Pencil size={18} strokeWidth={1.5} />
                    </button>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      {modal && (
        <ProductoFormSheet
          producto={modal === 'nuevo' ? undefined : modal}
          proveedores={proveedores}
          rol={rol}
          onClose={() => setModal(null)}
          onSaved={() => {
            setModal(null)
            cargar()
          }}
          onStockChanged={cargar}
        />
      )}

      {actualizandoPrecios && (
        <ActualizarPreciosSheet
          productos={productos}
          proveedores={proveedores}
          seleccionInicial={Array.from(seleccion)}
          onClose={() => setActualizandoPrecios(false)}
          onSaved={(cantidad) => {
            setActualizandoPrecios(false)
            setSeleccion(new Set())
            setResultadoPrecios(
              `${cantidad} producto${cantidad === 1 ? '' : 's'} actualizado${cantidad === 1 ? '' : 's'}.`,
            )
            cargar()
          }}
        />
      )}
    </div>
  )
}
