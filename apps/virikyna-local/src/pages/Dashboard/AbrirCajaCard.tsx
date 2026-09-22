import { useEffect, useState } from 'react'
import { supabase } from '../../lib/supabaseClient'
import { formatCurrency, formatFechaHora, friendlyError, mensajeErrorGuardado, nombresPorId } from '@virikyna/shared'
import type { AperturaCaja, CierreCaja } from '@virikyna/shared'
import { Field, ErrorText, inputClass } from '../../components/FormField'
import { IconAbrirCaja } from '../../components/icons'

// Recuadro de apertura de caja (docs/21_apertura_caja.sql, punto 8 del roadmap). Vive en el
// dashboard principal (Cajero y Admin de Virikyna Local) porque es lo primero que necesita
// resolver quien arranca el turno, antes de vender. Mientras hay una caja abierta no se muestra
// ningún formulario acá — solo el estado — porque no se puede reabrir hasta el próximo Cierre Z.
export function AbrirCajaCard() {
  const [loading, setLoading] = useState(true)
  const [apertura, setApertura] = useState<AperturaCaja | null>(null)
  const [ultimoZ, setUltimoZ] = useState<CierreCaja | null>(null)
  const [nombreZ, setNombreZ] = useState<string | null>(null)
  const [modificar, setModificar] = useState(false)
  const [montoInput, setMontoInput] = useState('0')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function cargar() {
    setLoading(true)
    setError(null)

    const [aperturaRes, zRes] = await Promise.all([
      supabase.from('aperturas_caja').select('*').is('cierre_z_id', null).order('abierta_at', { ascending: false }).limit(1).maybeSingle(),
      supabase.from('cierres_caja').select('*').eq('tipo', 'z').order('created_at', { ascending: false }).limit(1).maybeSingle(),
    ])

    if (aperturaRes.error) {
      setError(friendlyError(aperturaRes.error))
      setLoading(false)
      return
    }

    const aperturaAbierta = (aperturaRes.data as AperturaCaja | null) ?? null
    const z = (zRes.data as CierreCaja | null) ?? null
    setApertura(aperturaAbierta)
    setUltimoZ(z)
    setMontoInput(String(z?.efectivo_contado ?? 0))

    if (z) {
      const nombres = await nombresPorId(supabase, [z.usuario_id])
      setNombreZ(nombres.get(z.usuario_id) ?? null)
    } else {
      setNombreZ(null)
    }

    setLoading(false)
  }

  useEffect(() => {
    cargar()
  }, [])

  const montoEsperado = ultimoZ?.efectivo_contado ?? 0

  async function abrir(monto: number) {
    setSaving(true)
    setError(null)
    const { error: rpcError, status } = await supabase.rpc('abrir_caja', { p_monto_real: monto })
    if (rpcError) {
      setSaving(false)
      setError(mensajeErrorGuardado(rpcError, status, 'abrir la caja', 'podés reintentar'))
      return
    }
    setModificar(false)
    setSaving(false)
    await cargar()
  }

  if (loading) return null

  if (apertura) {
    return (
      <section className="flex items-center gap-3 rounded-lg bg-surface p-card shadow-sm">
        <IconAbrirCaja className="h-6 w-6 text-accent-dark [stroke-width:1.5]" />
        <div>
          <p className="font-sans text-label-bold uppercase text-ink-soft">Caja abierta</p>
          <p className="font-sans text-body-md text-ink">
            {formatCurrency(apertura.monto_real)} desde {formatFechaHora(apertura.abierta_at)}
          </p>
        </div>
      </section>
    )
  }

  return (
    <section className="rounded-lg border border-accent bg-accent-light p-card shadow-sm">
      <div className="flex items-center gap-2">
        <IconAbrirCaja className="h-6 w-6 text-accent-darker [stroke-width:1.5]" />
        <p className="font-sans text-label-bold uppercase text-accent-darker">Abrir caja</p>
      </div>
      <p className="mt-2 font-display text-headline-md text-accent-darker">{formatCurrency(montoEsperado)}</p>
      <p className="mt-1 font-sans text-label-md text-ink-soft">
        {ultimoZ
          ? `Monto esperado según el Cierre Z de ${nombreZ ?? '—'} — ${formatFechaHora(ultimoZ.created_at)}`
          : 'No hay ningún Cierre Z registrado todavía — se abre en $0.'}
      </p>

      {error && (
        <div className="mt-3">
          <ErrorText>{error}</ErrorText>
        </div>
      )}

      {!modificar ? (
        <div className="mt-stack-md flex flex-wrap gap-3">
          <button
            type="button"
            disabled={saving}
            onClick={() => abrir(montoEsperado)}
            className="rounded-lg bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
          >
            {saving ? 'Abriendo...' : `Confirmar ${formatCurrency(montoEsperado)}`}
          </button>
          <button
            type="button"
            onClick={() => setModificar(true)}
            className="rounded-lg border border-accent px-4 py-3 font-sans text-label-bold text-accent-dark hover:bg-white"
          >
            Modificar monto
          </button>
        </div>
      ) : (
        <div className="mt-stack-md flex flex-wrap items-end gap-3">
          <Field label="Monto real en caja">
            <input
              type="number"
              step="0.01"
              autoFocus
              value={montoInput}
              onChange={(e) => setMontoInput(e.target.value)}
              className={inputClass}
            />
          </Field>
          <button
            type="button"
            disabled={saving || montoInput.trim() === '' || Number.isNaN(Number(montoInput))}
            onClick={() => abrir(Number(montoInput))}
            className="rounded-lg bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
          >
            {saving ? 'Abriendo...' : 'Abrir con este monto'}
          </button>
          <button
            type="button"
            onClick={() => {
              setModificar(false)
              setMontoInput(String(montoEsperado))
            }}
            className="rounded-lg px-4 py-3 font-sans text-label-bold text-ink-soft hover:bg-white"
          >
            Cancelar
          </button>
        </div>
      )}
    </section>
  )
}
