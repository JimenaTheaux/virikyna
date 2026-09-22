import { lazy, Suspense, useEffect, useMemo, useState } from 'react'
import type { Proveedor } from '@virikyna/shared'
import { formatCurrency, friendlyError, coincideBusquedaProducto } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { usePerfil } from '../../auth/AuthContext'
import { buscarProductoPorCodigoBarras } from '../../lib/productos'
import { IconBuscar, IconCamara, IconMas, IconPorcentaje } from '../../components/icons'
import { ProductoFormSheet } from './ProductoFormSheet'
import { ActualizarPreciosSheet } from './ActualizarPreciosSheet'
import type { ProductoConRelaciones } from './types'

const BarcodeScanner = lazy(() => import('../../components/BarcodeScanner'))

const SELECT_PRODUCTOS =
  '*, proveedor:proveedores(razon_social, margen_1_default, margen_2_default), stock_ubicaciones(ubicacion, cantidad)'

type Modal =
  | { tipo: 'nuevo'; codigoBarras?: string }
  | { tipo: 'editar'; producto: ProductoConRelaciones }
  | null

// Mismo cuadro de acciones que Inventario en Virikyna Local (alta, edición, baja, reactivación,
// actualización de precios; ajuste de stock exclusivo admin) — docs/04_modulos_y_funciones.md,
// módulo 5.1. La diferencia mobile-first: cards en vez de tabla, y un botón de escaneo que
// busca el producto por código de barras antes de decidir si abre edición o alta.
export function InventarioPage() {
  const { rol } = usePerfil()
  const [productos, setProductos] = useState<ProductoConRelaciones[]>([])
  const [proveedores, setProveedores] = useState<Proveedor[]>([])
  const [busqueda, setBusqueda] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [modal, setModal] = useState<Modal>(null)
  const [escaneando, setEscaneando] = useState(false)
  const [buscandoEscaneo, setBuscandoEscaneo] = useState(false)
  const [actualizandoPrecios, setActualizandoPrecios] = useState(false)
  const [resultadoPrecios, setResultadoPrecios] = useState<string | null>(null)

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

  const productosFiltrados = useMemo(() => {
    const q = busqueda.trim().toLowerCase()
    if (!q) return productos
    return productos.filter((p) => coincideBusquedaProducto(p, q))
  }, [productos, busqueda])

  async function handleEscaneo(codigo: string) {
    setEscaneando(false)
    setBuscandoEscaneo(true)
    const producto = await buscarProductoPorCodigoBarras(codigo)
    setBuscandoEscaneo(false)
    if (producto) {
      setModal({ tipo: 'editar', producto: producto as ProductoConRelaciones })
    } else {
      setModal({ tipo: 'nuevo', codigoBarras: codigo })
    }
  }

  if (!rol) return null

  return (
    <div className="flex h-full flex-col gap-stack-md">
      <div className="flex items-start justify-between gap-2">
        <div>
          <h1 className="font-display text-headline-lg text-accent-darker">Inventario</h1>
          <p className="mt-1 font-sans text-body-md text-ink-soft">Catálogo, precios y stock por ubicación.</p>
        </div>
        <button
          type="button"
          onClick={() => setActualizandoPrecios(true)}
          aria-label="Actualización masiva de precios"
          className="flex flex-shrink-0 items-center justify-center rounded border border-line bg-surface px-4 py-3.5 text-accent-dark hover:bg-accent-light"
        >
          <IconPorcentaje className="h-6 w-6" />
        </button>
      </div>

      <div className="flex gap-2">
        <div className="relative flex-1">
          <IconBuscar className="pointer-events-none absolute left-3 top-1/2 h-5 w-5 -translate-y-1/2 text-ink-soft" />
          <input
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar por nombre, marca o código..."
            className="w-full rounded border border-line bg-surface py-3.5 pl-11 pr-4 font-sans text-body-md text-ink outline-none focus:border-accent"
          />
        </div>
        <button
          type="button"
          onClick={() => setEscaneando(true)}
          aria-label="Escanear código de barras"
          className="flex items-center justify-center rounded border border-line bg-surface px-4 text-accent-dark hover:bg-accent-light"
        >
          <IconCamara className="h-6 w-6" />
        </button>
      </div>

      {buscandoEscaneo && (
        <p className="font-sans text-label-md text-ink-soft">Buscando producto por código...</p>
      )}

      {error && <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>}
      {resultadoPrecios && (
        <p className="rounded bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">
          {resultadoPrecios}
        </p>
      )}

      <div className="flex-1 space-y-3 overflow-y-auto">
        {loading && <p className="py-6 text-center font-sans text-body-md text-ink-soft">Cargando...</p>}

        {!loading && productosFiltrados.length === 0 && (
          <p className="py-6 text-center font-sans text-body-md text-ink-soft">
            {busqueda ? 'No hay productos que coincidan con la búsqueda.' : 'No hay productos cargados todavía.'}
          </p>
        )}

        {productosFiltrados.map((producto) => {
          const stockLocal = producto.stock_ubicaciones.find((s) => s.ubicacion === 'local')?.cantidad ?? 0
          const stockDeposito =
            producto.stock_ubicaciones.find((s) => s.ubicacion === 'deposito')?.cantidad ?? 0
          return (
            <button
              key={producto.id}
              type="button"
              onClick={() => setModal({ tipo: 'editar', producto })}
              className="w-full rounded-lg border border-line bg-surface p-4 text-left shadow-sm active:bg-bg"
            >
              <div className="flex items-start justify-between gap-2">
                <div>
                  <p className="font-sans text-label-bold text-ink">{producto.nombre}</p>
                  <p className="font-sans text-label-md text-ink-soft">
                    {producto.proveedor?.razon_social ?? 'Sin proveedor'}
                  </p>
                </div>
                <span className={producto.estado === 'activo' ? 'text-success' : 'text-ink-soft'}>
                  {producto.estado === 'activo' ? 'Activo' : 'Inactivo'}
                </span>
              </div>
              <div className="mt-3 flex items-end justify-between">
                <div>
                  <p className="font-sans text-label-md text-ink-soft">Stock Local / Depósito</p>
                  <p className="font-sans text-body-md text-ink">
                    {stockLocal} / {stockDeposito}
                  </p>
                </div>
                <p className="font-display text-headline-md text-accent-darker">
                  {formatCurrency(producto.precio_venta)}
                </p>
              </div>
            </button>
          )
        })}
      </div>

      <button
        type="button"
        onClick={() => setModal({ tipo: 'nuevo' })}
        aria-label="Nuevo producto"
        className="fixed bottom-[calc(96px+env(safe-area-inset-bottom,0px))] right-5 z-30 flex h-14 w-14 items-center justify-center rounded-full bg-accent text-white shadow-lg hover:bg-accent-dark"
      >
        <IconMas className="h-7 w-7" />
      </button>

      {modal && (
        <ProductoFormSheet
          producto={modal.tipo === 'editar' ? modal.producto : undefined}
          codigoBarrasInicial={modal.tipo === 'nuevo' ? modal.codigoBarras : undefined}
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

      {escaneando && (
        <Suspense fallback={null}>
          <BarcodeScanner onDetect={handleEscaneo} onClose={() => setEscaneando(false)} />
        </Suspense>
      )}

      {actualizandoPrecios && (
        <ActualizarPreciosSheet
          productos={productos}
          proveedores={proveedores}
          onClose={() => setActualizandoPrecios(false)}
          onSaved={(cantidad) => {
            setActualizandoPrecios(false)
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
