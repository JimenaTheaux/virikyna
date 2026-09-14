import { Navigate, Outlet } from 'react-router-dom'
import { useAuth } from './AuthContext'

// Nota: "sesión activa sin perfil admin" (cajero, o usuario desactivado) ya se resuelve en
// AuthContext haciendo signOut automático — acá solo falta la sesión, nunca sobra el rol.
export function RequireAuth() {
  const { session, loading } = useAuth()

  if (loading) {
    return (
      <div className="flex h-screen items-center justify-center bg-bg font-sans text-body-md text-ink-soft">
        Cargando...
      </div>
    )
  }

  if (!session) {
    return <Navigate to="/login" replace />
  }

  return <Outlet />
}
