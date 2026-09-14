import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { IconCierreCaja, IconFacturacion, IconInventario, IconVentas } from '../../components/icons'
import { fechaISO, formatCurrency } from '@virikyna/shared'
import { fetchProductosStockBajo, fetchVentasUltimosDias } from './queries'

export function CajeroDashboard() {
  const [loading, setLoading] = useState(true)
  const [ventasHoy, setVentasHoy] = useState(0)
  const [stockBajoCount, setStockBajoCount] = useState(0)

  useEffect(() => {
    async function cargar() {
      setLoading(true)
      const [ventasRes, stockRes] = await Promise.all([fetchVentasUltimosDias(1), fetchProductosStockBajo()])
      setVentasHoy(ventasRes.porDia.get(fechaISO(0))?.total ?? 0)
      setStockBajoCount(stockRes.data.length)
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

      <div className="grid flex-1 grid-cols-3 grid-rows-2 gap-stack-sm">
        <Link
          to="/ventas"
          className="flex h-[130px] flex-col items-center justify-center gap-2 rounded-lg bg-accent text-white shadow-sm transition hover:bg-accent-dark"
        >
          <IconVentas className="h-7 w-7 [stroke-width:1.5]" />
          <span className="font-sans text-body-lg">Nueva venta</span>
        </Link>

        <Link
          to="/inventario"
          className="flex h-[130px] flex-col items-center justify-center gap-2 rounded-lg bg-surface shadow-sm transition hover:bg-accent-light"
        >
          <IconInventario className="h-7 w-7 text-accent-dark [stroke-width:1.5]" />
          <span className="font-sans text-body-lg text-ink">Inventario</span>
        </Link>

        <Link
          to="/facturacion"
          className="flex h-[130px] flex-col items-center justify-center gap-2 rounded-lg bg-surface shadow-sm transition hover:bg-accent-light"
        >
          <IconFacturacion className="h-7 w-7 text-accent-dark [stroke-width:1.5]" />
          <span className="font-sans text-body-lg text-ink">Facturación</span>
        </Link>

        <Link
          to="/cierre-caja"
          className="flex h-[130px] flex-col items-center justify-center gap-2 rounded-lg bg-surface shadow-sm transition hover:bg-accent-light"
        >
          <IconCierreCaja className="h-7 w-7 text-accent-dark [stroke-width:1.5]" />
          <span className="font-sans text-body-lg text-ink">Cierre de caja</span>
        </Link>

        <div className="flex h-[130px] flex-col items-center justify-center gap-2 rounded-lg bg-accent-light shadow-sm">
          <span className="font-sans text-label-bold uppercase text-ink-soft">Ventas del día</span>
          <span className="font-display text-display-card text-accent-darker">
            {loading ? '—' : formatCurrency(ventasHoy)}
          </span>
        </div>

        <Link
          to="/inventario"
          className={`flex h-[130px] flex-col items-center justify-center gap-2 rounded-lg shadow-sm transition ${
            stockBajoCount > 0 ? 'bg-amarillo/30 hover:bg-amarillo/40' : 'bg-surface hover:bg-accent-light'
          }`}
        >
          <span className="font-sans text-label-bold uppercase text-ink-soft">Stock bajo</span>
          <span className="font-display text-headline-md text-accent-darker">
            {loading ? '—' : stockBajoCount === 0 ? 'Todo en orden' : `${stockBajoCount} producto${stockBajoCount === 1 ? '' : 's'}`}
          </span>
        </Link>
      </div>
    </div>
  )
}
