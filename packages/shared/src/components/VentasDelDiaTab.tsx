import { Fragment, useEffect, useState, type ComponentType } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { FileText } from 'lucide-react'
import { friendlyError } from '../../lib/supabaseErrors'
import { formatCurrency, fechaHoyISO, formatFechaCortaLocal, formatHora, rangoTimestampsAR } from '../../lib/format'
import { emitirFacturaCReal } from '../../lib/arcaFacturacion'
import { formatCantidad } from '../../lib/cargaInicial'
import { nombreItemVendido } from '../../lib/productoTexto'
import type { Cliente, FacturaC, FormaPagoVenta, Venta, VentaPago } from '../../types/database'
import {
  itemsComprobanteDesdeVenta,
  SELECT_ITEMS_COMPROBANTE,
  type DatosComprobante,
  type VentaItemComprobanteRow,
} from '../../lib/comprobante'
import { EstadoBadge } from './EstadoBadge'
import { RowActionsMenu, type RowActionsMenuItem } from './RowActionsMenu'

export type VentaConFactura = Venta & {
  factura_c: FacturaC | null
  cliente: Pick<Cliente, 'razon_social' | 'nombre_fantasia' | 'mail' | 'celular'> | null
}

// Los ítems vienen en la misma consulta (mismo select que el comprobante), así la fila los muestra
// y "Ver detalle" no vuelve a pedirlos.
type VentaConItems = VentaConFactura & { items: VentaItemComprobanteRow[] }

// Ítems que entran en el renglón resumen antes del "+N más" (promedio real: 1,3 por ticket).
const ITEMS_EN_RESUMEN = 3

function nombreCorto(it: VentaItemComprobanteRow): string {
  return it.producto_nombre ?? it.producto?.nombre ?? 'Producto'
}

export interface VentasDelDiaTabProps {
  supabase: SupabaseClient
  formaPagoLabel: Record<FormaPagoVenta, string>
  ComprobanteModal: ComponentType<{ datos: DatosComprobante; onClose: () => void }>
  IconVerDetalle: ComponentType<{ className?: string }>
  IconEnviar: ComponentType<{ className?: string }>
}

// Submenú "Ventas del día" de Facturación — igual en Virikyna Local y Virikyna Gestión, por eso
// vive acá. Lo que sí difiere por app (cliente Supabase, ComprobanteModal, íconos, mock de CAE)
// se recibe por props en vez de importarse directo.
export function VentasDelDiaTab({
  supabase,
  formaPagoLabel,
  ComprobanteModal,
  IconVerDetalle,
  IconEnviar,
}: VentasDelDiaTabProps) {
  const [ventas, setVentas] = useState<VentaConItems[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [resultado, setResultado] = useState<string | null>(null)
  const [emitiendoId, setEmitiendoId] = useState<string | null>(null)
  const [expandidas, setExpandidas] = useState<Set<string>>(new Set())

  function toggleExpandida(id: string) {
    setExpandidas((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const [verComprobante, setVerComprobante] = useState<DatosComprobante | null>(null)

  async function cargar() {
    setLoading(true)
    setError(null)

    const rango = rangoTimestampsAR(fechaHoyISO(), fechaHoyISO())
    const { data, error: dbError } = await supabase
      .from('ventas')
      .select(
        `*, factura_c:facturas_c(*), cliente:clientes(razon_social, nombre_fantasia, mail, celular), items:venta_items(${SELECT_ITEMS_COMPROBANTE})`,
      )
      .gte('created_at', rango.desde)
      .lte('created_at', rango.hasta)
      .order('created_at', { ascending: false })

    if (dbError) {
      setError(friendlyError(dbError))
    } else {
      setVentas((data ?? []) as unknown as VentaConItems[])
    }
    setLoading(false)
  }

  useEffect(() => {
    cargar()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  async function armarComprobante(venta: VentaConItems): Promise<DatosComprobante> {
    const items = itemsComprobanteDesdeVenta(venta.items)

    let pagos: { formaPago: FormaPagoVenta; monto: number }[] | undefined
    if (venta.forma_pago === 'combinado') {
      const { data: pagosData } = await supabase
        .from('venta_pagos')
        .select('forma_pago, monto')
        .eq('venta_id', venta.id)
      pagos = ((pagosData ?? []) as unknown as Pick<VentaPago, 'forma_pago' | 'monto'>[]).map((p) => ({
        formaPago: p.forma_pago,
        monto: p.monto,
      }))
    }

    const clienteNombre = venta.cliente
      ? venta.cliente.razon_social ?? venta.cliente.nombre_fantasia ?? 'Cliente'
      : 'Consumidor final'

    return {
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
      items,
      subtotal: venta.subtotal,
      descuentoPorcentaje: venta.descuento_porcentaje,
      recargoPorcentaje: venta.recargo_porcentaje,
      precioOficial: venta.precio_oficial,
      total: venta.total,
      cae: venta.factura_c?.cae ?? null,
    }
  }

  async function verDetalle(venta: VentaConItems) {
    setVerComprobante(await armarComprobante(venta))
  }

  async function emitirFacturaC(venta: VentaConItems) {
    if (emitiendoId) return
    setEmitiendoId(venta.id)
    setResultado(null)

    const { mensaje } = await emitirFacturaCReal(supabase, venta)

    setEmitiendoId(null)
    setResultado(mensaje)
    cargar()
  }

  return (
    <div className="flex h-full flex-col">
      <p className="font-sans text-body-md text-ink-soft">Todas las ventas registradas hoy.</p>

      {error && (
        <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>
      )}
      {resultado && (
        <p className="mt-stack-md rounded bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">
          {resultado}
        </p>
      )}

      <div className="mt-stack-md flex-1 overflow-auto rounded-xl shadow-sm">
        {/* table-fixed + colgroup: columnas cortas con ancho fijo (en rem, medido sobre el contenido
            más largo), Cliente y Medio de pago se reparten el resto — 100% del contenedor, sin
            scroll horizontal en ningún ancho. Debajo de 1280px el padding baja a px-2. */}
        <table className="w-full table-fixed text-left font-sans text-table-row max-xl:[&_td]:px-2 max-xl:[&_th]:px-2">
          <colgroup>
            <col className="w-[6.25rem]" />
            <col className="w-14" />
            <col />
            <col className="xl:w-[15%]" />
            <col className="w-[6.75rem] xl:w-[7.5rem]" />
            <col className="w-[6.75rem] xl:w-[7.5rem]" />
            <col className="w-14" />
          </colgroup>
          <thead>
            <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
              <th className="px-3 py-2.5">Fecha</th>
              <th className="px-3 py-2.5">Hora</th>
              <th className="px-3 py-2.5">Cliente</th>
              <th className="px-3 py-2.5">Medio de pago</th>
              <th className="px-3 py-2.5">Monto</th>
              <th className="px-3 py-2.5">Estado</th>
              <th className="px-3 py-2.5"></th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={7}>
                  Cargando...
                </td>
              </tr>
            )}
            {!loading && ventas.length === 0 && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={7}>
                  Todavía no hay ventas hoy.
                </td>
              </tr>
            )}
            {ventas.map((venta, i) => {
              const acciones: RowActionsMenuItem[] = [
                { label: 'Ver detalle', icon: IconVerDetalle, onClick: () => verDetalle(venta) },
                { label: 'Enviar comprobante', icon: IconEnviar, onClick: () => verDetalle(venta) },
              ]
              if (venta.estado === 'sin_facturar') {
                acciones.push({
                  label: emitiendoId === venta.id ? 'Emitiendo...' : 'Emitir Factura C',
                  icon: FileText,
                  onClick: () => emitirFacturaC(venta),
                  disabled: emitiendoId === venta.id,
                })
              }
              const items = venta.items ?? []
              const conItems = items.length > 0
              const expandida = expandidas.has(venta.id)
              const ocultos = items.length - ITEMS_EN_RESUMEN
              // Cada venta son dos <tr> (datos + renglón de ítems): la franja alternada va por
              // índice, no con even:, para que las dos filas compartan color. Estado y ⋮ (26px)
              // abarcan las dos filas (rowSpan) para no estirar la primera: ~56px con ítems.
              const franja = i % 2 === 1 ? 'bg-table-row-alt' : ''
              const celda = conItems ? 'px-3 pb-0 pt-2.5' : 'px-3 py-2.5'
              const celdaDoble = conItems ? 'px-3 pt-2 align-top' : 'px-3 py-2.5'
              const filas = conItems ? 2 : undefined
              return (
                <Fragment key={venta.id}>
                  <tr
                    onClick={conItems ? () => toggleExpandida(venta.id) : undefined}
                    className={`${franja} ${conItems ? 'cursor-pointer' : 'border-b border-table-divider'}`}
                  >
                    <td className={`whitespace-nowrap text-ink-soft ${celda}`}>{formatFechaCortaLocal(venta.created_at)}</td>
                    <td className={`whitespace-nowrap text-ink-soft ${celda}`}>{formatHora(venta.created_at)}</td>
                    <td className={`text-ink-soft [overflow-wrap:anywhere] ${celda}`}>
                      {venta.cliente ? venta.cliente.razon_social ?? venta.cliente.nombre_fantasia : 'Consumidor final'}
                    </td>
                    <td className={`text-ink-soft [overflow-wrap:anywhere] ${celda}`}>{formaPagoLabel[venta.forma_pago]}</td>
                    <td className={`whitespace-nowrap font-sans font-semibold text-ink ${celda}`}>{formatCurrency(venta.total)}</td>
                    <td rowSpan={filas} className={celdaDoble}>
                      {venta.estado === 'facturado' && <EstadoBadge variant="green">Facturada</EstadoBadge>}
                      {venta.estado === 'sin_facturar' && <EstadoBadge variant="amber">Sin facturar</EstadoBadge>}
                    </td>
                    {/* El menú no expande la fila: los clicks del portal también burbujean por React. */}
                    <td rowSpan={filas} className={`cursor-default text-right ${celdaDoble}`} onClick={(e) => e.stopPropagation()}>
                      <RowActionsMenu ariaLabel={`Más acciones para la venta N° ${venta.numero}`} items={acciones} />
                    </td>
                  </tr>
                  {conItems && (
                    <tr onClick={() => toggleExpandida(venta.id)} className={`cursor-pointer border-b border-table-divider ${franja}`}>
                      <td colSpan={5} className="px-3 pb-2.5 pt-0">
                        <button
                          type="button"
                          aria-expanded={expandida}
                          aria-label={`${expandida ? 'Ocultar' : 'Ver'} ítems de la venta N° ${venta.numero}`}
                          onClick={(e) => {
                            e.stopPropagation()
                            toggleExpandida(venta.id)
                          }}
                          className="block w-full rounded-sm text-left font-sans text-label-md text-ink-soft focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
                        >
                          {expandida ? (
                            <ul className="flex max-w-2xl flex-col gap-0.5 py-0.5">
                              {items.map((it, j) => (
                                <li key={j} className="flex justify-between gap-stack-md">
                                  <span className="min-w-0 [overflow-wrap:anywhere]">
                                    {formatCantidad(Number(it.cantidad))}× {nombreItemVendido(it, it.producto)}
                                  </span>
                                  <span className="whitespace-nowrap">{formatCurrency(Number(it.importe))}</span>
                                </li>
                              ))}
                            </ul>
                          ) : (
                            <span className="flex min-w-0 gap-1">
                              <span className="min-w-0 truncate">
                                {items
                                  .slice(0, ITEMS_EN_RESUMEN)
                                  .map((it) => `${formatCantidad(Number(it.cantidad))}× ${nombreCorto(it)}`)
                                  .join(' · ')}
                              </span>
                              {ocultos > 0 && <span className="shrink-0">· +{ocultos} más</span>}
                            </span>
                          )}
                        </button>
                      </td>
                    </tr>
                  )}
                </Fragment>
              )
            })}
          </tbody>
        </table>
      </div>

      {verComprobante && <ComprobanteModal datos={verComprobante} onClose={() => setVerComprobante(null)} />}
    </div>
  )
}
