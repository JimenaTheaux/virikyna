// Borradores de formularios (docs/54): un formulario a medio cargar se guarda como JSON en la
// tabla `borradores` y no toca nada del negocio (stock, costos, saldos, caja) hasta que se
// confirma con su RPC de siempre. Fase 1: factura de compra / NC (lib/borradorFactura.ts).
//
// Dos capas, para no perder nada:
//   - localStorage, en cada cambio: cubre el cierre inesperado (app, corte de luz, sin red).
//   - la tabla, con debounce: visible para todos y retomable desde el sistema donde se creó.
// Lo que quedó solo en el equipo (sin conexión, app cerrada antes del debounce) se sube al volver
// a abrir el listado (subirBorradoresPendientes) o cuando vuelve la red.
//
// Control optimista: cada UPDATE filtra por la `version` que se leyó (la base la incrementa sola).
// Si otro guardó antes, no actualiza nada: el formulario avisa y frena el autoguardado.

import { useCallback, useEffect, useRef, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { isNetworkError } from './supabaseErrors'
import { nombresPorId } from './perfiles'
import { formatHora } from './format'

export type SistemaApp = 'local' | 'gestion' | 'inventario'
export type TipoBorrador = 'factura_compra'

export const SISTEMA_LABEL: Record<SistemaApp, string> = {
  local: 'Virikyna Local',
  gestion: 'Virikyna Gestión',
  inventario: 'Virikyna Inventario',
}

// fetch de supabase-js con el header x-virikyna-app, solo para PostgREST (/rest/v1/): la RLS de
// borradores lo usa como chequeo blando del sistema de origen (app_cliente(), docs/54). No va a las
// Edge Functions a propósito: su CORS solo acepta authorization, x-client-info, apikey y
// content-type, y un header de más rompería el preflight (ej. la emisión ARCA de Local).
export function fetchConApp(app: SistemaApp): typeof fetch {
  return (input, init) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
    if (!url.includes('/rest/v1/')) return fetch(input, init)
    const headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined))
    headers.set('x-virikyna-app', app)
    return fetch(input, { ...init, headers })
  }
}

export type BorradorFila<T = unknown> = {
  id: string
  tipo: TipoBorrador
  sistema: SistemaApp
  payload: T
  resumen: string | null
  usuario_id: string
  actualizado_por: string
  created_at: string
  updated_at: string
  version: number
}

export type BorradorConNombres<T = unknown> = BorradorFila<T> & { autor: string | null; editor: string | null }

// ─── Copia en el equipo (localStorage) ────────────────────────────────────────────────────────

type EntradaLocal = {
  id: string
  tipo: TipoBorrador
  sistema: SistemaApp
  usuarioId: string | null
  payload: unknown
  resumen: string
  version: number | null // null = todavía no llegó a la base
  pendiente: boolean // hay cambios que la base no tiene
  guardadoEn: string
}

const PREFIJO = 'virikyna:borrador:'

function escribirLocal(e: EntradaLocal) {
  try {
    localStorage.setItem(PREFIJO + e.id, JSON.stringify(e))
  } catch {
    // Sin espacio o storage bloqueado: queda la copia de la base.
  }
}

function borrarLocal(id: string) {
  try {
    localStorage.removeItem(PREFIJO + id)
  } catch {
    // nada
  }
}

function leerLocales(): EntradaLocal[] {
  const entradas: EntradaLocal[] = []
  try {
    for (let i = 0; i < localStorage.length; i++) {
      const clave = localStorage.key(i)
      if (!clave?.startsWith(PREFIJO)) continue
      try {
        entradas.push(JSON.parse(localStorage.getItem(clave) ?? '') as EntradaLocal)
      } catch {
        localStorage.removeItem(clave)
      }
    }
  } catch {
    // storage bloqueado
  }
  return entradas
}

// Borradores abiertos en un formulario de esta pestaña: subirBorradoresPendientes no los toca (el
// formulario los sube él mismo, y dos subidas a la vez se pisarían la version).
const abiertos = new Set<string>()

async function usuarioActual(supabase: SupabaseClient): Promise<string | null> {
  const { data } = await supabase.auth.getSession()
  return data.session?.user.id ?? null
}

// Sube lo que quedó solo en este equipo (sin conexión, o la app se cerró antes del debounce). Solo
// los del usuario logueado: la RLS no deja crear un borrador a nombre de otro. Si mientras tanto
// alguien cambió el mismo borrador en la base, no se lo pisa: se sube como borrador nuevo.
// Una sola subida a la vez: dos listados montados (o el doble efecto de React en desarrollo) que
// suben lo mismo en paralelo chocaban por id y terminaban creando una copia de más.
let subiendo: Promise<void> | null = null

export function subirBorradoresPendientes(supabase: SupabaseClient, sistema: SistemaApp): Promise<void> {
  if (!subiendo) {
    subiendo = subirPendientes(supabase, sistema).finally(() => {
      subiendo = null
    })
  }
  return subiendo
}

async function subirPendientes(supabase: SupabaseClient, sistema: SistemaApp): Promise<void> {
  const yo = await usuarioActual(supabase)
  if (!yo) return
  for (const e of leerLocales()) {
    if (!e.pendiente || e.sistema !== sistema || abiertos.has(e.id)) continue
    if (e.usuarioId && e.usuarioId !== yo) continue
    let version: number | null = null
    if (e.version === null) {
      const { data, error, status } = await supabase
        .from('borradores')
        .insert({ id: e.id, tipo: e.tipo, sistema: e.sistema, payload: e.payload, resumen: e.resumen })
        .select('version')
        .maybeSingle()
      if (error && isNetworkError(status)) return
      if (!error) version = (data as { version: number } | null)?.version ?? null
      // Ya estaba en la base (se subió en otra pestaña o antes de cortarse la respuesta): listo.
      if (error?.code === '23505') {
        escribirLocal({ ...e, pendiente: false })
        continue
      }
    } else {
      const { data, error, status } = await supabase
        .from('borradores')
        .update({ payload: e.payload, resumen: e.resumen })
        .eq('id', e.id)
        .eq('version', e.version)
        .select('version')
        .maybeSingle()
      if (error && isNetworkError(status)) return
      if (!error && data) version = (data as { version: number }).version
    }
    if (version !== null) {
      escribirLocal({ ...e, version, pendiente: false })
      continue
    }
    // Cambió en la base (u otro lo borró): copia nueva, así no se pierde lo cargado offline.
    const id = crypto.randomUUID()
    const { data, error, status } = await supabase
      .from('borradores')
      .insert({ id, tipo: e.tipo, sistema: e.sistema, payload: e.payload, resumen: `${e.resumen} (copia sin conexión)` })
      .select('version')
      .maybeSingle()
    if (error && isNetworkError(status)) return
    borrarLocal(e.id)
    if (!error && data) escribirLocal({ ...e, id, version: (data as { version: number }).version, pendiente: false })
  }
}

// ─── Hook del formulario ──────────────────────────────────────────────────────────────────────

export type EstadoBorrador =
  | { tipo: 'inactivo' }
  | { tipo: 'guardando' }
  | { tipo: 'guardado'; en: Date }
  | { tipo: 'sin_conexion'; en: Date } // quedó en el equipo; se sube al volver la red
  | { tipo: 'error'; mensaje: string }
  | { tipo: 'conflicto'; editor: string | null; en: string } // otro guardó después: autoguardado frenado
  | { tipo: 'eliminado' } // lo borró o lo confirmó otro: autoguardado frenado

type OpcionesBorrador<T> = {
  supabase: SupabaseClient
  sistema: SistemaApp
  tipo: TipoBorrador
  payload: T
  resumen: string
  // Autoguardado prendido (ej. desde el primer dato real). guardarAhora funciona igual sin esto.
  activo: boolean
  demoraMs?: number
}

export function useBorrador<T>({ supabase, sistema, tipo, payload, resumen, activo, demoraMs = 2000 }: OpcionesBorrador<T>) {
  const [id, setId] = useState<string>(() => crypto.randomUUID())
  const [estado, setEstado] = useState<EstadoBorrador>({ tipo: 'inactivo' })
  const [usuarioId, setUsuarioId] = useState<string | null>(null)
  const idRef = useRef<string>(id)
  const versionRef = useRef<number | null>(null)
  const jsonServidorRef = useRef<string | null>(null) // último payload que la base tiene
  const ultimosRef = useRef({ payload, resumen })
  ultimosRef.current = { payload, resumen }
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const enCursoRef = useRef<Promise<void> | null>(null)
  const otraVezRef = useRef(false)
  const frenadoRef = useRef(false) // finalizado, descartado, confirmando, conflicto o eliminado
  const usuarioRef = useRef<string | null>(null)

  useEffect(() => {
    let vivo = true
    usuarioActual(supabase).then((u) => {
      usuarioRef.current = u
      if (vivo) setUsuarioId(u)
    })
    return () => {
      vivo = false
    }
  }, [supabase])

  useEffect(() => {
    abiertos.add(id)
    return () => {
      abiertos.delete(id)
    }
  }, [id])

  useEffect(
    () => () => {
      if (timerRef.current) clearTimeout(timerRef.current)
    },
    [],
  )

  const guardarLocal = useCallback(() => {
    const { payload: p, resumen: r } = ultimosRef.current
    escribirLocal({
      id: idRef.current,
      tipo,
      sistema,
      usuarioId: usuarioRef.current,
      payload: p,
      resumen: r,
      version: versionRef.current,
      pendiente: true,
      guardadoEn: new Date().toISOString(),
    })
  }, [tipo, sistema])

  const subir = useCallback(async () => {
    if (frenadoRef.current) return
    const { payload: p, resumen: r } = ultimosRef.current
    const json = JSON.stringify(p)
    if (json === jsonServidorRef.current) return
    const idActual = idRef.current
    setEstado({ tipo: 'guardando' })

    const res =
      versionRef.current === null
        ? await supabase
            .from('borradores')
            .insert({ id: idActual, tipo, sistema, payload: p, resumen: r })
            .select('version')
            .maybeSingle()
        : await supabase
            .from('borradores')
            .update({ payload: p, resumen: r })
            .eq('id', idActual)
            .eq('version', versionRef.current)
            .select('version')
            .maybeSingle()
    if (idActual !== idRef.current) return // se retomó otro borrador mientras tanto

    if (res.error) {
      setEstado(
        isNetworkError(res.status)
          ? { tipo: 'sin_conexion', en: new Date() }
          : { tipo: 'error', mensaje: 'No se pudo guardar el borrador en la base; lo cargado sigue en este equipo.' },
      )
      return
    }
    if (!res.data) {
      // 0 filas: otro guardó una version más nueva, o ya no existe.
      frenadoRef.current = true
      const { data: actual } = await supabase
        .from('borradores')
        .select('actualizado_por, updated_at')
        .eq('id', idActual)
        .maybeSingle()
      if (actual) {
        const nombres = await nombresPorId(supabase, [actual.actualizado_por as string])
        setEstado({ tipo: 'conflicto', editor: nombres.get(actual.actualizado_por as string) ?? null, en: actual.updated_at as string })
      } else {
        setEstado({ tipo: 'eliminado' })
      }
      return
    }
    versionRef.current = (res.data as { version: number }).version
    jsonServidorRef.current = json
    escribirLocal({
      id: idActual,
      tipo,
      sistema,
      usuarioId: usuarioRef.current,
      payload: p,
      resumen: r,
      version: versionRef.current,
      pendiente: false,
      guardadoEn: new Date().toISOString(),
    })
    setEstado({ tipo: 'guardado', en: new Date() })
  }, [supabase, tipo, sistema])

  // Una subida a la vez: si cambia algo mientras sube, sube otra vez al terminar.
  const guardarEnServidor = useCallback((): Promise<void> => {
    if (enCursoRef.current) {
      otraVezRef.current = true
      return enCursoRef.current
    }
    const promesa = (async () => {
      do {
        otraVezRef.current = false
        await subir()
      } while (otraVezRef.current && !frenadoRef.current)
    })().finally(() => {
      enCursoRef.current = null
    })
    enCursoRef.current = promesa
    return promesa
  }, [subir])

  // Autoguardado: equipo al instante, base con debounce.
  const json = JSON.stringify(payload)
  useEffect(() => {
    if (!activo || frenadoRef.current || json === jsonServidorRef.current) return
    guardarLocal()
    if (timerRef.current) clearTimeout(timerRef.current)
    timerRef.current = setTimeout(() => void guardarEnServidor(), demoraMs)
  }, [json, activo, id, demoraMs, guardarLocal, guardarEnServidor])

  // Volvió la red con cambios sin subir.
  useEffect(() => {
    function alVolver() {
      if (!frenadoRef.current && JSON.stringify(ultimosRef.current.payload) !== jsonServidorRef.current && versionRef.current !== null) {
        void guardarEnServidor()
      }
    }
    window.addEventListener('online', alVolver)
    return () => window.removeEventListener('online', alVolver)
  }, [guardarEnServidor])

  function limpiarTimer() {
    if (timerRef.current) clearTimeout(timerRef.current)
    timerRef.current = null
  }

  return {
    id,
    estado,
    usuarioId,
    // Botón "Guardar borrador" y "Guardar borrador" del diálogo de cierre.
    guardarAhora: useCallback(async () => {
      limpiarTimer()
      if (frenadoRef.current) return
      guardarLocal()
      await guardarEnServidor()
    }, [guardarLocal, guardarEnServidor]),
    // "Descartar": se borra de la base y del equipo.
    descartar: useCallback(async () => {
      limpiarTimer()
      frenadoRef.current = true
      await enCursoRef.current
      borrarLocal(idRef.current)
      if (versionRef.current !== null) await supabase.from('borradores').delete().eq('id', idRef.current)
    }, [supabase]),
    // Antes de confirmar: frena el autoguardado y espera la subida en curso (si no, podría llegar
    // después de que la RPC borró el borrador y dejarlo huérfano). Devuelve el id a mandar como
    // p_borrador_id, o null si nunca llegó a la base.
    prepararConfirmacion: useCallback(async (): Promise<string | null> => {
      limpiarTimer()
      frenadoRef.current = true
      await enCursoRef.current
      return versionRef.current !== null ? idRef.current : null
    }, []),
    // La confirmación falló: vuelve el autoguardado.
    cancelarConfirmacion: useCallback(() => {
      frenadoRef.current = false
    }, []),
    // Confirmado: la RPC ya borró la fila; queda limpiar el equipo.
    finalizar: useCallback(() => {
      limpiarTimer()
      frenadoRef.current = true
      borrarLocal(idRef.current)
    }, []),
    // Retomar un borrador de la lista (o recargar el de otro tras un conflicto). `payloadRestaurado`
    // es el que quedó en el formulario después de re-leer productos/proveedor: no se vuelve a
    // subir si el usuario no cambia nada.
    retomar: useCallback((fila: BorradorFila<unknown>, payloadRestaurado: unknown) => {
      limpiarTimer()
      idRef.current = fila.id
      versionRef.current = fila.version
      jsonServidorRef.current = JSON.stringify(payloadRestaurado)
      frenadoRef.current = false
      setId(fila.id)
      setEstado({ tipo: 'guardado', en: new Date(fila.updated_at) })
    }, []),
    // Formulario nuevo (Inventario después de guardar): otro borrador, desde cero.
    reiniciar: useCallback(() => {
      limpiarTimer()
      const nuevo = crypto.randomUUID()
      idRef.current = nuevo
      versionRef.current = null
      jsonServidorRef.current = null
      frenadoRef.current = false
      setId(nuevo)
      setEstado({ tipo: 'inactivo' })
    }, []),
    // Tras "eliminado": lo cargado sigue en pantalla y se guarda como borrador nuevo.
    guardarComoNuevo: useCallback(async () => {
      borrarLocal(idRef.current)
      const nuevo = crypto.randomUUID()
      idRef.current = nuevo
      versionRef.current = null
      jsonServidorRef.current = null
      frenadoRef.current = false
      setId(nuevo)
      guardarLocal()
      await guardarEnServidor()
    }, [guardarLocal, guardarEnServidor]),
    // Tras "conflicto": la fila actual de la base, para restaurarla en el formulario.
    leerDelServidor: useCallback(async (): Promise<BorradorFila<unknown> | null> => {
      const { data } = await supabase.from('borradores').select('*').eq('id', idRef.current).maybeSingle()
      return (data as BorradorFila<unknown> | null) ?? null
    }, [supabase]),
  }
}

export type ControlBorrador = ReturnType<typeof useBorrador>

// ─── Listado ──────────────────────────────────────────────────────────────────────────────────

// Sin react-query a propósito: Virikyna Inventario no tiene QueryClientProvider.
export function useBorradores<T>(supabase: SupabaseClient, tipo: TipoBorrador, sistema: SistemaApp) {
  const [borradores, setBorradores] = useState<BorradorConNombres<T>[]>([])
  const [cargando, setCargando] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [n, setN] = useState(0)

  useEffect(() => {
    let vivo = true
    ;(async () => {
      setCargando(true)
      await subirBorradoresPendientes(supabase, sistema).catch(() => {})
      const { data, error: dbError } = await supabase
        .from('borradores')
        .select('*')
        .eq('tipo', tipo)
        .order('updated_at', { ascending: false })
      if (!vivo) return
      if (dbError) {
        setError('No se pudieron leer los borradores.')
        setCargando(false)
        return
      }
      const filas = (data ?? []) as BorradorFila<T>[]
      const nombres = await nombresPorId(
        supabase,
        filas.flatMap((b) => [b.usuario_id, b.actualizado_por]),
      )
      if (!vivo) return
      setError(null)
      setBorradores(filas.map((b) => ({ ...b, autor: nombres.get(b.usuario_id) ?? null, editor: nombres.get(b.actualizado_por) ?? null })))
      setCargando(false)
    })()
    return () => {
      vivo = false
    }
  }, [supabase, tipo, sistema, n])

  return { borradores, cargando, error, recargar: useCallback(() => setN((x) => x + 1), []) }
}

export async function eliminarBorrador(supabase: SupabaseClient, id: string) {
  borrarLocal(id)
  return supabase.from('borradores').delete().eq('id', id)
}

// "hace 12 s" / "hace 3 min" / "a las 14:05" — indicador discreto del formulario.
export function haceCuanto(desde: Date, ahora: Date = new Date()): string {
  const s = Math.max(0, Math.round((ahora.getTime() - desde.getTime()) / 1000))
  if (s < 10) return 'recién'
  if (s < 60) return `hace ${s} s`
  if (s < 3600) return `hace ${Math.floor(s / 60)} min`
  return `a las ${formatHora(desde.toISOString())}`
}
