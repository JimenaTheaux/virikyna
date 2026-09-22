import { useEffect, useState } from 'react'
import { supabase } from '../../lib/supabaseClient'
import { formatCurrency, formatFechaHora, nombresPorId } from '@virikyna/shared'
import type { AperturaCaja } from '@virikyna/shared'

type AperturaConNombre = AperturaCaja & { nombre: string | null }

// Alerta de aperturas de caja con diferencia (docs/21_apertura_caja.sql, punto 8 del roadmap):
// cuando un cajero abre la caja con un monto distinto al esperado (efectivo_contado del último
// Cierre Z), la dueña lo ve acá apenas entra al dashboard, sin tener que ir a buscarlo.
export function AperturasAlerta() {
  const [aperturas, setAperturas] = useState<AperturaConNombre[]>([])

  useEffect(() => {
    async function cargar() {
      const { data } = await supabase
        .from('aperturas_caja')
        .select('*')
        .neq('diferencia', 0)
        .order('abierta_at', { ascending: false })
        .limit(5)

      const filas = (data ?? []) as unknown as AperturaCaja[]
      if (filas.length === 0) {
        setAperturas([])
        return
      }
      const nombres = await nombresPorId(supabase, filas.map((a) => a.usuario_id))
      setAperturas(filas.map((a) => ({ ...a, nombre: nombres.get(a.usuario_id) ?? null })))
    }
    cargar()
  }, [])

  if (aperturas.length === 0) return null

  return (
    <div className="flex flex-col gap-2 rounded-lg border border-amarillo bg-amarillo/20 p-card">
      {aperturas.map((a) => (
        <p key={a.id} className="font-sans text-body-md text-ink">
          ⚠ Apertura de caja con diferencia de {formatCurrency(Math.abs(a.diferencia))}
          {a.diferencia > 0 ? ' (sobró)' : ' (faltó)'} — {a.nombre ?? 'usuario desconocido'},{' '}
          {formatFechaHora(a.abierta_at)}
        </p>
      ))}
    </div>
  )
}
