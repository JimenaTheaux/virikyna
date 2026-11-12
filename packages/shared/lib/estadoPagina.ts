// Estado de una pantalla que sobrevive a ir y volver (docs/73, "B parcial"). Mismo patrón que los
// filtros de Inventario (src/components/inventario/FiltrosInventario.tsx):
//   - En la URL (?desde=&estado=&tab=…): recargar o "Atrás" lo conservan.
//   - Recordado en la sesión (sessionStorage): entrar de nuevo desde el menú (link sin parámetros)
//     vuelve a lo último. Un link que trae parámetros manda sobre lo recordado.
// Y una memoria aparte, solo en memoria, para lo que no va en la URL (orden, selección, scroll).
// Todo se olvida al cambiar de usuario (olvidarEstadoPaginas, desde AppShell).

import { useCallback, useEffect, useRef, useState } from 'react'
import { useSearchParams } from 'react-router-dom'

const PREFIJO = 'virikyna:pagina:'

function leerGuardado(pagina: string): URLSearchParams | null {
  try {
    const raw = sessionStorage.getItem(PREFIJO + pagina)
    return raw === null ? null : new URLSearchParams(raw)
  } catch {
    return null
  }
}

function guardar(pagina: string, valores: Record<string, string>, defaults: Record<string, string>) {
  try {
    const propios = new URLSearchParams()
    for (const [k, v] of Object.entries(valores)) if (v && v !== defaults[k]) propios.set(k, v)
    sessionStorage.setItem(PREFIJO + pagina, propios.toString())
  } catch {
    // Sin storage (ventana privada, bloqueado): queda en la URL, solo no se recuerda.
  }
}

// Las apps usan HashRouter: la URL vigente está en el hash. Varias escrituras en el mismo momento
// (ej. la pestaña de la página y los filtros de la pestaña, al restaurarse juntos) se acumulan acá:
// setSearchParams(prev => …) de React Router parte de un `prev` viejo y la segunda pisaba a la primera.
let pendiente: URLSearchParams | null = null

function paramsActuales(): URLSearchParams {
  if (pendiente) return pendiente
  const h = window.location.hash
  const i = h.indexOf('?')
  return new URLSearchParams(i >= 0 ? h.slice(i + 1) : '')
}

function escribirUrl(
  setParams: ReturnType<typeof useSearchParams>[1],
  valores: Record<string, string>,
  defaults: Record<string, string>,
) {
  if (!pendiente) {
    pendiente = paramsActuales()
    setTimeout(() => {
      pendiente = null
    }, 0)
  }
  for (const [k, v] of Object.entries(valores)) {
    if (v && v !== defaults[k]) pendiente.set(k, v)
    else pendiente.delete(k)
  }
  setParams(new URLSearchParams(pendiente), { replace: true })
}

// `pagina`: clave única de la pantalla (y de la parte de la pantalla), ej. 'facturacion:filtros'.
// `defaults`: valor de cada parámetro cuando no está en la URL (no se escribe).
export function useParamsPagina<K extends string>(pagina: string, defaults: Record<K, string>) {
  const [params, setParams] = useSearchParams()
  const claves = Object.keys(defaults) as K[]
  // Lo recordado se usa hasta que la URL lo tiene (o hasta el primer cambio a mano).
  const restaurarRef = useRef<URLSearchParams | null | undefined>(undefined)
  if (restaurarRef.current === undefined) {
    restaurarRef.current = claves.some((k) => params.has(k)) ? null : leerGuardado(pagina)
  }
  const r = restaurarRef.current
  const fuente = r && !claves.some((k) => params.has(k)) ? r : params
  const valores = Object.fromEntries(claves.map((k) => [k, fuente.get(k) ?? defaults[k]])) as Record<K, string>

  useEffect(() => {
    const restaurar = restaurarRef.current
    if (restaurar) {
      escribirUrl(setParams, Object.fromEntries(claves.map((k) => [k, restaurar.get(k) ?? ''])), defaults)
    } else {
      // Entró con parámetros (link, recarga): eso pasa a ser lo recordado.
      guardar(pagina, valores, defaults)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const valoresRef = useRef(valores)
  valoresRef.current = valores

  const set = useCallback(
    (cambios: Partial<Record<K, string>>) => {
      restaurarRef.current = null
      const actuales = paramsActuales()
      const base = Object.fromEntries(
        claves.map((k) => [k, actuales.has(k) ? (actuales.get(k) as string) : valoresRef.current[k]]),
      ) as Record<string, string>
      const nuevos = { ...base, ...cambios } as Record<string, string>
      escribirUrl(setParams, nuevos, defaults)
      guardar(pagina, nuevos, defaults)
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [pagina, setParams],
  )

  return { valores, set }
}

const SOLO_BUSQUEDA = { q: '' }

// Buscador de una pantalla (?q=…): el input responde al instante y la URL se escribe con 200 ms de
// espera. Devuelve [texto del input, setter, texto ya aplicado].
export function useBusquedaPagina(pagina: string) {
  const { valores, set } = useParamsPagina(pagina, SOLO_BUSQUEDA)
  const [texto, setTexto] = useState(valores.q)
  useEffect(() => {
    if (texto.trim() === valores.q) return
    const t = setTimeout(() => set({ q: texto.trim() }), 200)
    return () => clearTimeout(t)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [texto])
  return [texto, setTexto, valores.q] as const
}

// ─── Memoria de la sesión (no va a la URL) ────────────────────────────────────────────────────

const memoria = new Map<string, unknown>()

export function recordarEnPagina<T>(clave: string, valor: T) {
  memoria.set(clave, valor)
}

export function leerDePagina<T>(clave: string): T | undefined {
  return memoria.get(clave) as T | undefined
}

// Cambiar de usuario: lo que dejó el anterior no se le muestra al siguiente.
export function olvidarEstadoPaginas() {
  memoria.clear()
  try {
    for (let i = sessionStorage.length - 1; i >= 0; i--) {
      const clave = sessionStorage.key(i)
      if (clave?.startsWith(PREFIJO)) sessionStorage.removeItem(clave)
    }
  } catch {
    // storage bloqueado
  }
}
