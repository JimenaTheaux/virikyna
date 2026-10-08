import { CargaInicial } from '@virikyna/shared'
import { supabase } from '../lib/supabaseClient'
import { usePerfil } from '../auth/AuthContext'

// Carga inicial de inventario (docs/04 módulo 5.2). En Gestión (solo admin) queda siempre: abre y
// cierra la etapa, ve el avance por usuario y puede seguir cargando con la carga cerrada.
export function CargaInicialPage() {
  const { perfil } = usePerfil()
  if (!perfil) return null
  return <CargaInicial supabase={supabase} perfil={perfil} variante="escritorio" bloquearSiCerrada={false} controlesAdmin />
}
