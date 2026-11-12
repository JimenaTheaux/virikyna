// Aviso de "cambiaron datos de X" entre un documento de la bandeja (docs/73) y el listado que lo
// abrió. El documento vive en AppShell, fuera de la página: no puede llamar al `cargar()` de un
// listado que quizás ya se desmontó (o se volvió a montar y es otra instancia). Publica un tema y
// el listado montado en ese momento, si hay uno, se recarga. Si no hay ninguno, no pasa nada: el
// listado lee datos frescos al montarse.
//
// Se eligió un evento y no invalidateQueries porque estos listados (facturas de compra, borradores,
// productos) cargan con useState + useEffect, no con React Query: pasarlos a React Query era un
// cambio mucho más grande para lograr lo mismo.

import { useEffect, useRef } from 'react'

export type TemaDatos = 'facturas_compra' | 'borradores_factura' | 'productos'

type Oyente = (detalle?: string) => void

const oyentes = new Map<TemaDatos, Set<Oyente>>()

// `detalle`: texto opcional para el listado (ej. "Se eliminó X." en Inventario).
export function avisarCambioDatos(tema: TemaDatos, detalle?: string) {
  oyentes.get(tema)?.forEach((oyente) => oyente(detalle))
}

export function useAlCambiarDatos(tema: TemaDatos, alCambiar: Oyente) {
  const ref = useRef(alCambiar)
  ref.current = alCambiar
  useEffect(() => {
    const oyente: Oyente = (detalle) => ref.current(detalle)
    let set = oyentes.get(tema)
    if (!set) {
      set = new Set()
      oyentes.set(tema, set)
    }
    set.add(oyente)
    return () => {
      oyentes.get(tema)?.delete(oyente)
    }
  }, [tema])
}
