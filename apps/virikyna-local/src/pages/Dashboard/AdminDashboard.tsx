import { useEffect, useState, type ReactNode } from 'react'
import {
  AlertaPreciosCard,
  DefectuososCard,
  fechaISO,
  formatCurrency,
  friendlyError,
  hoyAR,
  ProductosVendidos,
  StockBajoCard,
  useVentasPorProducto,
} from '@virikyna/shared'
import { fetchDevolucionesUltimosDias, fetchVentasUltimosDias } from './queries'
import { WeeklySalesChart } from './WeeklySalesChart'
import { AbrirCajaCard } from './AbrirCajaCard'
import { supabase } from '../../lib/supabaseClient'
import type { VentaDelDia } from './types'

// KPI compacto (~70 px): etiqueta + cifra de 22 px, el detalle en una línea chica debajo.
function Kpi({ label, children, detalle }: { label: string; children: ReactNode; detalle?: ReactNode }) {
  return (
    <div className="min-w-0 rounded-lg bg-surface p-3.5 shadow-sm">
      <p className="font-sans text-label-md font-bold uppercase text-ink-soft">{label}</p>
      <div className="mt-0.5 flex flex-wrap items-baseline gap-x-2 font-display text-headline-md text-accent-darker">{children}</div>
      {detalle && <p className="mt-0.5 truncate font-sans text-label-md text-ink-soft">{detalle}</p>}
    </div>
  )
}

// Orden por prioridad (1366×768 sin scroll, ventana de Tauri maximizada): lo accionable arriba
// (caja, alerta de precios), las cifras del día al medio y los listados abajo, que se acomodan al
// alto que queda (scroll interno). Sin accesos rápidos: repetían el menú lateral.
export function AdminDashboard() {
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [porDia, setPorDia] = useState<Map<string, VentaDelDia>>(new Map())
  const [devolucionesNetoHoy, setDevolucionesNetoHoy] = useState(0)

  // Productos vendidos hoy (docs/61, día argentino como la RPC).
  const hoy = hoyAR(0)
  const productosQuery = useVentasPorProducto(supabase, { desde: hoy, hasta: hoy })

  useEffect(() => {
    async function cargar() {
      setLoading(true)
      setError(null)
      const [ventasRes, devolucionesRes] = await Promise.all([fetchVentasUltimosDias(7), fetchDevolucionesUltimosDias(1)])
      if (ventasRes.error) setError(friendlyError(ventasRes.error as never))
      setPorDia(ventasRes.porDia)
      setDevolucionesNetoHoy(devolucionesRes.netoPorDia.get(fechaISO(0)) ?? 0)
      setLoading(false)
    }
    cargar()
  }, [])

  const ventasHoy = porDia.get(fechaISO(0)) ?? { fecha: fechaISO(0), total: 0, cantidad: 0 }
  const ayer = porDia.get(fechaISO(-1)) ?? { fecha: fechaISO(-1), total: 0, cantidad: 0 }
  const ticketPromedio = ventasHoy.cantidad > 0 ? ventasHoy.total / ventasHoy.cantidad : 0

  const variacion =
    ayer.total > 0
      ? {
          texto: `${ventasHoy.total >= ayer.total ? '↑' : '↓'} ${Math.abs(Math.round(((ventasHoy.total - ayer.total) / ayer.total) * 100))}%`,
          detalle: `vs. ayer (${formatCurrency(ayer.total)})`,
          subida: ventasHoy.total >= ayer.total,
        }
      : null

  const errorProductos = productosQuery.error ? friendlyError(productosQuery.error as never) : null

  return (
    <div className="flex h-full flex-col gap-3">
      <div className="flex flex-wrap items-baseline gap-x-3">
        <h1 className="font-display text-headline-lg text-accent-darker">Dashboard</h1>
        <p className="font-sans text-body-md text-ink-soft">Panorama del negocio, hoy.</p>
      </div>

      {error && <p className="rounded bg-error/10 px-4 py-2 font-sans text-body-md text-error">{error}</p>}

      <AbrirCajaCard />
      <AlertaPreciosCard supabase={supabase} variant="fila" />

      <div className="grid grid-cols-3 gap-3">
        <Kpi
          label="Ventas de hoy (brutas)"
          detalle={
            !loading && devolucionesNetoHoy !== 0
              ? `Devoluciones ${devolucionesNetoHoy < 0 ? '−' : '+'} ${formatCurrency(Math.abs(devolucionesNetoHoy))} · Neta ${formatCurrency(ventasHoy.total + devolucionesNetoHoy)}`
              : undefined
          }
        >
          <span>{loading ? '—' : formatCurrency(ventasHoy.total)}</span>
          {!loading && variacion && (
            <span title={variacion.detalle} className={`font-sans text-label-bold ${variacion.subida ? 'text-success' : 'text-error'}`}>
              {variacion.texto}
              <span className="sr-only"> {variacion.detalle}</span>
            </span>
          )}
        </Kpi>
        <Kpi label="Tickets hoy">{loading ? '—' : ventasHoy.cantidad}</Kpi>
        <Kpi label="Ticket promedio">{loading ? '—' : formatCurrency(ticketPromedio)}</Kpi>
      </div>

      <div className="grid min-h-0 flex-1 grid-cols-3 gap-3">
        <div className="col-span-2 flex min-h-0 flex-col gap-3">
          <div className="rounded-lg bg-surface p-3.5 shadow-sm">
            <WeeklySalesChart porDia={porDia} altoBarras="h-12" />
          </div>
          {errorProductos ? (
            <p className="rounded bg-error/10 px-4 py-2 font-sans text-body-md text-error">{errorProductos}</p>
          ) : (
            <ProductosVendidos
              filas={productosQuery.data ?? []}
              titulo="Productos vendidos hoy"
              className="min-h-[9rem] flex-1"
              alturaTabla="min-h-0 flex-1"
              verTodosArriba
            />
          )}
        </div>
        <div className="flex min-h-0 flex-col gap-3">
          <StockBajoCard supabase={supabase} className="min-h-0 flex-1 overflow-hidden" />
          <DefectuososCard supabase={supabase} to="/facturacion" variant="auto" />
        </div>
      </div>
    </div>
  )
}
