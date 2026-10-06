import { useState } from 'react'
import { CargarFacturaCompraModal as CargarFacturaCompraModalCompartido } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { ProductoFormModal } from '../Inventario/ProductoFormModal'
import { FacturaCompraDetallePorId } from './FacturaCompraDetallePorId'

type Props = {
  onClose: () => void
  onSaved: () => void
  // Copiar una factura ya cargada (docs/33): el formulario la carga solo a partir del id.
  copiadaDeId?: string
}

// La planilla vive en packages/shared (misma que Virikyna Local); acá solo se conecta el
// cliente de Supabase, el formulario de producto de esta app y el detalle que abre el link a la
// factura original de una copia. La carga usa el mismo RPC atómico `cargar_factura_compra`, así
// que un admin puede cargar una factura sin ir a la caja.
export function CargarFacturaCompraModal({ onClose, onSaved, copiadaDeId }: Props) {
  const [originalId, setOriginalId] = useState<string | null>(null)

  return (
    <>
      <CargarFacturaCompraModalCompartido
        supabase={supabase}
        onClose={onClose}
        onSaved={onSaved}
        copiadaDeId={copiadaDeId}
        onVerOriginal={setOriginalId}
        crearProducto={({ proveedores, nombreInicial, codigoBarrasInicial, onClose: cerrar, onSaved: guardado, onUsarExistente }) => (
          <ProductoFormModal
            proveedores={proveedores}
            nombreInicial={nombreInicial}
            codigoBarrasInicial={codigoBarrasInicial}
            onClose={cerrar}
            onSaved={guardado}
            onEditarExistente={onUsarExistente}
            accionExistente="usar"
            onStockChanged={() => {}}
          />
        )}
      />
      {originalId && <FacturaCompraDetallePorId facturaId={originalId} onClose={() => setOriginalId(null)} />}
    </>
  )
}
