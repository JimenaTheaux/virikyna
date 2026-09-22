import { check } from '@tauri-apps/plugin-updater'
import { relaunch } from '@tauri-apps/plugin-process'
import { getVersion } from '@tauri-apps/api/app'

export type UpdateStatus =
  | { state: 'checking' }
  | { state: 'up-to-date'; current: string }
  | { state: 'downloading'; current: string; latest: string }
  | { state: 'installing'; latest: string }
  | { state: 'error'; message: string }

/**
 * Chequea, descarga e instala una actualización nueva. Se llama una sola vez al
 * arrancar la app (silenciosa) y también desde el botón manual de Configuración
 * (docs/05_stack_tecnico.md sección 8). Siempre deja en consola la versión
 * actual vs. la última disponible, para poder confirmar en cada instalación
 * futura que el update sí se aplicó.
 */
export async function checkForUpdates(onStatus?: (status: UpdateStatus) => void): Promise<void> {
  const current = await getVersion()
  onStatus?.({ state: 'checking' })

  try {
    const update = await check()

    if (!update) {
      console.log(`[updater] Versión actual: ${current}. No hay actualizaciones disponibles.`)
      onStatus?.({ state: 'up-to-date', current })
      return
    }

    console.log(`[updater] Versión actual: ${current}. Nueva versión disponible: ${update.version}. Descargando...`)
    onStatus?.({ state: 'downloading', current, latest: update.version })

    await update.downloadAndInstall()

    console.log(`[updater] Actualización a ${update.version} descargada e instalada. Reiniciando...`)
    onStatus?.({ state: 'installing', latest: update.version })

    await relaunch()
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    console.error('[updater] No se pudo verificar/aplicar la actualización:', error)
    onStatus?.({ state: 'error', message })
  }
}
