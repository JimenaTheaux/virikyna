import { useState, type FormEvent } from 'react'
import type { UbicacionStock } from '@virikyna/shared'
import { BottomSheet, friendlyError, MOTIVOS_AJUSTE_STOCK } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, ErrorText, inputClass, selectClass } from '../../components/FormField'

// Mismo RPC ajustar_stock que Virikyna Local (docs/06_estructura_de_datos.md) — exclusivo
// admin, motivo obligatorio, sin motor local que amortigüe: si se corta la conexión a mitad
// de la llamada, se muestra el error y el usuario reintenta (docs/05_stack_tecnico.md, sección 2).
type Props = {
  productoId: string
  productoNombre: string
  ubicacion: UbicacionStock
  onClose: () => void
  onSaved: () => void
}

export function AjustarStockSheet({ productoId, productoNombre, ubicacion, onClose, onSaved }: Props) {
  const [cantidad, setCantidad] = useState('')
  const [motivoTipo, setMotivoTipo] = useState<(typeof MOTIVOS_AJUSTE_STOCK)[number]>(MOTIVOS_AJUSTE_STOCK[0])
  const [detalle, setDetalle] = useState('')
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

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)

    const cantidadNum = Number(cantidad)
    if (!cantidadNum) {
      setError('Ingresá una cantidad distinta de cero (positiva para sumar, negativa para restar).')
      return
    }
    if (motivoTipo === 'Otro' && !detalle.trim()) {
      setError('Contá brevemente el motivo del ajuste.')
      return
    }

    const motivo = detalle.trim() ? `${motivoTipo}: ${detalle.trim()}` : motivoTipo

    setSaving(true)
    const { error: dbError } = await supabase.rpc('ajustar_stock', {
      p_producto_id: productoId,
      p_ubicacion: ubicacion,
      p_cantidad: cantidadNum,
      p_motivo: motivo,
    })
    setSaving(false)

    if (dbError) {
      setError(friendlyError(dbError))
      return
    }
    onSaved()
  }

  return (
    <BottomSheet title={`Ajustar stock — ${ubicacion === 'local' ? 'Local' : 'Depósito'}`} onClose={pedirCierre}>
      <form onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        <p className="font-sans text-body-md text-ink-soft">{productoNombre}</p>

        <Field label="Cantidad" hint="Positiva para sumar, negativa para restar.">
          <input
            type="number"
            inputMode="numeric"
            step="1"
            autoFocus
            value={cantidad}
            onChange={(e) => setCantidad(e.target.value)}
            className={inputClass}
          />
        </Field>

        <Field label="Motivo">
          <select
            value={motivoTipo}
            onChange={(e) => setMotivoTipo(e.target.value as (typeof MOTIVOS_AJUSTE_STOCK)[number])}
            className={selectClass}
          >
            {MOTIVOS_AJUSTE_STOCK.map((m) => (
              <option key={m} value={m}>
                {m}
              </option>
            ))}
          </select>
        </Field>

        <Field label="Detalle" hint={motivoTipo === 'Otro' ? 'Obligatorio' : 'Opcional'}>
          <input value={detalle} onChange={(e) => setDetalle(e.target.value)} className={inputClass} />
        </Field>

        {error && <ErrorText>{error}</ErrorText>}

        <div className="mt-stack-md flex flex-col gap-3">
          <button
            type="submit"
            disabled={saving}
            className="rounded bg-accent px-4 py-4 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
          >
            {saving ? 'Guardando...' : 'Confirmar ajuste'}
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
    </BottomSheet>
  )
}
