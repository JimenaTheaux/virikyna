import { useEffect } from 'react'
import { useBlocker } from 'react-router-dom'
import { avisarIntentoSalir, hayCambiosSinGuardar } from '../../lib/cambiosSinGuardar'
import { hayDocumentosConCambios } from './documentos/contexto'

// Un solo bloqueador de navegación para toda la app (React Router admite uno a la vez): con un
// formulario con cambios abierto, Atrás (Android, navegador) o un cambio de ruta no desmonta nada;
// el formulario de más arriba decide (lib/cambiosSinGuardar.ts). Recargar o cerrar la pestaña pide
// la confirmación del navegador.
//
// Un documento minimizado de la bandeja (docs/73) no frena la navegación (sigue abierto, no se
// pierde nada), pero cerrar o recargar la pestaña sí lo perdería: ahí también se pregunta.
//
// Requiere un router "de datos" (createHashRouter): se monta una vez, adentro del router, en Gestión
// e Inventario. Local usa <HashRouter> y no lo necesita (Tauri, sin botón Atrás; la recarga ya está
// bloqueada en lib/proteccionVentana.ts).
export function GuardiaNavegacion() {
  const blocker = useBlocker(
    ({ currentLocation, nextLocation }) => hayCambiosSinGuardar() && currentLocation.pathname !== nextLocation.pathname,
  )

  useEffect(() => {
    if (blocker.state !== 'blocked') return
    const manejado = avisarIntentoSalir({ continuar: () => blocker.proceed(), cancelar: () => blocker.reset() })
    // El formulario se cerró entre el bloqueo y acá: no hay a quién preguntarle, se sigue.
    if (!manejado) blocker.proceed()
  }, [blocker])

  useEffect(() => {
    function avisarAntesDeSalir(e: BeforeUnloadEvent) {
      if (!hayCambiosSinGuardar() && !hayDocumentosConCambios()) return
      e.preventDefault()
      e.returnValue = ''
    }
    window.addEventListener('beforeunload', avisarAntesDeSalir)
    return () => window.removeEventListener('beforeunload', avisarAntesDeSalir)
  }, [])

  return null
}
