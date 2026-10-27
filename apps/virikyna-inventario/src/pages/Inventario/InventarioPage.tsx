import { lazy, Suspense, useEffect, useMemo, useState } from 'react'
import type { Proveedor } from '@virikyna/shared'
import {
  BadgeStock,
  BottomSheet,
  cantidadFiltrosAplicados,
  cargarProductosInventario,
  ChipsStock,
  coincideBusquedaInventario,
  ControlSegmentado,
  ESTADO_OPCIONES,
  EstadoBadge,
  filtrarInventario,
  friendlyError,
  mensajeListadoVacio,
  ProductoLinea,
  SelectBuscable,
  stockTotal,
  useFiltrosInventario,
} from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { usePerfil } from '../../auth/AuthContext'
import { IconBuscar, IconCamara, IconMas, IconPorcentaje } from '../../components/icons'
import { ProductoFormSheet } from './ProductoFormSheet'
import { ActualizarPreciosSheet } from './ActualizarPreciosSheet'
import { MarcarIvaSheet } from './MarcarIvaSheet'
import type { ProductoConRelaciones } from './types'

const BarcodeScanner = lazy(() => import('../../components/BarcodeScanner'))

type Modal =
  | { tipo: 'nuevo'; codigoBarras?: string; nombre?: string }
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
  // Mismos filtros que Local y Gestión (docs/64), en la URL y recordados en la sesión.
  const { filtros, busqueda, setBusqueda, aplicar, limpiar } = useFiltrosInventario()
  const [verFiltros, setVerFiltros] = useState(false)
  // true mientras lo que hay en el buscador vino de la cámara (se apaga apenas se tipea).
  const [vieneDeEscaneo, setVieneDeEscaneo] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [modal, setModal] = useState<Modal>(null)
  const [escaneando, setEscaneando] = useState(false)
  const [actualizandoPrecios, setActualizandoPrecios] = useState(false)
  const [marcandoIva, setMarcandoIva] = useState(false)
  const [resultadoPrecios, setResultadoPrecios] = useState<string | null>(null)

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
      setProductos(productosRes.data as ProductoConRelaciones[])
    }
    setProveedores((proveedoresRes.data ?? []) as Proveedor[])
    setLoading(false)
  }

  useEffect(() => {
    cargar()
  }, [])

  // Sin encabezados para ordenar en el celular: nombre, o stock ascendente en los chips de problemas.
  const { visibles: productosFiltrados, totalEstado, contadores } = useMemo(
    () => filtrarInventario(productos, filtros, { stockDe: stockTotal, coincideBusqueda: coincideBusquedaInventario }),
    // filtros es un objeto nuevo en cada render: dependencias por campo.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [productos, filtros.estado, filtros.stock, filtros.marca, filtros.proveedor, filtros.q],
  )
  const marcas = useMemo(
    () =>
      [...new Set(productos.map((p) => p.marca).filter((m): m is string => !!m))]
        .sort((a, b) => a.localeCompare(b, 'es'))
        .map((m) => ({ value: m, label: m })),
    [productos],
  )
  const opcionesProveedor = useMemo(() => proveedores.map((p) => ({ value: p.id, label: p.razon_social })), [proveedores])
  const hayFiltros = cantidadFiltrosAplicados(filtros) > 0
  const filtrosEnSheet = Number(!!filtros.marca) + Number(!!filtros.proveedor)
  const vacio = mensajeListadoVacio(filtros)

  // Escanear con la cámara llena el buscador y filtra la lista (igual que en Local y Gestión), en
  // vez de saltar directo a editar/crear: si el producto existe aparece en la lista para tocarlo, y
  // si no existe la lista vacía ofrece crearlo con ese código.
  function handleEscaneo(codigo: string) {
    setEscaneando(false)
    setBusqueda(codigo)
    setVieneDeEscaneo(true)
  }

  // Lo escaneado es siempre un código (aunque sea alfanumérico, Code 128/39, o corto). Tipeado a
  // mano, un número largo es casi seguro un código; cualquier otro texto se toma como nombre.
  const textoBusqueda = busqueda.trim()
  const esCodigo = vieneDeEscaneo || /^\d{6,}$/.test(textoBusqueda)

  if (!rol) return null

  return (
    // Un solo scroll (el de <main> en AppShell): la lista crece con la página. El buscador queda
    // pegado arriba con sticky en vez de tener la lista su propio scroll anidado.
    <div className="flex flex-col gap-stack-md">
      <div className="flex items-start justify-between gap-2">
        <div>
          <h1 className="font-display text-headline-lg text-accent-darker">Inventario</h1>
          <p className="mt-1 font-sans text-body-md text-ink-soft">Catálogo, precios y stock por ubicación.</p>
        </div>
        <div className="flex flex-shrink-0 gap-2">
          {/* IVA de productos (docs/47): solo admin, igual que los márgenes. */}
          {rol === 'admin' && (
            <button
              type="button"
              onClick={() => setMarcandoIva(true)}
              aria-label="Marcar productos con o sin IVA"
              className="flex min-w-12 items-center justify-center rounded border border-line bg-surface px-3 py-3.5 font-sans text-label-bold text-accent-dark hover:bg-accent-light"
            >
              IVA
            </button>
          )}
          {/* Con texto: solo el ícono "%" no se entendía (pedido de Alicia, 2026-10-27). */}
          <button
            type="button"
            onClick={() => setActualizandoPrecios(true)}
            aria-label="Precios: actualización masiva"
            className="flex flex-shrink-0 items-center justify-center gap-1 rounded border border-line bg-surface px-3 py-3.5 font-sans text-label-bold text-accent-dark hover:bg-accent-light"
          >
            <IconPorcentaje className="h-5 w-5" />
            Precios
          </button>
        </div>
      </div>

      <div className="sticky -top-stack-md z-10 -mx-stack-md flex gap-2 bg-bg px-stack-md py-2">
        <div className="relative flex-1">
          <IconBuscar className="pointer-events-none absolute left-3 top-1/2 h-5 w-5 -translate-y-1/2 text-ink-soft" />
          <input
            value={busqueda}
            onChange={(e) => {
              setBusqueda(e.target.value)
              setVieneDeEscaneo(false)
            }}
            placeholder="Buscar nombre, marca, código o proveedor..."
            className="w-full rounded border border-line bg-surface py-3.5 pl-11 pr-12 font-sans text-body-md text-ink outline-none focus:border-accent"
          />
          {busqueda && (
            <button
              type="button"
              onClick={() => {
                setBusqueda('')
                setVieneDeEscaneo(false)
              }}
              aria-label="Limpiar búsqueda"
              className="absolute right-1 top-1/2 flex h-11 w-11 -translate-y-1/2 items-center justify-center rounded text-ink-soft active:bg-accent-light"
            >
              <span aria-hidden="true">✕</span>
            </button>
          )}
        </div>
        <button
          type="button"
          onClick={() => setEscaneando(true)}
          aria-label="Escanear código de barras"
          className="flex min-w-12 items-center justify-center rounded border border-line bg-surface px-4 text-accent-dark hover:bg-accent-light"
        >
          <IconCamara className="h-6 w-6" />
        </button>
      </div>

      {/* Filtros: estado y "Filtros (N)" (marca/proveedor en un sheet), chips con scroll horizontal. */}
      <div className="flex flex-col gap-3">
        <div className="flex items-end gap-2">
          <div className="min-w-0 flex-1">
            <ControlSegmentado
              legend="Estado"
              ocultarLegend
              size="touch"
              opciones={ESTADO_OPCIONES}
              value={filtros.estado}
              onChange={(estado) => aplicar({ estado })}
            />
          </div>
          <button
            type="button"
            onClick={() => setVerFiltros(true)}
            className={`flex min-h-[58px] shrink-0 items-center rounded border px-4 font-sans text-label-bold ${
              filtrosEnSheet > 0 ? 'border-accent bg-accent-light text-accent-darker' : 'border-line bg-surface text-accent-dark'
            }`}
          >
            Filtros{filtrosEnSheet > 0 ? ` (${filtrosEnSheet})` : ''}
          </button>
        </div>
        <ChipsStock size="touch" value={filtros.stock} contadores={contadores} onChange={(stock) => aplicar({ stock })} />
        <div className="flex items-center justify-between gap-2">
          <p className="font-sans text-label-md text-ink-soft" aria-live="polite">
            {loading ? 'Cargando productos…' : `Mostrando ${productosFiltrados.length} de ${totalEstado}`}
          </p>
          {hayFiltros && (
            <button
              type="button"
              onClick={() => {
                limpiar()
                setVieneDeEscaneo(false)
              }}
              className="min-h-11 rounded px-3 font-sans text-label-bold text-accent-dark active:bg-accent-light"
            >
              Limpiar filtros
            </button>
          )}
        </div>
      </div>

      {error && <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>}
      {resultadoPrecios && (
        <p className="rounded bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">
          {resultadoPrecios}
        </p>
      )}

      <div className="space-y-3">
        {loading && <p className="py-6 text-center font-sans text-body-md text-ink-soft">Cargando...</p>}

        {!loading && productosFiltrados.length === 0 && (
          <div className="flex flex-col items-center gap-3 py-6">
            <p className="text-center font-sans text-body-md text-ink-soft">
              {productos.length === 0 ? 'No hay productos cargados todavía.' : vacio.texto}
            </p>
            {productos.length > 0 && vacio.conLimpiar && (
              <button
                type="button"
                onClick={() => {
                  limpiar()
                  setVieneDeEscaneo(false)
                }}
                className="min-h-12 rounded px-4 font-sans text-label-bold text-accent-dark active:bg-accent-light"
              >
                Limpiar filtros
              </button>
            )}
            {textoBusqueda && (
              <button
                type="button"
                onClick={() =>
                  setModal(
                    esCodigo
                      ? { tipo: 'nuevo', codigoBarras: textoBusqueda }
                      : { tipo: 'nuevo', nombre: textoBusqueda },
                  )
                }
                className="flex min-h-12 items-center gap-1 rounded border border-accent/60 px-4 font-sans text-label-bold text-accent-dark active:bg-accent-light"
              >
                <IconMas className="h-5 w-5" />
                Crear producto {esCodigo ? 'con este código' : `"${textoBusqueda}"`}
              </button>
            )}
          </div>
        )}

        {productosFiltrados.map((producto) => {
          const inactivo = producto.estado !== 'activo'
          return (
            <button
              key={producto.id}
              type="button"
              onClick={() => setModal({ tipo: 'editar', producto })}
              className={`w-full rounded-lg border border-line bg-surface p-4 text-left shadow-sm active:bg-bg ${inactivo ? 'opacity-60' : ''}`}
            >
              <ProductoLinea producto={producto} precio={producto.precio_venta} tamano="card">
                <span className="flex flex-wrap items-center gap-x-3 gap-y-1">
                  <BadgeStock stock={stockTotal(producto)} minimo={Number(producto.stock_minimo)} variante="linea" />
                  {inactivo && <EstadoBadge variant="neutral">INACTIVO</EstadoBadge>}
                  {producto.precio_manual !== null && <span>Precio manual</span>}
                  {Number(producto.iva_porcentaje) === 0 && <span>Sin IVA</span>}
                </span>
              </ProductoLinea>
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
          key={modal.tipo === 'editar' ? modal.producto.id : 'nuevo'}
          producto={modal.tipo === 'editar' ? modal.producto : undefined}
          codigoBarrasInicial={modal.tipo === 'nuevo' ? modal.codigoBarras : undefined}
          nombreInicial={modal.tipo === 'nuevo' ? modal.nombre : undefined}
          proveedores={proveedores}
          rol={rol}
          onClose={() => setModal(null)}
          onSaved={() => {
            setModal(null)
            cargar()
          }}
          onStockChanged={cargar}
          onEliminado={(nombre) => {
            setModal(null)
            setResultadoPrecios(`Se eliminó ${nombre}.`)
            cargar()
          }}
          onEditarExistente={(id) => {
            const existente = productos.find((p) => p.id === id)
            if (existente) setModal({ tipo: 'editar', producto: existente })
          }}
        />
      )}

      {verFiltros && (
        <BottomSheet
          title="Filtros"
          onClose={() => setVerFiltros(false)}
          dialogo={{ onEscape: () => setVerFiltros(false) }}
          footer={
            <button
              type="button"
              onClick={() => setVerFiltros(false)}
              className="min-h-12 w-full rounded bg-accent px-4 font-sans text-label-bold text-white active:bg-accent-dark"
            >
              Ver {productosFiltrados.length} producto{productosFiltrados.length === 1 ? '' : 's'}
            </button>
          }
        >
          {/* Lugar abajo para que la lista de opciones abra sin quedar cortada. */}
          <div className="flex min-h-[22rem] flex-col gap-stack-md">
            <label className="flex flex-col gap-2">
              <span className="font-sans text-label-md text-ink">Marca</span>
              <SelectBuscable
                label="Marca"
                todasLabel="Todas las marcas"
                size="touch"
                value={filtros.marca}
                opciones={marcas}
                onChange={(marca) => aplicar({ marca })}
              />
            </label>
            <label className="flex flex-col gap-2">
              <span className="font-sans text-label-md text-ink">Proveedor</span>
              <SelectBuscable
                label="Proveedor"
                todasLabel="Todos los proveedores"
                size="touch"
                value={filtros.proveedor}
                opciones={opcionesProveedor}
                onChange={(proveedor) => aplicar({ proveedor })}
              />
            </label>
            {filtrosEnSheet > 0 && (
              <button
                type="button"
                onClick={() => aplicar({ marca: '', proveedor: '' })}
                className="min-h-12 self-start rounded px-3 font-sans text-label-bold text-accent-dark active:bg-accent-light"
              >
                Quitar marca y proveedor
              </button>
            )}
          </div>
        </BottomSheet>
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

      {marcandoIva && rol === 'admin' && (
        <MarcarIvaSheet
          productos={productos}
          onClose={() => setMarcandoIva(false)}
          onSaved={(cantidad) => {
            setMarcandoIva(false)
            setResultadoPrecios(`IVA cambiado en ${cantidad} producto${cantidad === 1 ? '' : 's'}.`)
            cargar()
          }}
        />
      )}
    </div>
  )
}
