// Registro global de "hay un formulario con cambios sin guardar" (docs/auditoria-2026-10-19.md, B.3).
// Una sola lista para toda la app, sin Provider: la usan
//   - GuardiaNavegacion (Gestión, Inventario): el botón Atrás / cambio de ruta no desmonta un
//     formulario con cambios; se le pasa el intento al de más arriba.
//   - El aviso de actualización de Local: antes de reiniciar, pregunta si hay algo sin guardar.
// Cada formulario se anota con useCambiosSinGuardar mientras tenga cambios. Modal y BottomSheet lo
// hacen solos con la prop `cambiosSinGuardar`.

import { useEffect, useRef } from 'react'

// Navegación frenada: el formulario decide. `continuar` sigue a la ruta pedida (una página que se
// abandona); `cancelar` se queda donde está (un modal que solo se cierra).
export type IntentoSalir = { continuar: () => void; cancelar: () => void }

type Entrada = { onIntentoSalir: (intento: IntentoSalir) => void }

// En orden de alta: el último es el de más arriba (un modal abierto sobre otro).
const pila: Entrada[] = []

export function hayCambiosSinGuardar(): boolean {
  return pila.length > 0
}

// Le pasa el intento al formulario de más arriba. Devuelve false si no hay ninguno.
export function avisarIntentoSalir(intento: IntentoSalir): boolean {
  const ultimo = pila[pila.length - 1]
  if (!ultimo) return false
  ultimo.onIntentoSalir(intento)
  return true
}

export function useCambiosSinGuardar(activo: boolean, onIntentoSalir: (intento: IntentoSalir) => void) {
  // Siempre la última versión del callback, sin volver a anotarse en cada render.
  const callbackRef = useRef(onIntentoSalir)
  callbackRef.current = onIntentoSalir

  useEffect(() => {
    if (!activo) return
    const entrada: Entrada = { onIntentoSalir: (intento) => callbackRef.current(intento) }
    pila.push(entrada)
    return () => {
      const i = pila.indexOf(entrada)
      if (i >= 0) pila.splice(i, 1)
    }
  }, [activo])
}
