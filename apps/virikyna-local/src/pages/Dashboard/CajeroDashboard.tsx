import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { IconCierreCaja, IconFacturacion, IconInventario, IconVentas } from '../../components/icons'
import { fechaISO, formatCurrency, StockBajoCard } from '@virikyna/shared'
import { fetchVentasUltimosDias } from './queries'
import { AbrirCajaCard } from './AbrirCajaCard'
import { supabase } from '../../lib/supabaseClient'

export function CajeroDashboard() {
  const [loading, setLoading] = useState(true)
  const [ventasHoy, setVentasHoy] = useState(0)

  useEffect(() => {
    async function cargar() {
      setLoading(true)
      const ventasRes = await fetchVentasUltimosDias(1)
      setVentasHoy(ventasRes.porDia.get(fechaISO(0))?.total ?? 0)
      setLoading(false)
    }
    cargar()
  }, [])

  return (
    <div className="flex h-full flex-col gap-stack-md">
      <div>
        <h1 className="font-display text-headline-lg text-accent-darker">Dashboard</h1>
        <p className="mt-1 font-sans text-body-md text-ink-soft">Accesos rápidos del día.</p>
      </div>

      <AbrirCajaCard />

      <div className="grid flex-1 grid-cols-3 grid-rows-3 gap-stack-sm">
        <Link
          to="/ventas"
          className="col-start-1 row-start-1 flex h-full flex-col items-center justify-center gap-2 rounded-lg bg-accent text-white shadow-sm transition hover:bg-accent-dark"
        >
          <IconVentas className="h-7 w-7 [stroke-width:1.5]" />
          <span className="font-sans text-body-lg">Nueva venta</span>
        </Link>

        <Link
          to="/inventario"
          className="col-start-2 row-start-1 flex h-full flex-col items-center justify-center gap-2 rounded-lg bg-surface shadow-sm transition hover:bg-accent-light"
        >
          <IconInventario className="h-7 w-7 text-accent-dark [stroke-width:1.5]" />
          <span className="font-sans text-body-lg text-ink">Inventario</span>
        </Link>

        <Link
          to="/facturacion"
          className="col-start-1 row-start-2 flex h-full flex-col items-center justify-center gap-2 rounded-lg bg-surface shadow-sm transition hover:bg-accent-light"
        >
          <IconFacturacion className="h-7 w-7 text-accent-dark [stroke-width:1.5]" />
          <span className="font-sans text-body-lg text-ink">Facturación</span>
        </Link>

        <Link
          to="/cierre-caja"
          className="col-start-2 row-start-2 flex h-full flex-col items-center justify-center gap-2 rounded-lg bg-surface shadow-sm transition hover:bg-accent-light"
        >
          <IconCierreCaja className="h-7 w-7 text-accent-dark [stroke-width:1.5]" />
          <span className="font-sans text-body-lg text-ink">Cierre de caja</span>
        </Link>

        <div className="col-start-1 row-start-3 col-span-2 flex h-full flex-col items-center justify-center gap-2 rounded-lg bg-accent-light shadow-sm">
          <span className="font-sans text-label-bold uppercase text-ink-soft">Ventas del día</span>
          <span className="font-display text-display-card text-accent-darker">
            {loading ? '—' : formatCurrency(ventasHoy)}
          </span>
        </div>

        <StockBajoCard supabase={supabase} className="col-start-3 row-start-1 row-span-3 h-full" />
      </div>
    </div>
  )
}
