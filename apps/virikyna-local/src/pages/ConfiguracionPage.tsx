import { useEffect, useState } from 'react'
import { getVersion } from '@tauri-apps/api/app'
import { checkForUpdates, type UpdateStatus } from '../lib/updater'

function estadoTexto(status: UpdateStatus | null): string {
  if (!status) return ''
  switch (status.state) {
    case 'checking':
      return 'Buscando actualizaciones...'
    case 'up-to-date':
      return 'Ya tenés la última versión instalada.'
    case 'downloading':
      return `Actualización ${status.latest} encontrada, descargando e instalando...`
    case 'installing':
      return `Actualización ${status.latest} instalada. Reiniciando la app...`
    case 'error':
      return `No se pudo buscar la actualización: ${status.message}`
  }
}

// La gestión de usuarios es exclusiva de Virikyna Gestión (docs/04, módulo 9) — a propósito no
// se duplica acá. Esta pantalla solo existe para que un admin que abre Configuración desde la
// Caja entienda adónde ir, en vez de encontrar un módulo vacío sin explicación.
export function ConfiguracionPage() {
  const [version, setVersion] = useState<string>('')
  const [status, setStatus] = useState<UpdateStatus | null>(null)

  useEffect(() => {
    void getVersion().then(setVersion)
  }, [])

  const buscando = status?.state === 'checking' || status?.state === 'downloading' || status?.state === 'installing'

  return (
    <section className="flex h-full flex-col rounded-lg bg-surface p-card shadow-sm">
      <h1 className="font-display text-headline-lg text-accent-darker">Configuración</h1>
      <p className="mt-1 font-sans text-body-md text-ink-soft">Usuarios, roles y ajustes generales.</p>
      <div className="mt-6 flex flex-1 flex-col items-center justify-center gap-2 rounded border border-dashed border-line px-6 text-center font-sans text-body-md text-ink-soft">
        <p>La gestión de usuarios (crear, editar, blanquear contraseña, desactivar) se hace desde <strong>Virikyna Gestión</strong>.</p>
        <p>Virikyna Local se usa para operar el mostrador — para administrar usuarios, entrá a Virikyna Gestión con tu cuenta de admin.</p>
      </div>
      <div className="mt-6 flex flex-col items-start gap-2 rounded border border-line px-6 py-4 font-sans text-body-md text-ink-soft">
        <p>
          Versión instalada: <strong>{version || '...'}</strong>
        </p>
        <button
          type="button"
          disabled={buscando}
          onClick={() => void checkForUpdates(setStatus)}
          className="rounded bg-accent px-4 py-2 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
        >
          {buscando ? 'Buscando...' : 'Buscar actualizaciones'}
        </button>
        {status && (
          <p className={status.state === 'error' ? 'text-error' : ''}>{estadoTexto(status)}</p>
        )}
      </div>
    </section>
  )
}
