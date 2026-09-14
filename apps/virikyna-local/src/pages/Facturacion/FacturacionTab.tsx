import { useEffect, useState } from 'react'
import type { EstadoComprobante, FormaPagoVenta } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { friendlyError, emitirFacturaCReal } from '@virikyna/shared'
import { formatCurrency, formatFechaHora } from '@virikyna/shared'
import { FORMA_PAGO_LABEL, type DatosComprobante } from '../../lib/comprobante'
import { ComprobanteModal } from '../../components/ComprobanteModal'
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

    if (fechaDesde) query = query.gte('created_at', `${fechaDesde}T00:00:00`)
    if (fechaHasta) query = query.lte('created_at', `${fechaHasta}T23:59:59`)
    if (formaPagoFiltro !== 'todas') query = query.eq('forma_pago', formaPagoFiltro)

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
  }, [fechaDesde, fechaHasta, estadoFiltro, formaPagoFiltro])

  function toggleSeleccion(id: string) {
    setSeleccion((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

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
      items: items.map((it) => ({
        nombre: it.producto?.nombre ?? 'Producto',
        codigo: it.producto?.codigo_barras ?? it.producto?.codigo_interno ?? '',
        cantidad: it.cantidad,
        precioUnitario: it.precio_unitario,
        importe: it.importe,
      })),
      subtotal: venta.subtotal,
      descuentoPorcentaje: venta.descuento_porcentaje,
      total: venta.total,
      cae: venta.factura_c?.cae ?? null,
    })
  }

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

        <div className="ml-auto flex items-center gap-3">
          {seleccion.size > 0 && (
            <p className="font-sans text-body-md text-ink-soft">
              {seleccion.size} seleccionado{seleccion.size === 1 ? '' : 's'} · {formatCurrency(totalSeleccionado)}
            </p>
          )}
          <button
            type="button"
            onClick={emitirFacturas}
            disabled={seleccion.size === 0 || emitiendo}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-50"
          >
            {emitiendo ? 'Emitiendo...' : 'Emitir Factura C'}
          </button>
        </div>
      </div>

      {error && (
        <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>
      )}
      {resultadoEmision && (
        <p className="mt-stack-md rounded bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">
          {resultadoEmision}
        </p>
      )}

      <div className="mt-stack-md flex-1 overflow-auto rounded-lg border border-line">
        <table className="w-full text-left font-sans text-body-md">
          <thead>
            <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
              <th className="px-4 py-3"></th>
              <th className="px-4 py-3">N°</th>
              <th className="min-w-[120px] whitespace-nowrap px-4 py-3">Fecha</th>
              <th className="px-4 py-3">Cliente</th>
              <th className="px-4 py-3">Medio de pago</th>
              <th className="px-4 py-3">Total</th>
              <th className="px-4 py-3">Estado</th>
              <th className="px-4 py-3"></th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr>
                <td className="px-4 py-6 text-ink-soft" colSpan={8}>
                  Cargando...
                </td>
              </tr>
            )}
            {!loading && ventas.length === 0 && (
              <tr>
                <td className="px-4 py-6 text-ink-soft" colSpan={8}>
                  No hay comprobantes para este filtro.
                </td>
              </tr>
            )}
            {ventas.map((venta) => (
              <tr key={venta.id} className="min-h-[56px] border-b border-line last:border-0">
                <td className="px-4 py-2.5">
                  {venta.estado === 'sin_facturar' && (
                    <input
                      type="checkbox"
                      checked={seleccion.has(venta.id)}
                      onChange={() => toggleSeleccion(venta.id)}
                      className="h-4 w-4 accent-accent"
                    />
                  )}
                </td>
                <td className="px-4 py-2.5 text-ink">{venta.numero}</td>
                <td className="whitespace-nowrap px-4 py-2.5 text-ink-soft">{formatFechaHora(venta.created_at)}</td>
                <td className="px-4 py-2.5 text-ink-soft">
                  {venta.cliente ? venta.cliente.razon_social ?? venta.cliente.nombre_fantasia : 'Consumidor final'}
                </td>
                <td className="px-4 py-2.5 text-ink-soft">{FORMA_PAGO_LABEL[venta.forma_pago]}</td>
                <td className="px-4 py-2.5 font-sans text-label-bold text-ink">{formatCurrency(venta.total)}</td>
                <td className="px-4 py-2.5">
                  <span className={venta.estado === 'facturado' ? 'text-success' : 'text-ink-soft'}>
                    {ESTADO_LABEL[venta.estado === 'facturado' ? 'facturado' : 'sin_facturar']}
                  </span>
                </td>
                <td className="px-4 py-2.5 text-right">
                  <button
                    type="button"
                    onClick={() => verDetalle(venta)}
                    className="rounded px-3 py-1.5 font-sans text-label-bold text-accent-dark hover:bg-accent-light"
                  >
                    {venta.estado === 'facturado' ? 'Ver factura' : 'Ver comprobante'}
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
