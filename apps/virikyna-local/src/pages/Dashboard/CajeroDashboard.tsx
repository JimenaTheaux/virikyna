import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { IconVentas } from '../../components/icons'
import {
  AlertaPreciosCard,
  fechaISO,
  formatCurrency,
  friendlyError,
  hoyAR,
  ProductosVendidos,
  StockBajoCard,
  useVentasPorProducto,
} from '@virikyna/shared'
import { fetchVentasUltimosDias } from './queries'
import { AbrirCajaCard } from './AbrirCajaCard'
import { supabase } from '../../lib/supabaseClient'

// Lo del turno: caja, etiquetas a cambiar, vender y qué se vendió. Inventario, Facturación y
// Cierre de caja quedan en el menú lateral (antes se repetían acá como botones).
export function CajeroDashboard() {
  const [loading, setLoading] = useState(true)
  const [ventasHoy, setVentasHoy] = useState(0)

  const hoy = hoyAR(0)
  const productosQuery = useVentasPorProducto(supabase, { desde: hoy, hasta: hoy })
  const errorProductos = productosQuery.error ? friendlyError(productosQuery.error as never) : null

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
    <div className="flex h-full flex-col gap-3">
      <div className="flex flex-wrap items-baseline gap-x-3">
        <h1 className="font-display text-headline-lg text-accent-darker">Dashboard</h1>
        <p className="font-sans text-body-md text-ink-soft">Lo del día.</p>
      </div>

      <AbrirCajaCard />
      <AlertaPreciosCard supabase={supabase} variant="fila" />

      <div className="grid min-h-0 flex-1 grid-cols-3 grid-rows-[auto_minmax(0,1fr)] gap-3">
        <Link
          to="/ventas"
          className="flex h-24 items-center justify-center gap-3 rounded-lg bg-accent text-white shadow-sm transition hover:bg-accent-dark"
        >
          <IconVentas className="h-7 w-7 [stroke-width:1.5]" />
          <span className="font-sans text-body-lg font-semibold">Nueva venta</span>
        </Link>

        <div className="flex h-24 flex-col justify-center rounded-lg bg-accent-light px-4 shadow-sm">
          <span className="font-sans text-label-md font-bold uppercase text-ink-soft">Ventas del día</span>
          <span className="mt-0.5 font-display text-headline-md text-accent-darker">
            {loading ? '—' : formatCurrency(ventasHoy)}
          </span>
        </div>

        <StockBajoCard supabase={supabase} className="col-start-3 row-span-2 row-start-1 min-h-0 overflow-hidden" />

        <div className="col-span-2 flex min-h-0 flex-col">
          {errorProductos ? (
            <p className="rounded bg-error/10 px-4 py-2 font-sans text-body-md text-error">{errorProductos}</p>
          ) : (
            <ProductosVendidos
              filas={productosQuery.data ?? []}
              titulo="Productos vendidos hoy"
              className="min-h-0 flex-1"
              alturaTabla="min-h-0 flex-1"
              verTodosArriba
            />
          )}
        </div>
      </div>
    </div>
  )
}
