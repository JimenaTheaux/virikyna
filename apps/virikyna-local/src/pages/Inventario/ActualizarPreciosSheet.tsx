import { useMemo, useState, type FormEvent } from 'react'
import type { Proveedor } from '@virikyna/shared'
import { friendlyError } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, ErrorText, inputClass, selectClass } from '../../components/FormField'
import { Modal } from '../../components/Modal'
import type { ProductoConRelaciones } from './types'

type Modo = 'proveedor' | 'seleccion'

type Props = {
  productos: ProductoConRelaciones[]
  proveedores: Proveedor[]
  seleccionInicial: string[]
  onClose: () => void
  onSaved: (cantidad: number) => void
}

// Actualización masiva de precios (docs/04_modulos_y_funciones.md, módulo 5) — el % se aplica
// sobre el costo vía RPC actualizar_precios_masivo, que recalcula precio_venta con el margen
// vigente de cada producto. Elegir proveedor o selección puntual son excluyentes entre sí.
export function ActualizarPreciosSheet({ productos, proveedores, seleccionInicial, onClose, onSaved }: Props) {
  const [modo, setModo] = useState<Modo>(seleccionInicial.length > 0 ? 'seleccion' : 'proveedor')
  const [proveedorId, setProveedorId] = useState('')
  const [seleccion, setSeleccion] = useState<Set<string>>(new Set(seleccionInicial))
  const [busqueda, setBusqueda] = useState('')
  const [porcentaje, setPorcentaje] = useState('')
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

  const productosFiltrados = useMemo(() => {
    const q = busqueda.trim().toLowerCase()
    if (!q) return productos
    return productos.filter(
      (p) => p.nombre.toLowerCase().includes(q) || (p.proveedor?.razon_social ?? '').toLowerCase().includes(q),
    )
  }, [productos, busqueda])

  function toggle(id: string) {
    setSeleccion((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)

    const porcentajeNum = Number(porcentaje)
    if (!porcentaje.trim() || Number.isNaN(porcentajeNum) || porcentajeNum === 0) {
      setError('Ingresá un porcentaje distinto de cero (positivo para aumentar, negativo para bajar).')
      return
    }
    if (modo === 'proveedor' && !proveedorId) {
      setError('Elegí un proveedor.')
      return
    }
    if (modo === 'seleccion' && seleccion.size === 0) {
      setError('Tildá al menos un producto.')
      return
    }

    setSaving(true)
    const { data, error: dbError } = await supabase.rpc('actualizar_precios_masivo', {
      p_porcentaje: porcentajeNum,
      p_proveedor_id: modo === 'proveedor' ? proveedorId : null,
      p_producto_ids: modo === 'seleccion' ? Array.from(seleccion) : null,
    })
    setSaving(false)

    if (dbError) {
      setError(friendlyError(dbError))
      return
    }
    onSaved(Number(data) || 0)
  }

  return (
    <Modal title="Actualización masiva de precios" onClose={pedirCierre} widthClassName="max-w-[640px]">
      <form onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        <div className="flex flex-wrap gap-4">
          <label className="flex items-center gap-2 font-sans text-body-md text-ink">
            <input
              type="radio"
              checked={modo === 'proveedor'}
              onChange={() => setModo('proveedor')}
              className="h-4 w-4 accent-accent"
            />
            Todos los productos de un proveedor
          </label>
          <label className="flex items-center gap-2 font-sans text-body-md text-ink">
            <input
              type="radio"
              checked={modo === 'seleccion'}
              onChange={() => setModo('seleccion')}
              className="h-4 w-4 accent-accent"
            />
            Selección puntual
          </label>
        </div>

        {modo === 'proveedor' && (
          <Field label="Proveedor">
            <select value={proveedorId} onChange={(e) => setProveedorId(e.target.value)} className={selectClass}>
              <option value="">Elegí un proveedor...</option>
              {proveedores.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.razon_social}
                </option>
              ))}
            </select>
          </Field>
        )}

        {modo === 'seleccion' && (
          <div className="flex flex-col gap-2">
            <div className="flex items-center justify-between gap-3">
              <span className="font-sans text-label-bold text-ink">
                Productos ({seleccion.size} seleccionado{seleccion.size === 1 ? '' : 's'})
              </span>
              <input
                value={busqueda}
                onChange={(e) => setBusqueda(e.target.value)}
                placeholder="Buscar producto..."
                className={`${inputClass} w-48 py-2`}
              />
            </div>
            <div className="max-h-64 overflow-y-auto rounded border border-line">
              {productosFiltrados.map((p) => (
                <label
                  key={p.id}
                  className="flex items-center gap-3 border-b border-line px-3 py-2 last:border-0 hover:bg-bg"
                >
                  <input
                    type="checkbox"
                    checked={seleccion.has(p.id)}
                    onChange={() => toggle(p.id)}
                    className="h-4 w-4 accent-accent"
                  />
                  <span className="font-sans text-body-md text-ink">{p.nombre}</span>
                  <span className="ml-auto font-sans text-label-md text-ink-soft">
                    {p.proveedor?.razon_social ?? '—'}
                  </span>
                </label>
              ))}
              {productosFiltrados.length === 0 && (
                <p className="px-3 py-4 text-center font-sans text-body-md text-ink-soft">Sin resultados.</p>
              )}
            </div>
          </div>
        )}

        <Field label="Porcentaje (%)" hint="Positivo para aumentar, negativo para bajar. Se aplica sobre el costo.">
          <input
            type="number"
            step="0.01"
            autoFocus
            value={porcentaje}
            onChange={(e) => setPorcentaje(e.target.value)}
            className={inputClass}
          />
        </Field>

        {error && <ErrorText>{error}</ErrorText>}

        <div className="mt-stack-md flex flex-col gap-3">
          <button
            type="submit"
            disabled={saving}
            className="rounded bg-accent px-4 py-4 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
          >
            {saving ? 'Aplicando...' : 'Aplicar'}
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

      {confirmCerrar && (
        <ConfirmDialog
          title="Cerrar sin guardar"
          mensaje="Hay cambios sin guardar en este formulario. ¿Querés cerrar de todos modos?"
          confirmLabel="Cerrar sin guardar"
          onCancel={() => setConfirmCerrar(false)}
          onConfirm={onClose}
        />
      )}
    </Modal>
  )
}
