import { VentasDelDiaTab as SharedVentasDelDiaTab } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { FORMA_PAGO_LABEL } from '../../lib/comprobante'
import { ComprobanteModal } from '../../components/ComprobanteModal'
import { IconVerDetalle, IconEnviar } from '../../components/icons'

export function VentasDelDiaTab() {
  return (
    <SharedVentasDelDiaTab
      supabase={supabase}
      formaPagoLabel={FORMA_PAGO_LABEL}
      ComprobanteModal={ComprobanteModal}
      IconVerDetalle={IconVerDetalle}
      IconEnviar={IconEnviar}
    />
  )
}
