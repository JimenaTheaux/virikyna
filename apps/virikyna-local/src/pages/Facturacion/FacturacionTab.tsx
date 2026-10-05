import { useEffect, useState } from 'react'
import { Eye, ArrowLeftRight } from 'lucide-react'
import type { EstadoComprobante, FormaPagoVenta } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { friendlyError, emitirFacturaCReal } from '@virikyna/shared'
import { formatCurrency, formatFechaCortaLocal, formatHora, rangoTimestampsAR } from '@virikyna/shared'
import { EstadoBadge, RowActionsMenu } from '@virikyna/shared'
import { FORMA_PAGO_LABEL, type DatosComprobante } from '../../lib/comprobante'
import { ComprobanteModal } from '../../components/ComprobanteModal'
import { DevolucionModal } from './DevolucionModal'
import type { VentaConFactura, VentaItemConProducto } from './types'

const ESTADO_LABEL: Record<'sin_facturar' | 'facturado', string> = {
  sin_facturar: 'Sin facturar',
  facturado: 'Facturada',
}

type EstadoFiltro = 'todas' | EstadoComprobante

export function FacturacionTab() {
  const [ventas, setVentas] = useState<VentaConFactura[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const [fechaDesde, setFechaDesde] = useState('')
  const [fechaHasta, setFechaHasta] = useState('')
  const [estadoFiltro, setEstadoFiltro] = useState<EstadoFiltro>('todas')
  const [formaPagoFiltro, setFormaPagoFiltro] = useState<'todas' | FormaPagoVenta>('todas')
  // Ticket por número (server-side) o por nombre de cliente (sobre lo ya cargado) — para ubicar
  // rápido la venta original de una devolución/cambio.
  const [busqueda, setBusqueda] = useState('')
  const [aDevolver, setADevolver] = useState<VentaConFactura | null>(null)

  const [seleccion, setSeleccion] = useState<Set<string>>(new Set())
  const [emitiendo, setEmitiendo] = useState(false)
  const [resultadoEmision, setResultadoEmision] = useState<string | null>(null)

  const [verComprobante, setVerComprobante] = useState<DatosComprobante | null>(null)

  async function cargar() {
    setLoading(true)
    setError(null)

    let query = supabase
      .from('ventas')
      .select('*, factura_c:facturas_c(*), cliente:clientes(razon_social, nombre_fantasia, mail, celular)')
      .in('estado', estadoFiltro === 'todas' ? ['sin_facturar', 'facturado'] : [estadoFiltro])
      .order('created_at', { ascending: false })

    if (fechaDesde) query = query.gte('created_at', rangoTimestampsAR(fechaDesde, fechaDesde).desde)
    if (fechaHasta) query = query.lte('created_at', rangoTimestampsAR(fechaHasta, fechaHasta).hasta)
    if (formaPagoFiltro !== 'todas') query = query.eq('forma_pago', formaPagoFiltro)
    const numeroBuscado = /^\d+$/.test(busqueda.trim()) ? Number(busqueda.trim()) : null
    if (numeroBuscado !== null) query = query.eq('numero', numeroBuscado)

    const { data, error: dbError } = await query
    if (dbError) {
      setError(friendlyError(dbError))
    } else {
      setVentas((data ?? []) as unknown as VentaConFactura[])
    }
    setLoading(false)
  }

  useEffect(() => {
    cargar()
  }, [fechaDesde, fechaHasta, estadoFiltro, formaPagoFiltro, busqueda])

  function toggleSeleccion(id: string) {
    setSeleccion((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const textoCliente = /^\d+$/.test(busqueda.trim()) ? '' : busqueda.trim().toLowerCase()
  const ventasVisibles = textoCliente
    ? ventas.filter((v) =>
        `${v.cliente?.razon_social ?? ''} ${v.cliente?.nombre_fantasia ?? ''}`.toLowerCase().includes(textoCliente),
      )
    : ventas

  const seleccionadas = ventas.filter((v) => seleccion.has(v.id))
  const totalSeleccionado = seleccionadas.reduce((acc, v) => acc + v.total, 0)

  async function emitirFacturas() {
    if (seleccion.size === 0 || emitiendo) return
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
    cargar()
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
    })
  }

  return (
    <div className="flex h-full flex-col">
      {/* Filtros y "Emitir Factura C" en la misma fila: los filtros se achican (y solo si de verdad
          no entran, bajan a una segunda línea DENTRO de su bloque), el botón queda siempre a la
          derecha alineado con los inputs — nunca solo en una línea aparte. */}
      <div className="flex items-end gap-3">
        <div className="flex min-w-0 flex-1 flex-wrap items-end gap-2">
          <label className="flex w-[9.5rem] flex-col gap-1">
            <span className="font-sans text-label-md text-ink-soft">Desde</span>
            <input
              type="date"
              value={fechaDesde}
              onChange={(e) => setFechaDesde(e.target.value)}
              className="w-full rounded border border-line bg-surface px-3 py-2 font-sans text-body-md text-ink outline-none focus:border-accent"
            />
          </label>
          <label className="flex w-[9.5rem] flex-col gap-1">
            <span className="font-sans text-label-md text-ink-soft">Hasta</span>
            <input
              type="date"
              value={fechaHasta}
              onChange={(e) => setFechaHasta(e.target.value)}
              className="w-full rounded border border-line bg-surface px-3 py-2 font-sans text-body-md text-ink outline-none focus:border-accent"
            />
          </label>
          <label className="flex min-w-[8rem] max-w-[16rem] flex-1 flex-col gap-1">
            <span className="whitespace-nowrap font-sans text-label-md text-ink-soft">N° de ticket o cliente</span>
            <input
              type="search"
              value={busqueda}
              onChange={(e) => setBusqueda(e.target.value)}
              placeholder="Ej. 1234 o Pérez"
              className="w-full rounded border border-line bg-surface px-3 py-2 font-sans text-body-md text-ink outline-none focus:border-accent"
            />
          </label>
          <label className="flex w-[8rem] flex-col gap-1">
            <span className="font-sans text-label-md text-ink-soft">Estado</span>
            <select
              value={estadoFiltro}
              onChange={(e) => setEstadoFiltro(e.target.value as EstadoFiltro)}
              className="w-full rounded border border-line bg-surface px-3 py-2 font-sans text-body-md text-ink outline-none focus:border-accent"
            >
              <option value="todas">Todas</option>
              <option value="sin_facturar">Sin facturar</option>
              <option value="facturado">Facturada</option>
            </select>
          </label>
          <label className="flex w-[10rem] flex-col gap-1">
            <span className="font-sans text-label-md text-ink-soft">Medio de pago</span>
            <select
              value={formaPagoFiltro}
              onChange={(e) => setFormaPagoFiltro(e.target.value as 'todas' | FormaPagoVenta)}
              className="w-full rounded border border-line bg-surface px-3 py-2 font-sans text-body-md text-ink outline-none focus:border-accent"
            >
              <option value="todas">Todos</option>
              {Object.entries(FORMA_PAGO_LABEL).map(([value, label]) => (
                <option key={value} value={value}>
                  {label}
                </option>
              ))}
            </select>
          </label>
        </div>

        <button
          type="button"
          onClick={emitirFacturas}
          disabled={seleccion.size === 0 || emitiendo}
          className="min-h-[42px] shrink-0 whitespace-nowrap rounded bg-accent px-4 py-2 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-50"
        >
          {emitiendo ? 'Emitiendo...' : 'Emitir Factura C'}
        </button>
      </div>
      {seleccion.size > 0 && (
        <p className="mt-2 text-right font-sans text-body-md text-ink-soft">
          {seleccion.size} seleccionado{seleccion.size === 1 ? '' : 's'} · {formatCurrency(totalSeleccionado)}
        </p>
      )}

      {error && (
        <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>
      )}
      {resultadoEmision && (
        <p className="mt-stack-md rounded bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">
          {resultadoEmision}
        </p>
      )}

      <div className="mt-stack-md flex-1 overflow-auto rounded-xl shadow-sm">
        {/* table-fixed + colgroup: columnas de contenido corto con ancho fijo (en rem, medido sobre
            el contenido más largo: fecha+hora, "$ 1.234.567,89", badge "Sin facturar") y Cliente /
            Medio de pago se reparten el resto — la tabla mide siempre el 100% del contenedor, sin
            scroll horizontal, en cualquier resolución o escala de Windows. Debajo de 1280px el
            padding baja a px-2 para no aplastar Cliente. */}
        <table className="w-full table-fixed text-left font-sans text-table-row max-xl:[&_td]:px-2 max-xl:[&_th]:px-2">
          <colgroup>
            <col className="w-8 xl:w-10" />
            <col className="w-16" />
            <col className="w-[7.5rem] xl:w-[9rem]" />
            <col />
            <col className="xl:w-[15%]" />
            <col className="w-[6.75rem] xl:w-[7.5rem]" />
            <col className="w-[6.75rem] xl:w-[7.5rem]" />
            <col className="w-14" />
          </colgroup>
          <thead>
            <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
              <th className="px-3 py-2.5"></th>
              <th className="px-3 py-2.5">N°</th>
              <th className="px-3 py-2.5">Fecha</th>
              <th className="px-3 py-2.5">Cliente</th>
              <th className="px-3 py-2.5">Medio de pago</th>
              <th className="px-3 py-2.5">Total</th>
              <th className="px-3 py-2.5">Estado</th>
              <th className="px-3 py-2.5"></th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={8}>
                  Cargando...
                </td>
              </tr>
            )}
            {!loading && ventasVisibles.length === 0 && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={8}>
                  No hay comprobantes para este filtro.
                </td>
              </tr>
            )}
            {ventasVisibles.map((venta) => (
              <tr key={venta.id} className="border-b border-table-divider last:border-0 even:bg-table-row-alt">
                <td className="px-3 py-3">
                  {venta.estado === 'sin_facturar' && (
                    <input
                      type="checkbox"
                      checked={seleccion.has(venta.id)}
                      onChange={() => toggleSeleccion(venta.id)}
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
                <td className="px-3 py-3 text-ink-soft [overflow-wrap:anywhere]">{FORMA_PAGO_LABEL[venta.forma_pago]}</td>
                <td className="whitespace-nowrap px-3 py-3 font-sans font-semibold text-ink">{formatCurrency(venta.total)}</td>
                <td className="px-3 py-3">
                  <EstadoBadge variant={venta.estado === 'facturado' ? 'green' : 'amber'}>
                    {ESTADO_LABEL[venta.estado === 'facturado' ? 'facturado' : 'sin_facturar']}
                  </EstadoBadge>
                </td>
                <td className="px-3 py-3 text-right">
                  <RowActionsMenu
                    ariaLabel={`Más acciones para el comprobante ${venta.numero}`}
                    items={[
                      {
                        label: venta.estado === 'facturado' ? 'Ver factura' : 'Ver comprobante',
                        icon: Eye,
                        onClick: () => verDetalle(venta),
                      },
                      {
                        label: 'Devolución / Cambio',
                        icon: ArrowLeftRight,
                        onClick: () => setADevolver(venta),
                      },
                    ]}
                  />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {aDevolver && (
        <DevolucionModal
          venta={aDevolver}
          onClose={() => setADevolver(null)}
          onDone={() => {
            setADevolver(null)
            cargar()
          }}
        />
      )}

      {verComprobante && <ComprobanteModal datos={verComprobante} onClose={() => setVerComprobante(null)} />}
    </div>
  )
}
