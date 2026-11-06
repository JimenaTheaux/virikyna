import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Eye } from 'lucide-react'
import type { ClienteSaldo } from '@virikyna/shared'
import { formatCurrency, friendlyError } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { Modal } from '../../components/Modal'

type Props = {
  onClose: () => void
}

// Listado de clientes con saldo de cuenta corriente pendiente, abierto desde la card "Pendiente
// de cobro" de Resumen Cuentas. El detalle y el cobro están en la cuenta corriente del cliente
// (/clientes/:id, docs/68): el ojo cierra este modal y lleva ahí.
export function PendienteCobroModal({ onClose }: Props) {
  const [clientes, setClientes] = useState<ClienteSaldo[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const navigate = useNavigate()

  async function cargar() {
    setLoading(true)
    setError(null)
    const { data, error: dbError } = await supabase
      .from('clientes_saldo')
      .select('*')
      .gt('saldo_actual', 0)
      .order('saldo_actual', { ascending: false })

    if (dbError) {
      setError(friendlyError(dbError))
      setLoading(false)
      return
    }

    const clientesData = (data ?? []) as ClienteSaldo[]
    setClientes(clientesData)
    setLoading(false)
  }

  useEffect(() => {
    cargar()
  }, [])

  return (
    <Modal title="Pendiente de cobro" onClose={onClose} dialogo={{ onEscape: onClose }} widthClassName="max-w-[560px]">
      <div className="flex flex-col gap-stack-md">
        <p className="font-sans text-body-md text-ink-soft">Clientes con cuenta corriente pendiente, de mayor a menor.</p>

        {error && <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>}

        <div className="overflow-x-auto rounded-lg border border-line">
          <table className="w-full text-left font-sans text-body-md leading-5">
            <thead>
              <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
                <th className="whitespace-nowrap px-3 py-2">Cliente</th>
                <th className="whitespace-nowrap px-3 py-2 text-right">Saldo</th>
                <th className="whitespace-nowrap px-3 py-2"></th>
              </tr>
            </thead>
            <tbody>
              {loading && (
                <tr>
                  <td className="px-4 py-4 text-ink-soft" colSpan={3}>
                    Cargando...
                  </td>
                </tr>
              )}
              {!loading && clientes.length === 0 && (
                <tr>
                  <td className="px-4 py-4 text-ink-soft" colSpan={3}>
                    No hay cuentas corrientes pendientes.
                  </td>
                </tr>
              )}
              {clientes.map((c) => (
                <tr key={c.id} className="border-b border-line last:border-0">
                  <td className="px-3 py-2 text-ink">{c.razon_social ?? c.nombre_fantasia}</td>
                  <td className="px-3 py-2 text-right text-error">{formatCurrency(c.saldo_actual)}</td>
                  <td className="px-3 py-2 text-right">
                    <button
                      type="button"
                      onClick={() => {
                        onClose()
                        navigate(`/clientes/${c.id}`)
                      }}
                      title="Ver cuenta corriente"
                      aria-label={`Ver cuenta corriente de ${c.razon_social ?? c.nombre_fantasia}`}
                      className="rounded px-3 py-1.5 text-accent-dark hover:bg-accent-light"
                    >
                      <Eye size={18} strokeWidth={1.5} />
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

    </Modal>
  )
}
