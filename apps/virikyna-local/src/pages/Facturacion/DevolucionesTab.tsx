import { DevolucionesTab as SharedDevolucionesTab } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { showToast } from '../../lib/toast'
import { usePerfil } from '../../auth/AuthContext'
import { ComprobanteModal } from '../../components/ComprobanteModal'

export function DevolucionesTab() {
  const { rol } = usePerfil()
  return (
    <SharedDevolucionesTab supabase={supabase} esAdmin={rol === 'admin'} onAviso={showToast} ComprobanteModal={ComprobanteModal} />
  )
}
