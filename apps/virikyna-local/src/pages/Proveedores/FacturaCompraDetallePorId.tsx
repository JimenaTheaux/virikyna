import { friendlyError, useFacturaCompraPorId } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { Modal } from '../../components/Modal'
import { FacturaCompraDetalleModal } from './FacturaCompraDetalleModal'

type Props = {
  facturaId: string
  onClose: () => void
}

// Detalle de una factura de la que solo se tiene el id — el link "Copia de Factura A 0001-123" del
// formulario de copia (docs/33). Sin botón Copiar: desde una copia no se encadena otra.
export function FacturaCompraDetallePorId({ facturaId, onClose }: Props) {
  const { factura, proveedorNombre, cargando, error } = useFacturaCompraPorId(supabase, facturaId)

  if (factura) {
    return (
      <FacturaCompraDetalleModal
        factura={factura}
        proveedorNombre={proveedorNombre || '—'}
        onClose={onClose}
        onPagoRegistrado={() => {}}
      />
    )
  }
  return (
    <Modal title="Factura de compra" onClose={onClose} dialogo={{ onEscape: onClose }}>
      <p role="status" className="font-sans text-body-md text-ink-soft">
        {cargando ? 'Cargando factura…' : error ? friendlyError(error) : 'No se encontró la factura.'}
      </p>
    </Modal>
  )
}
