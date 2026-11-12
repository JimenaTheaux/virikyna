import { useState } from 'react'
import { useCambiosSinGuardar, type IntentoSalir } from '../../lib/cambiosSinGuardar'
import { ConfirmDialog } from './ConfirmDialog'

// Formulario que vive en la página (no en un Modal), ej. Registrar egreso o Movimientos manuales de
// Gestión (docs/73): mientras tenga algo cargado queda anotado en cambiosSinGuardar, así cambiar de
// pantalla, de pestaña, Atrás o cerrar la pestaña preguntan en vez de perderlo en silencio.
// Devuelve el diálogo a dibujar.
export function useAvisoSalidaSinGuardar(activo: boolean, mensaje = 'Hay datos cargados sin guardar en este formulario. Si salís, se pierden.') {
  const [intento, setIntento] = useState<IntentoSalir | null>(null)
  useCambiosSinGuardar(activo, setIntento)
  if (!intento) return null
  return (
    <ConfirmDialog
      title="Salir sin guardar"
      mensaje={mensaje}
      confirmLabel="Salir sin guardar"
      cancelLabel="Seguir acá"
      onCancel={() => {
        intento.cancelar()
        setIntento(null)
      }}
      onConfirm={() => {
        setIntento(null)
        intento.continuar()
      }}
    />
  )
}
