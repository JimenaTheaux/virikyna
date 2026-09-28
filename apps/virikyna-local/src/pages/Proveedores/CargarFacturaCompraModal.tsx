import { CargarFacturaCompraModal as CargarFacturaCompraModalCompartido } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { usePerfil } from '../../auth/AuthContext'
import { ProductoFormSheet } from '../Inventario/ProductoFormSheet'

type Props = {
  onClose: () => void
  onSaved: () => void
}

// La planilla vive en packages/shared (misma que Virikyna Gestión); acá solo se conecta el
// cliente de Supabase y el formulario de producto de esta app (que depende del rol del usuario).
export function CargarFacturaCompraModal({ onClose, onSaved }: Props) {
  const { rol } = usePerfil()

  return (
    <CargarFacturaCompraModalCompartido
      supabase={supabase}
      onClose={onClose}
      onSaved={onSaved}
      crearProducto={({ proveedores, nombreInicial, onClose: cerrar, onSaved: guardado }) =>
        rol ? (
          <ProductoFormSheet
            proveedores={proveedores}
            rol={rol}
            nombreInicial={nombreInicial}
            onClose={cerrar}
            onSaved={guardado}
            onStockChanged={() => {}}
          />
        ) : null
      }
    />
  )
}
