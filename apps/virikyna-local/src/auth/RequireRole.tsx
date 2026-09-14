import { Navigate, Outlet } from 'react-router-dom'
import type { RolUsuario } from '@virikyna/shared'
import { usePerfil } from './AuthContext'

// Segunda capa de defensa además de la RLS de Supabase (ver 02_roles_y_permisos.md):
// un cajero no debe poder entrar a una ruta de admin ni editando la URL a mano.
export function RequireRole({ role }: { role: RolUsuario }) {
  const { rol, loading } = usePerfil()

  if (loading) return null
  if (rol !== role) return <Navigate to="/dashboard" replace />

  return <Outlet />
}
