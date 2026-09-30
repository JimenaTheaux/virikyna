import { useEffect, useState, type ComponentType } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { FileText } from 'lucide-react'
import { friendlyError } from '../../lib/supabaseErrors'
import { formatCurrency, fechaHoyISO, formatFechaCortaLocal, formatHora } from '../../lib/format'
import { emitirFacturaCReal } from '../../lib/arcaFacturacion'
import type { Cliente, FacturaC, FormaPagoVenta, Producto, Venta, VentaItem, VentaPago } from '../../types/database'
import { EstadoBadge } from './EstadoBadge'
import { RowActionsMenu, type RowActionsMenuItem } from './RowActionsMenu'

export type VentaConFactura = Venta & {
  factura_c: FacturaC | null
  cliente: Pick<Cliente, 'razon_social' | 'nombre_fantasia' | 'mail' | 'celular'> | null
}

export type VentaItemConProducto = Pick<VentaItem, 'cantidad' | 'precio_unitario' | 'importe'> & {
  producto: Pick<Producto, 'nombre' | 'codigo_barras' | 'codigo_interno'> | null
}

export type DatosComprobante = {
  tipo: 'comprobante_x' | 'factura_c'
  numero: string
  fecha: string
  clienteNombre: string
  clienteMail: string | null
  clienteCelular: string | null
  formaPago: FormaPagoVenta
  pagos?: { formaPago: FormaPagoVenta; monto: number }[] // solo con más de 1 elemento = pago combinado
  items: { nombre: string; codigo: string; cantidad: number; precioUnitario: number; importe: number }[]
  subtotal: number
  descuentoPorcentaje: number
  recargoPorcentaje: number
  precioOficial: number // calculado por el sistema, antes del redondeo manual del cajero
  total: number // = precio cobrado (puede diferir de precioOficial por redondeo)
  cae: string | null
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
  const [ventas, setVentas] = useState<VentaConFactura[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [resultado, setResultado] = useState<string | null>(null)
  const [emitiendoId, setEmitiendoId] = useState<string | null>(null)

  const [verComprobante, setVerComprobante] = useState<DatosComprobante | null>(null)

  async function cargar() {
    setLoading(true)
    setError(null)

    const hoy = fechaHoyISO()
    const { data, error: dbError } = await supabase
      .from('ventas')
      .select('*, factura_c:facturas_c(*), cliente:clientes(razon_social, nombre_fantasia, mail, celular)')
      .gte('created_at', `${hoy}T00:00:00`)
      .lte('created_at', `${hoy}T23:59:59`)
      .order('created_at', { ascending: false })

    if (dbError) {
      setError(friendlyError(dbError))
    } else {
      setVentas((data ?? []) as unknown as VentaConFactura[])
    }
    setLoading(false)
  }

  useEffect(() => {
    cargar()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  async function armarComprobante(venta: VentaConFactura): Promise<DatosComprobante> {
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
    }
  }

  async function verDetalle(venta: VentaConFactura) {
    setVerComprobante(await armarComprobante(venta))
  }

  async function emitirFacturaC(venta: VentaConFactura) {
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
            <col className="w-[6.75rem] xl:w-[7.5rem]" />
            <col className="w-16" />
            <col />
            <col className="xl:w-[15%]" />
            <col className="w-[7.75rem] xl:w-[8.5rem]" />
            <col className="w-[7.75rem] xl:w-[8.5rem]" />
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
            {ventas.map((venta) => {
              const items: RowActionsMenuItem[] = [
                { label: 'Ver detalle', icon: IconVerDetalle, onClick: () => verDetalle(venta) },
                { label: 'Enviar comprobante', icon: IconEnviar, onClick: () => verDetalle(venta) },
              ]
              if (venta.estado === 'sin_facturar') {
                items.push({
                  label: emitiendoId === venta.id ? 'Emitiendo...' : 'Emitir Factura C',
                  icon: FileText,
                  onClick: () => emitirFacturaC(venta),
                  disabled: emitiendoId === venta.id,
                })
              }
              return (
                <tr key={venta.id} className="border-b border-table-divider last:border-0 even:bg-table-row-alt">
                  <td className="whitespace-nowrap px-3 py-3 text-ink-soft">{formatFechaCortaLocal(venta.created_at)}</td>
                  <td className="whitespace-nowrap px-3 py-3 text-ink-soft">{formatHora(venta.created_at)}</td>
                  <td className="px-3 py-3 text-ink-soft [overflow-wrap:anywhere]">
                    {venta.cliente ? venta.cliente.razon_social ?? venta.cliente.nombre_fantasia : 'Consumidor final'}
                  </td>
                  <td className="px-3 py-3 text-ink-soft [overflow-wrap:anywhere]">{formaPagoLabel[venta.forma_pago]}</td>
                  <td className="whitespace-nowrap px-3 py-3 font-sans font-semibold text-ink">{formatCurrency(venta.total)}</td>
                  <td className="px-3 py-3">
                    {venta.estado === 'facturado' && <EstadoBadge variant="green">Facturada</EstadoBadge>}
                    {venta.estado === 'sin_facturar' && <EstadoBadge variant="amber">Sin facturar</EstadoBadge>}
                  </td>
                  <td className="px-3 py-3 text-right">
                    <RowActionsMenu ariaLabel={`Más acciones para la venta N° ${venta.numero}`} items={items} />
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      {verComprobante && <ComprobanteModal datos={verComprobante} onClose={() => setVerComprobante(null)} />}
    </div>
  )
}
