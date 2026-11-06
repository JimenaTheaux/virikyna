import { useMemo, useState, type ComponentType } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { useQuery } from '@tanstack/react-query'
import { FileText } from 'lucide-react'
import { friendlyError } from '../../../lib/supabaseErrors'
import { fechaLocalDeISO, formatFechaHora, rangoTimestampsAR } from '../../../lib/format'
import { cargarComprobanteVenta, type DatosComprobante } from '../../../lib/comprobante'
import {
  CLASE_HISTORIAL,
  detalleFilaHistorial,
  etiquetaComprobanteFila,
  fetchHistorialProducto,
  fetchResumenHistorial,
  formatCantidadStock,
  GRUPO_DE_CLASE,
  GRUPOS_HISTORIAL,
  lineasCambios,
  type FilaHistorial,
  type GrupoHistorial,
} from '../../../lib/historialProducto'
import { ORIGEN_PRECIO_LABEL, type OrigenPrecio } from '../dashboard/preciosCambiados'
import { ControlSegmentado } from '../ControlSegmentado'
import { EstadoBadge } from '../EstadoBadge'
import { MostrarMas, PAGINA_LISTA } from '../MostrarMas'
import { cargarDevolucionDetalle, DevolucionDetalleModal, type DevolucionConDetalle } from '../DevolucionDetalleModal'

type Props = {
  supabase: SupabaseClient
  productoId: string
  // Lo que cambia por app se recibe armado (mismo criterio que VentasDelDiaTab): el comprobante de
  // venta (Local lo envía con el plugin shell de Tauri) y el detalle de factura de compra (cada app
  // tiene el suyo, con sus acciones por rol).
  ComprobanteModal: ComponentType<{ datos: DatosComprobante; onClose: () => void }>
  FacturaCompraDetalle: ComponentType<{ facturaId: string; onClose: () => void }>
}

type Abierto =
  | { tipo: 'venta'; datos: DatosComprobante }
  | { tipo: 'factura'; id: string }
  | { tipo: 'devolucion'; devolucion: DevolucionConDetalle }

const inputFecha =
  'rounded border border-line bg-surface px-3 py-2 font-sans text-body-md text-ink outline-none focus:border-accent'

const origenPrecioLabel = (o: string) => ORIGEN_PRECIO_LABEL[o as OrigenPrecio] ?? o

// Pestaña "Historial de movimientos" del detalle de producto (docs/70), en Gestión y Local. Una sola
// llamada trae la línea de tiempo entera con el stock resultante de cada fila (lo calcula la base
// sobre todos los movimientos): filtrar por tipo o fecha acá no cambia el stock de ninguna fila.
export function HistorialMovimientosTab({ supabase, productoId, ComprobanteModal, FacturaCompraDetalle }: Props) {
  const [grupo, setGrupo] = useState<GrupoHistorial>('todos')
  const [desde, setDesde] = useState('')
  const [hasta, setHasta] = useState('')
  const [mostrar, setMostrar] = useState(PAGINA_LISTA)
  const [abierto, setAbierto] = useState<Abierto | null>(null)
  const [abriendo, setAbriendo] = useState<number | null>(null)
  const [errorAbrir, setErrorAbrir] = useState<string | null>(null)

  const historial = useQuery({
    queryKey: ['historial-producto', productoId],
    queryFn: () => fetchHistorialProducto(supabase, productoId),
  })
  const rango = useMemo(
    () => ({
      desde: desde ? rangoTimestampsAR(desde, desde).desde : null,
      hasta: hasta ? rangoTimestampsAR(hasta, hasta).hasta : null,
    }),
    [desde, hasta],
  )
  const resumen = useQuery({
    queryKey: ['historial-producto', productoId, 'resumen', rango.desde, rango.hasta],
    queryFn: () => fetchResumenHistorial(supabase, productoId, rango),
  })

  const filas = historial.data ?? []
  const filtradas = useMemo(
    () =>
      filas.filter((f) => {
        if (grupo !== 'todos' && GRUPO_DE_CLASE[f.clase] !== grupo) return false
        const dia = fechaLocalDeISO(f.fecha)
        if (desde && dia < desde) return false
        if (hasta && dia > hasta) return false
        return true
      }),
    [filas, grupo, desde, hasta],
  )
  const visibles = filtradas.slice(0, mostrar)
  const conFiltro = grupo !== 'todos' || desde !== '' || hasta !== ''

  function cambiarFiltro(fn: () => void) {
    fn()
    setMostrar(PAGINA_LISTA)
  }

  async function abrirComprobante(f: FilaHistorial) {
    if (!f.refTabla || !f.refId) return
    setErrorAbrir(null)
    if (f.refTabla === 'factura_compra') {
      setAbierto({ tipo: 'factura', id: f.refId })
      return
    }
    setAbriendo(f.orden)
    try {
      if (f.refTabla === 'venta') {
        setAbierto({ tipo: 'venta', datos: await cargarComprobanteVenta(supabase, f.refId) })
      } else {
        setAbierto({ tipo: 'devolucion', devolucion: await cargarDevolucionDetalle(supabase, f.refId) })
      }
    } catch (e) {
      setErrorAbrir(`No se pudo abrir ${etiquetaComprobanteFila(f)?.toLowerCase() ?? 'el comprobante'}: ${friendlyError(e as never)}`)
    } finally {
      setAbriendo(null)
    }
  }

  const error = historial.error ?? resumen.error
  if (error) {
    return (
      <div role="alert" className="flex flex-wrap items-center gap-3 rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">
        <span>No se pudo cargar el historial: {friendlyError(error as never)}</span>
        <button
          type="button"
          onClick={() => {
            historial.refetch()
            resumen.refetch()
          }}
          className="rounded border border-error px-4 py-2 font-sans text-label-bold text-error transition hover:bg-error hover:text-white"
        >
          Reintentar
        </button>
      </div>
    )
  }

  if (historial.isPending) {
    return (
      <p role="status" className="py-6 font-sans text-body-md text-ink-soft">
        Cargando historial...
      </p>
    )
  }

  const r = resumen.data
  const hayMovimientos = filas.some((f) => f.cantidad !== null)

  return (
    <div className="flex flex-col gap-stack-md">
      {/* Resumen (D3): stock actual y último movimiento son siempre del producto entero. */}
      <dl className="grid grid-cols-3 gap-2 lg:grid-cols-6">
        <Tarjeta
          label="Stock actual"
          valor={r ? formatCantidadStock(r.stockActual, false) : '…'}
          tono={r && r.stockActual < 0 ? 'negativo' : 'destacado'}
          ayuda={r && r.stockActual < 0 ? 'Negativo' : undefined}
        />
        <Tarjeta label="Stock inicial" valor={r ? formatCantidadStock(r.stockInicial, false) : '…'} />
        <Tarjeta label="Entradas" valor={r ? formatCantidadStock(r.entradas, false) : '…'} />
        <Tarjeta label="Salidas" valor={r ? formatCantidadStock(r.salidas, false) : '…'} />
        <Tarjeta label="Ajustes" valor={r ? (r.ajustes === 0 ? '0' : formatCantidadStock(r.ajustes)) : '…'} />
        <Tarjeta
          label="Último movimiento"
          valor={r?.ultimoMovimientoFecha ? formatFechaHora(r.ultimoMovimientoFecha) : '—'}
          ayuda={r?.ultimoMovimientoClase ? CLASE_HISTORIAL[r.ultimoMovimientoClase].label : undefined}
          chico
        />
      </dl>
      {(desde || hasta) && (
        <p className="-mt-2 font-sans text-label-md text-ink-soft">
          Stock inicial, entradas, salidas y ajustes son del período elegido. El stock actual y el último movimiento, de
          todo el historial.
        </p>
      )}
      {r && r.diferenciaSinRegistro !== 0 && (
        <p role="status" className="rounded bg-badge-amber-bg px-3 py-2 font-sans text-label-md text-badge-amber-text">
          El stock no coincide con los movimientos registrados: hay una diferencia de{' '}
          {formatCantidadStock(r.diferenciaSinRegistro)} sin registro (primera fila del historial).
        </p>
      )}

      <div className="flex flex-wrap items-end gap-3">
        <div className="flex flex-col gap-1">
          <span aria-hidden className="font-sans text-label-md text-ink-soft">
            Tipo
          </span>
          <ControlSegmentado
            legend="Tipo de movimiento"
            ocultarLegend
            opciones={GRUPOS_HISTORIAL}
            value={grupo}
            onChange={(v) => cambiarFiltro(() => setGrupo(v))}
          />
        </div>
        <label className="flex flex-col gap-1">
          <span className="font-sans text-label-md text-ink-soft">Desde</span>
          <input
            type="date"
            value={desde}
            max={hasta || undefined}
            onChange={(e) => cambiarFiltro(() => setDesde(e.target.value))}
            className={inputFecha}
          />
        </label>
        <label className="flex flex-col gap-1">
          <span className="font-sans text-label-md text-ink-soft">Hasta</span>
          <input
            type="date"
            value={hasta}
            min={desde || undefined}
            onChange={(e) => cambiarFiltro(() => setHasta(e.target.value))}
            className={inputFecha}
          />
        </label>
        {conFiltro && (
          <button
            type="button"
            onClick={() =>
              cambiarFiltro(() => {
                setGrupo('todos')
                setDesde('')
                setHasta('')
              })
            }
            className="rounded border border-line px-4 py-2 font-sans text-label-bold text-accent-dark transition hover:bg-accent-light"
          >
            Quitar filtros
          </button>
        )}
        <p aria-live="polite" className="ml-auto pb-2 font-sans text-label-md text-ink-soft">
          {filtradas.length} {filtradas.length === 1 ? 'registro' : 'registros'}
          {conFiltro && ` de ${filas.length}`}
        </p>
      </div>

      {errorAbrir && (
        <p role="alert" className="rounded bg-error/10 px-3 py-2 font-sans text-label-md text-error">
          {errorAbrir}
        </p>
      )}

      {!hayMovimientos && !conFiltro && (
        <p className="font-sans text-body-md text-ink-soft">Sin movimientos todavía.</p>
      )}

      {filtradas.length === 0 ? (
        conFiltro && <p className="py-2 font-sans text-body-md text-ink-soft">Ningún registro coincide con el filtro.</p>
      ) : (
        <div className="overflow-hidden rounded-xl shadow-sm">
          <table className="w-full table-fixed text-left font-sans text-table-row max-xl:[&_td]:px-2 max-xl:[&_th]:px-2">
            <caption className="sr-only">
              Historial de movimientos de stock, precio y datos del producto, del más reciente al más viejo. La columna
              Stock es el stock después de cada movimiento.
            </caption>
            <colgroup>
              <col className="w-[8.75rem]" />
              <col className="w-[12.75rem]" />
              <col />
              <col className="w-[7rem]" />
              <col className="w-[5.25rem]" />
              <col className="w-[5.25rem]" />
              <col className="w-[2.75rem]" />
            </colgroup>
            <thead>
              <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
                <th scope="col" className="px-3 py-2.5">Fecha y hora</th>
                <th scope="col" className="px-3 py-2.5">Movimiento</th>
                <th scope="col" className="px-3 py-2.5">Detalle / origen</th>
                <th scope="col" className="px-3 py-2.5">Usuario</th>
                <th scope="col" className="px-3 py-2.5 text-right">Cantidad</th>
                <th scope="col" className="px-3 py-2.5 text-right">Stock</th>
                <th scope="col" className="px-1 py-2.5">
                  <span className="sr-only">Comprobante</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {visibles.map((f) => (
                <FilaTabla
                  key={f.orden}
                  fila={f}
                  abriendo={abriendo === f.orden}
                  onAbrir={() => abrirComprobante(f)}
                />
              ))}
            </tbody>
          </table>
        </div>
      )}
      <MostrarMas restantes={filtradas.length - visibles.length} onClick={() => setMostrar((n) => n + PAGINA_LISTA)} />

      {abierto?.tipo === 'venta' && <ComprobanteModal datos={abierto.datos} onClose={() => setAbierto(null)} />}
      {abierto?.tipo === 'factura' && <FacturaCompraDetalle facturaId={abierto.id} onClose={() => setAbierto(null)} />}
      {abierto?.tipo === 'devolucion' && (
        <DevolucionDetalleModal supabase={supabase} devolucion={abierto.devolucion} onClose={() => setAbierto(null)} />
      )}
    </div>
  )
}

function FilaTabla({ fila: f, abriendo, onAbrir }: { fila: FilaHistorial; abriendo: boolean; onAbrir: () => void }) {
  const clase = CLASE_HISTORIAL[f.clase] ?? { label: f.clase, variant: 'neutral' as const }
  const detalle = detalleFilaHistorial(f, origenPrecioLabel)
  const cambios = lineasCambios(f.cambios)
  const comprobante = etiquetaComprobanteFila(f)
  return (
    <tr className="border-b border-table-divider align-top last:border-0 even:bg-table-row-alt">
      <td className="whitespace-nowrap px-3 py-3 tabular-nums text-ink-soft">{formatFechaHora(f.fecha)}</td>
      <td className="px-3 py-3">
        <EstadoBadge variant={clase.variant}>{clase.label}</EstadoBadge>
      </td>
      <td className="px-3 py-3 text-ink [overflow-wrap:anywhere]">
        {detalle || (cambios.length === 0 ? <span className="text-ink-soft">—</span> : null)}
        {cambios.length > 0 && (
          <ul className={`text-ink-soft ${detalle ? 'mt-0.5' : ''}`}>
            {cambios.map((c) => (
              <li key={c}>{c}</li>
            ))}
          </ul>
        )}
      </td>
      <td className="px-3 py-3 text-ink-soft [overflow-wrap:anywhere]">{f.usuarioNombre ?? '—'}</td>
      <td className="px-3 py-3 text-right tabular-nums text-ink">
        {f.cantidad === null ? <span className="sr-only">sin cantidad</span> : formatCantidadStock(f.cantidad)}
      </td>
      <td className="px-3 py-3 text-right font-semibold tabular-nums text-ink">
        {formatCantidadStock(f.stockResultante, false)}
      </td>
      <td className="px-1 py-2">
        {comprobante && (
          <button
            type="button"
            onClick={onAbrir}
            disabled={abriendo}
            aria-label={`Ver ${comprobante}`}
            title={`Ver ${comprobante}`}
            className="flex h-[26px] w-[26px] items-center justify-center rounded bg-table-divider text-accent-dark transition hover:bg-accent-light disabled:opacity-60"
          >
            <FileText aria-hidden className="h-4 w-4" />
          </button>
        )}
      </td>
    </tr>
  )
}

function Tarjeta({
  label,
  valor,
  ayuda,
  tono,
  chico,
}: {
  label: string
  valor: string
  ayuda?: string
  tono?: 'destacado' | 'negativo'
  chico?: boolean
}) {
  const fondo =
    tono === 'negativo'
      ? 'border-transparent bg-badge-amber-bg text-badge-amber-text'
      : tono === 'destacado'
        ? 'border-transparent bg-accent-light text-accent-darker'
        : 'border-line bg-surface text-ink'
  return (
    <div className={`flex min-w-0 flex-col rounded-lg border px-3 py-2 ${fondo}`}>
      {/* Sin opacidad: el rótulo mantiene contraste AA en los tres fondos (docs/08 §5.3). */}
      <dt className={`font-sans text-label-bold uppercase ${tono ? '' : 'text-ink-soft'}`}>{label}</dt>
      <dd className={`tabular-nums [overflow-wrap:anywhere] ${chico ? 'font-sans text-label-bold' : 'font-display text-headline-md'}`}>
        {valor}
      </dd>
      {ayuda && <dd className="font-sans text-label-md">{ayuda}</dd>}
    </div>
  )
}
