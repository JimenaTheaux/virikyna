import { DevolucionesTab as SharedDevolucionesTab } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { showToast } from '../../lib/toast'
import { usePerfil } from '../../auth/AuthContext'

export function DevolucionesTab() {
  const { rol } = usePerfil()
  return <SharedDevolucionesTab supabase={supabase} esAdmin={rol === 'admin'} onAviso={showToast} />
}
