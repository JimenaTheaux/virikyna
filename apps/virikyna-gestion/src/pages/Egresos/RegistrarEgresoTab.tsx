import { useState, type FormEvent } from 'react'
import type { CategoriaEgreso, FormaPagoEgreso } from '@virikyna/shared'
import { fechaHoyISO, friendlyError, registrarEgresoGeneral } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { CATEGORIA_EGRESO_LABEL, CATEGORIAS_EGRESO_GENERAL, FORMA_PAGO_EGRESO_LABEL } from '../../lib/caja'
import { Field, ErrorText, inputClass, selectClass } from '../../components/FormField'

const FORMAS_PAGO_EGRESO = Object.keys(FORMA_PAGO_EGRESO_LABEL) as FormaPagoEgreso[]

// Exclusivo Gestión — siempre origen='general'. Nunca se mezcla con el egreso de turno que
// carga un cajero desde el Cierre de Caja de Virikyna Local (origen='turno').
export function RegistrarEgresoTab() {
  const [categoria, setCategoria] = useState<CategoriaEgreso>('sueldo')
  const [monto, setMonto] = useState('')
  const [descripcion, setDescripcion] = useState('')
  const [formaPago, setFormaPago] = useState<FormaPagoEgreso>('efectivo')
  // Arranca en hoy pero es editable — para cargar un gasto que ocurrió unos días antes.
  const [fecha, setFecha] = useState(fechaHoyISO())
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [ok, setOk] = useState(false)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setOk(false)

    const montoNum = Number(monto)
    if (!montoNum || montoNum <= 0) {
      setError('Ingresá un monto mayor a cero.')
      return
    }
    if (!descripcion.trim()) {
      setError('La descripción es obligatoria.')
      return
    }
    if (!fecha) {
      setError('La fecha del egreso es obligatoria.')
      return
    }

    setSaving(true)
    const { error: rpcError } = await registrarEgresoGeneral(supabase, {
      categoria,
      monto: montoNum,
      descripcion: descripcion.trim(),
      formaPago,
      origen: 'general',
      fecha,
    })
    setSaving(false)

    if (rpcError) {
      setError(friendlyError(rpcError))
      return
    }
    setMonto('')
    setDescripcion('')
    setFecha(fechaHoyISO())
    setOk(true)
  }

  return (
    <form onSubmit={handleSubmit} className="rounded-lg border border-line p-4">
      <p className="font-sans text-label-bold text-ink-soft">Registrar egreso general</p>
      <p className="mt-1 font-sans text-body-md text-ink-soft">Sueldo, servicio u otro gasto sin proveedor.</p>
      <div className="mt-3 grid grid-cols-3 gap-stack-md">
        <Field label="Categoría">
          <select value={categoria} onChange={(e) => setCategoria(e.target.value as CategoriaEgreso)} className={selectClass}>
            {CATEGORIAS_EGRESO_GENERAL.map((c) => (
              <option key={c} value={c}>
                {CATEGORIA_EGRESO_LABEL[c]}
              </option>
            ))}
          </select>
        </Field>
        <Field label="Monto">
          <input type="number" step="0.01" value={monto} onChange={(e) => setMonto(e.target.value)} className={inputClass} />
        </Field>
        <Field label="Fecha">
          <input type="date" value={fecha} onChange={(e) => setFecha(e.target.value)} className={inputClass} />
        </Field>
        <Field label="Forma de pago">
          <select value={formaPago} onChange={(e) => setFormaPago(e.target.value as FormaPagoEgreso)} className={selectClass}>
            {FORMAS_PAGO_EGRESO.map((f) => (
              <option key={f} value={f}>
                {FORMA_PAGO_EGRESO_LABEL[f]}
              </option>
            ))}
          </select>
        </Field>
        <Field label="Descripción">
          <input value={descripcion} onChange={(e) => setDescripcion(e.target.value)} className={inputClass} />
        </Field>
      </div>

      {error && (
        <div className="mt-3">
          <ErrorText>{error}</ErrorText>
        </div>
      )}

      {ok && (
        <p className="mt-3 rounded bg-success/10 px-4 py-3 font-sans text-body-md text-success">
          Egreso registrado — mirá el historial para confirmarlo.
        </p>
      )}

      <div className="mt-3 flex justify-end">
        <button
          type="submit"
          disabled={saving}
          className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
        >
          {saving ? 'Guardando...' : 'Registrar egreso'}
        </button>
      </div>
    </form>
  )
}
