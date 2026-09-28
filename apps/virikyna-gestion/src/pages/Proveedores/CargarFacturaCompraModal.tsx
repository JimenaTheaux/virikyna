import { CargarFacturaCompraModal as CargarFacturaCompraModalCompartido } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { ProductoFormModal } from '../Inventario/ProductoFormModal'

type Props = {
  onClose: () => void
  onSaved: () => void
}

// La planilla vive en packages/shared (misma que Virikyna Local); acá solo se conecta el
// cliente de Supabase y el formulario de producto de esta app. La carga usa el mismo RPC
// atómico `cargar_factura_compra`, así que un admin puede cargar una factura sin ir a la caja.
export function CargarFacturaCompraModal({ onClose, onSaved }: Props) {
  return (
    <CargarFacturaCompraModalCompartido
      supabase={supabase}
      onClose={onClose}
      onSaved={onSaved}
      crearProducto={({ proveedores, nombreInicial, onClose: cerrar, onSaved: guardado }) => (
        <ProductoFormModal
          proveedores={proveedores}
          nombreInicial={nombreInicial}
          onClose={cerrar}
          onSaved={guardado}
          onStockChanged={() => {}}
        />
      )}
    />
  )
}
