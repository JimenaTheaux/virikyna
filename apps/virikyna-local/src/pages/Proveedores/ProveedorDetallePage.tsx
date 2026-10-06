import { useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { ProveedorCuentaCorriente, proveedorQueryKeys } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { CargarFacturaCompraModal } from './CargarFacturaCompraModal'
import { FacturaCompraDetalleModal } from './FacturaCompraDetalleModal'

// /proveedores/:id — cuenta corriente de un proveedor (docs/31). Envoltorio fino del componente
// compartido: Local registra sus pagos con origen 'turno' (salen de la caja y entran en su Cierre),
// sin Editar/Anular (exclusivos de Gestión). Copiar (docs/33) y el detalle son los propios de Local.
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
        origen="turno"
        permitirEditarAnular={false}
        onCopiar={(c) => setCopiarId(c.id)}
        onVolver={() => navigate('/proveedores?tab=proveedores')}
        renderDetalle={({ factura, proveedorNombre, onClose, onChanged }) => (
          <FacturaCompraDetalleModal
            factura={factura}
            proveedorNombre={proveedorNombre}
            onClose={onClose}
            onPagoRegistrado={onChanged}
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
