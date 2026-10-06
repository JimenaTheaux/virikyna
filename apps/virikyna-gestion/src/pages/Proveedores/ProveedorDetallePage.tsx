import { useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { ProveedorCuentaCorriente, proveedorQueryKeys } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { CargarFacturaCompraModal } from './CargarFacturaCompraModal'
import { FacturaCompraDetalleModal } from './FacturaCompraDetalleModal'

// /proveedores/:id — cuenta corriente de un proveedor (docs/31). Envoltorio fino del componente
// compartido: Gestión registra sus pagos con origen 'general' (no salen de la caja de Local ni
// entran en su Cierre), habilita Editar/Anular, Copiar (docs/33) y enchufa su propio detalle de
// comprobante.
export function ProveedorDetallePage() {
  const { id = '' } = useParams()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [copiarId, setCopiarId] = useState<string | null>(null)

  return (
    <>
      <ProveedorCuentaCorriente
        key={id}
        supabase={supabase}
        proveedorId={id}
        origen="general"
        permitirEditarAnular
        onCopiar={(c) => setCopiarId(c.id)}
        onVolver={() => navigate('/proveedores?tab=proveedores')}
        renderDetalle={({ factura, proveedorNombre, onClose, onChanged }) => (
          <FacturaCompraDetalleModal
            factura={factura}
            proveedorNombre={proveedorNombre}
            onClose={onClose}
            onChanged={onChanged}
            onCopiar={() => {
              onClose()
              setCopiarId(factura.id)
            }}
          />
        )}
      />

      {copiarId && (
        <CargarFacturaCompraModal
          copiadaDeId={copiarId}
          onClose={() => setCopiarId(null)}
          onSaved={() => {
            setCopiarId(null)
            // La copia puede ser de otro proveedor (se puede cambiar al copiar): se refrescan todas
            // las cuentas en caché, no solo la de esta pantalla.
            void queryClient.invalidateQueries({ queryKey: ['proveedor'] })
            void queryClient.invalidateQueries({ queryKey: proveedorQueryKeys.saldos })
          }}
        />
      )}
    </>
  )
}
