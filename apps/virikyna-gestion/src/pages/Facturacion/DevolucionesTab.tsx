import { DevolucionesTab as SharedDevolucionesTab } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { ComprobanteModal } from '../../components/ComprobanteModal'

// Gestión es solo para admin (AuthContext) y no tiene toast: el aviso de anulación se muestra
// como banner dentro de la pestaña. "Ver ticket" del detalle abre el comprobante original (docs/74).
export function DevolucionesTab() {
  return <SharedDevolucionesTab supabase={supabase} esAdmin ComprobanteModal={ComprobanteModal} />
}
