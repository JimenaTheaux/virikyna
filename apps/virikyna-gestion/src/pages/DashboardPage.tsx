import { useRef } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { IconCajaGestion, IconInventario, IconProveedores } from '../components/icons'
import { formatCurrency, friendlyError, hoyAR, StockBajoCard, DefectuososCard } from '@virikyna/shared'
import { useVentasPorDia } from './Dashboard/queries'
import { WeeklySalesChart } from './Dashboard/WeeklySalesChart'
import { AperturasAlerta } from './Dashboard/AperturasAlerta'
import { PeriodoFiltro } from './Dashboard/PeriodoFiltro'
import { diasDelRango, periodoDesdeParams, type TipoPeriodo } from './Dashboard/periodo'
import type { VentaDelDia } from './Dashboard/types'
import { supabase } from '../lib/supabaseClient'

// Suma de las filas por día (ya agregadas por la RPC) que caen dentro de un rango.
function totalesDe(filas: VentaDelDia[], { desde, hasta }: { desde: string; hasta: string }) {
  return filas
    .filter((f) => f.fecha >= desde && f.fecha <= hasta)
    .reduce((acc, f) => ({ total: acc.total + f.total, cantidad: acc.cantidad + f.cantidad }), { total: 0, cantidad: 0 })
}

const ACCESOS_RAPIDOS = [
  { to: '/inventario', label: 'Inventario', Icon: IconInventario },
  { to: '/proveedores', label: 'Proveedores', Icon: IconProveedores },
  { to: '/caja-gestion', label: 'Caja Gestión', Icon: IconCajaGestion },
]

// Vista única — Virikyna Gestión es exclusiva de Admin, sin variante Cajero
// (docs/04_modulos_y_funciones.md, módulo 2).
export function DashboardPage() {
  // El período vive en la URL (?periodo=…), así sobrevive a recargar y se puede compartir.
  // Todas las fechas en hora argentina (hoyAR), no del reloj de la PC — mismo día que la RPC.
  const [searchParams, setSearchParams] = useSearchParams()
  const periodo = periodoDesdeParams(searchParams)
  const fechaHoy = hoyAR(0)

  // Una sola llamada cubre el período, el anterior (comparación) y los días del gráfico.
  const ventasQuery = useVentasPorDia(periodo.consulta.desde, periodo.consulta.hasta)
  const loading = ventasQuery.isPending
  const error = ventasQuery.error ? friendlyError(ventasQuery.error as never) : null
  const filas = ventasQuery.data ?? []

  // Mientras llegan los datos del período nuevo se siguen mostrando los anteriores
  // (placeholderData): los KPIs y el gráfico se calculan con el período al que pertenecen esos
  // datos, no con el recién elegido — si no, sumarían $ 0 por un instante.
  const periodoDeLosDatos = useRef(periodo)
  if (!ventasQuery.isPlaceholderData) periodoDeLosDatos.current = periodo
  const mostrado = periodoDeLosDatos.current

  const actual = totalesDe(filas, mostrado.actual)
  const anterior = totalesDe(filas, mostrado.anterior)
  const ticketPromedio = actual.cantidad > 0 ? actual.total / actual.cantidad : 0

  const variacion =
    anterior.total > 0
      ? {
          texto: `${actual.total >= anterior.total ? '+' : ''}${(((actual.total - anterior.total) / anterior.total) * 100).toFixed(0)}% vs. ${mostrado.comparacion}`,
          subida: actual.total >= anterior.total,
        }
      : actual.total > 0
        ? {
            texto: `Sin ventas ${mostrado.comparacion === 'ayer' ? 'ayer' : `en ${mostrado.comparacion}`} para comparar`,
            subida: true,
          }
        : null

  function elegirTipo(tipo: TipoPeriodo) {
    if (tipo === 'hoy') setSearchParams({}, { replace: true })
    else if (tipo === 'rango') {
      // Arranca del período que se está viendo (en "Hoy", los 7 días del gráfico).
      const base = periodo.tipo === 'hoy' ? periodo.grafico : periodo.actual
      setSearchParams({ periodo: 'rango', desde: base.desde, hasta: base.hasta }, { replace: true })
    } else setSearchParams({ periodo: tipo }, { replace: true })
  }

  function elegirRango(desde: string, hasta: string) {
    setSearchParams({ periodo: 'rango', desde, hasta }, { replace: true })
  }

  const actualizando = ventasQuery.isPlaceholderData ? 'opacity-60' : ''

  return (
    <div className="flex h-full flex-col gap-stack-md">
      <div className="flex flex-wrap items-end justify-between gap-stack-md">
        <div>
          <h1 className="font-display text-headline-lg text-accent-darker">Dashboard</h1>
          <p className="mt-1 font-sans text-body-md text-ink-soft">Panorama del negocio.</p>
        </div>
        <PeriodoFiltro periodo={periodo} onTipo={elegirTipo} onRango={elegirRango} />
      </div>

      {error && <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>}

      <AperturasAlerta />

      <div className={`grid grid-cols-2 gap-gutter-grid transition-opacity xl:grid-cols-4 ${actualizando}`}>
        <div className="col-span-2 min-w-0 rounded-lg bg-surface p-card shadow-sm">
          <p className="font-sans text-label-bold uppercase text-ink-soft">Ventas</p>
          <p className="mt-2 font-display text-display-card text-accent-darker">
            {loading ? '—' : formatCurrency(actual.total)}
          </p>
          <p className="mt-2 font-sans text-label-md text-ink-soft">{mostrado.descripcion}</p>
          {!loading && variacion && (
            <p className={`mt-1 font-sans text-label-bold ${variacion.subida ? 'text-success' : 'text-error'}`}>
              {variacion.texto}
            </p>
          )}
        </div>
        <div className="min-w-0 rounded-lg bg-surface p-card shadow-sm">
          <p className="font-sans text-label-bold uppercase text-ink-soft">Tickets</p>
          <p className="mt-2 font-display text-headline-md text-accent-darker">{loading ? '—' : actual.cantidad}</p>
          <p className="mt-2 font-sans text-label-md text-ink-soft">{mostrado.descripcion}</p>
        </div>
        <div className="min-w-0 rounded-lg bg-surface p-card shadow-sm">
          <p className="font-sans text-label-bold uppercase text-ink-soft">Ticket promedio</p>
          <p className="mt-2 font-display text-headline-md text-accent-darker">
            {loading ? '—' : formatCurrency(ticketPromedio)}
          </p>
          <p className="mt-2 font-sans text-label-md text-ink-soft">{mostrado.descripcion}</p>
        </div>
      </div>

      <div className="grid flex-1 grid-cols-1 gap-gutter-grid lg:grid-cols-3">
        <div className={`min-w-0 rounded-lg bg-surface p-card shadow-sm transition-opacity lg:col-span-2 ${actualizando}`}>
          <WeeklySalesChart
            titulo={mostrado.tipo === 'hoy' ? 'Últimos 7 días' : 'Ventas por día'}
            dias={diasDelRango(mostrado.grafico)}
            serie={filas}
            hoy={fechaHoy}
          />
        </div>

        <div className="flex flex-col gap-gutter-grid">
          <StockBajoCard supabase={supabase} className="flex-1" />
          <DefectuososCard supabase={supabase} to="/inventario" />
        </div>
      </div>

      <div className="grid grid-cols-1 gap-gutter-grid sm:grid-cols-3">
        {ACCESOS_RAPIDOS.map(({ to, label, Icon }) => (
          <Link
            key={to}
            to={to}
            className="flex items-center gap-3 rounded-lg bg-surface p-card shadow-sm transition hover:bg-accent-light"
          >
            <Icon className="h-6 w-6 text-accent-dark" />
            <span className="font-sans text-label-bold text-ink">{label}</span>
          </Link>
        ))}
      </div>
    </div>
  )
}
