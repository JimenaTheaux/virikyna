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
// Local cobra con origen 'turno': el cobro entra al Cierre X/Z del día (el efectivo queda en el cajón, docs/58) y exige caja abierta.
export function ClienteCuentaCorrientePage() {
  const { id = '' } = useParams()
  const navigate = useNavigate()
  return (
    <ClienteCuentaCorriente
      key={id}
      supabase={supabase}
      clienteId={id}
      origen="turno"
      onVolver={() => navigate('/clientes')}
      ComprobanteModal={ComprobanteModal}
    />
  )
}
