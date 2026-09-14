import { check } from '@tauri-apps/plugin-updater'
import { relaunch } from '@tauri-apps/plugin-process'

/**
 * Chequea, descarga e instala una actualización nueva sin intervención del
 * cajero (docs/05_stack_tecnico.md sección 8). Se llama una sola vez al
 * arrancar la app — nunca en medio de una venta.
 */
export async function checkForUpdates(): Promise<void> {
  try {
    const update = await check()
    if (!update) return

    await update.downloadAndInstall()
    await relaunch()
  } catch (error) {
    console.error('No se pudo verificar/aplicar la actualización:', error)
  }
}
