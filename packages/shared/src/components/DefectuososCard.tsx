import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import type { SupabaseClient } from '@supabase/supabase-js'

export type DefectuosoPendiente = { productoId: string; nombre: string; cantidad: number }

// Ítems devueltos como defectuosos (docs/24, reingresa_stock = false) de devoluciones activas:
// mercadería separada que no volvió al stock y espera revisión.
export async function fetchDefectuososPendientes(
  supabase: SupabaseClient,
): Promise<{ data: DefectuosoPendiente[]; error: unknown }> {
  const { data, error } = await supabase
    .from('devolucion_items')
    .select('producto_id, cantidad, producto:productos(nombre), devolucion:devoluciones!inner(estado)')
    .eq('tipo', 'devuelto')
    .eq('reingresa_stock', false)
    .eq('devolucion.estado', 'activa')

  if (error || !data) return { data: [], error }

  const porProducto = new Map<string, DefectuosoPendiente>()
  for (const row of data as unknown as { producto_id: string; cantidad: number; producto: { nombre: string } | null }[]) {
    const actual = porProducto.get(row.producto_id) ?? {
      productoId: row.producto_id,
      nombre: row.producto?.nombre ?? 'Producto',
      cantidad: 0,
    }
    actual.cantidad += row.cantidad
    porProducto.set(row.producto_id, actual)
  }
  return { data: [...porProducto.values()].sort((a, b) => b.cantidad - a.cantidad), error: null }
}

export interface DefectuososCardProps {
  supabase: SupabaseClient
  to: string // pantalla a la que lleva el click (cada app tiene su propia ruta)
  className?: string
  maxItems?: number
}

// Alerta para la dueña: mercadería devuelta como defectuosa, separada del stock, pendiente de
// revisión. Misma consulta y listado en Virikyna Local y Virikyna Gestión, por eso vive acá.
export function DefectuososCard({ supabase, to, className = '', maxItems = 3 }: DefectuososCardProps) {
  const [loading, setLoading] = useState(true)
  const [items, setItems] = useState<DefectuosoPendiente[]>([])

  useEffect(() => {
    let activo = true
    fetchDefectuososPendientes(supabase).then(({ data }) => {
      if (activo) {
        setItems(data)
        setLoading(false)
      }
    })
    return () => {
      activo = false
    }
  }, [supabase])

  const unidades = items.reduce((acc, i) => acc + i.cantidad, 0)

  return (
    <Link
      to={to}
      className={`flex flex-col rounded-lg p-card shadow-sm transition ${
        items.length > 0
          ? 'border border-amarillo bg-amarillo/20 hover:bg-amarillo/30'
          : 'bg-surface hover:bg-accent-light'
      } ${className}`}
    >
      <p className="font-sans text-label-bold uppercase text-ink-soft">Defectuosos pendientes de revisión</p>
      <p className="mt-2 font-display text-headline-md text-accent-darker">
        {loading ? '—' : items.length === 0 ? 'Ninguno' : `${unidades} unidad${unidades === 1 ? '' : 'es'}`}
      </p>
      <ul className="mt-2 space-y-1">
        {items.slice(0, maxItems).map((i) => (
          <li key={i.productoId} className="font-sans text-label-md text-ink-soft">
            {i.nombre} ({i.cantidad})
          </li>
        ))}
      </ul>
      {items.length > maxItems && (
        <p className="mt-1 font-sans text-label-md text-accent-dark">+{items.length - maxItems} más</p>
      )}
    </Link>
  )
}
