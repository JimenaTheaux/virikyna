import { useId, useState, type FormEvent } from 'react'
import {
  corregirSaldoInicial,
  formatCurrency,
  formatFechaHora,
  friendlyError,
  type TipoCuentaSaldoInicial,
} from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { Modal } from '../../components/Modal'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, ErrorText, inputClass } from '../../components/FormField'

export type CuentaACorregir = {
  tipo: TipoCuentaSaldoInicial
  id: string
  nombre: string
  saldoInicial: number
  fecha: string | null
  usuario: string | null
}

type Props = {
  cuenta: CuentaACorregir
  onClose: () => void
  onCorregido: (resultado: { anterior: number; nuevo: number }) => void
}

// Corrección de un saldo inicial ya cargado (docs/69): REEMPLAZA el monto (no suma), con motivo
// obligatorio. El RPC vuelve a validar todo (solo admin) y deja el motivo en la auditoría.
export function CorregirSaldoInicialModal({ cuenta, onClose, onCorregido }: Props) {
  const [monto, setMonto] = useState('')
  const [motivo, setMotivo] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [dirty, setDirty] = useState(false)
  const [confirmCerrar, setConfirmCerrar] = useState(false)
  const formId = useId()
  const ayudaMontoId = useId()

  const montoNum = monto.trim() === '' ? NaN : Number(monto)
  const montoValido = Number.isFinite(montoNum)

  function pedirCierre() {
    if (dirty) setConfirmCerrar(true)
    else onClose()
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    if (!montoValido) {
      setError('Ingresá el monto nuevo.')
      return
    }
    if (Math.round(montoNum * 100) === Math.round(cuenta.saldoInicial * 100)) {
      setError('El monto nuevo es igual al actual.')
      return
    }
    if (motivo.trim().length < 3) {
      setError('Ingresá el motivo de la corrección.')
      return
    }
    setSaving(true)
    const { data, error: rpcError } = await corregirSaldoInicial(supabase, {
      tipo: cuenta.tipo,
      id: cuenta.id,
      montoNuevo: montoNum,
      motivo: motivo.trim(),
    })
    setSaving(false)
    if (rpcError) {
      setError(friendlyError(rpcError))
      return
    }
    const r = data as { anterior: number; nuevo: number }
    onCorregido({ anterior: Number(r.anterior), nuevo: Number(r.nuevo) })
  }

  return (
    <Modal
      title="Corregir saldo inicial"
      onClose={pedirCierre}
      cambiosSinGuardar={dirty}
      widthClassName="max-w-[520px]"
      footer={
        <div className="flex justify-end gap-3">
          <button
            type="button"
            onClick={pedirCierre}
            className="rounded px-4 py-3 font-sans text-label-bold text-ink-soft hover:bg-bg"
          >
            Cancelar
          </button>
          <button
            type="submit"
            form={formId}
            disabled={saving}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
          >
            {saving ? 'Guardando...' : 'Guardar corrección'}
          </button>
        </div>
      }
    >
      <form
        id={formId}
        onSubmit={handleSubmit}
        onChangeCapture={() => setDirty(true)}
        // Enter en un campo nunca guarda: una corrección se confirma solo con el botón.
        onKeyDown={(e) => {
          if (e.key === 'Enter' && e.target instanceof HTMLInputElement) e.preventDefault()
        }}
        className="flex flex-col gap-stack-md"
      >
        <dl className="grid grid-cols-[auto_1fr] gap-x-stack-md gap-y-1 rounded-lg border border-line p-4 font-sans text-body-md">
          <dt className="text-ink-soft">{cuenta.tipo === 'proveedor' ? 'Proveedor' : 'Cliente'}</dt>
          <dd className="text-ink [overflow-wrap:anywhere]">{cuenta.nombre}</dd>
          <dt className="text-ink-soft">Saldo inicial actual</dt>
          <dd className="font-semibold tabular-nums text-ink">{formatCurrency(cuenta.saldoInicial)}</dd>
          <dt className="text-ink-soft">Cargado</dt>
          <dd className="text-ink">
            {cuenta.fecha ? formatFechaHora(cuenta.fecha) : '—'}
            {cuenta.usuario ? ` · ${cuenta.usuario}` : ''}
          </dd>
        </dl>

        <p className="rounded bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">
          El monto nuevo <strong>reemplaza</strong> al actual, no se suma. Si lo que falta es una deuda nueva, cargala como
          comprobante.
        </p>

        <Field label="Monto nuevo">
          <input
            type="number"
            step="0.01"
            data-autofocus
            value={monto}
            onChange={(e) => setMonto(e.target.value)}
            aria-describedby={ayudaMontoId}
            className={`${inputClass} text-right tabular-nums`}
          />
        </Field>
        {/* Formato argentino de lo que se va a guardar: "4.500" en este campo es 4,50 (punto decimal). */}
        <p id={ayudaMontoId} aria-live="polite" className="-mt-2 font-sans text-body-md text-ink-soft">
          {montoValido ? (
            <>
              Se va a registrar: <strong className="tabular-nums text-ink">{formatCurrency(montoNum)}</strong>
            </>
          ) : (
            'Usá punto o coma para los centavos, sin separador de miles.'
          )}
        </p>

        <Field label="Motivo (obligatorio)" hint="Queda en el Historial junto con el monto anterior y el nuevo.">
          <textarea
            value={motivo}
            onChange={(e) => setMotivo(e.target.value)}
            rows={3}
            maxLength={300}
            className={`${inputClass} resize-y`}
          />
        </Field>

        {error && <ErrorText>{error}</ErrorText>}
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
