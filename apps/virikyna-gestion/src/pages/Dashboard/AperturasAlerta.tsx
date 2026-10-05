import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabaseClient'
import { usePerfil } from '../../auth/AuthContext'
import { formatCurrency, formatFechaHora, friendlyError } from '@virikyna/shared'

type AperturaPendiente = {
  id: string
  diferencia: number
  usuario_nombre: string | null
  abierta_at: string
}

const QUERY_KEY = ['aperturas-pendientes']

async function fetchAperturasPendientes(): Promise<AperturaPendiente[]> {
  const { data, error } = await supabase.rpc('aperturas_con_diferencia_pendientes')
  if (error) throw error
  return ((data ?? []) as (Omit<AperturaPendiente, 'diferencia'> & { diferencia: number | string })[]).map((a) => ({
    ...a,
    diferencia: Number(a.diferencia),
  }))
}

// Alerta de aperturas de caja con diferencia (docs/21_apertura_caja.sql, punto 8 del roadmap):
// cuando un cajero abre la caja con un monto distinto al esperado (efectivo_contado del último
// Cierre Z), la dueña lo ve acá apenas entra al dashboard, sin tener que ir a buscarlo.
// Muestra todas las pendientes de revisión, sin límite ni filtro de período, hasta que la dueña
// las marca como revisadas (docs/27_aperturas_revisadas.sql). La RPC ya trae el nombre de quién abrió.
export function AperturasAlerta() {
  const queryClient = useQueryClient()
  const { rol } = usePerfil()
  const { data: aperturas = [], error } = useQuery({
    queryKey: QUERY_KEY,
    queryFn: fetchAperturasPendientes,
  })

  const marcar = useMutation({
    mutationFn: async (aperturaId: string) => {
      const { error: rpcError } = await supabase.rpc('marcar_apertura_revisada', { p_apertura_id: aperturaId })
      if (rpcError) throw rpcError
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: QUERY_KEY }),
  })

  if (error) {
    return (
      <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">
        No se pudieron cargar las alertas de apertura de caja: {friendlyError(error as never)}
      </p>
    )
  }

  if (aperturas.length === 0) return null

  return (
    <div className="flex flex-col gap-2 rounded-lg border border-amarillo bg-amarillo/20 p-card">
      {marcar.error && (
        <p className="font-sans text-body-md text-error">{friendlyError(marcar.error as never)}</p>
      )}
      {aperturas.map((a) => (
        <div key={a.id} className="flex flex-wrap items-center justify-between gap-2">
          <p className="min-w-0 font-sans text-body-md text-ink">
            ⚠ Apertura de caja con diferencia de {formatCurrency(Math.abs(a.diferencia))}
            {a.diferencia > 0 ? ' (sobró)' : ' (faltó)'} — {a.usuario_nombre ?? 'usuario desconocido'},{' '}
            {formatFechaHora(a.abierta_at)}
          </p>
          {rol === 'admin' && (
            <button
              type="button"
              onClick={() => marcar.mutate(a.id)}
              disabled={marcar.isPending}
              className="shrink-0 rounded px-3 py-1.5 font-sans text-label-bold text-accent-darker transition hover:bg-amarillo/30 disabled:opacity-60"
            >
              {marcar.isPending && marcar.variables === a.id ? 'Marcando…' : 'Marcar revisada'}
            </button>
          )}
        </div>
      ))}
    </div>
  )
}
