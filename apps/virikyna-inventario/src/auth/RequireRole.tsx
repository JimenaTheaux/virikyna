import { Navigate, Outlet } from 'react-router-dom'
import type { RolUsuario } from '@virikyna/shared'
import { usePerfil } from './AuthContext'

// Segunda capa de defensa además de la RLS de Supabase — igual que en Virikyna Local
// (ver apps/virikyna-local/src/auth/RequireRole.tsx): un cajero no debe poder entrar a una
// pantalla de admin (ej. ajustar stock) ni editando la URL a mano.
export function RequireRole({ role }: { role: RolUsuario }) {
  const { rol, loading } = usePerfil()

  if (loading) return null
  if (rol !== role) return <Navigate to="/inventario" replace />

  return <Outlet />
}
