import { useNavigate, useParams } from 'react-router-dom'
import { ProveedorCuentaCorriente } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { FacturaCompraDetalleModal } from './FacturaCompraDetalleModal'

// /proveedores/:id — cuenta corriente de un proveedor (docs/31). Envoltorio fino del componente
// compartido: Gestión registra sus pagos con origen 'general' (no salen de la caja de Local ni
// entran en su Cierre), habilita Editar/Anular y enchufa su propio detalle de comprobante.
export function ProveedorDetallePage() {
  const { id = '' } = useParams()
  const navigate = useNavigate()

  return (
    <ProveedorCuentaCorriente
      key={id}
      supabase={supabase}
      proveedorId={id}
      origen="general"
      permitirEditarAnular
      onVolver={() => navigate('/proveedores?tab=proveedores')}
      renderDetalle={({ factura, proveedorNombre, onClose, onChanged }) => (
        <FacturaCompraDetalleModal
          factura={factura}
          proveedorNombre={proveedorNombre}
          onClose={onClose}
          onChanged={onChanged}
        />
      )}
    />
  )
}
