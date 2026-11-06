import { useNavigate, useParams } from 'react-router-dom'
import { ClienteCuentaCorriente, ClientesPage } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { SearchInput } from '../../components/SearchInput'
import { ComprobanteModal } from '../../components/ComprobanteModal'

// /clientes — listado compartido (packages/shared, docs/68). Abrir un cliente lleva a su cuenta.
export function ClientesListadoPage() {
  const navigate = useNavigate()
  return <ClientesPage supabase={supabase} SearchInput={SearchInput} onAbrirCuenta={(id) => navigate(`/clientes/${id}`)} />
}

// /clientes/:id — cuenta corriente del cliente (docs/68), misma pantalla que proveedores.
// Gestión cobra con origen 'general': el cobro entra directo a la cuenta de cada medio (Caja Gestión), no al Cierre de Local.
export function ClienteCuentaCorrientePage() {
  const { id = '' } = useParams()
  const navigate = useNavigate()
  return (
    <ClienteCuentaCorriente
      key={id}
      supabase={supabase}
      clienteId={id}
      origen="general"
      onVolver={() => navigate('/clientes')}
      ComprobanteModal={ComprobanteModal}
    />
  )
}
