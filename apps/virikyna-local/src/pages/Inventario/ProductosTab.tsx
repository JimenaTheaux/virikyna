import { ProductosTab as ProductosTabCompartida } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { usePerfil } from '../../auth/AuthContext'
import { ProductoFormSheet } from './ProductoFormSheet'
import { ActualizarPreciosSheet } from './ActualizarPreciosSheet'

// La lista vive en packages/shared (igual que en Gestión); Local aporta su formulario, que
// condiciona margen y ajuste de stock por rol, y su actualización masiva.
export function ProductosTab() {
  const { rol } = usePerfil()
  if (!rol) return null

  return (
    <ProductosTabCompartida
      supabase={supabase}
      renderFormulario={({ producto, ...resto }) => (
        <ProductoFormSheet key={producto?.id ?? 'nuevo'} producto={producto} rol={rol} {...resto} />
      )}
      renderActualizarPrecios={(args) => <ActualizarPreciosSheet {...args} />}
    />
  )
}
