import { open as abrirEnNavegador } from '@tauri-apps/plugin-shell'
import { ComprobanteModal as ComprobanteModalCompartido, type ComprobanteModalProps } from '@virikyna/shared'
import { showToast } from '../lib/toast'

// La implementación vive en packages/shared (igual que en Gestión). Local abre los links con el
// plugin shell de Tauri (dentro del WebView window.open no abre el navegador ni WhatsApp) y al
// enviar descarga el PDF (Gmail) o la imagen JPG (WhatsApp) para adjuntarlos.
export function ComprobanteModal(props: ComprobanteModalProps) {
  return (
    <ComprobanteModalCompartido
      {...props}
      abrirUrl={(url) => abrirEnNavegador(url)}
      descargarAlEnviar
      onAviso={showToast}
    />
  )
}
