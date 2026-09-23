import { useEffect, useState, type FormEvent } from 'react'
import type { PostgrestError } from '@supabase/supabase-js'
import type {
  Auditoria,
  CambioMargenProducto,
  EstadoProducto,
  Proveedor,
  RolUsuario,
  UbicacionStock,
} from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import {
  calcularPrecioVenta,
  formatCurrency,
  formatFechaHora,
  friendlyError,
  generarCodigoInterno,
  historialDeMargen,
  nombresPorId,
} from '@virikyna/shared'
import { CodigoBarrasBox } from '@virikyna/shared'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, ErrorText, inputClass } from '../../components/FormField'
import { Modal } from '../../components/Modal'
import { AjustarStockSheet } from './AjustarStockSheet'
import { HistorialPrecioTab } from './HistorialPrecioTab'
import type { ProductoConRelaciones } from './types'

const IVA_DEFAULT = 21

// Input compacto para que el formulario completo entre en una sola pantalla sin scroll interno.
const inputCompacto = inputClass.replace('py-2.5', 'py-2')

type ProductoCreado = { id: string; nombre: string; costo: number; marca: string | null; codigo_barras: string | null }

type Props = {
  producto?: ProductoConRelaciones
  proveedores: Proveedor[]
  rol: RolUsuario
  nombreInicial?: string
  onClose: () => void
  onSaved: (creado?: ProductoCreado) => void
  // Desde el aviso de código duplicado: ir directo a editar el producto que ya existe.
  onEditarExistente?: (id: string) => void
  onStockChanged: () => void
}

export function ProductoFormSheet({
  producto,
  proveedores,
  rol,
  nombreInicial,
  onClose,
  onSaved,
  onStockChanged,
  onEditarExistente,
}: Props) {
  const esAdmin = rol === 'admin'

  const [nombre, setNombre] = useState(producto?.nombre ?? nombreInicial ?? '')
  const [descripcion, setDescripcion] = useState(producto?.descripcion ?? '')
  const [codigoBarras, setCodigoBarras] = useState(producto?.codigo_barras ?? '')
  const [proveedorId, setProveedorId] = useState(producto?.proveedor_id ?? '')
  const [marca, setMarca] = useState(producto?.marca ?? '')
  const [costo, setCosto] = useState(String(producto?.costo ?? ''))
  const [margen1, setMargen1] = useState(String(producto?.margen_1 ?? 0))
  const [margen2, setMargen2] = useState(String(producto?.margen_2 ?? 0))
  // En alta, los márgenes siguen al proveedor elegido hasta que un admin los edite a mano.
  const [margenesAuto, setMargenesAuto] = useState(!producto)
  const [stockMinimo, setStockMinimo] = useState(String(producto?.stock_minimo ?? 0))
  const [estado, setEstado] = useState<EstadoProducto>(producto?.estado ?? 'activo')
  const [stock, setStock] = useState(producto?.stock_ubicaciones ?? [])
  const [ajusteUbicacion, setAjusteUbicacion] = useState<UbicacionStock | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [dirty, setDirty] = useState(false)
  const [confirmCerrar, setConfirmCerrar] = useState(false)
  const [tab, setTab] = useState<'datos' | 'historial'>('datos')
  const [cambiosMargen, setCambiosMargen] = useState<CambioMargenProducto[]>([])
  const [usuariosCambio, setUsuariosCambio] = useState<Map<string, string>>(new Map())
  const [cargandoHistorial, setCargandoHistorial] = useState(false)

  function pedirCierre() {
    if (dirty) {
      setConfirmCerrar(true)
    } else {
      onClose()
    }
  }

  useEffect(() => {
    if (!margenesAuto) return
    const proveedor = proveedores.find((p) => p.id === proveedorId)
    setMargen1(String(proveedor?.margen_1_default ?? 0))
    setMargen2(String(proveedor?.margen_2_default ?? 0))
  }, [proveedorId, margenesAuto, proveedores])

  // Historial de precio (prompt 5): se deriva de `auditoria`, no de una tabla propia — un solo
  // fetch al abrir la ficha alimenta tanto el tab "Historial de precio" como la línea de "última
  // modificación" de más abajo. Solo para admin: `auditoria` tiene RLS de solo-lectura-admin
  // (docs/06_estructura_de_datos.md), igual que el margen ya es un campo admin-only acá abajo.
  useEffect(() => {
    if (!producto || !esAdmin) return
    let cancelado = false
    setCargandoHistorial(true)
    supabase
      .from('auditoria')
      .select('*')
      .eq('tabla_afectada', 'productos')
      .eq('registro_id', producto.id)
      .eq('accion', 'edicion')
      .order('created_at', { ascending: false })
      .then(async ({ data }) => {
        const cambios = historialDeMargen((data ?? []) as unknown as Auditoria[])
        const usuarios = await nombresPorId(
          supabase,
          cambios.map((c) => c.usuarioId),
        )
        if (cancelado) return
        setCambiosMargen(cambios)
        setUsuariosCambio(usuarios)
        setCargandoHistorial(false)
      })
    return () => {
      cancelado = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [producto?.id, esAdmin])

  const buscarProductoPorCodigo = async (codigo: string) => {
    const { data } = await supabase.from('productos').select('id, nombre').eq('codigo_barras', codigo).maybeSingle()
    return data ?? null
  }

  const costoNum = Number(costo) || 0
  const margen1Num = Number(margen1) || 0
  const margen2Num = Number(margen2) || 0
  const precioVenta = calcularPrecioVenta(costoNum, margen1Num, margen2Num, IVA_DEFAULT)

  async function recargarStock() {
    if (!producto) return
    const { data } = await supabase
      .from('stock_ubicaciones')
      .select('ubicacion, cantidad')
      .eq('producto_id', producto.id)
    setStock(data ?? [])
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)

    const nombreLimpio = nombre.trim()
    if (!nombreLimpio) {
      setError('El nombre es obligatorio.')
      return
    }
    if (costoNum < 0) {
      setError('El costo no puede ser negativo.')
      return
    }

    const codigoBarrasLimpio = codigoBarras.trim() || null

    const payload = {
      nombre: nombreLimpio,
      descripcion: descripcion.trim() || null,
      codigo_barras: codigoBarrasLimpio,
      proveedor_id: proveedorId || null,
      marca: marca.trim() || null,
      costo: costoNum,
      margen_1: margen1Num,
      margen_2: margen2Num,
      stock_minimo: Number(stockMinimo) || 0,
      estado,
    }

    setSaving(true)
    let dbError: PostgrestError | null = null
    let creado: ProductoCreado | undefined

    if (producto) {
      const { error } = await supabase.from('productos').update(payload).eq('id', producto.id)
      dbError = error
    } else {
      const { data, error } = await supabase
        .from('productos')
        .insert({
          ...payload,
          codigo_interno: codigoBarrasLimpio ? null : generarCodigoInterno(),
        })
        .select('id, nombre, costo, marca, codigo_barras')
        .single()
      dbError = error
      creado = data ?? undefined
    }
    setSaving(false)

    if (dbError) {
      setError(friendlyError(dbError))
      return
    }
    onSaved(creado)
  }

  const stockLocal = stock.find((s) => s.ubicacion === 'local')?.cantidad ?? 0
  const stockDeposito = stock.find((s) => s.ubicacion === 'deposito')?.cantidad ?? 0

  return (
    <Modal
      title={producto ? 'Editar producto' : 'Nuevo producto'}
      onClose={pedirCierre}
      widthClassName="max-w-[960px]"
      footer={
        tab === 'datos' || !producto || !esAdmin ? (
          <div className="flex flex-col gap-2">
            {error && <ErrorText>{error}</ErrorText>}
            <div className="flex justify-end gap-2">
              <button
                type="button"
                onClick={pedirCierre}
                className="rounded border border-line px-5 py-2.5 font-sans text-label-bold text-ink-soft hover:bg-bg"
              >
                Cancelar
              </button>
              <button
                type="submit"
                form="producto-form"
                disabled={saving}
                className="rounded bg-accent px-5 py-2.5 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
              >
                {saving ? 'Guardando...' : 'Guardar producto'}
              </button>
            </div>
          </div>
        ) : undefined
      }
    >
      {producto && esAdmin && (
        <div className="mb-stack-md flex gap-1 border-b border-line">
          <button
            type="button"
            onClick={() => setTab('datos')}
            className={[
              'rounded-t px-4 py-2 font-sans text-label-bold',
              tab === 'datos' ? 'border-b-2 border-accent text-accent-darker' : 'text-ink-soft hover:text-accent-darker',
            ].join(' ')}
          >
            Datos
          </button>
          <button
            type="button"
            onClick={() => setTab('historial')}
            className={[
              'rounded-t px-4 py-2 font-sans text-label-bold',
              tab === 'historial'
                ? 'border-b-2 border-accent text-accent-darker'
                : 'text-ink-soft hover:text-accent-darker',
            ].join(' ')}
          >
            Historial de precio
          </button>
        </div>
      )}

      {tab === 'historial' && producto && esAdmin ? (
        <HistorialPrecioTab cambios={cambiosMargen} usuarios={usuariosCambio} loading={cargandoHistorial} />
      ) : (
      <form
        id="producto-form"
        onSubmit={handleSubmit}
        onChangeCapture={() => setDirty(true)}
        className="grid grid-cols-[minmax(0,1fr)_240px] gap-stack-md"
      >
        <div className="flex flex-col gap-3">
          <CodigoBarrasBox
            value={codigoBarras}
            onChange={(v) => {
              setCodigoBarras(v)
              setDirty(true)
            }}
            buscarPorCodigo={buscarProductoPorCodigo}
            excluirId={producto?.id}
            onEditarExistente={onEditarExistente}
          />

          <div className="grid grid-cols-2 gap-3">
            <Field label="Nombre">
              <input
                value={nombre}
                onChange={(e) => setNombre(e.target.value)}
                placeholder="Ej: Agua mineral 500ml"
                className={inputCompacto}
              />
            </Field>
            <Field label="Marca">
              <input
                value={marca}
                onChange={(e) => setMarca(e.target.value)}
                placeholder="Ej: Coca Cola"
                className={inputCompacto}
              />
            </Field>
          </div>

          <Field label="Descripción (opcional)">
            <input value={descripcion} onChange={(e) => setDescripcion(e.target.value)} className={inputCompacto} />
          </Field>

          <Field label="Proveedor">
            <select value={proveedorId} onChange={(e) => setProveedorId(e.target.value)} className={inputCompacto}>
              <option value="">Sin proveedor</option>
              {proveedores.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.razon_social}
                </option>
              ))}
            </select>
          </Field>

          <div className="rounded-lg border border-line p-3">
            <p className="mb-2 font-sans text-label-bold text-ink">Precio</p>
            <div className="grid grid-cols-3 gap-3">
              <Field label="Costo">
                <input
                  type="number"
                  min="0"
                  step="0.01"
                  value={costo}
                  onChange={(e) => setCosto(e.target.value)}
                  placeholder="$ 0,00"
                  className={inputCompacto}
                />
              </Field>
              <Field label="Margen 1 (%)">
                <input
                  type="number"
                  step="0.01"
                  value={margen1}
                  disabled={!esAdmin}
                  onChange={(e) => {
                    setMargenesAuto(false)
                    setMargen1(e.target.value)
                  }}
                  className={inputCompacto}
                />
              </Field>
              <Field label="Margen 2 (%)">
                <input
                  type="number"
                  step="0.01"
                  value={margen2}
                  disabled={!esAdmin}
                  onChange={(e) => {
                    setMargenesAuto(false)
                    setMargen2(e.target.value)
                  }}
                  className={inputCompacto}
                />
              </Field>
            </div>
            {!esAdmin && (
              <p className="mt-2 font-sans text-label-md text-ink-soft">
                El margen lo define un administrador. Como cajero, solo cargás el costo.
              </p>
            )}
            <div className="mt-2 flex items-center justify-between rounded bg-accent-light/50 px-3 py-2">
              <div>
                <p className="font-sans text-label-md text-ink-soft">Precio de venta</p>
                <p className="font-sans text-label-md text-ink-soft">Costo × margen 1 × margen 2 × IVA 21%</p>
              </div>
              <p className="font-display text-headline-md text-accent-darker">{formatCurrency(precioVenta)}</p>
            </div>
            {producto && esAdmin && cambiosMargen.length > 0 && (
              <p className="mt-2 font-sans text-label-md text-ink-soft">
                Última modificación de margen: {formatFechaHora(cambiosMargen[0].createdAt)}
                {usuariosCambio.get(cambiosMargen[0].usuarioId)
                  ? ` — ${usuariosCambio.get(cambiosMargen[0].usuarioId)}`
                  : ''}
              </p>
            )}
          </div>

          <div className="grid grid-cols-2 gap-3">
            <Field label="Stock mínimo">
              <input
                type="number"
                min="0"
                step="1"
                value={stockMinimo}
                onChange={(e) => setStockMinimo(e.target.value)}
                className={inputCompacto}
              />
            </Field>
            {producto && (
              <Field label="Estado">
                <select
                  value={estado}
                  onChange={(e) => setEstado(e.target.value as EstadoProducto)}
                  className={inputCompacto}
                >
                  <option value="activo">Activo</option>
                  <option value="inactivo">Inactivo</option>
                </select>
              </Field>
            )}
          </div>
        </div>

        <aside className="flex flex-col gap-3">
          <div>
            <p className="mb-1.5 font-sans text-label-md text-ink-soft">Vista previa</p>
            <div className="rounded-lg border border-line bg-surface p-3">
              <p className="font-sans text-label-md uppercase text-ink-soft">Código</p>
              <p className="truncate font-sans text-label-bold text-ink">{codigoBarras.trim() || '— sin escanear —'}</p>
              <p className="mt-2 font-sans text-label-md uppercase text-ink-soft">Nombre / marca</p>
              <p className="font-sans text-label-bold text-ink">
                {nombre.trim() || marca.trim() ? [nombre.trim(), marca.trim()].filter(Boolean).join(' · ') : '— vacío —'}
              </p>
              <p className="mt-2 font-sans text-label-md uppercase text-ink-soft">Precio de venta</p>
              <p className="font-display text-headline-md text-accent-darker">{formatCurrency(precioVenta)}</p>
            </div>
          </div>
          <p className="rounded-lg border border-line bg-surface p-3 font-sans text-label-md text-ink-soft">
            Se actualiza en vivo a medida que completás el formulario, para verificar antes de guardar.
          </p>

          {producto && (
            <div className="rounded-lg border border-line bg-surface p-3">
              <p className="font-sans text-label-bold text-ink">Stock por ubicación</p>
              <div className="mt-1.5 flex flex-col gap-1 font-sans text-body-md text-ink">
                <span className="flex items-center justify-between">
                  <span>
                    Local: <strong>{stockLocal}</strong>
                  </span>
                  {esAdmin && (
                    <button
                      type="button"
                      onClick={() => setAjusteUbicacion('local')}
                      className="rounded px-2 py-0.5 font-sans text-label-md text-accent-dark hover:bg-accent-light"
                    >
                      Ajustar
                    </button>
                  )}
                </span>
                <span className="flex items-center justify-between">
                  <span>
                    Depósito: <strong>{stockDeposito}</strong>
                  </span>
                  {esAdmin && (
                    <button
                      type="button"
                      onClick={() => setAjusteUbicacion('deposito')}
                      className="rounded px-2 py-0.5 font-sans text-label-md text-accent-dark hover:bg-accent-light"
                    >
                      Ajustar
                    </button>
                  )}
                </span>
              </div>
              {!esAdmin && (
                <p className="mt-2 font-sans text-label-md text-ink-soft">
                  El ajuste manual de stock lo hace solo un administrador.
                </p>
              )}
            </div>
          )}
        </aside>
      </form>
      )}

      {confirmCerrar && (
        <ConfirmDialog
          title="Cerrar sin guardar"
          mensaje="Hay cambios sin guardar en este formulario. ¿Querés cerrar de todos modos?"
          confirmLabel="Cerrar sin guardar"
          onCancel={() => setConfirmCerrar(false)}
          onConfirm={onClose}
        />
      )}

      {producto && ajusteUbicacion && (
        <AjustarStockSheet
          productoId={producto.id}
          productoNombre={producto.nombre}
          ubicacion={ajusteUbicacion}
          onClose={() => setAjusteUbicacion(null)}
          onSaved={async () => {
            setAjusteUbicacion(null)
            await recargarStock()
            onStockChanged()
          }}
        />
      )}
    </Modal>
  )
}
