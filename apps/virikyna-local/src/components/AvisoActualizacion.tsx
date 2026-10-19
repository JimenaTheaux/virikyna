import { useState, useSyncExternalStore } from 'react'
import { hayCambiosSinGuardar } from '@virikyna/shared'
import { ConfirmDialog } from './ConfirmDialog'
import { actualizacionParaOfrecer, instalarYReiniciar, posponerActualizacion, suscribirActualizacion } from '../lib/updater'
import { AVISO_COBRO, hayCobroEnCurso } from '../lib/proteccionVentana'
import { showToast } from '../lib/toast'

// Aviso no bloqueante de "Hay una versión nueva" (lib/updater.ts). Montado una sola vez en main.tsx.
// Queda abajo a la izquierda (los toasts van a la derecha) y por debajo de los modales: con un
// formulario abierto no tapa nada, y se puede usar al cerrarlo.
export function AvisoActualizacion() {
  const version = useSyncExternalStore(suscribirActualizacion, actualizacionParaOfrecer)
  const [confirmando, setConfirmando] = useState(false)
  const [instalando, setInstalando] = useState(false)

  if (!version) return null

  async function instalar() {
    setConfirmando(false)
    setInstalando(true)
    try {
      await instalarYReiniciar()
    } catch (error) {
      console.error('[updater] No se pudo instalar la actualización:', error)
      showToast('No se pudo instalar la actualización. Probá de nuevo más tarde.')
      setInstalando(false)
    }
  }

  function reiniciarAhora() {
    // Cerrar la app en medio de un cobro dejaría el ticket a medias (mismo criterio que
    // proteccionVentana): primero que termine.
    if (hayCobroEnCurso()) {
      showToast(AVISO_COBRO)
      return
    }
    if (hayCambiosSinGuardar()) {
      setConfirmando(true)
      return
    }
    void instalar()
  }

  return (
    <>
      <div
        role="status"
        className="fixed bottom-6 left-6 z-40 flex max-w-[360px] flex-col gap-3 rounded-lg border border-accent/40 bg-surface p-4 font-sans shadow-lg"
      >
        <div>
          <p className="text-label-bold text-accent-darker">Hay una versión nueva ({version})</p>
          <p className="text-body-md text-ink-soft">Ya está descargada. Se instala al reiniciar la app.</p>
        </div>
        <div className="flex justify-end gap-2">
          <button
            type="button"
            onClick={posponerActualizacion}
            disabled={instalando}
            className="rounded px-3 py-2 text-label-bold text-ink-soft hover:bg-bg disabled:opacity-60"
          >
            Después
          </button>
          <button
            type="button"
            onClick={reiniciarAhora}
            disabled={instalando}
            className="rounded bg-accent px-3 py-2 text-label-bold text-white hover:bg-accent-dark disabled:opacity-60"
          >
            {instalando ? 'Instalando...' : 'Reiniciar ahora'}
          </button>
        </div>
      </div>
      {confirmando && (
        <ConfirmDialog
          title="Hay cambios sin guardar"
          mensaje="Hay un formulario con cambios sin guardar. Si reiniciás ahora, se pierden. ¿Reiniciar igual?"
          confirmLabel="Reiniciar igual"
          onCancel={() => setConfirmando(false)}
          onConfirm={() => void instalar()}
        />
      )}
    </>
  )
}
