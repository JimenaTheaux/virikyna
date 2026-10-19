import {
  createContext,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from 'react'
import { Navigate, Outlet } from 'react-router-dom'
import type { AuthChangeEvent, Session, SupabaseClient, User } from '@supabase/supabase-js'
import type { Perfil } from '../types/database'

type AuthState = {
  session: Session | null
  user: User | null
  perfil: Perfil | null
  loading: boolean
  error: string | null
  signIn: (email: string, password: string) => Promise<{ error: string | null }>
  signOut: () => Promise<void>
}

type Opciones = {
  // Regla extra de la app sobre el perfil (además de existir y estar activo). Devuelve el mensaje
  // con el que se rechaza la sesión, o null si puede entrar. Gestión: solo admin.
  validarPerfil?: (perfil: Perfil) => string | null
}

// Fábrica de auth compartida entre las tres apps de Virikyna — mismo Supabase Auth y misma regla de
// perfil (docs/04_modulos_y_funciones.md, módulo 1): la sesión se resuelve contra `perfiles`, y un
// usuario desactivado (o que no pasa `validarPerfil`) se desloguea al instante.
// Cada app la instancia una sola vez con su propio cliente de Supabase.
//
// Eventos de Supabase Auth (docs/auditoria-2026-10-19.md, B.3 #1): la sesión se renueva sola cada
// ~hora (TOKEN_REFRESHED) y al volver a la pestaña puede llegar otra vez SIGNED_IN del mismo usuario.
// Ninguno de los dos puede volver a "Cargando…": eso desmontaba la pantalla entera y se perdía lo
// que hubiera en un formulario abierto. Solo la carga inicial o un usuario distinto cargan el perfil
// con `loading`; USER_UPDATED lo recarga en silencio.
export function createAuthController(supabase: SupabaseClient, loginPath = '/login', opciones: Opciones = {}) {
  const AuthContext = createContext<AuthState | null>(null)

  function AuthProvider({ children }: { children: ReactNode }) {
    const [session, setSession] = useState<Session | null>(null)
    const [perfil, setPerfil] = useState<Perfil | null>(null)
    const [loading, setLoading] = useState(true)
    const [error, setError] = useState<string | null>(null)
    // Usuario cuyo perfil está cargado (o cargándose): decide si un SIGNED_IN es otro usuario.
    const usuarioRef = useRef<string | null>(null)

    useEffect(() => {
      let active = true

      async function cargarPerfil(userId: string) {
        const { data, error: perfilError } = await supabase
          .from('perfiles')
          .select('*')
          .eq('id', userId)
          .single()

        if (!active) return

        const rechazo =
          perfilError || !data
            ? 'No se pudo cargar el perfil de este usuario.'
            : !data.activo
              ? 'Este usuario está desactivado. Consultá con un administrador.'
              : (opciones.validarPerfil?.(data as Perfil) ?? null)

        if (rechazo) {
          setError(rechazo)
          setPerfil(null)
          await supabase.auth.signOut()
          return
        }

        setPerfil(data as Perfil)
      }

      // Con loading (carga inicial o usuario nuevo) o en silencio (USER_UPDATED). Diferido con
      // setTimeout: Supabase desaconseja llamar a la API adentro del callback de onAuthStateChange
      // (puede trabarse esperando el mismo lock de la sesión).
      function programarPerfil(userId: string, conLoading: boolean) {
        usuarioRef.current = userId
        if (conLoading) setLoading(true)
        setTimeout(() => {
          if (!active) return
          cargarPerfil(userId).finally(() => {
            if (active && conLoading) setLoading(false)
          })
        }, 0)
      }

      const {
        data: { subscription },
      } = supabase.auth.onAuthStateChange((event: AuthChangeEvent, newSession) => {
        if (!active) return
        setSession(newSession)

        if (!newSession) {
          // SIGNED_OUT, o INITIAL_SESSION sin sesión guardada.
          usuarioRef.current = null
          setPerfil(null)
          setLoading(false)
          return
        }

        const userId = newSession.user.id
        switch (event) {
          case 'INITIAL_SESSION':
            programarPerfil(userId, true)
            break
          case 'SIGNED_IN':
            if (userId !== usuarioRef.current) programarPerfil(userId, true)
            break
          case 'USER_UPDATED':
            programarPerfil(userId, false)
            break
          default:
            // TOKEN_REFRESHED, PASSWORD_RECOVERY, MFA_*: solo la sesión nueva, nada más.
            break
        }
      })

      return () => {
        active = false
        subscription.unsubscribe()
      }
    }, [])

    async function signIn(email: string, password: string) {
      setError(null)
      const { error: signInError } = await supabase.auth.signInWithPassword({ email, password })
      if (signInError) {
        const message =
          signInError.message === 'Invalid login credentials'
            ? 'Email o contraseña incorrectos.'
            : signInError.message
        setError(message)
        return { error: message }
      }
      return { error: null }
    }

    async function signOut() {
      await supabase.auth.signOut()
    }

    return (
      <AuthContext.Provider
        value={{
          session,
          user: session?.user ?? null,
          perfil,
          loading,
          error,
          signIn,
          signOut,
        }}
      >
        {children}
      </AuthContext.Provider>
    )
  }

  function useAuth() {
    const ctx = useContext(AuthContext)
    if (!ctx) throw new Error('useAuth debe usarse dentro de <AuthProvider>')
    return ctx
  }

  function usePerfil() {
    const { perfil, loading } = useAuth()
    return { perfil, rol: perfil?.rol ?? null, loading }
  }

  // "Cargando…" solo hasta mostrar la app por primera vez. Después, nunca más se reemplaza el
  // <Outlet/> por un loader (desmontaría formularios abiertos): un cambio de usuario en otra pestaña
  // actualiza el perfil en el lugar, y cerrar sesión lleva al login.
  function RequireAuth() {
    const { session, loading } = useAuth()
    const mostradaRef = useRef(false)

    if (!session) {
      if (loading && !mostradaRef.current) return <Cargando />
      return <Navigate to={loginPath} replace />
    }

    if (loading && !mostradaRef.current) return <Cargando />

    mostradaRef.current = true
    return <Outlet />
  }

  return { AuthProvider, useAuth, usePerfil, RequireAuth }
}

function Cargando() {
  return (
    <div className="flex h-screen items-center justify-center bg-bg font-sans text-body-md text-ink-soft">
      Cargando...
    </div>
  )
}
