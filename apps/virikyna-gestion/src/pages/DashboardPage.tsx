import { useRef, useState, type ReactNode } from 'react'
import { useSearchParams } from 'react-router-dom'
import { formatCurrency, friendlyError, hoyAR, StockBajoCard, DefectuososCard, ProductosVendidos } from '@virikyna/shared'
import { useVentasPorDia, useVentasPorProducto } from './Dashboard/queries'
import { WeeklySalesChart } from './Dashboard/WeeklySalesChart'
import { AperturasAlerta } from './Dashboard/AperturasAlerta'
import { PeriodoFiltro } from './Dashboard/PeriodoFiltro'
import { Reponer } from './Dashboard/Reponer'
import { TopProductos } from './Dashboard/TopProductos'
import { VentasPorMarca } from './Dashboard/VentasPorMarca'
import { diasDelRango, periodoDesdeParams, type TipoPeriodo } from './Dashboard/periodo'
import type { Medida, VentaDelDia } from './Dashboard/types'
import { supabase } from '../lib/supabaseClient'

// Suma de las filas por día (ya agregadas por la RPC) que caen dentro de un rango.
function totalesDe(filas: VentaDelDia[], { desde, hasta }: { desde: string; hasta: string }) {
  return filas
    .filter((f) => f.fecha >= desde && f.fecha <= hasta)
    .reduce((acc, f) => ({ total: acc.total + f.total, cantidad: acc.cantidad + f.cantidad }), { total: 0, cantidad: 0 })
}

// KPI compacto (~70 px): etiqueta + cifra de 22 px; el período va una sola vez, bajo el título.
function Kpi({ label, children, className = '' }: { label: string; children: ReactNode; className?: string }) {
  return (
    <div className={`min-w-0 rounded-lg bg-surface p-3.5 shadow-sm ${className}`}>
      <p className="font-sans text-label-md font-bold uppercase text-ink-soft">{label}</p>
      <div className="mt-0.5 flex flex-wrap items-baseline gap-x-2 font-display text-headline-md text-accent-darker">{children}</div>
    </div>
  )
}

// Vista única — Virikyna Gestión es exclusiva de Admin, sin variante Cajero
// (docs/04_modulos_y_funciones.md, módulo 2).
export function DashboardPage() {
  // El período vive en la URL (?periodo=…), así sobrevive a recargar y se puede compartir.
  // Todas las fechas en hora argentina (hoyAR), no del reloj de la PC — mismo día que la RPC.
  const [searchParams, setSearchParams] = useSearchParams()
  const periodo = periodoDesdeParams(searchParams)
  const fechaHoy = hoyAR(0)
  const [medida, setMedida] = useState<Medida>('unidades')

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

  // Por producto (docs/61): mismo período actual y anterior que los KPIs.
  const productosQuery = useVentasPorProducto(periodo.actual, periodo.anterior)
  const productos = productosQuery.data ?? []
  const errorProductos = productosQuery.error ? friendlyError(productosQuery.error as never) : null
  const unDia = periodo.actual.desde === periodo.actual.hasta

  const actual = totalesDe(filas, mostrado.actual)
  const anterior = totalesDe(filas, mostrado.anterior)
  const ticketPromedio = actual.cantidad > 0 ? actual.total / actual.cantidad : 0

  const variacion =
    anterior.total > 0
      ? {
          texto: `${actual.total >= anterior.total ? '↑' : '↓'} ${Math.abs(Math.round(((actual.total - anterior.total) / anterior.total) * 100))}%`,
          detalle: `vs. ${mostrado.comparacion} (${formatCurrency(anterior.total)})`,
          subida: actual.total >= anterior.total,
        }
      : actual.total > 0
        ? {
            texto: 'sin comparación',
            detalle: `Sin ventas ${mostrado.comparacion === 'ayer' ? 'ayer' : `en ${mostrado.comparacion}`} para comparar`,
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
  const actualizandoProductos = productosQuery.isPlaceholderData ? 'opacity-60' : ''

  // Todas las alturas salen del contenido (nada de h-full / flex-1): si no entra, scrollea el
  // <main> del layout, que deja lugar abajo para el footer fijo.
  return (
    <div className="flex flex-col gap-stack-md">
      {/* Título y período en una línea: en 1366×768 Hoy y Semana entran sin scroll. */}
      <div className="flex flex-wrap items-center justify-between gap-x-stack-md gap-y-2">
        <div className="flex min-w-0 flex-wrap items-baseline gap-x-3">
          <h1 className="font-display text-headline-lg text-accent-darker">Dashboard</h1>
          <p className="font-sans text-body-md text-ink-soft">{mostrado.descripcion}</p>
        </div>
        <PeriodoFiltro periodo={periodo} onTipo={elegirTipo} onRango={elegirRango} />
      </div>

      {error && <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>}
      {errorProductos && (
        <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{errorProductos}</p>
      )}

      <AperturasAlerta />

      <div className={`grid grid-cols-2 gap-gutter-grid transition-opacity xl:grid-cols-4 ${actualizando}`}>
        <Kpi label="Ventas">
          <span>{loading ? '—' : formatCurrency(actual.total)}</span>
          {!loading && variacion && (
            <span
              title={variacion.detalle}
              className={`font-sans text-label-bold ${variacion.subida ? 'text-success' : 'text-error'}`}
            >
              {variacion.texto}
              <span className="sr-only"> {variacion.detalle}</span>
            </span>
          )}
        </Kpi>
        <Kpi label="Tickets">{loading ? '—' : actual.cantidad}</Kpi>
        <Kpi label="Ticket promedio">{loading ? '—' : formatCurrency(ticketPromedio)}</Kpi>
        {/* Alertas de inventario: indicador chico con link, sin listado (el detalle está en Inventario). */}
        <div className="flex min-w-0 flex-col justify-center gap-0.5 rounded-lg bg-surface p-1.5 shadow-sm">
          <StockBajoCard supabase={supabase} variant="compacta" />
          <DefectuososCard supabase={supabase} to="/inventario" variant="compacta" />
        </div>
      </div>

      {/* Dos columnas que apilan cada una lo suyo (sin filas compartidas, así ninguna card deja
          hueco por la altura de la vecina): gráfico + tabla | Reponer + Por marca. Debajo de xl,
          todo en una columna. */}
      <div className="grid grid-cols-1 items-start gap-gutter-grid xl:grid-cols-3">
        <div className="flex min-w-0 flex-col gap-gutter-grid xl:col-span-2">
          <div className={`min-w-0 rounded-lg bg-surface p-4 shadow-sm transition-opacity ${actualizando}`}>
            <WeeklySalesChart
              titulo={mostrado.tipo === 'hoy' || mostrado.actual.desde === mostrado.actual.hasta ? 'Últimos 7 días' : 'Ventas por día'}
              dias={diasDelRango(mostrado.grafico)}
              serie={filas}
              hoy={mostrado.actual.desde === mostrado.actual.hasta ? mostrado.actual.hasta : fechaHoy}
            />
          </div>
          <div className={`min-w-0 transition-opacity ${actualizandoProductos}`}>
            {unDia ? (
              <ProductosVendidos
                filas={productos}
                titulo={periodo.tipo === 'hoy' ? 'Productos vendidos hoy' : 'Productos vendidos'}
              />
            ) : (
              <TopProductos filas={productos} medida={medida} onMedida={setMedida} comparacion={periodo.comparacion} />
            )}
          </div>
        </div>
        <div className={`flex min-w-0 flex-col gap-gutter-grid transition-opacity ${actualizandoProductos}`}>
          <Reponer filas={productos} loading={productosQuery.isPending} />
          {!unDia && <VentasPorMarca filas={productos} medida={medida} />}
        </div>
      </div>
    </div>
  )
}
