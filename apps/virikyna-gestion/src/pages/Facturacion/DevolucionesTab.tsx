import { DevolucionesTab as SharedDevolucionesTab } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'

// Gestión es solo para admin (AuthContext) y no tiene toast: el aviso de anulación se muestra
// como banner dentro de la pestaña.
export function DevolucionesTab() {
  return <SharedDevolucionesTab supabase={supabase} esAdmin />
}
