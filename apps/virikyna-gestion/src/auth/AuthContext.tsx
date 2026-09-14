import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import type { Session, User } from '@supabase/supabase-js'
import type { Perfil } from '@virikyna/shared'
import { supabase } from '../lib/supabaseClient'

type AuthState = {
  session: Session | null
  user: User | null
  perfil: Perfil | null
  loading: boolean
  error: string | null
  signIn: (email: string, password: string) => Promise<{ error: string | null }>
  signOut: () => Promise<void>
}

const AuthContext = createContext<AuthState | null>(null)

// Virikyna Gestión es exclusiva de Admin (docs/02_roles_y_permisos.md) — a diferencia de
// Virikyna Local/Inventario, acá NO se usa la fábrica genérica createAuthController: un
// cajero que inicia sesión con credenciales válidas igual queda afuera, con mensaje claro,
// en vez de solo ocultarle rutas en el router.
export function AuthProvider({ children }: { children: ReactNode }) {
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

      if (data.rol !== 'admin') {
        setError('Virikyna Gestión es exclusiva para administradores. Usá Virikyna Local para operar el mostrador.')
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
        signInError.message === 'Invalid login credentials' ? 'Email o contraseña incorrectos.' : signInError.message
      setError(message)
      return { error: message }
    }
    return { error: null }
  }

  async function signOut() {
    await supabase.auth.signOut()
  }

  return (
    <AuthContext.Provider value={{ session, user: session?.user ?? null, perfil, loading, error, signIn, signOut }}>
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth() {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth debe usarse dentro de <AuthProvider>')
  return ctx
}

export function usePerfil() {
  const { perfil, loading } = useAuth()
  return { perfil, rol: perfil?.rol ?? null, loading }
}
