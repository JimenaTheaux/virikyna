import {
  createContext,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from 'react'
import { Navigate, Outlet } from 'react-router-dom'
import type { Session, SupabaseClient, User } from '@supabase/supabase-js'
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

// Fábrica de auth compartida entre las apps de Virikyna (Local, Inventario móvil) — mismo
// Supabase Auth y misma regla de perfil (docs/04_modulos_y_funciones.md, módulo 1): la sesión
// se resuelve contra `perfiles`, y un usuario desactivado se desloguea al instante.
// Cada app la instancia una sola vez con su propio cliente de Supabase.
export function createAuthController(supabase: SupabaseClient, loginPath = '/login') {
  const AuthContext = createContext<AuthState | null>(null)

  function AuthProvider({ children }: { children: ReactNode }) {
    const [session, setSession] = useState<Session | null>(null)
    const [perfil, setPerfil] = useState<Perfil | null>(null)
    const [loading, setLoading] = useState(true)
    const [error, setError] = useState<string | null>(null)

    useEffect(() => {
      let active = true

      async function cargarPerfil(userId: string) {
        const { data, error: perfilError } = await supabase
          .from('perfiles')
          .select('*')
          .eq('id', userId)
          .single()

        if (!active) return

        if (perfilError || !data) {
          setError('No se pudo cargar el perfil de este usuario.')
          setPerfil(null)
          await supabase.auth.signOut()
          return
        }

        if (!data.activo) {
          setError('Este usuario está desactivado. Consultá con un administrador.')
          setPerfil(null)
          await supabase.auth.signOut()
          return
        }

        setPerfil(data as Perfil)
      }

      supabase.auth.getSession().then(({ data: { session: initialSession } }) => {
        if (!active) return
        setSession(initialSession)
        if (initialSession) {
          cargarPerfil(initialSession.user.id).finally(() => active && setLoading(false))
        } else {
          setLoading(false)
        }
      })

      const {
        data: { subscription },
      } = supabase.auth.onAuthStateChange((_event, newSession) => {
        if (!active) return
        setSession(newSession)
        if (newSession) {
          setLoading(true)
          cargarPerfil(newSession.user.id).finally(() => active && setLoading(false))
        } else {
          setPerfil(null)
          setLoading(false)
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

  function RequireAuth() {
    const { session, loading } = useAuth()

    if (loading) {
      return (
        <div className="flex h-screen items-center justify-center bg-bg font-sans text-body-md text-ink-soft">
          Cargando...
        </div>
      )
    }

    if (!session) {
      return <Navigate to={loginPath} replace />
    }

    return <Outlet />
  }

  return { AuthProvider, useAuth, usePerfil, RequireAuth }
}
