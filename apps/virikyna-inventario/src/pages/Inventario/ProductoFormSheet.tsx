import { useEffect, useState, type FormEvent } from 'react'
import type { PostgrestError } from '@supabase/supabase-js'
import type { EstadoProducto, Proveedor, RolUsuario, UbicacionStock } from '@virikyna/shared'
import {
  BottomSheet,
  calcularPrecioVenta,
  formatCurrency,
  friendlyError,
  generarCodigoInterno,
  IVA_DEFAULT,
} from '@virikyna/shared'
import { CodigoBarrasBox } from '@virikyna/shared'
import { buscarProductoPorCodigoBarras } from '../../lib/productos'
import { supabase } from '../../lib/supabaseClient'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, ErrorText, inputClass, selectClass } from '../../components/FormField'
import { AjustarStockSheet } from './AjustarStockSheet'
import type { ProductoConRelaciones } from './types'

type ProductoCreado = { id: string; nombre: string; costo: number }

type Props = {
  producto?: ProductoConRelaciones
  proveedores: Proveedor[]
  rol: RolUsuario
  codigoBarrasInicial?: string
  nombreInicial?: string
  onClose: () => void
  onSaved: (creado?: ProductoCreado) => void
  // Desde el aviso de código duplicado: ir directo a editar el producto que ya existe.
  onEditarExistente?: (id: string) => void
  onStockChanged: () => void
}

// Mismas reglas que apps/virikyna-local/src/pages/Inventario/ProductoFormModal.tsx (alta, edición,
// márgenes exclusivos admin, ajuste de stock exclusivo admin) — solo cambia la presentación
// (bottom sheet en vez de modal centrado) y que el código de barras se puede completar
// escaneando con la cámara, no solo tipeando.
export function ProductoFormSheet({
  producto,
  proveedores,
  rol,
  codigoBarrasInicial,
  nombreInicial,
  onClose,
  onSaved,
  onStockChanged,
  onEditarExistente,
}: Props) {
  const esAdmin = rol === 'admin'

  const [nombre, setNombre] = useState(producto?.nombre ?? nombreInicial ?? '')
  const [descripcion, setDescripcion] = useState(producto?.descripcion ?? '')
  const [codigoBarras, setCodigoBarras] = useState(producto?.codigo_barras ?? codigoBarrasInicial ?? '')
  const [proveedorId, setProveedorId] = useState(producto?.proveedor_id ?? '')
  const [marca, setMarca] = useState(producto?.marca ?? '')
  const [costo, setCosto] = useState(String(producto?.costo ?? ''))
  const [margen1, setMargen1] = useState(String(producto?.margen_1 ?? 0))
  const [margen2, setMargen2] = useState(String(producto?.margen_2 ?? 0))
  const [margenesAuto, setMargenesAuto] = useState(!producto)
  const [stockMinimo, setStockMinimo] = useState(String(producto?.stock_minimo ?? 0))
  const [estado, setEstado] = useState<EstadoProducto>(producto?.estado ?? 'activo')
  const [stock, setStock] = useState(producto?.stock_ubicaciones ?? [])
  const [ajusteUbicacion, setAjusteUbicacion] = useState<UbicacionStock | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [dirty, setDirty] = useState(false)
  const [confirmCerrar, setConfirmCerrar] = useState(false)

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
        .select('id, nombre, costo')
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

  const buscarProductoPorCodigo = async (codigo: string) => {
    const p = await buscarProductoPorCodigoBarras(codigo)
    return p ? { id: p.id, nombre: p.nombre } : null
  }

  const stockLocal = stock.find((s) => s.ubicacion === 'local')?.cantidad ?? 0
  const stockDeposito = stock.find((s) => s.ubicacion === 'deposito')?.cantidad ?? 0

  return (
    <BottomSheet title={producto ? 'Editar producto' : 'Nuevo producto'} onClose={pedirCierre}>
      <form onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
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

        <Field label="Nombre">
          <input value={nombre} onChange={(e) => setNombre(e.target.value)} className={inputClass} />
        </Field>

        <Field label="Marca">
          <input value={marca} onChange={(e) => setMarca(e.target.value)} className={inputClass} />
        </Field>

        <Field label="Descripción">
          <input value={descripcion} onChange={(e) => setDescripcion(e.target.value)} className={inputClass} />
        </Field>

        <Field label="Proveedor">
          <select value={proveedorId} onChange={(e) => setProveedorId(e.target.value)} className={selectClass}>
            <option value="">Sin proveedor</option>
            {proveedores.map((p) => (
              <option key={p.id} value={p.id}>
                {p.razon_social}
              </option>
            ))}
          </select>
        </Field>
        <div className="rounded border border-line p-4">
          <div className="grid grid-cols-3 gap-stack-sm">
            <Field label="Costo">
              <input
                type="number"
                inputMode="decimal"
                min="0"
                step="0.01"
                value={costo}
                onChange={(e) => setCosto(e.target.value)}
                className={inputClass}
              />
            </Field>
            <Field label="Margen 1 (%)">
              <input
                type="number"
                inputMode="decimal"
                step="0.01"
                value={margen1}
                disabled={!esAdmin}
                onChange={(e) => {
                  setMargenesAuto(false)
                  setMargen1(e.target.value)
                }}
                className={inputClass}
              />
            </Field>
            <Field label="Margen 2 (%)">
              <input
                type="number"
                inputMode="decimal"
                step="0.01"
                value={margen2}
                disabled={!esAdmin}
                onChange={(e) => {
                  setMargenesAuto(false)
                  setMargen2(e.target.value)
                }}
                className={inputClass}
              />
            </Field>
          </div>
          {!esAdmin && (
            <p className="mt-2 font-sans text-label-md text-ink-soft">
              El margen lo define un administrador. Como cajero, solo cargás el costo.
            </p>
          )}
          <p className="mt-3 font-display text-headline-md text-accent-darker">
            Precio de venta: {formatCurrency(precioVenta)}
          </p>
          <p className="font-sans text-label-md text-ink-soft">Costo × margen 1 × margen 2 × IVA 21%</p>
        </div>

        <Field label="Stock mínimo" hint="Dispara la alerta de stock bajo.">
          <input
            type="number"
            inputMode="numeric"
            min="0"
            step="1"
            value={stockMinimo}
            onChange={(e) => setStockMinimo(e.target.value)}
            className={inputClass}
          />
        </Field>

        {producto && (
          <Field label="Estado">
            <select value={estado} onChange={(e) => setEstado(e.target.value as EstadoProducto)} className={selectClass}>
              <option value="activo">Activo</option>
              <option value="inactivo">Inactivo</option>
            </select>
          </Field>
        )}

        {producto && (
          <div className="rounded border border-line p-4">
            <p className="font-sans text-label-bold text-ink">Stock por ubicación</p>
            <div className="mt-2 flex flex-col gap-2 font-sans text-body-md text-ink">
              <span className="flex items-center justify-between">
                Local: <strong>{stockLocal}</strong>
                {esAdmin && (
                  <button
                    type="button"
                    onClick={() => setAjusteUbicacion('local')}
                    className="rounded px-3 py-1.5 font-sans text-label-bold text-accent-dark hover:bg-accent-light"
                  >
                    Ajustar
                  </button>
                )}
              </span>
              <span className="flex items-center justify-between">
                Depósito: <strong>{stockDeposito}</strong>
                {esAdmin && (
                  <button
                    type="button"
                    onClick={() => setAjusteUbicacion('deposito')}
                    className="rounded px-3 py-1.5 font-sans text-label-bold text-accent-dark hover:bg-accent-light"
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

        {error && <ErrorText>{error}</ErrorText>}

        <div className="mt-stack-md flex flex-col gap-3">
          <button
            type="submit"
            disabled={saving}
            className="rounded bg-accent px-4 py-4 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
          >
            {saving ? 'Guardando...' : 'Guardar'}
          </button>
          <button
            type="button"
            onClick={pedirCierre}
            className="rounded px-4 py-3 font-sans text-label-bold text-ink-soft hover:bg-bg"
          >
            Cancelar
          </button>
        </div>
      </form>

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

      {confirmCerrar && (
        <ConfirmDialog
          title="Cerrar sin guardar"
          mensaje="Hay cambios sin guardar en este formulario. ¿Querés cerrar de todos modos?"
          confirmLabel="Cerrar sin guardar"
          onCancel={() => setConfirmCerrar(false)}
          onConfirm={onClose}
        />
      )}
    </BottomSheet>
  )
}
