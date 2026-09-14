import { useState, type FormEvent } from 'react'
import type { Proveedor } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { friendlyError } from '@virikyna/shared'
import { Modal } from '../../components/Modal'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, ErrorText, inputClass } from '../../components/FormField'

type Props = {
  proveedor?: Proveedor
  onClose: () => void
  onSaved: () => void
}

export function ProveedorFormModal({ proveedor, onClose, onSaved }: Props) {
  const [razonSocial, setRazonSocial] = useState(proveedor?.razon_social ?? '')
  const [cuit, setCuit] = useState(proveedor?.cuit ?? '')
  const [direccion, setDireccion] = useState(proveedor?.direccion ?? '')
  const [telefono, setTelefono] = useState(proveedor?.telefono ?? '')
  const [mail, setMail] = useState(proveedor?.mail ?? '')
  const [contacto, setContacto] = useState(proveedor?.contacto ?? '')
  const [margen1Default, setMargen1Default] = useState(String(proveedor?.margen_1_default ?? 0))
  const [margen2Default, setMargen2Default] = useState(String(proveedor?.margen_2_default ?? 0))
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

    const razonSocialLimpia = razonSocial.trim()
    if (!razonSocialLimpia) {
      setError('La razón social es obligatoria.')
      return
    }

    const payload = {
      razon_social: razonSocialLimpia,
      cuit: cuit.trim() || null,
      direccion: direccion.trim() || null,
      telefono: telefono.trim() || null,
      mail: mail.trim() || null,
      contacto: contacto.trim() || null,
      margen_1_default: Number(margen1Default) || 0,
      margen_2_default: Number(margen2Default) || 0,
    }

    setSaving(true)
    const { error: dbError } = proveedor
      ? await supabase.from('proveedores').update(payload).eq('id', proveedor.id)
      : await supabase.from('proveedores').insert(payload)
    setSaving(false)

    if (dbError) {
      setError(friendlyError(dbError))
      return
    }
    onSaved()
  }

  return (
    <Modal
      title={proveedor ? 'Editar proveedor' : 'Nuevo proveedor'}
      onClose={pedirCierre}
      widthClassName="max-w-[600px]"
    >
      <form onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        <Field label="Razón social">
          <input
            autoFocus
            value={razonSocial}
            onChange={(e) => setRazonSocial(e.target.value)}
            className={inputClass}
          />
        </Field>

        <div className="grid grid-cols-2 gap-stack-md">
          <Field label="CUIT">
            <input
              value={cuit}
              onChange={(e) => setCuit(e.target.value.replace(/\D/g, ''))}
              inputMode="numeric"
              className={inputClass}
            />
          </Field>
          <Field label="Teléfono">
            <input value={telefono} onChange={(e) => setTelefono(e.target.value)} className={inputClass} />
          </Field>
        </div>

        <Field label="Dirección">
          <input value={direccion} onChange={(e) => setDireccion(e.target.value)} className={inputClass} />
        </Field>

        <div className="grid grid-cols-2 gap-stack-md">
          <Field label="Mail">
            <input type="email" value={mail} onChange={(e) => setMail(e.target.value)} className={inputClass} />
          </Field>
          <Field label="Contacto">
            <input value={contacto} onChange={(e) => setContacto(e.target.value)} className={inputClass} />
          </Field>
        </div>

        <div className="rounded border border-line p-4">
          <p className="font-sans text-label-bold text-ink">Márgenes por defecto</p>
          <p className="mt-1 font-sans text-label-md text-ink-soft">
            Los productos nuevos de este proveedor heredan estos márgenes automáticamente.
          </p>
          <div className="mt-3 grid grid-cols-2 gap-stack-md">
            <Field label="Margen 1 (%)">
              <input
                type="number"
                step="0.01"
                value={margen1Default}
                onChange={(e) => setMargen1Default(e.target.value)}
                className={inputClass}
              />
            </Field>
            <Field label="Margen 2 (%)">
              <input
                type="number"
                step="0.01"
                value={margen2Default}
                onChange={(e) => setMargen2Default(e.target.value)}
                className={inputClass}
              />
            </Field>
          </div>
        </div>

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
            {saving ? 'Guardando...' : 'Guardar'}
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
