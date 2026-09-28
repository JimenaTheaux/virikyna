import type { Proveedor } from '@virikyna/shared'
import { ActualizarPreciosModal as ActualizarPreciosCompartido } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import type { ProductoConRelaciones } from './types'

type Props = {
  productos: ProductoConRelaciones[]
  proveedores: Proveedor[]
  seleccionInicial: string[]
  onClose: () => void
  onSaved: (cantidad: number) => void
}

// La actualización masiva de precios vive en packages/shared (misma para Virikyna Local y
// Virikyna Gestión); acá solo se conecta el cliente de Supabase de esta app.
export function ActualizarPreciosSheet(props: Props) {
  return <ActualizarPreciosCompartido supabase={supabase} {...props} />
}
