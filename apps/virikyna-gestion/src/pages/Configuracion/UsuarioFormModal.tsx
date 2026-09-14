import { useState, type FormEvent } from 'react'
import type { Perfil, RolUsuario } from '@virikyna/shared'
import { friendlyError } from '@virikyna/shared'
import { Modal } from '../../components/Modal'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, ErrorText, inputClass, selectClass } from '../../components/FormField'
import { crearUsuario, editarUsuario } from '../../lib/usuarios'

type Props = {
  usuario?: Perfil
  onClose: () => void
  onSaved: () => void
}

// Alta pide email + contraseña inicial (crea el auth.users vía Edge Function); edición solo
// toca nombre y rol (docs/04_modulos_y_funciones.md, módulo 9) — el email no se reasigna acá.
export function UsuarioFormModal({ usuario, onClose, onSaved }: Props) {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [nombre, setNombre] = useState(usuario?.nombre ?? '')
  const [rol, setRol] = useState<RolUsuario>(usuario?.rol ?? 'cajero')
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

    const nombreLimpio = nombre.trim()
    if (!nombreLimpio) {
      setError('El nombre es obligatorio.')
      return
    }

    setSaving(true)

    if (usuario) {
      const { error: rpcError } = await editarUsuario(usuario.id, nombreLimpio, rol)
      setSaving(false)
      if (rpcError) {
        setError(friendlyError(rpcError))
        return
      }
      onSaved()
      return
    }

    if (!email.trim() || !password.trim()) {
      setSaving(false)
      setError('Email y contraseña inicial son obligatorios para un usuario nuevo.')
      return
    }
    if (password.length < 6) {
      setSaving(false)
      setError('La contraseña debe tener al menos 6 caracteres.')
      return
    }

    const { error: fnError } = await crearUsuario(email.trim(), password, nombreLimpio, rol)
    setSaving(false)
    if (fnError) {
      setError(fnError)
      return
    }
    onSaved()
  }

  return (
    <Modal title={usuario ? 'Editar usuario' : 'Nuevo usuario'} onClose={pedirCierre} widthClassName="max-w-[480px]">
      <form onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        {!usuario && (
          <>
            <Field label="Email">
              <input
                type="email"
                autoFocus
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className={inputClass}
              />
            </Field>
            <Field label="Contraseña inicial" hint="La persona puede cambiarla después; mínimo 6 caracteres.">
              <input
                type="password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                className={inputClass}
              />
            </Field>
          </>
        )}

        <Field label="Nombre">
          <input
            autoFocus={Boolean(usuario)}
            value={nombre}
            onChange={(e) => setNombre(e.target.value)}
            className={inputClass}
          />
        </Field>

        <Field label="Rol">
          <select value={rol} onChange={(e) => setRol(e.target.value as RolUsuario)} className={selectClass}>
            <option value="cajero">Cajero</option>
            <option value="admin">Admin</option>
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
