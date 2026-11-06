import { useCallback, type KeyboardEvent } from 'react'
import { manejarEnterComoTab } from './enterComoTab'

// <form onKeyDown={useEnterComoTab()}>: Enter pasa al campo siguiente y, en el último, al botón
// principal; nunca envía el formulario desde un campo (ver lib/enterComoTab.ts). Un buscador con
// Enter propio va dentro de un contenedor data-enter-tab="propio"; un campo que no debe recibir el
// foco con Enter, dentro de data-enter-tab="saltear".
export function useEnterComoTab() {
  return useCallback((e: KeyboardEvent<HTMLFormElement>) => manejarEnterComoTab(e, e.currentTarget), [])
}
