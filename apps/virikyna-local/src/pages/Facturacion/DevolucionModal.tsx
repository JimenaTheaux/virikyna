import { useEffect, useMemo, useState } from 'react'
import type { FormaPagoVenta, MotivoDevolucion, Producto } from '@virikyna/shared'
import {
  MENSAJE_PLAZO_DEVOLUCION,
  MOTIVOS_DEVOLUCION,
  MOTIVO_DEVOLUCION_LABEL,
  ProductoBuscador,
  armarFiltroBusquedaProducto,
  crearDevolucion,
  formatCurrency,
  formatFechaHora,
  friendlyError,
  precioEfectivoUnitario,
  redondear2,
  totalLineas,
  useDebouncedValue,
  ventaDentroDePlazoDevolucion,
} from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { showToast } from '../../lib/toast'
import { Modal } from '../../components/Modal'
import { ErrorText, Field, inputClass, selectClass } from '../../components/FormField'
import { FORMA_PAGO_LABEL } from '../../lib/comprobante'
import { FormaPagoSelector } from '../Ventas/FormaPagoSelector'
import { PagoCombinadoModal } from '../Ventas/PagoCombinadoModal'
import type { PagoParcial } from '../Ventas/types'
import type { VentaConFactura } from './types'

type Props = {
  venta: VentaConFactura
  onClose: () => void
  onDone: () => void
}

type ItemVendido = {
  productoId: string
  nombre: string
  codigo: string
  vendida: number
  yaDevuelta: number
  precioUnitario: number // lo que el cliente realmente pagó por unidad
}

type ItemNuevo = {
  productoId: string
  nombre: string
  codigo: string
  precioUnitario: number // precio de lista actual
  cantidad: string
}

type ProductoResultado = Pick<Producto, 'id' | 'nombre' | 'codigo_barras' | 'codigo_interno' | 'precio_venta'>

type VentaItemRow = {
  producto_id: string
  cantidad: number
  importe: number
  producto: { nombre: string; codigo_barras: string | null; codigo_interno: string | null } | null
}

type DevueltoRow = { producto_id: string; cantidad: number }

// Devolución / cambio sobre una venta ya emitida (docs/24). Crea un documento nuevo vinculado a la
// venta — la venta original no se toca. Los precios y validaciones reales los hace el RPC
// crear_devolucion; los totales de acá son la vista previa en vivo.
export function DevolucionModal({ venta, onClose, onDone }: Props) {
  const [items, setItems] = useState<ItemVendido[]>([])
  const [cargando, setCargando] = useState(true)
  const [errorCarga, setErrorCarga] = useState<string | null>(null)

  const [cantidades, setCantidades] = useState<Record<string, string>>({})
  const [motivo, setMotivo] = useState<MotivoDevolucion | ''>('')
  const [motivoDetalle, setMotivoDetalle] = useState('')
  const [observaciones, setObservaciones] = useState('')

  const [nuevos, setNuevos] = useState<ItemNuevo[]>([])
  const [busqueda, setBusqueda] = useState('')
  const busquedaDebounced = useDebouncedValue(busqueda, 200)
  const [resultados, setResultados] = useState<ProductoResultado[]>([])

  const [formaPago, setFormaPago] = useState<FormaPagoVenta | null>(null)
  const [pagosCombinados, setPagosCombinados] = useState<PagoParcial[] | null>(null)
  const [combinadoOpen, setCombinadoOpen] = useState(false)

  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const dentroDePlazo = ventaDentroDePlazoDevolucion(venta.created_at)

  // Ítems de la venta + lo ya devuelto en devoluciones activas previas → cantidad disponible.
  useEffect(() => {
    let cancelado = false
    async function cargar() {
      const [itemsRes, devueltosRes] = await Promise.all([
        supabase
          .from('venta_items')
          .select('producto_id, cantidad, importe, producto:productos(nombre, codigo_barras, codigo_interno)')
          .eq('venta_id', venta.id),
        supabase
          .from('devolucion_items')
          .select('producto_id, cantidad, devolucion:devoluciones!inner(venta_id, estado)')
          .eq('tipo', 'devuelto')
          .eq('devolucion.venta_id', venta.id)
          .eq('devolucion.estado', 'activa'),
      ])
      if (cancelado) return
      if (itemsRes.error || devueltosRes.error) {
        setErrorCarga(friendlyError(itemsRes.error ?? devueltosRes.error))
        setCargando(false)
        return
      }

      const yaDevuelta = new Map<string, number>()
      for (const d of (devueltosRes.data ?? []) as unknown as DevueltoRow[]) {
        yaDevuelta.set(d.producto_id, (yaDevuelta.get(d.producto_id) ?? 0) + d.cantidad)
      }

      // Un mismo producto puede estar en varias líneas de la venta: se agrupa por producto.
      const porProducto = new Map<string, VentaItemRow[]>()
      for (const row of (itemsRes.data ?? []) as unknown as VentaItemRow[]) {
        porProducto.set(row.producto_id, [...(porProducto.get(row.producto_id) ?? []), row])
      }
      setItems(
        [...porProducto.entries()].map(([productoId, lineas]) => ({
          productoId,
          nombre: lineas[0].producto?.nombre ?? 'Producto',
          codigo: lineas[0].producto?.codigo_barras ?? lineas[0].producto?.codigo_interno ?? '',
          vendida: lineas.reduce((acc, l) => acc + l.cantidad, 0),
          yaDevuelta: yaDevuelta.get(productoId) ?? 0,
          precioUnitario: precioEfectivoUnitario(
            lineas.map((l) => ({ cantidad: l.cantidad, importe: l.importe })),
            venta,
          ),
        })),
      )
      setCargando(false)
    }
    cargar()
    return () => {
      cancelado = true
    }
  }, [venta])

  // Buscador de producto para el cambio — mismo componente y misma consulta que el buscador de Ventas.
  useEffect(() => {
    const q = busquedaDebounced.trim()
    if (!q) {
      setResultados([])
      return
    }
    let cancelado = false
    supabase
      .from('productos')
      .select('id, nombre, codigo_barras, codigo_interno, precio_venta')
      .eq('estado', 'activo')
      .or(armarFiltroBusquedaProducto(q))
      .order('nombre')
      .limit(6)
      .then(({ data }) => {
        if (!cancelado) setResultados((data ?? []) as ProductoResultado[])
      })
    return () => {
      cancelado = true
    }
  }, [busquedaDebounced])

  function disponible(item: ItemVendido): number {
    return redondear2(item.vendida - item.yaDevuelta)
  }

  const lineasDevueltas = useMemo(
    () =>
      items
        .map((item) => ({ item, cantidad: Number(cantidades[item.productoId]) || 0 }))
        .filter((l) => l.cantidad > 0),
    [items, cantidades],
  )
  const totalDevuelto = totalLineas(lineasDevueltas.map((l) => ({ cantidad: l.cantidad, precioUnitario: l.item.precioUnitario })))
  const totalNuevo = totalLineas(nuevos.map((n) => ({ cantidad: Number(n.cantidad) || 0, precioUnitario: n.precioUnitario })))
  const diferencia = redondear2(totalNuevo - totalDevuelto)

  function agregarNuevo(p: ProductoResultado) {
    setNuevos((prev) => {
      const existente = prev.find((n) => n.productoId === p.id)
      if (existente) {
        return prev.map((n) => (n.productoId === p.id ? { ...n, cantidad: String((Number(n.cantidad) || 0) + 1) } : n))
      }
      return [
        ...prev,
        {
          productoId: p.id,
          nombre: p.nombre,
          codigo: p.codigo_barras ?? p.codigo_interno ?? '',
          precioUnitario: p.precio_venta,
          cantidad: '1',
        },
      ]
    })
    setBusqueda('')
    setResultados([])
  }

  async function confirmar() {
    setError(null)
    if (!dentroDePlazo) return setError(MENSAJE_PLAZO_DEVOLUCION)
    if (lineasDevueltas.length === 0) return setError('Indicá la cantidad a devolver de al menos un producto.')
    const excedida = lineasDevueltas.find((l) => l.cantidad > disponible(l.item))
    if (excedida) {
      return setError(`De "${excedida.item.nombre}" solo se pueden devolver ${disponible(excedida.item)}.`)
    }
    if (!motivo) return setError('Elegí el motivo de la devolución.')
    if (motivo === 'otro' && !motivoDetalle.trim()) return setError('Con motivo "Otro" el detalle es obligatorio.')
    if (nuevos.some((n) => !(Number(n.cantidad) > 0))) {
      return setError('Los productos nuevos necesitan una cantidad mayor a 0.')
    }

    let pagos: PagoParcial[] | null = null
    if (diferencia !== 0) {
      if (!formaPago) return setError('Elegí la forma de pago para saldar la diferencia.')
      if (formaPago === 'combinado') {
        const suma = redondear2((pagosCombinados ?? []).reduce((acc, p) => acc + p.monto, 0))
        if (!pagosCombinados || pagosCombinados.length !== 2 || suma !== Math.abs(diferencia)) {
          return setError('El pago combinado no coincide con la diferencia. Volvé a repartirlo.')
        }
        pagos = pagosCombinados
      }
    }

    setGuardando(true)
    const { error: rpcError } = await crearDevolucion(supabase, {
      ventaId: venta.id,
      motivo,
      motivoDetalle: motivoDetalle.trim() || null,
      observaciones: observaciones.trim() || null,
      itemsDevueltos: lineasDevueltas.map((l) => ({ productoId: l.item.productoId, cantidad: l.cantidad })),
      itemsNuevos: nuevos.map((n) => ({ productoId: n.productoId, cantidad: Number(n.cantidad) })),
      formaPago: diferencia !== 0 && formaPago !== 'combinado' ? formaPago : null,
      pagos,
    })
    setGuardando(false)
    if (rpcError) {
      setError(friendlyError(rpcError))
      return
    }
    showToast(`Devolución registrada — ticket ${venta.numero}.`)
    onDone()
  }

  const clienteNombre = venta.cliente
    ? venta.cliente.razon_social ?? venta.cliente.nombre_fantasia ?? 'Cliente'
    : 'Consumidor final'

  const quedaAFavorDe =
    diferencia > 0
      ? { texto: `El cliente paga ${formatCurrency(diferencia)}`, className: 'text-accent-darker' }
      : diferencia < 0
        ? { texto: `A favor del cliente: ${formatCurrency(Math.abs(diferencia))}`, className: 'text-error' }
        : { texto: 'Sin diferencia', className: 'text-success' }

  const footer = (
    <div className="flex flex-wrap items-center gap-x-6 gap-y-2">
      <div className="flex gap-6 font-sans">
        <div>
          <p className="text-label-md text-ink-soft">Total devuelto</p>
          <p className="text-label-bold text-ink">{formatCurrency(totalDevuelto)}</p>
        </div>
        <div>
          <p className="text-label-md text-ink-soft">Total nuevo</p>
          <p className="text-label-bold text-ink">{formatCurrency(totalNuevo)}</p>
        </div>
        <div>
          <p className="text-label-md text-ink-soft">Diferencia</p>
          <p className={`text-label-bold ${quedaAFavorDe.className}`}>{quedaAFavorDe.texto}</p>
        </div>
      </div>
      <div className="ml-auto flex gap-3">
        <button
          type="button"
          onClick={onClose}
          className="rounded px-4 py-3 font-sans text-label-bold text-ink-soft hover:bg-bg"
        >
          Cancelar
        </button>
        <button
          type="button"
          onClick={confirmar}
          disabled={guardando || cargando || !dentroDePlazo}
          className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-50"
        >
          {guardando ? 'Guardando...' : 'Confirmar devolución'}
        </button>
      </div>
    </div>
  )

  return (
    <Modal title={`Devolución / Cambio — Ticket ${venta.numero}`} onClose={onClose} widthClassName="max-w-[960px]" footer={footer}>
      <div className="flex flex-col gap-stack-md">
        <p className="font-sans text-body-md text-ink-soft">
          {formatFechaHora(venta.created_at)} · {clienteNombre} · {FORMA_PAGO_LABEL[venta.forma_pago]} · Total{' '}
          {formatCurrency(venta.total)}
        </p>

        {!dentroDePlazo && <ErrorText>{MENSAJE_PLAZO_DEVOLUCION}</ErrorText>}
        {venta.factura_c && (
          <p className="rounded bg-amarillo/20 px-4 py-3 font-sans text-body-md text-ink">
            Esta venta tiene Factura C. La devolución queda como registro interno: no genera nota de crédito.
          </p>
        )}
        {errorCarga && <ErrorText>{errorCarga}</ErrorText>}

        <section>
          <p className="font-sans text-label-bold text-ink-soft">Productos a devolver</p>
          <div className="mt-2 overflow-hidden rounded-lg border border-line">
            <table className="w-full text-left font-sans text-body-md leading-5">
              <thead>
                <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
                  <th className="px-3 py-2">Producto</th>
                  <th className="px-3 py-2 text-right">Vendida</th>
                  <th className="px-3 py-2 text-right">Ya devuelta</th>
                  <th className="px-3 py-2 text-right">Disponible</th>
                  <th className="px-3 py-2 text-right">Precio pagado</th>
                  <th className="w-[110px] px-3 py-2 text-right">A devolver</th>
                </tr>
              </thead>
              <tbody>
                {cargando && (
                  <tr>
                    <td className="px-3 py-3 text-ink-soft" colSpan={6}>
                      Cargando...
                    </td>
                  </tr>
                )}
                {items.map((item) => {
                  const disp = disponible(item)
                  return (
                    <tr key={item.productoId} className="border-b border-line last:border-0">
                      <td className="px-3 py-1.5 text-ink">
                        {item.nombre}
                        {item.codigo && <span className="ml-2 text-label-md text-ink-soft">{item.codigo}</span>}
                      </td>
                      <td className="px-3 py-1.5 text-right text-ink-soft">{item.vendida}</td>
                      <td className="px-3 py-1.5 text-right text-ink-soft">{item.yaDevuelta}</td>
                      <td className="px-3 py-1.5 text-right text-ink">{disp}</td>
                      <td className="px-3 py-1.5 text-right text-ink-soft">{formatCurrency(item.precioUnitario)}</td>
                      <td className="px-3 py-1.5 text-right">
                        <input
                          type="number"
                          min="0"
                          max={disp}
                          step="any"
                          disabled={disp <= 0 || !dentroDePlazo}
                          value={cantidades[item.productoId] ?? ''}
                          onChange={(e) => setCantidades((prev) => ({ ...prev, [item.productoId]: e.target.value }))}
                          placeholder="0"
                          className="w-full rounded border border-line bg-surface px-2 py-1.5 text-right font-sans text-body-md text-ink outline-none focus:border-accent disabled:bg-bg"
                        />
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        </section>

        <section className="grid grid-cols-[220px_1fr] gap-3">
          <Field label="Motivo" compact>
            <select
              value={motivo}
              onChange={(e) => setMotivo(e.target.value as MotivoDevolucion | '')}
              className={selectClass}
            >
              <option value="">Elegí un motivo…</option>
              {MOTIVOS_DEVOLUCION.map((m) => (
                <option key={m} value={m}>
                  {MOTIVO_DEVOLUCION_LABEL[m]}
                </option>
              ))}
            </select>
          </Field>
          <Field
            label={motivo === 'otro' ? 'Detalle del motivo (obligatorio)' : 'Detalle del motivo (opcional)'}
            compact
            hint={motivo === 'defectuoso' ? 'Lo devuelto no vuelve al stock: queda separado para revisión.' : undefined}
          >
            <input value={motivoDetalle} onChange={(e) => setMotivoDetalle(e.target.value)} className={inputClass} />
          </Field>
        </section>

        <section>
          <p className="font-sans text-label-bold text-ink-soft">Cambio — productos nuevos (opcional)</p>
          <div className="relative mt-2">
            <ProductoBuscador value={busqueda} onChange={setBusqueda} autoFocus={false} />
            {busqueda.trim() && (
              <div className="absolute z-10 mt-1 w-full overflow-hidden rounded-lg border border-line bg-surface shadow-sm">
                {resultados.length === 0 && (
                  <p className="px-4 py-3 font-sans text-body-md text-ink-soft">Sin resultados.</p>
                )}
                {resultados.map((p) => (
                  <button
                    key={p.id}
                    type="button"
                    onClick={() => agregarNuevo(p)}
                    className="flex w-full items-center justify-between px-4 py-2.5 text-left font-sans hover:bg-accent-light"
                  >
                    <span>
                      <span className="block text-body-md text-ink">{p.nombre}</span>
                      <span className="block text-label-md text-ink-soft">{p.codigo_barras ?? p.codigo_interno ?? '—'}</span>
                    </span>
                    <span className="text-label-bold text-accent-darker">{formatCurrency(p.precio_venta)}</span>
                  </button>
                ))}
              </div>
            )}
          </div>

          {nuevos.length > 0 && (
            <div className="mt-2 overflow-hidden rounded-lg border border-line">
              <table className="w-full text-left font-sans text-body-md leading-5">
                <tbody>
                  {nuevos.map((n) => (
                    <tr key={n.productoId} className="border-b border-line last:border-0">
                      <td className="px-3 py-1.5 text-ink">{n.nombre}</td>
                      <td className="px-3 py-1.5 text-right text-ink-soft">{formatCurrency(n.precioUnitario)}</td>
                      <td className="w-[110px] px-3 py-1.5">
                        <input
                          type="number"
                          min="0"
                          step="any"
                          value={n.cantidad}
                          onChange={(e) =>
                            setNuevos((prev) =>
                              prev.map((x) => (x.productoId === n.productoId ? { ...x, cantidad: e.target.value } : x)),
                            )
                          }
                          className="w-full rounded border border-line bg-surface px-2 py-1.5 text-right font-sans text-body-md text-ink outline-none focus:border-accent"
                        />
                      </td>
                      <td className="px-3 py-1.5 text-right text-ink">
                        {formatCurrency(redondear2((Number(n.cantidad) || 0) * n.precioUnitario))}
                      </td>
                      <td className="px-3 py-1.5 text-right">
                        <button
                          type="button"
                          onClick={() => setNuevos((prev) => prev.filter((x) => x.productoId !== n.productoId))}
                          aria-label={`Quitar ${n.nombre}`}
                          className="rounded px-2 py-1 text-ink-soft hover:bg-bg hover:text-error"
                        >
                          ✕
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>

        {diferencia !== 0 && (
          <section>
            <p className={`font-sans text-label-bold ${quedaAFavorDe.className}`}>
              {diferencia > 0 ? 'Cobrar la diferencia' : 'Devolver la diferencia'}: {formatCurrency(Math.abs(diferencia))}
            </p>
            <div className="mt-2 max-w-[420px]">
              <FormaPagoSelector
                value={formaPago}
                disponibleCuentaCorriente={false}
                onChange={(v) => {
                  setFormaPago(v)
                  setPagosCombinados(null)
                }}
                onCombinado={() => setCombinadoOpen(true)}
              />
              {formaPago === 'combinado' && pagosCombinados && (
                <p className="mt-1.5 font-sans text-label-md text-ink-soft">
                  {pagosCombinados.map((p) => `${FORMA_PAGO_LABEL[p.formaPago]} ${formatCurrency(p.monto)}`).join(' + ')}
                </p>
              )}
            </div>
          </section>
        )}

        <Field label="Observaciones (opcional)" compact hint="Saldos a favor, vouchers internos, cualquier aclaración. No hay cuenta corriente: queda solo como nota.">
          <textarea
            value={observaciones}
            onChange={(e) => setObservaciones(e.target.value)}
            rows={2}
            className={inputClass}
          />
        </Field>

        {error && <ErrorText>{error}</ErrorText>}
      </div>

      {combinadoOpen && diferencia !== 0 && (
        <PagoCombinadoModal
          total={Math.abs(diferencia)}
          valorActual={pagosCombinados}
          onClose={() => setCombinadoOpen(false)}
          onAplicar={(pagos) => {
            setFormaPago('combinado')
            setPagosCombinados(pagos)
          }}
        />
      )}
    </Modal>
  )
}
