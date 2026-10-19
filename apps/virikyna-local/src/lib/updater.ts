import { check, type Update } from '@tauri-apps/plugin-updater'
import { relaunch } from '@tauri-apps/plugin-process'
import { getVersion } from '@tauri-apps/api/app'

// Actualización de Virikyna Local (docs/05_stack_tecnico.md sección 8; docs/auditoria-2026-10-19.md
// B.3 #2). Al arrancar se busca y se DESCARGA en segundo plano; nunca se instala ni se reinicia sola
// (en Windows, install() cierra la app, y antes eso podía pasar con alguien cargando un formulario).
// Con la descarga lista, <AvisoActualizacion /> ofrece "Reiniciar ahora" / "Después".

export type UpdateStatus =
  | { state: 'checking' }
  | { state: 'up-to-date'; current: string }
  | { state: 'downloading'; current: string; latest: string }
  | { state: 'ready'; current: string; latest: string }
  | { state: 'installing'; latest: string }
  | { state: 'error'; message: string }

// Estado del módulo (una sola instancia de la app): lo lee el aviso y la pantalla de Configuración.
let descargada: Update | null = null
let enCurso: Promise<void> | null = null
// "Después": no volver a ofrecerla en esta sesión (se ofrece de nuevo al próximo arranque).
let pospuesta = false
const listeners = new Set<() => void>()

function avisar() {
  listeners.forEach((l) => l())
}

export function suscribirActualizacion(listener: () => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

// Versión descargada y lista para instalar que todavía hay que ofrecer, o null.
export function actualizacionParaOfrecer(): string | null {
  return descargada && !pospuesta ? descargada.version : null
}

export function posponerActualizacion() {
  pospuesta = true
  avisar()
}

/**
 * Busca una versión nueva y, si hay, la descarga (sin instalar). Al arrancar se llama en silencio:
 * un error de red o de descarga no rompe nada, solo queda en consola. Desde el botón de
 * Configuración (`manual`), la versión vuelve a ofrecerse aunque se haya elegido "Después".
 * Siempre deja en consola la versión actual vs. la disponible.
 */
export async function buscarActualizacion(
  onStatus?: (status: UpdateStatus) => void,
  { manual = false }: { manual?: boolean } = {},
): Promise<void> {
  if (manual) pospuesta = false
  const current = await getVersion().catch(() => '?')
  onStatus?.({ state: 'checking' })

  if (descargada) {
    onStatus?.({ state: 'ready', current, latest: descargada.version })
    avisar()
    return
  }
  // Dos búsquedas a la vez (arranque + botón): la segunda espera a la primera.
  if (enCurso) {
    await enCurso
    if (descargada) onStatus?.({ state: 'ready', current, latest: (descargada as Update).version })
    else onStatus?.({ state: 'up-to-date', current })
    return
  }

  enCurso = (async () => {
    try {
      const update = await check()
      if (!update) {
        console.log(`[updater] Versión actual: ${current}. No hay actualizaciones disponibles.`)
        onStatus?.({ state: 'up-to-date', current })
        return
      }
      console.log(`[updater] Versión actual: ${current}. Nueva versión disponible: ${update.version}. Descargando...`)
      onStatus?.({ state: 'downloading', current, latest: update.version })
      await update.download()
      descargada = update
      console.log(`[updater] Versión ${update.version} descargada. Se instala cuando se elija "Reiniciar ahora".`)
      onStatus?.({ state: 'ready', current, latest: update.version })
      avisar()
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      console.warn('[updater] No se pudo buscar o descargar la actualización:', error)
      onStatus?.({ state: 'error', message })
    } finally {
      enCurso = null
    }
  })()
  await enCurso
}

/**
 * Instala la versión ya descargada y reinicia. Solo desde "Reiniciar ahora" (después de las
 * confirmaciones de AvisoActualizacion). En Windows install() cierra la app y lanza el instalador;
 * relaunch() cubre macOS/Linux.
 */
export async function instalarYReiniciar(): Promise<void> {
  if (!descargada) return
  console.log(`[updater] Instalando ${descargada.version} y reiniciando...`)
  await descargada.install()
  await relaunch()
}
