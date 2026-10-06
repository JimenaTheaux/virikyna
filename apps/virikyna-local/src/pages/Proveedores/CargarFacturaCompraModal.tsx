import { useState } from 'react'
import { CargarFacturaCompraModal as CargarFacturaCompraModalCompartido } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { usePerfil } from '../../auth/AuthContext'
import { ProductoFormSheet } from '../Inventario/ProductoFormSheet'
import { FacturaCompraDetallePorId } from './FacturaCompraDetallePorId'

type Props = {
  onClose: () => void
  onSaved: () => void
  // Copiar una factura ya cargada (docs/33): el formulario la carga solo a partir del id.
  copiadaDeId?: string
}

// La planilla vive en packages/shared (misma que Virikyna Gestión); acá solo se conecta el
// cliente de Supabase, el formulario de producto de esta app (que depende del rol del usuario) y
// el detalle que abre el link a la factura original de una copia.
export function CargarFacturaCompraModal({ onClose, onSaved, copiadaDeId }: Props) {
  const { rol } = usePerfil()
  const [originalId, setOriginalId] = useState<string | null>(null)

  return (
    <>
      <CargarFacturaCompraModalCompartido
        supabase={supabase}
        onClose={onClose}
        onSaved={onSaved}
        copiadaDeId={copiadaDeId}
        onVerOriginal={setOriginalId}
        crearProducto={({ proveedores, nombreInicial, codigoBarrasInicial, onClose: cerrar, onSaved: guardado, onUsarExistente }) =>
          rol ? (
            <ProductoFormSheet
              proveedores={proveedores}
              rol={rol}
              nombreInicial={nombreInicial}
              codigoBarrasInicial={codigoBarrasInicial}
              onClose={cerrar}
              onSaved={guardado}
              onEditarExistente={onUsarExistente}
              accionExistente="usar"
              onStockChanged={() => {}}
            />
          ) : null
        }
      />
      {originalId && <FacturaCompraDetallePorId facturaId={originalId} onClose={() => setOriginalId(null)} />}
    </>
  )
}
