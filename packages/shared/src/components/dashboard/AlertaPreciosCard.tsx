import { useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { IndicadorCompacto } from '../StockBajoCard'
import { CambiosPrecioModal } from './CambiosPrecioModal'
import { useAlertaPrecios } from './preciosCambiados'

export interface AlertaPreciosCardProps {
  supabase: SupabaseClient
  // 'fila' (Dashboard de Local, Admin y Cajero): renglón de ancho completo, arriba, porque es tarea
  // del día. 'linea' (Gestión): un renglón más en la celda compacta de Stock / Defectuosos.
  variant: 'fila' | 'linea'
  className?: string
}

// Alerta de cambios de precio (docs/67): cuántos productos tienen un precio distinto al de su
// etiqueta en el local. Click → CambiosPrecioModal (ver, imprimir y marcar). Ámbar si hay alguno.
export function AlertaPreciosCard({ supabase, variant, className = '' }: AlertaPreciosCardProps) {
  const [abierto, setAbierto] = useState(false)
  const alerta = useAlertaPrecios(supabase)
  const n = alerta.data ?? 0
  const valor = alerta.isPending || alerta.isError ? '—' : String(n)
  const hay = n > 0

  const modal = abierto && <CambiosPrecioModal supabase={supabase} onClose={() => setAbierto(false)} />

  if (variant === 'linea') {
    return (
      <>
        <IndicadorCompacto onClick={() => setAbierto(true)} label="Precios a etiquetar" valor={valor} alerta={hay} className={className} />
        {modal}
      </>
    )
  }

  return (
    <>
      <button
        type="button"
        onClick={() => setAbierto(true)}
        className={`flex w-full items-center justify-between gap-3 rounded-lg px-4 py-2.5 text-left shadow-sm transition ${
          hay ? 'border border-amarillo bg-amarillo/20 hover:bg-amarillo/30' : 'bg-surface hover:bg-accent-light'
        } ${className}`}
      >
        <span className="flex min-w-0 items-center gap-2 font-sans text-label-md">
          <span aria-hidden="true" className={`h-2.5 w-2.5 shrink-0 rounded-full ${hay ? 'bg-badge-amber-text' : 'bg-line'}`} />
          <span className="font-bold uppercase text-ink-soft">Cambios de precio</span>
          <span className="text-ink-soft" aria-hidden="true">
            ·
          </span>
          <span className={`truncate ${hay ? 'font-semibold text-badge-amber-text' : 'text-ink-soft'}`}>
            {valor === '—'
              ? '—'
              : hay
                ? `${n} pendiente${n === 1 ? '' : 's'} de etiquetar`
                : 'Etiquetas al día'}
          </span>
        </span>
        <span className="shrink-0 font-sans text-label-bold text-accent-dark">
          {hay ? 'Ver y marcar' : 'Ver historial'} <span aria-hidden="true">›</span>
        </span>
      </button>
      {modal}
    </>
  )
}
