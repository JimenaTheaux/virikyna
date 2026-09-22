import { useEffect, useState, type ComponentType } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { friendlyError } from '../../lib/supabaseErrors'
import { formatCurrency, fechaHoyISO } from '../../lib/format'
import { emitirFacturaCReal } from '../../lib/arcaFacturacion'
import type { Cliente, FacturaC, FormaPagoVenta, Producto, Venta, VentaItem, VentaPago } from '../../types/database'

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
  total: number
  cae: string | null
}

export interface VentasDelDiaTabProps {
  supabase: SupabaseClient
  formaPagoLabel: Record<FormaPagoVenta, string>
  ComprobanteModal: ComponentType<{ datos: DatosComprobante; onClose: () => void }>
  IconVerDetalle: ComponentType<{ className?: string }>
  IconEnviar: ComponentType<{ className?: string }>
}

function formatFecha(iso: string): string {
  return new Date(iso).toLocaleDateString('es-AR', { dateStyle: 'short' })
}

function formatHora(iso: string): string {
  return new Date(iso).toLocaleTimeString('es-AR', { timeStyle: 'short' })
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

      <div className="mt-stack-md flex-1 overflow-auto rounded-lg border border-line">
        <table className="w-full text-left font-sans text-body-md leading-5">
          <thead>
            <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
              <th className="px-3 py-2">Fecha</th>
              <th className="px-3 py-2">Hora</th>
              <th className="px-3 py-2">Cliente</th>
              <th className="px-3 py-2">Medio de pago</th>
              <th className="px-3 py-2">Monto</th>
              <th className="px-3 py-2"></th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={6}>
                  Cargando...
                </td>
              </tr>
            )}
            {!loading && ventas.length === 0 && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={6}>
                  Todavía no hay ventas hoy.
                </td>
              </tr>
            )}
            {ventas.map((venta) => (
              <tr key={venta.id} className="border-b border-line last:border-0">
                <td className="px-3 py-1.5 text-ink-soft">{formatFecha(venta.created_at)}</td>
                <td className="px-3 py-1.5 text-ink-soft">{formatHora(venta.created_at)}</td>
                <td className="px-3 py-1.5 text-ink-soft">
                  {venta.cliente ? venta.cliente.razon_social ?? venta.cliente.nombre_fantasia : 'Consumidor final'}
                </td>
                <td className="px-3 py-1.5 text-ink-soft">{formaPagoLabel[venta.forma_pago]}</td>
                <td className="px-3 py-1.5 font-sans text-label-bold text-ink">{formatCurrency(venta.total)}</td>
                <td className="px-3 py-1.5">
                  <div className="flex items-center justify-end gap-2">
                    <button
                      type="button"
                      onClick={() => verDetalle(venta)}
                      title="Ver detalle"
                      aria-label={`Ver detalle de la venta N° ${venta.numero}`}
                      className="rounded p-2 text-ink-soft hover:bg-accent-light hover:text-accent-darker"
                    >
                      <IconVerDetalle className="h-5 w-5" />
                    </button>
                    <button
                      type="button"
                      onClick={() => verDetalle(venta)}
                      title="Enviar comprobante"
                      aria-label={`Enviar comprobante de la venta N° ${venta.numero}`}
                      className="rounded p-2 text-ink-soft hover:bg-accent-light hover:text-accent-darker"
                    >
                      <IconEnviar className="h-5 w-5" />
                    </button>
                    {venta.estado === 'sin_facturar' ? (
                      <button
                        type="button"
                        onClick={() => emitirFacturaC(venta)}
                        disabled={emitiendoId === venta.id}
                        className="rounded bg-accent px-3 py-1.5 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-50"
                      >
                        {emitiendoId === venta.id ? 'Emitiendo...' : 'Factura C'}
                      </button>
                    ) : venta.estado === 'facturado' ? (
                      <span className="px-3 py-1.5 font-sans text-label-bold text-success">Facturada</span>
                    ) : null}
                  </div>
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
