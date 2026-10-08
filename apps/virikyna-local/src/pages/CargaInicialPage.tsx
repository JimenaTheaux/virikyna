import { CargaInicial } from '@virikyna/shared'
import { supabase } from '../lib/supabaseClient'
import { usePerfil } from '../auth/AuthContext'

// Carga inicial de inventario (docs/04 módulo 5.2): tabla de escritorio. Con la carga cerrada la
// pantalla se bloquea (después del cierre solo sigue en Gestión).
export function CargaInicialPage() {
  const { perfil } = usePerfil()
  if (!perfil) return null
  return <CargaInicial supabase={supabase} perfil={perfil} variante="escritorio" bloquearSiCerrada />
}
