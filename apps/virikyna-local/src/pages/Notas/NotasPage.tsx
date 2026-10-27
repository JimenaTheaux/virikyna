import { NotasInternas } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { usePerfil } from '../../auth/AuthContext'

export function NotasPage() {
  const { perfil } = usePerfil()
  return <NotasInternas supabase={supabase} origen="local" usuarioId={perfil?.id ?? null} />
}
