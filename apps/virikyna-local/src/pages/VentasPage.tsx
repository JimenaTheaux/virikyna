import { useEffect, useMemo, useRef, useState } from 'react'
import type { FormaPagoVenta } from '@virikyna/shared'
import { supabase } from '../lib/supabaseClient'
import { mensajeErrorGuardado } from '@virikyna/shared'
import { formatCurrency } from '@virikyna/shared'
import type { DatosComprobante } from '../lib/comprobante'
import { ComprobanteModal } from '../components/ComprobanteModal'
import { Modal } from '../components/Modal'
import { ProductoBusqueda } from './Ventas/ProductoBusqueda'
import { CarritoTabla } from './Ventas/CarritoTabla'
import { ClienteSelector } from './Ventas/ClienteSelector'
import { FormaPagoSelector } from './Ventas/FormaPagoSelector'
import { DescuentoModal } from './Ventas/DescuentoModal'
import type { CartItem, ClienteSeleccionado } from './Ventas/types'

export function VentasPage() {
  const [cart, setCart] = useState<CartItem[]>([])
  const [cliente, setCliente] = useState<ClienteSeleccionado | null>(null)
  const [formaPago, setFormaPago] = useState<FormaPagoVenta | null>(null)
  const [descuentoPorcentaje, setDescuentoPorcentaje] = useState(0)
  const [nota, setNota] = useState('')
  const [descuentoModalOpen, setDescuentoModalOpen] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [comprobante, setComprobante] = useState<DatosComprobante | null>(null)
  const [confirmando, setConfirmando] = useState(false)

  const searchInputRef = useRef<HTMLInputElement>(null)

  const subtotal = useMemo(() => cart.reduce((acc, it) => acc + it.cantidad * it.precioUnitario, 0), [cart])
  const total = useMemo(() => Math.round(subtotal * (1 - descuentoPorcentaje / 100) * 100) / 100, [
    subtotal,
    descuentoPorcentaje,
  ])

  function resetVenta() {
    setCart([])
    setCliente(null)
    setFormaPago(null)
    setDescuentoPorcentaje(0)
    setNota('')
    setError(null)
    setConfirmando(false)
  }

  function agregarProducto(item: Omit<CartItem, 'cantidad'>) {
    setCart((prev) => {
      const idx = prev.findIndex((it) => it.productoId === item.productoId)
      if (idx >= 0) {
        const next = [...prev]
        next[idx] = { ...next[idx], cantidad: next[idx].cantidad + 1 }
        return next
      }
      return [...prev, { ...item, cantidad: 1 }]
    })
  }

  function cambiarCantidad(productoId: string, cantidad: number) {
    setCart((prev) => prev.map((it) => (it.productoId === productoId ? { ...it, cantidad } : it)).filter((it) => it.cantidad > 0))
  }

  function quitarItem(productoId: string) {
    setCart((prev) => prev.filter((it) => it.productoId !== productoId))
  }

  function iniciarCobro() {
    if (saving || confirmando) return
    if (cart.length === 0) {
      setError('Agregá al menos un producto al carrito.')
      return
    }
    if (!formaPago) {
      setError('Elegí una forma de pago.')
      return
    }
    if (formaPago === 'cuenta_corriente' && !cliente) {
      setError('La cuenta corriente requiere elegir un cliente.')
      return
    }

    setError(null)
    setConfirmando(true)
  }

  function cancelarConfirmacion() {
    setConfirmando(false)
  }

  async function confirmarCobro() {
    if (saving || !formaPago) return

    setError(null)
    setSaving(true)

    const { data: ventaId, error: rpcError, status } = await supabase.rpc('confirmar_venta', {
      p_cliente_id: cliente?.id ?? null,
      p_forma_pago: formaPago,
      p_items: cart.map((it) => ({
        producto_id: it.productoId,
        cantidad: it.cantidad,
        precio_unitario: it.precioUnitario,
        descuento_porcentaje: 0,
      })),
      p_descuento_porcentaje: descuentoPorcentaje,
      p_nota: nota.trim() || null,
    })

    if (rpcError || !ventaId) {
      setSaving(false)
      setError(mensajeErrorGuardado(rpcError, status, 'registrar la venta', 'el carrito sigue acá'))
      return
    }

    const { data: ventaRow } = await supabase
      .from('ventas')
      .select('numero, created_at')
      .eq('id', ventaId)
      .single()

    setSaving(false)
    setComprobante({
      tipo: 'comprobante_x',
      numero: ventaRow ? String(ventaRow.numero) : '',
      fecha: ventaRow?.created_at ?? new Date().toISOString(),
      clienteNombre: cliente?.nombre ?? 'Consumidor final',
      clienteMail: cliente?.mail ?? null,
      clienteCelular: cliente?.celular ?? null,
      formaPago,
      items: cart.map((it) => ({
        nombre: it.nombre,
        codigo: it.codigo,
        cantidad: it.cantidad,
        precioUnitario: it.precioUnitario,
        importe: it.cantidad * it.precioUnitario,
      })),
      subtotal,
      descuentoPorcentaje,
      total,
      cae: null,
    })
    resetVenta()
  }

  // Referencia con el estado más reciente para que el listener global de teclado (registrado una sola vez)
  // no quede con closures viejas — ver docs/04_modulos_y_funciones.md, atajos de la pantalla de Ventas.
  const stateRef = useRef({ saving, confirmando, modalOpen: descuentoModalOpen || comprobante !== null })
  useEffect(() => {
    stateRef.current = { saving, confirmando, modalOpen: descuentoModalOpen || comprobante !== null }
  })
  const actionsRef = useRef({ iniciarCobro, confirmarCobro, cancelarConfirmacion, resetVenta })
  useEffect(() => {
    actionsRef.current = { iniciarCobro, confirmarCobro, cancelarConfirmacion, resetVenta }
  })

  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      if (stateRef.current.modalOpen) return

      const target = e.target as HTMLElement
      const tag = target.tagName
      const isSearch = target === searchInputRef.current
      const isTextish = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT'
      const searchEmpty = isSearch && (target as HTMLInputElement).value.trim() === ''

      if (e.key === 'Escape') {
        if (isTextish && !isSearch) return
        e.preventDefault()
        if (stateRef.current.confirmando) {
          actionsRef.current.cancelarConfirmacion()
        } else {
          actionsRef.current.resetVenta()
        }
        return
      }

      if (e.key === 'Enter') {
        if ((isTextish && !isSearch) || tag === 'BUTTON') return
        if (stateRef.current.saving) return
        e.preventDefault()
        if (stateRef.current.confirmando) {
          actionsRef.current.confirmarCobro()
        } else {
          actionsRef.current.iniciarCobro()
        }
        return
      }

      if (stateRef.current.confirmando) return
      if (isTextish && !searchEmpty) return
      if (stateRef.current.saving) return

      const key = e.key.toLowerCase()
      if (key === 'e') {
        e.preventDefault()
        setFormaPago('efectivo')
      } else if (key === 't') {
        e.preventDefault()
        setFormaPago('transferencia')
      } else if (key === 'q') {
        e.preventDefault()
        setFormaPago('qr')
      } else if (key === 'z') {
        e.preventDefault()
        setFormaPago('tarjeta_debito')
      } else if (key === 'c') {
        e.preventDefault()
        setFormaPago('tarjeta_credito')
      } else if (key === 'd') {
        e.preventDefault()
        setDescuentoModalOpen(true)
      }
    }

    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [])

  return (
    <div className="flex h-full gap-stack-md">
      <section className="flex flex-1 flex-col overflow-hidden rounded-lg bg-surface p-card shadow-sm">
        <div className="flex items-start justify-between">
          <div>
            <h1 className="font-display text-headline-lg text-accent-darker">Ventas</h1>
            <p className="mt-1 font-sans text-body-md text-ink-soft">
              {cliente ? cliente.nombre : 'Consumidor final'}
            </p>
          </div>
          <ClienteSelector cliente={cliente} onChange={setCliente} />
        </div>

        <div className="mt-stack-md">
          <ProductoBusqueda inputRef={searchInputRef} onAgregar={agregarProducto} />
        </div>

        <CarritoTabla items={cart} onCantidadChange={cambiarCantidad} onQuitar={quitarItem} />
      </section>

      <aside className="flex w-[340px] flex-shrink-0 flex-col overflow-y-auto rounded-lg bg-surface p-card-sm shadow-sm">
        <p className="text-right font-sans text-label-bold text-ink-soft">TOTAL A PAGAR</p>
        <p className="text-right font-display text-display-total text-accent-darker">{formatCurrency(total)}</p>
        {descuentoPorcentaje > 0 && (
          <p className="mt-1 text-right font-sans text-label-md text-ink-soft">
            Subtotal {formatCurrency(subtotal)} · Descuento {descuentoPorcentaje}%
          </p>
        )}

        <div className="mt-stack-md">
          <FormaPagoSelector
            value={formaPago}
            disponibleCuentaCorriente={cliente !== null}
            onChange={setFormaPago}
          />
        </div>

        <div className="mt-stack-sm">
          <label className="flex flex-col gap-1">
            <span className="font-sans text-label-bold text-ink-soft">Nota (opcional)</span>
            <input
              value={nota}
              onChange={(e) => setNota(e.target.value)}
              className="rounded border border-line bg-surface px-3 py-2 font-sans text-body-md text-ink outline-none focus:border-accent"
            />
          </label>
        </div>

        {error && (
          <p className="mt-stack-sm rounded bg-error/10 px-4 py-2 font-sans text-body-md text-error">{error}</p>
        )}

        <div className="mt-stack-sm grid grid-cols-2 gap-2">
          <button
            type="button"
            onClick={() => setDescuentoModalOpen(true)}
            disabled={confirmando}
            className="rounded-lg border border-line px-4 py-2.5 font-sans text-label-bold text-ink-soft hover:border-accent disabled:opacity-50"
          >
            Descuento (D)
          </button>
          <button
            type="button"
            onClick={resetVenta}
            className="rounded-lg border border-error px-4 py-2.5 font-sans text-label-bold text-error hover:bg-error/10"
          >
            Cancelar (Esc)
          </button>
        </div>

        <button
          type="button"
          onClick={iniciarCobro}
          disabled={cart.length === 0 || !formaPago || confirmando}
          className="mt-stack-sm flex items-center justify-center gap-2 rounded-lg bg-accent px-4 py-4 font-display text-headline-md text-white transition hover:bg-accent-dark disabled:opacity-50"
        >
          COBRAR (Enter)
        </button>
      </aside>

      {confirmando && (
        <Modal title="Confirmar venta" onClose={cancelarConfirmacion} widthClassName="max-w-[400px]">
          <p className="text-center font-sans text-label-bold text-accent-darker">
            ¿Confirmar venta por {formatCurrency(total)}?
          </p>
          {error && (
            <p className="mt-stack-sm rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>
          )}
          <div className="mt-stack-md grid grid-cols-2 gap-2">
            <button
              type="button"
              onClick={cancelarConfirmacion}
              disabled={saving}
              className="rounded-lg border border-line px-4 py-3 font-sans text-label-bold text-ink-soft hover:border-accent disabled:opacity-50"
            >
              Cancelar (Esc)
            </button>
            <button
              type="button"
              onClick={confirmarCobro}
              disabled={saving}
              className="rounded-lg bg-accent px-4 py-3 font-display text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-50"
            >
              {saving ? 'Cobrando...' : 'Confirmar (Enter)'}
            </button>
          </div>
        </Modal>
      )}

      {descuentoModalOpen && (
        <DescuentoModal
          valorActual={descuentoPorcentaje}
          onClose={() => setDescuentoModalOpen(false)}
          onAplicar={setDescuentoPorcentaje}
        />
      )}

      {comprobante && (
        <ComprobanteModal
          datos={comprobante}
          onClose={() => setComprobante(null)}
          footer={
            <button
              type="button"
              onClick={() => {
                setComprobante(null)
                searchInputRef.current?.focus()
              }}
              className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white hover:bg-accent-dark"
            >
              Nueva venta
            </button>
          }
        />
      )}
    </div>
  )
}
