import { useEffect, useState, type FormEvent } from 'react'
import type { PerfilPublico } from '@virikyna/shared'
import { useAuth } from '../../auth/AuthContext'
import { supabase } from '../../lib/supabaseClient'
import { friendlyError, fechaHoyISO } from '@virikyna/shared'
import { Modal } from '../../components/Modal'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, ErrorText, inputClass, selectClass } from '../../components/FormField'

// Retiro de efectivo: el cajero entrega plata física a un admin durante el turno. Este es el
// ÚNICO camino por el que ese efectivo llega a Caja Gestión — el Cierre Z solo informa cuánto
// efectivo hay en el cajón, nunca lo suma a las cuentas (docs/14_retiro_efectivo_caja.sql).
// Por eso vive acá, separado del flujo de Cierre X/Z, no como un paso del cierre.
export function RegistrarRetiroModal({ onClose, onSaved }: { onClose: () => void; onSaved: () => void }) {
  const { user, perfil } = useAuth()
  const [fecha, setFecha] = useState(fechaHoyISO())
  const [monto, setMonto] = useState('')
  const [adminId, setAdminId] = useState('')
  const [cajeroId, setCajeroId] = useState('')
  const [admins, setAdmins] = useState<PerfilPublico[]>([])
  const [cajeros, setCajeros] = useState<PerfilPublico[]>([])
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [dirty, setDirty] = useState(false)
  const [confirmCerrar, setConfirmCerrar] = useState(false)

  useEffect(() => {
    if (perfil) setCajeroId(perfil.id)
  }, [perfil])

  useEffect(() => {
    supabase.rpc('listar_admins').then(({ data }) => setAdmins((data ?? []) as PerfilPublico[]))
    supabase
      .from('perfiles_publico')
      .select('id, nombre')
      .order('nombre')
      .then(({ data }) => setCajeros((data ?? []) as PerfilPublico[]))
  }, [])

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

    const montoNum = Number(monto)
    if (!montoNum || montoNum <= 0) {
      setError('Ingresá un importe mayor a cero.')
      return
    }
    if (!user) {
      setError('No se pudo identificar al usuario actual.')
      return
    }
    if (!adminId) {
      setError('Elegí qué admin recibe el efectivo.')
      return
    }
    if (!cajeroId) {
      setError('Elegí qué cajero entrega el efectivo.')
      return
    }

    setSaving(true)
    const { error: rpcError } = await supabase.rpc('registrar_retiro_caja', {
      p_monto: montoNum,
      p_admin_id: adminId,
      p_cajero_id: cajeroId,
      p_fecha: fecha,
    })
    setSaving(false)

    if (rpcError) {
      setError(friendlyError(rpcError))
      return
    }
    onSaved()
  }

  return (
    <Modal title="Registrar retiro" onClose={pedirCierre} widthClassName="max-w-[460px]">
      <form onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        <Field label="Fecha">
          <input type="date" value={fecha} onChange={(e) => setFecha(e.target.value)} className={inputClass} />
        </Field>

        <Field label="Importe">
          <input
            type="number"
            step="0.01"
            autoFocus
            value={monto}
            onChange={(e) => setMonto(e.target.value)}
            className={inputClass}
          />
        </Field>

        <Field label="Admin que recibe">
          <select value={adminId} onChange={(e) => setAdminId(e.target.value)} className={selectClass}>
            <option value="">Elegí un admin</option>
            {admins.map((a) => (
              <option key={a.id} value={a.id}>
                {a.nombre}
              </option>
            ))}
          </select>
        </Field>

        <Field label="Cajero" hint="Autocompleta con tu usuario — cambialo si estás registrando el retiro de otro turno">
          <select value={cajeroId} onChange={(e) => setCajeroId(e.target.value)} className={selectClass}>
            <option value="">Elegí un cajero</option>
            {cajeros.map((c) => (
              <option key={c.id} value={c.id}>
                {c.nombre}
              </option>
            ))}
          </select>
        </Field>

        {error && <ErrorText>{error}</ErrorText>}

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
            disabled={saving}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
          >
            {saving ? 'Guardando...' : 'Registrar retiro'}
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
