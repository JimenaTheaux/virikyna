import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { fetchDefectuososPendientes, type DefectuosoPendiente } from './queries'

// Alerta para la dueña: mercadería devuelta como defectuosa que no volvió al stock (docs/24,
// reingresa_stock = false) — está separada esperando revisión.
export function DefectuososCard({ maxItems = 3 }: { maxItems?: number }) {
  const [loading, setLoading] = useState(true)
  const [items, setItems] = useState<DefectuosoPendiente[]>([])

  useEffect(() => {
    let activo = true
    fetchDefectuososPendientes().then(({ data }) => {
      if (activo) {
        setItems(data)
        setLoading(false)
      }
    })
    return () => {
      activo = false
    }
  }, [])

  const unidades = items.reduce((acc, i) => acc + i.cantidad, 0)

  return (
    <Link
      to="/facturacion"
      className={`flex flex-col rounded-lg p-card shadow-sm transition ${
        items.length > 0
          ? 'border border-amarillo bg-amarillo/20 hover:bg-amarillo/30'
          : 'bg-surface hover:bg-accent-light'
      }`}
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
        <p className="mt-1 font-sans text-label-md text-accent-dark">+{items.length - maxItems} más — ver Devoluciones</p>
      )}
    </Link>
  )
}
