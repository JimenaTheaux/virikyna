import { CargaInicial } from '@virikyna/shared'
import { supabase } from '../lib/supabaseClient'
import { usePerfil } from '../auth/AuthContext'
import { AjustarStockModal } from './Inventario/AjustarStockModal'

// Carga inicial de inventario (docs/04 módulo 5.2). En Gestión (solo admin) queda siempre: abre y
// cierra la etapa, ve el avance por usuario y puede seguir cargando con la carga cerrada. Con la
// carga cerrada, el stock de un producto ya cargado se corrige con "Ajustar stock" (docs/70 D7).
export function CargaInicialPage() {
  const { perfil } = usePerfil()
  if (!perfil) return null
  return (
    <CargaInicial
      supabase={supabase}
      perfil={perfil}
      variante="escritorio"
      bloquearSiCerrada={false}
      controlesAdmin
      AjustarStock={AjustarStockModal}
    />
  )
}
