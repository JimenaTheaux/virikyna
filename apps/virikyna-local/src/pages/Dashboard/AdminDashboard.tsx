import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { IconCierreCaja, IconConfiguracion, IconInventario, IconProveedores } from '../../components/icons'
import { fechaISO, formatCurrency, StockBajoCard } from '@virikyna/shared'
import { friendlyError } from '@virikyna/shared'
import { fetchVentasUltimosDias } from './queries'
import { WeeklySalesChart } from './WeeklySalesChart'
import { AbrirCajaCard } from './AbrirCajaCard'
import { supabase } from '../../lib/supabaseClient'
import type { VentaDelDia } from './types'

const ACCESOS_RAPIDOS = [
  { to: '/inventario', label: 'Inventario', Icon: IconInventario },
  { to: '/proveedores', label: 'Proveedores', Icon: IconProveedores },
  { to: '/cierre-caja', label: 'Cierre de Caja', Icon: IconCierreCaja },
  { to: '/configuracion', label: 'Configuración', Icon: IconConfiguracion },
]

export function AdminDashboard() {
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [porDia, setPorDia] = useState<Map<string, VentaDelDia>>(new Map())

  useEffect(() => {
    async function cargar() {
      setLoading(true)
      setError(null)
      const ventasRes = await fetchVentasUltimosDias(7)
      if (ventasRes.error) setError(friendlyError(ventasRes.error as never))
      setPorDia(ventasRes.porDia)
      setLoading(false)
    }
    cargar()
  }, [])

  const hoy = porDia.get(fechaISO(0)) ?? { fecha: fechaISO(0), total: 0, cantidad: 0 }
  const ayer = porDia.get(fechaISO(-1)) ?? { fecha: fechaISO(-1), total: 0, cantidad: 0 }
  const ticketPromedio = hoy.cantidad > 0 ? hoy.total / hoy.cantidad : 0

  const variacion =
    ayer.total > 0
      ? { texto: `${hoy.total >= ayer.total ? '+' : ''}${(((hoy.total - ayer.total) / ayer.total) * 100).toFixed(0)}% vs. ayer`, subida: hoy.total >= ayer.total }
      : hoy.total > 0
        ? { texto: 'Sin ventas ayer para comparar', subida: true }
        : null

  return (
    <div className="flex h-full flex-col gap-stack-md">
      <div>
        <h1 className="font-display text-headline-lg text-accent-darker">Dashboard</h1>
        <p className="mt-1 font-sans text-body-md text-ink-soft">Panorama del negocio, hoy.</p>
      </div>

      {error && <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>}

      <AbrirCajaCard />

      <div className="grid grid-cols-4 gap-gutter-grid">
        <div className="col-span-2 rounded-lg bg-surface p-card shadow-sm">
          <p className="font-sans text-label-bold uppercase text-ink-soft">Ventas de hoy</p>
          <p className="mt-2 font-display text-display-card text-accent-darker">
            {loading ? '—' : formatCurrency(hoy.total)}
          </p>
          {!loading && variacion && (
            <p className={`mt-2 font-sans text-label-bold ${variacion.subida ? 'text-success' : 'text-error'}`}>
              {variacion.texto}
            </p>
          )}
        </div>
        <div className="rounded-lg bg-surface p-card shadow-sm">
          <p className="font-sans text-label-bold uppercase text-ink-soft">Tickets hoy</p>
          <p className="mt-2 font-display text-headline-md text-accent-darker">{loading ? '—' : hoy.cantidad}</p>
        </div>
        <div className="rounded-lg bg-surface p-card shadow-sm">
          <p className="font-sans text-label-bold uppercase text-ink-soft">Ticket promedio</p>
          <p className="mt-2 font-display text-headline-md text-accent-darker">
            {loading ? '—' : formatCurrency(ticketPromedio)}
          </p>
        </div>
      </div>

      <div className="grid flex-1 grid-cols-3 gap-gutter-grid">
        <div className="col-span-2 rounded-lg bg-surface p-card shadow-sm">
          <WeeklySalesChart porDia={porDia} />
        </div>

        <StockBajoCard supabase={supabase} />
      </div>

      <div className="grid grid-cols-4 gap-stack-sm">
        {ACCESOS_RAPIDOS.map(({ to, label, Icon }) => (
          <Link
            key={to}
            to={to}
            className="flex h-[130px] flex-col items-center justify-center gap-2 rounded-lg bg-surface shadow-sm transition hover:bg-accent-light"
          >
            <Icon className="h-7 w-7 text-accent-dark [stroke-width:1.5]" />
            <span className="font-sans text-body-lg text-ink">{label}</span>
          </Link>
        ))}
      </div>
    </div>
  )
}
