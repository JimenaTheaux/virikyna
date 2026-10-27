import { useCallback, useEffect, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { formatCurrency, formatFechaHora } from '../../lib/format'
import { friendlyError } from '../../lib/supabaseErrors'
import { Modal } from './Modal'

// Ventas con la emisión de Factura C bloqueada para revisar (docs/66): un intento llegó a pedir el CAE,
// se cortó, y cuando otra pantalla volvió a intentar ARCA ya tenía otro último número. Puede haber una
// factura emitida para la venta que no quedó guardada. Mientras esté acá, la venta no se puede emitir.
export type EmisionARevisar = {
  venta_id: string
  venta_numero: number
  venta_total: number
  venta_fecha: string
  ambiente: 'homologacion' | 'produccion' | null
  registrado_at: string | null
  registrado_por_nombre: string | null
  ultimo_arca: number | null
  ultimo_arca_actual: number | null
  revisar_at: string
  revisar_detectado_por_nombre: string | null
}

// `version`: cambiarlo vuelve a consultar (ej. después de emitir).
export function useEmisionesARevisar(supabase: SupabaseClient, version: unknown = 0) {
  const [lista, setLista] = useState<EmisionARevisar[]>([])
  const [recargas, setRecargas] = useState(0)
  const recargar = useCallback(() => setRecargas((n) => n + 1), [])

  useEffect(() => {
    let vigente = true
    supabase.rpc('listar_emisiones_factura_c_a_revisar').then(({ data, error }) => {
      // Sin la lista no se bloquea nada de más: la función igual rechaza emitir esas ventas.
      if (vigente && !error) setLista((data ?? []) as EmisionARevisar[])
    })
    return () => {
      vigente = false
    }
  }, [supabase, version, recargas])

  return { lista, recargar }
}

export function AvisoEmisionesARevisar({
  supabase,
  lista,
  esAdmin,
  onDesbloqueada,
}: {
  supabase: SupabaseClient
  lista: EmisionARevisar[]
  esAdmin: boolean
  onDesbloqueada: () => void
}) {
  const [aDesbloquear, setADesbloquear] = useState<EmisionARevisar | null>(null)
  if (lista.length === 0) return null

  return (
    <div role="alert" className="mt-stack-md rounded bg-badge-red-bg px-4 py-3 font-sans text-body-md text-ink">
      <p className="font-semibold text-error">
        Revisar emisión: {lista.length === 1 ? '1 venta puede' : `${lista.length} ventas pueden`} tener una Factura C
        emitida en ARCA que no quedó guardada.
      </p>
      <p className="mt-1 text-ink-soft">
        {esAdmin
          ? 'Buscala en ARCA (Mis Comprobantes) por fecha e importe antes de desbloquear. Si está, no desbloquees: hay que registrarla aparte.'
          : 'No se pueden emitir hasta que un administrador lo revise.'}
      </p>
      <table className="mt-2 w-full text-left text-table-row">
        <thead>
          <tr className="text-ink-soft">
            <th className="py-1 pr-3 font-semibold">Venta</th>
            <th className="py-1 pr-3 font-semibold">Total</th>
            <th className="py-1 pr-3 font-semibold">Intento de emisión</th>
            <th className="py-1 pr-3 font-semibold">Último N° en ARCA (guardado → actual)</th>
            {esAdmin && <th className="py-1" />}
          </tr>
        </thead>
        <tbody>
          {lista.map((e) => (
            <tr key={e.venta_id} className="border-t border-error/20">
              <td className="py-1 pr-3">N° {e.venta_numero}</td>
              <td className="py-1 pr-3 whitespace-nowrap">{formatCurrency(e.venta_total)}</td>
              <td className="py-1 pr-3">
                {e.registrado_at ? formatFechaHora(e.registrado_at) : '—'} · {e.registrado_por_nombre ?? '—'}
              </td>
              <td className="py-1 pr-3">
                {e.ultimo_arca ?? '—'} → {e.ultimo_arca_actual ?? '—'}
                {e.ambiente === 'homologacion' && ' (homologación)'}
              </td>
              {esAdmin && (
                <td className="py-1 text-right">
                  <button
                    type="button"
                    onClick={() => setADesbloquear(e)}
                    className="rounded border border-error px-3 py-1 font-sans text-label-bold text-error transition hover:bg-error hover:text-white"
                  >
                    Desbloquear
                  </button>
                </td>
              )}
            </tr>
          ))}
        </tbody>
      </table>

      {aDesbloquear && (
        <DesbloquearModal
          supabase={supabase}
          emision={aDesbloquear}
          onCancel={() => setADesbloquear(null)}
          onListo={() => {
            setADesbloquear(null)
            onDesbloqueada()
          }}
        />
      )}
    </div>
  )
}

function DesbloquearModal({
  supabase,
  emision,
  onCancel,
  onListo,
}: {
  supabase: SupabaseClient
  emision: EmisionARevisar
  onCancel: () => void
  onListo: () => void
}) {
  const [nota, setNota] = useState('')
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function desbloquear() {
    setGuardando(true)
    setError(null)
    const { error: rpcError } = await supabase.rpc('desbloquear_emision_factura_c', {
      p_venta_id: emision.venta_id,
      p_nota: nota,
    })
    setGuardando(false)
    if (rpcError) setError(friendlyError(rpcError))
    else onListo()
  }

  return (
    <Modal title={`Desbloquear venta N° ${emision.venta_numero}`} onClose={onCancel} widthClassName="max-w-[480px]" dialogo={{ onEscape: onCancel }}>
      <div className="flex flex-col gap-stack-md font-sans text-body-md text-ink">
        <p role="alert" className="rounded border border-error bg-error/10 px-3 py-2 font-bold text-error">
          Antes de desbloquear, verificá en ARCA que esta venta NO tenga factura emitida. Si la tiene, desbloquear
          genera una factura duplicada.
        </p>
        <p>
          Desbloquear permite volver a emitir la Factura C de esta venta. Buscala en ARCA por importe
          ({formatCurrency(emision.venta_total)}
          {emision.registrado_at ? `, intento del ${formatFechaHora(emision.registrado_at)}` : ''}).
        </p>
        <label className="flex flex-col gap-1">
          <span className="text-label-md text-ink-soft">Qué revisaste (queda en el historial)</span>
          <textarea
            value={nota}
            onChange={(e) => setNota(e.target.value)}
            rows={3}
            className="rounded border border-line bg-surface px-3 py-2 outline-none focus:border-accent"
          />
        </label>
        {error && <p className="rounded bg-error/10 px-3 py-2 text-error">{error}</p>}
        <div className="flex justify-end gap-3">
          <button type="button" data-autofocus onClick={onCancel} className="rounded px-4 py-3 text-label-bold text-ink-soft hover:bg-bg">
            Volver
          </button>
          <button
            type="button"
            onClick={desbloquear}
            disabled={guardando || nota.trim() === ''}
            className="rounded border border-error px-4 py-3 text-label-bold text-error transition hover:bg-error hover:text-white disabled:opacity-60"
          >
            {guardando ? 'Desbloqueando...' : 'Desbloquear'}
          </button>
        </div>
      </div>
    </Modal>
  )
}
