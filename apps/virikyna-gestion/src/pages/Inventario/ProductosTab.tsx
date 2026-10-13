import { ProductosTab as ProductosTabCompartida } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { ProductoFormModal } from './ProductoFormModal'
import { ActualizarPreciosModal } from './ActualizarPreciosModal'

// La lista vive en packages/shared (igual que en Local); Gestión aporta su formulario (siempre
// admin) y su actualización masiva.
export function ProductosTab() {
  return (
    <ProductosTabCompartida
      supabase={supabase}
      renderFormulario={({ producto, ...resto }) => (
        <ProductoFormModal key={producto?.id ?? 'nuevo'} producto={producto} {...resto} />
      )}
      renderActualizarPrecios={(args) => <ActualizarPreciosModal {...args} />}
    />
  )
}
