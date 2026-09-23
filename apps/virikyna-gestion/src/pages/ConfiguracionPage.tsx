import { useEffect, useState } from 'react'
import { Ban, KeyRound, Pencil, RotateCcw } from 'lucide-react'
import type { Perfil } from '@virikyna/shared'
import { friendlyError } from '@virikyna/shared'
import { listarUsuarios, setUsuarioActivo } from '../lib/usuarios'
import { UsuarioFormModal } from './Configuracion/UsuarioFormModal'
import { BlanquearPasswordModal } from './Configuracion/BlanquearPasswordModal'

export function ConfiguracionPage() {
  const [usuarios, setUsuarios] = useState<Perfil[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [modal, setModal] = useState<'nuevo' | Perfil | null>(null)
  const [blanqueando, setBlanqueando] = useState<Perfil | null>(null)
  const [cambiandoActivo, setCambiandoActivo] = useState<string | null>(null)

  async function cargar() {
    setLoading(true)
    setError(null)
    const { data, error: rpcError } = await listarUsuarios()
    if (rpcError) {
      setError(friendlyError(rpcError as never, 'No se pudo cargar el listado de usuarios.'))
    } else {
      setUsuarios(data.sort((a, b) => a.nombre.localeCompare(b.nombre)))
    }
    setLoading(false)
  }

  useEffect(() => {
    cargar()
  }, [])

  async function toggleActivo(usuario: Perfil) {
    setCambiandoActivo(usuario.id)
    const { error: fnError } = await setUsuarioActivo(usuario.id, !usuario.activo)
    setCambiandoActivo(null)
    if (fnError) {
      setError(fnError)
      return
    }
    cargar()
  }

  return (
    <section className="flex h-full flex-col rounded-lg bg-surface p-card shadow-sm">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="font-display text-headline-lg text-accent-darker">Configuración</h1>
          <p className="mt-1 font-sans text-body-md text-ink-soft">Usuarios y roles del sistema.</p>
        </div>
        <button
          type="button"
          onClick={() => setModal('nuevo')}
          className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark"
        >
          + Nuevo usuario
        </button>
      </div>

      {error && (
        <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>
      )}

      <div className="mt-stack-md flex-1 overflow-auto rounded-lg border border-line">
        <table className="w-full text-left font-sans text-body-md leading-5">
          <thead>
            <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
              <th className="whitespace-nowrap px-3 py-2">Nombre</th>
              <th className="whitespace-nowrap px-3 py-2">Rol</th>
              <th className="whitespace-nowrap px-3 py-2">Estado</th>
              <th className="whitespace-nowrap px-3 py-2"></th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={4}>
                  Cargando...
                </td>
              </tr>
            )}
            {!loading && usuarios.length === 0 && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={4}>
                  No hay usuarios cargados todavía.
                </td>
              </tr>
            )}
            {usuarios.map((usuario) => (
              <tr key={usuario.id} className="border-b border-line last:border-0">
                <td className="px-3 py-1.5 text-ink">{usuario.nombre}</td>
                <td className="px-3 py-1.5 text-ink-soft">{usuario.rol === 'admin' ? 'Admin' : 'Cajero'}</td>
                <td className="px-3 py-1.5">
                  <span className={usuario.activo ? 'text-success' : 'text-ink-soft'}>
                    {usuario.activo ? 'Activo' : 'Desactivado'}
                  </span>
                </td>
                <td className="px-3 py-1.5 text-right">
                  <button
                    type="button"
                    onClick={() => setModal(usuario)}
                    title="Editar"
                    aria-label="Editar"
                    className="rounded px-3 py-1.5 text-accent-dark hover:bg-accent-light"
                  >
                    <Pencil size={18} strokeWidth={1.5} />
                  </button>
                  <button
                    type="button"
                    onClick={() => setBlanqueando(usuario)}
                    title="Blanquear contraseña"
                    aria-label="Blanquear contraseña"
                    className="rounded px-3 py-1.5 text-accent-dark hover:bg-accent-light"
                  >
                    <KeyRound size={18} strokeWidth={1.5} />
                  </button>
                  <button
                    type="button"
                    onClick={() => toggleActivo(usuario)}
                    disabled={cambiandoActivo === usuario.id}
                    title={usuario.activo ? 'Desactivar' : 'Reactivar'}
                    aria-label={usuario.activo ? 'Desactivar' : 'Reactivar'}
                    className="rounded px-3 py-1.5 text-error hover:bg-error/10 disabled:opacity-60"
                  >
                    {usuario.activo ? (
                      <Ban size={18} strokeWidth={1.5} />
                    ) : (
                      <RotateCcw size={18} strokeWidth={1.5} />
                    )}
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {modal && (
        <UsuarioFormModal
          usuario={modal === 'nuevo' ? undefined : modal}
          onClose={() => setModal(null)}
          onSaved={() => {
            setModal(null)
            cargar()
          }}
        />
      )}

      {blanqueando && (
        <BlanquearPasswordModal
          usuario={blanqueando}
          onClose={() => setBlanqueando(null)}
          onDone={() => setBlanqueando(null)}
        />
      )}
    </section>
  )
}
