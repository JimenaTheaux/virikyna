import { useEffect, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { keepPreviousData, useQuery, useQueryClient } from '@tanstack/react-query'
import type { EstadoComprobante, FormaPagoVenta } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { friendlyError, formatCurrency, emitirFacturaCReal, rangoTimestampsAR } from '@virikyna/shared'
import { formatFechaCortaLocal, formatHora, EstadoBadge } from '@virikyna/shared'
import { FORMA_PAGO_LABEL, type DatosComprobante } from '../../lib/comprobante'
import { ComprobanteModal } from '../../components/ComprobanteModal'
import { IconVerDetalle } from '../../components/icons'
import { filtrarVentas, segmentosResaltados, tieneNota } from './filtroVentas'
import type { VentaConFactura, VentaItemConProducto } from './types'

const ESTADO_LABEL: Record<'sin_facturar' | 'facturado', string> = {
  sin_facturar: 'Sin facturar',
  facturado: 'Facturada',
}

type EstadoFiltro = 'todas' | EstadoComprobante

async function fetchVentas(
  fechaDesde: string,
  fechaHasta: string,
  estadoFiltro: EstadoFiltro,
  formaPagoFiltro: 'todas' | FormaPagoVenta,
): Promise<VentaConFactura[]> {
  let query = supabase
    .from('ventas')
    .select('*, factura_c:facturas_c(*), cliente:clientes(razon_social, nombre_fantasia, mail, celular)')
    .in('estado', estadoFiltro === 'todas' ? ['sin_facturar', 'facturado'] : [estadoFiltro])
    .order('created_at', { ascending: false })

  if (fechaDesde) query = query.gte('created_at', rangoTimestampsAR(fechaDesde, fechaDesde).desde)
  if (fechaHasta) query = query.lte('created_at', rangoTimestampsAR(fechaHasta, fechaHasta).hasta)
  if (formaPagoFiltro !== 'todas') query = query.eq('forma_pago', formaPagoFiltro)

  const { data, error } = await query
  if (error) throw error
  return (data ?? []) as unknown as VentaConFactura[]
}

// Emite y envía Factura C de ventas ya cobradas en Virikyna Local — esta app no cobra
// (docs/05_stack_tecnico.md, sección 3), solo gestiona qué se factura formalmente y cuándo.
export function FacturacionTab() {
  const queryClient = useQueryClient()

  const [fechaDesde, setFechaDesde] = useState('')
  const [fechaHasta, setFechaHasta] = useState('')
  const [estadoFiltro, setEstadoFiltro] = useState<EstadoFiltro>('todas')
  const [formaPagoFiltro, setFormaPagoFiltro] = useState<'todas' | FormaPagoVenta>('todas')

  // Chip "Con notas" y buscador: filtran en cliente y viven en la URL (?notas=1&q=…) para
  // sobrevivir a recargar. El input escribe en la URL con 200 ms de debounce.
  const [searchParams, setSearchParams] = useSearchParams()
  const soloConNotas = searchParams.get('notas') === '1'
  const q = searchParams.get('q') ?? ''
  const [busqueda, setBusqueda] = useState(q)

  function actualizarParam(clave: 'notas' | 'q', valor: string | null) {
    setSearchParams(
      (prev) => {
        const next = new URLSearchParams(prev)
        if (valor) next.set(clave, valor)
        else next.delete(clave)
        return next
      },
      { replace: true },
    )
  }

  useEffect(() => {
    const valor = busqueda.trim()
    if (valor === q) return
    const t = setTimeout(() => actualizarParam('q', valor || null), 200)
    return () => clearTimeout(t)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [busqueda])

  const [seleccion, setSeleccion] = useState<Set<string>>(new Set())
  const [emitiendo, setEmitiendo] = useState(false)
  const [resultadoEmision, setResultadoEmision] = useState<string | null>(null)

  const [verComprobante, setVerComprobante] = useState<DatosComprobante | null>(null)

  // placeholderData: al cambiar un filtro se siguen viendo las filas anteriores hasta que llegan
  // las nuevas, sin parpadear a "Cargando...". staleTime 0: al volver a la tab se muestra lo que
  // había y se refresca igual — una venta facturada desde "Ventas del día" no puede seguir
  // apareciendo como "Sin facturar" acá.
  const ventasQuery = useQuery({
    queryKey: ['facturacion', fechaDesde, fechaHasta, estadoFiltro, formaPagoFiltro],
    queryFn: () => fetchVentas(fechaDesde, fechaHasta, estadoFiltro, formaPagoFiltro),
    placeholderData: keepPreviousData,
    staleTime: 0,
  })
  const ventas = ventasQuery.data ?? []
  const loading = ventasQuery.isPending
  const error = ventasQuery.error ? friendlyError(ventasQuery.error as never) : null

  const cantidadConNotas = ventas.filter((v) => tieneNota(v.nota)).length
  const visibles = filtrarVentas(ventas, soloConNotas, q)

  function toggleSeleccion(id: string) {
    setSeleccion((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  // Solo las filas visibles: una venta tildada que después quedó oculta por el chip o el buscador
  // no se factura sin que se vea.
  const seleccionadas = visibles.filter((v) => seleccion.has(v.id))
  const totalSeleccionado = seleccionadas.reduce((acc, v) => acc + v.total, 0)

  async function emitirFacturas() {
    if (seleccionadas.length === 0 || emitiendo) return
    setEmitiendo(true)
    setResultadoEmision(null)

    let ok = 0
    const errores: string[] = []

    // Secuencial y de a una — "1 Comprobante X = 1 Factura C", nunca se agrupan (regla
    // confirmada) — además ARCA solo acepta pedir un comprobante genuinamente por vez.
    for (const venta of seleccionadas) {
      const { ok: emitidaOk, mensaje } = await emitirFacturaCReal(supabase, venta)
      if (emitidaOk) {
        ok++
      } else {
        errores.push(mensaje)
      }
    }

    setEmitiendo(false)
    setSeleccion(new Set())
    setResultadoEmision(
      errores.length === 0
        ? `${ok} factura${ok === 1 ? '' : 's'} C emitida${ok === 1 ? '' : 's'} correctamente.`
        : `${ok} emitida(s). Con error — ${errores.join(' · ')}`,
    )
    queryClient.invalidateQueries({ queryKey: ['facturacion'] })
  }

  async function verDetalle(venta: VentaConFactura) {
    const { data: itemsData } = await supabase
      .from('venta_items')
      .select('cantidad, precio_unitario, importe, producto:productos(nombre, codigo_barras, codigo_interno)')
      .eq('venta_id', venta.id)
    const items = (itemsData ?? []) as unknown as VentaItemConProducto[]

    let pagos: { formaPago: FormaPagoVenta; monto: number }[] | undefined
    if (venta.forma_pago === 'combinado') {
      const { data: pagosData } = await supabase
        .from('venta_pagos')
        .select('forma_pago, monto')
        .eq('venta_id', venta.id)
      pagos = (pagosData ?? []).map((p) => ({ formaPago: p.forma_pago as FormaPagoVenta, monto: p.monto as number }))
    }

    const clienteNombre = venta.cliente
      ? venta.cliente.razon_social ?? venta.cliente.nombre_fantasia ?? 'Cliente'
      : 'Consumidor final'

    setVerComprobante({
      tipo: venta.factura_c ? 'factura_c' : 'comprobante_x',
      numero: venta.factura_c
        ? `${venta.factura_c.punto_venta}-${venta.factura_c.numero_factura}`
        : String(venta.numero),
      fecha: venta.factura_c?.fecha_emision ?? venta.created_at,
      clienteNombre,
      clienteMail: venta.cliente?.mail ?? null,
      clienteCelular: venta.cliente?.celular ?? null,
      formaPago: venta.forma_pago,
      pagos,
      items: items.map((it) => ({
        nombre: it.producto?.nombre ?? 'Producto',
        codigo: it.producto?.codigo_barras ?? it.producto?.codigo_interno ?? '',
        cantidad: it.cantidad,
        precioUnitario: it.precio_unitario,
        importe: it.importe,
      })),
      subtotal: venta.subtotal,
      descuentoPorcentaje: venta.descuento_porcentaje,
      recargoPorcentaje: venta.recargo_porcentaje,
      precioOficial: venta.precio_oficial,
      total: venta.total,
      cae: venta.factura_c?.cae ?? null,
      nota: venta.nota,
    })
  }

  const mensajeVacio = soloConNotas
    ? 'No hay ventas con notas en este período'
    : q.trim()
      ? 'No hay ventas que coincidan con la búsqueda.'
      : 'No hay comprobantes para este filtro.'

  return (
    <div className="flex h-full flex-col">
      <div className="flex flex-wrap items-end gap-3">
        <label className="flex flex-col gap-1">
          <span className="font-sans text-label-md text-ink-soft">Desde</span>
          <input
            type="date"
            value={fechaDesde}
            onChange={(e) => setFechaDesde(e.target.value)}
            className="rounded border border-line bg-surface px-3 py-2 font-sans text-body-md text-ink outline-none focus:border-accent"
          />
        </label>
        <label className="flex flex-col gap-1">
          <span className="font-sans text-label-md text-ink-soft">Hasta</span>
          <input
            type="date"
            value={fechaHasta}
            onChange={(e) => setFechaHasta(e.target.value)}
            className="rounded border border-line bg-surface px-3 py-2 font-sans text-body-md text-ink outline-none focus:border-accent"
          />
        </label>
        <label className="flex flex-col gap-1">
          <span className="font-sans text-label-md text-ink-soft">Estado</span>
          <select
            value={estadoFiltro}
            onChange={(e) => setEstadoFiltro(e.target.value as EstadoFiltro)}
            className="rounded border border-line bg-surface px-3 py-2 font-sans text-body-md text-ink outline-none focus:border-accent"
          >
            <option value="todas">Todas</option>
            <option value="sin_facturar">Sin facturar</option>
            <option value="facturado">Facturada</option>
          </select>
        </label>
        <label className="flex flex-col gap-1">
          <span className="font-sans text-label-md text-ink-soft">Medio de pago</span>
          <select
            value={formaPagoFiltro}
            onChange={(e) => setFormaPagoFiltro(e.target.value as 'todas' | FormaPagoVenta)}
            className="rounded border border-line bg-surface px-3 py-2 font-sans text-body-md text-ink outline-none focus:border-accent"
          >
            <option value="todas">Todos</option>
            {Object.entries(FORMA_PAGO_LABEL).map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
          </select>
        </label>
        <label className="flex min-w-[12rem] max-w-[20rem] flex-1 flex-col gap-1">
          <span className="font-sans text-label-md text-ink-soft">Buscar</span>
          <input
            type="search"
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="N° de venta, nota o cliente"
            className="w-full rounded border border-line bg-surface px-3 py-2 font-sans text-body-md text-ink outline-none focus:border-accent"
          />
        </label>
        <button
          type="button"
          aria-pressed={soloConNotas}
          onClick={() => actualizarParam('notas', soloConNotas ? null : '1')}
          className={[
            'rounded-full border px-4 py-2 font-sans text-label-bold transition',
            'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-1',
            soloConNotas
              ? 'border-accent bg-accent-light text-accent-darker'
              : 'border-line bg-surface text-ink-soft hover:border-accent hover:text-accent-darker',
          ].join(' ')}
        >
          Con notas ({cantidadConNotas})
        </button>

        <div className="ml-auto flex items-center gap-3">
          {seleccionadas.length > 0 && (
            <p className="font-sans text-body-md text-ink-soft">
              {seleccionadas.length} seleccionado{seleccionadas.length === 1 ? '' : 's'} ·{' '}
              {formatCurrency(totalSeleccionado)}
            </p>
          )}
          <button
            type="button"
            onClick={emitirFacturas}
            disabled={seleccionadas.length === 0 || emitiendo}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-50"
          >
            {emitiendo ? 'Emitiendo...' : 'Emitir Factura C'}
          </button>
        </div>
      </div>

      <p className="sr-only" aria-live="polite">
        {loading ? '' : `${visibles.length} venta${visibles.length === 1 ? '' : 's'}`}
      </p>

      {error && (
        <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>
      )}
      {resultadoEmision && (
        <p className="mt-stack-md rounded bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">
          {resultadoEmision}
        </p>
      )}

      <div className="mt-stack-md flex-1 overflow-auto rounded-xl shadow-sm">
        {/* Estilo "G" (docs/08, sección 5.2): table-fixed + colgroup, columnas cortas con ancho fijo
            en rem; Cliente y Medio de pago en %, y Nota sin ancho — se queda con todo el resto, es
            la que más espacio toma. Sin scroll horizontal en ningún ancho. */}
        <table className="w-full table-fixed text-left font-sans text-table-row max-xl:[&_td]:px-2 max-xl:[&_th]:px-2">
          <colgroup>
            <col className="w-8 xl:w-10" />
            <col className="w-12 xl:w-14" />
            <col className="w-[6rem] xl:w-[8rem]" />
            <col className="w-[14%] xl:w-[15%]" />
            <col />
            <col className="w-[11%]" />
            <col className="w-[6.75rem] xl:w-[7.5rem]" />
            <col className="w-[6.75rem] xl:w-[7.5rem]" />
            <col className="w-12" />
          </colgroup>
          <thead>
            <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
              <th className="px-3 py-2.5">
                <span className="sr-only">Seleccionar</span>
              </th>
              <th className="px-3 py-2.5">N°</th>
              <th className="px-3 py-2.5">Fecha</th>
              <th className="px-3 py-2.5">Cliente</th>
              <th className="px-3 py-2.5">Nota</th>
              <th className="px-3 py-2.5">Medio de pago</th>
              <th className="px-3 py-2.5">Total</th>
              <th className="px-3 py-2.5">Estado</th>
              <th className="px-3 py-2.5">
                <span className="sr-only">Acciones</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={9}>
                  Cargando...
                </td>
              </tr>
            )}
            {!loading && visibles.length === 0 && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={9}>
                  {mensajeVacio}
                </td>
              </tr>
            )}
            {visibles.map((venta) => (
              <tr key={venta.id} className="border-b border-table-divider last:border-0 even:bg-table-row-alt">
                <td className="px-3 py-3">
                  {venta.estado === 'sin_facturar' && (
                    <input
                      type="checkbox"
                      checked={seleccion.has(venta.id)}
                      onChange={() => toggleSeleccion(venta.id)}
                      aria-label={`Seleccionar venta N° ${venta.numero}`}
                      className="h-4 w-4 accent-accent"
                    />
                  )}
                </td>
                <td className="px-3 py-3 text-ink">{venta.numero}</td>
                <td className="px-3 py-3 text-ink-soft">
                  {/* Fecha y hora en una línea si entran; si la columna es angosta, la hora baja. */}
                  <span className="whitespace-nowrap">{formatFechaCortaLocal(venta.created_at)}</span>{' '}
                  <span className="whitespace-nowrap">{formatHora(venta.created_at)}</span>
                </td>
                <td className="px-3 py-3 text-ink-soft [overflow-wrap:anywhere]">
                  {venta.cliente ? venta.cliente.razon_social ?? venta.cliente.nombre_fantasia : 'Consumidor final'}
                </td>
                <td className="px-3 py-3 text-ink-soft">
                  {tieneNota(venta.nota) ? (
                    <p className="line-clamp-1 [overflow-wrap:anywhere]" title={venta.nota}>
                      {segmentosResaltados(venta.nota, q).map((s, i) =>
                        s.coincide ? (
                          <mark key={i} className="rounded-sm bg-amarillo text-ink">
                            {s.texto}
                          </mark>
                        ) : (
                          <span key={i}>{s.texto}</span>
                        ),
                      )}
                    </p>
                  ) : (
                    <>
                      <span aria-hidden="true">—</span>
                      <span className="sr-only">Sin nota</span>
                    </>
                  )}
                </td>
                <td className="px-3 py-3 text-ink-soft [overflow-wrap:anywhere]">{FORMA_PAGO_LABEL[venta.forma_pago]}</td>
                <td className="whitespace-nowrap px-3 py-3 font-semibold text-ink">{formatCurrency(venta.total)}</td>
                <td className="px-3 py-3">
                  <EstadoBadge variant={venta.estado === 'facturado' ? 'green' : 'amber'}>
                    {ESTADO_LABEL[venta.estado === 'facturado' ? 'facturado' : 'sin_facturar']}
                  </EstadoBadge>
                </td>
                <td className="px-3 py-3 text-right">
                  <button
                    type="button"
                    onClick={() => verDetalle(venta)}
                    aria-label={`${venta.estado === 'facturado' ? 'Ver factura' : 'Ver comprobante'} de la venta N° ${venta.numero}`}
                    title={venta.estado === 'facturado' ? 'Ver factura' : 'Ver comprobante'}
                    className="inline-flex h-[26px] w-[26px] items-center justify-center rounded bg-table-divider text-accent-dark hover:bg-accent-light focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
                  >
                    <IconVerDetalle className="h-4 w-4" />
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {verComprobante && <ComprobanteModal datos={verComprobante} onClose={() => setVerComprobante(null)} />}
    </div>
  )
}
