import { ComprobanteModal as ComprobanteModalCompartido, type ComprobanteModalProps } from '@virikyna/shared'

// La implementación vive en packages/shared (igual que en Local). Gestión es web: los links de
// Gmail y WhatsApp se abren en una pestaña nueva y el PDF se descarga con el botón.
export function ComprobanteModal(props: ComprobanteModalProps) {
  return <ComprobanteModalCompartido {...props} />
}
