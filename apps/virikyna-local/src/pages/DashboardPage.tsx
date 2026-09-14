import { usePerfil } from '../auth/AuthContext'
import { AdminDashboard } from './Dashboard/AdminDashboard'
import { CajeroDashboard } from './Dashboard/CajeroDashboard'

export function DashboardPage() {
  const { rol, loading } = usePerfil()

  if (loading || !rol) return null

  return rol === 'admin' ? <AdminDashboard /> : <CajeroDashboard />
}
