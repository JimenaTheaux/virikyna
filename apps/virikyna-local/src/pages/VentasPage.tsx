import { useEffect, useMemo, useRef, useState } from 'react'
import type { FormaPagoVenta } from '@virikyna/shared'
import { supabase } from '../lib/supabaseClient'
import { mensajeErrorGuardado } from '@virikyna/shared'
import { formatCurrency } from '@virikyna/shared'
import type { DatosComprobante } from '../lib/comprobante'
import { ComprobanteModal } from '../components/ComprobanteModal'
import { Modal } from '../components/Modal'
import { ConfirmDialog } from '../components/ConfirmDialog'
import { ProductoBusqueda } from './Ventas/ProductoBusqueda'
import { CarritoTabla } from './Ventas/CarritoTabla'
import { ClienteSelector } from './Ventas/ClienteSelector'
import { FormaPagoSelector } from './Ventas/FormaPagoSelector'
import { AjustePorcentajeModal } from './Ventas/AjustePorcentajeModal'
import { PagoCombinadoModal } from './Ventas/PagoCombinadoModal'
import { TicketsBar } from './Ventas/TicketsBar'
import { MAX_TICKETS, cargarTicketsGuardados, crearTicketVacio, guardarTickets } from './Ventas/ticketsStorage'
import type { TicketsPersistState } from './Ventas/ticketsStorage'
import type { CartItem, ClienteSeleccionado, PagoParcial, Ticket } from './Ventas/types'

function estadoInicial(): TicketsPersistState {
  const guardado = cargarTicketsGuardados()
  if (guardado) return guardado
  const ticket = crearTicketVacio(1)
  return { tickets: [ticket], activeTicketId: ticket.id, nextNumero: 2 }
}

function calcularTotales(t: Ticket) {
  const subtotal = t.cart.reduce((acc, it) => acc + it.cantidad * it.precioUnitario, 0)
  const total = Math.round(subtotal * (1 - t.descuentoPorcentaje / 100) * (1 + t.recargoPorcentaje / 100) * 100) / 100
  return { subtotal, total }
}

function validarTicket(t: Ticket): string | null {
  if (t.cart.length === 0) return 'Agregá al menos un producto al carrito.'
  if (!t.formaPago) return 'Elegí una forma de pago.'
  if (t.formaPago === 'cuenta_corriente' && !t.cliente) return 'La cuenta corriente requiere elegir un cliente.'
  if (t.formaPago === 'combinado') {
    if (!t.pagosCombinados || t.pagosCombinados.length !== 2) return 'Completá los 2 medios del pago combinado.'
    const { total } = calcularTotales(t)
    const suma = Math.round(t.pagosCombinados.reduce((acc, p) => acc + p.monto, 0) * 100) / 100
    if (suma !== total) return 'La suma del pago combinado ya no coincide con el total — volvé a repartirlo.'
  }
  return null
}

export function VentasPage() {
  // Tickets en espera (punto 6): cada ticket es una venta independiente. `ticketsState` se
  // persiste completo en localStorage — ver Ventas/ticketsStorage.ts — así que si se cierra la
  // app o hay un corte de luz, los tickets abiertos se recuperan al reabrir.
  const [ticketsState, setTicketsState] = useState<TicketsPersistState>(estadoInicial)
  const { tickets, activeTicketId } = ticketsState
  const activeTicket = tickets.find((t) => t.id === activeTicketId) ?? tickets[0]

  const [nota, setNotaState] = useState(activeTicket.nota)
  const [descuentoModalOpen, setDescuentoModalOpen] = useState(false)
  const [recargoModalOpen, setRecargoModalOpen] = useState(false)
  const [eliminarConfirmId, setEliminarConfirmId] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [comprobante, setComprobante] = useState<DatosComprobante | null>(null)
  const [confirmandoId, setConfirmandoId] = useState<string | null>(null)
  const [pagoCombinadoModalOpen, setPagoCombinadoModalOpen] = useState(false)

  const searchInputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    guardarTickets(ticketsState)
  }, [ticketsState])

  // El input de nota es no controlado por ticket directamente para no perder el cursor al tipear
  // (actualizarTicket dispararía un round-trip); se sincroniza al cambiar de ticket activo.
  useEffect(() => {
    setNotaState(activeTicket.nota)
  }, [activeTicket.id])

  const subtotal = useMemo(
    () => activeTicket.cart.reduce((acc, it) => acc + it.cantidad * it.precioUnitario, 0),
    [activeTicket.cart],
  )
  // Descuento y recargo son combinables — al ser ambos porcentajes multiplicativos sobre el mismo
  // subtotal, el total final no depende del orden en que se hayan cargado (D y luego R, o al revés).
  const total = useMemo(
    () =>
      Math.round(subtotal * (1 - activeTicket.descuentoPorcentaje / 100) * (1 + activeTicket.recargoPorcentaje / 100) * 100) /
      100,
    [subtotal, activeTicket.descuentoPorcentaje, activeTicket.recargoPorcentaje],
  )

  const bloqueado = confirmandoId !== null || saving || comprobante !== null

  function actualizarTicket(id: string, patch: Partial<Ticket>) {
    setTicketsState((prev) => ({
      ...prev,
      tickets: prev.tickets.map((t) => (t.id === id ? { ...t, ...patch } : t)),
    }))
  }

  function actualizarCarrito(id: string, updater: (cart: CartItem[]) => CartItem[]) {
    setTicketsState((prev) => ({
      ...prev,
      tickets: prev.tickets.map((t) => (t.id === id ? { ...t, cart: updater(t.cart) } : t)),
    }))
  }

  function setCliente(cliente: ClienteSeleccionado | null) {
    actualizarTicket(activeTicketId, { cliente })
  }

  function setFormaPago(formaPago: FormaPagoVenta | null) {
    actualizarTicket(activeTicketId, { formaPago, pagosCombinados: null })
  }

  function aplicarPagoCombinado(pagos: PagoParcial[]) {
    actualizarTicket(activeTicketId, { formaPago: 'combinado', pagosCombinados: pagos })
  }

  function setNota(value: string) {
    setNotaState(value)
    actualizarTicket(activeTicketId, { nota: value })
  }

  function limpiarTicketActivo() {
    actualizarTicket(activeTicketId, {
      cart: [],
      cliente: null,
      formaPago: null,
      pagosCombinados: null,
      descuentoPorcentaje: 0,
      recargoPorcentaje: 0,
      nota: '',
    })
    setError(null)
    setConfirmandoId(null)
  }

  function agregarProducto(item: Omit<CartItem, 'cantidad'>) {
    actualizarCarrito(activeTicketId, (cart) => {
      const idx = cart.findIndex((it) => it.productoId === item.productoId)
      if (idx >= 0) {
        const next = [...cart]
        next[idx] = { ...next[idx], cantidad: next[idx].cantidad + 1 }
        return next
      }
      return [...cart, { ...item, cantidad: 1 }]
    })
  }

  function cambiarCantidad(productoId: string, cantidad: number) {
    actualizarCarrito(activeTicketId, (cart) =>
      cart.map((it) => (it.productoId === productoId ? { ...it, cantidad } : it)).filter((it) => it.cantidad > 0),
    )
  }

  function quitarItem(productoId: string) {
    actualizarCarrito(activeTicketId, (cart) => cart.filter((it) => it.productoId !== productoId))
  }

  function seleccionarTicket(id: string) {
    if (bloqueado) return
    setTicketsState((prev) => (prev.tickets.some((t) => t.id === id) ? { ...prev, activeTicketId: id } : prev))
    setError(null)
  }

  function nuevoTicket() {
    if (bloqueado) return
    setTicketsState((prev) => {
      if (prev.tickets.length >= MAX_TICKETS) return prev
      const t = crearTicketVacio(prev.nextNumero)
      return { tickets: [...prev.tickets, t], activeTicketId: t.id, nextNumero: prev.nextNumero + 1 }
    })
    setError(null)
  }

  // Quita un ticket de la barra — se usa tanto al eliminarlo manualmente como al cerrarlo por
  // venta confirmada. Nunca deja la pantalla sin tickets: si era el último, crea uno vacío.
  function quitarTicket(id: string) {
    setTicketsState((prev) => {
      const restantes = prev.tickets.filter((t) => t.id !== id)
      if (restantes.length === 0) {
        const nuevo = crearTicketVacio(prev.nextNumero)
        return { tickets: [nuevo], activeTicketId: nuevo.id, nextNumero: prev.nextNumero + 1 }
      }
      const nuevaActiva = prev.activeTicketId === id ? restantes[0].id : prev.activeTicketId
      return { tickets: restantes, activeTicketId: nuevaActiva, nextNumero: prev.nextNumero }
    })
  }

  function pedirEliminarTicket(id: string) {
    if (bloqueado) return
    setEliminarConfirmId(id)
  }

  function confirmarEliminarTicket() {
    if (!eliminarConfirmId) return
    quitarTicket(eliminarConfirmId)
    setEliminarConfirmId(null)
  }

  function intentarCobrar(id: string) {
    if (bloqueado) return
    const ticket = tickets.find((t) => t.id === id)
    if (!ticket) return
    setTicketsState((prev) => (prev.tickets.some((t) => t.id === id) ? { ...prev, activeTicketId: id } : prev))
    const mensaje = validarTicket(ticket)
    if (mensaje) {
      setError(mensaje)
      return
    }
    setError(null)
    setConfirmandoId(id)
  }

  function iniciarCobro() {
    intentarCobrar(activeTicketId)
  }

  function cancelarConfirmacion() {
    setConfirmandoId(null)
  }

  async function confirmarCobro() {
    if (saving || !confirmandoId) return
    const ticket = tickets.find((t) => t.id === confirmandoId)
    if (!ticket || !ticket.formaPago) return

    setError(null)
    setSaving(true)

    const subtotalTicket = ticket.cart.reduce((acc, it) => acc + it.cantidad * it.precioUnitario, 0)
    const totalTicket =
      Math.round(subtotalTicket * (1 - ticket.descuentoPorcentaje / 100) * (1 + ticket.recargoPorcentaje / 100) * 100) / 100

    const esCombinado = ticket.formaPago === 'combinado' && ticket.pagosCombinados
    const { data: ventaId, error: rpcError, status } = await supabase.rpc('confirmar_venta', {
      p_cliente_id: ticket.cliente?.id ?? null,
      // Con pago combinado el backend ignora p_forma_pago y usa p_pagos — se manda el primer
      // medio como placeholder porque el parámetro es obligatorio (ver docs/22).
      p_forma_pago: esCombinado ? ticket.pagosCombinados![0].formaPago : ticket.formaPago,
      p_items: ticket.cart.map((it) => ({
        producto_id: it.productoId,
        cantidad: it.cantidad,
        precio_unitario: it.precioUnitario,
        descuento_porcentaje: 0,
      })),
      p_descuento_porcentaje: ticket.descuentoPorcentaje,
      p_nota: ticket.nota.trim() || null,
      p_recargo_porcentaje: ticket.recargoPorcentaje,
      p_pagos: esCombinado
        ? ticket.pagosCombinados!.map((p) => ({ forma_pago: p.formaPago, monto: p.monto }))
        : null,
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
      clienteNombre: ticket.cliente?.nombre ?? 'Consumidor final',
      clienteMail: ticket.cliente?.mail ?? null,
      clienteCelular: ticket.cliente?.celular ?? null,
      formaPago: ticket.formaPago,
      pagos: ticket.pagosCombinados ?? undefined,
      items: ticket.cart.map((it) => ({
        nombre: it.nombre,
        codigo: it.codigo,
        cantidad: it.cantidad,
        precioUnitario: it.precioUnitario,
        importe: it.cantidad * it.precioUnitario,
      })),
      subtotal: subtotalTicket,
      descuentoPorcentaje: ticket.descuentoPorcentaje,
      recargoPorcentaje: ticket.recargoPorcentaje,
      total: totalTicket,
      cae: null,
    })
    setConfirmandoId(null)
    quitarTicket(ticket.id)
  }

  // Referencia con el estado más reciente para que el listener global de teclado (registrado una sola vez)
  // no quede con closures viejas — ver docs/04_modulos_y_funciones.md, atajos de la pantalla de Ventas.
  const stateRef = useRef({
    saving,
    confirmando: confirmandoId !== null,
    modalOpen:
      descuentoModalOpen || recargoModalOpen || pagoCombinadoModalOpen || comprobante !== null || eliminarConfirmId !== null,
  })
  useEffect(() => {
    stateRef.current = {
      saving,
      confirmando: confirmandoId !== null,
      modalOpen:
        descuentoModalOpen || recargoModalOpen || pagoCombinadoModalOpen || comprobante !== null || eliminarConfirmId !== null,
    }
  })
  const actionsRef = useRef({ iniciarCobro, confirmarCobro, cancelarConfirmacion, limpiarTicketActivo })
  useEffect(() => {
    actionsRef.current = { iniciarCobro, confirmarCobro, cancelarConfirmacion, limpiarTicketActivo }
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
          actionsRef.current.limpiarTicketActivo()
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
      } else if (key === 'r') {
        e.preventDefault()
        setRecargoModalOpen(true)
      }
    }

    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeTicketId])

  return (
    <div className="flex h-full flex-col gap-stack-md">
      <TicketsBar
        tickets={tickets}
        activeTicketId={activeTicketId}
        onSeleccionar={seleccionarTicket}
        onNuevo={nuevoTicket}
        onEliminar={pedirEliminarTicket}
        onCobrar={intentarCobrar}
      />

      <div className="flex flex-1 gap-stack-md overflow-hidden">
        <section className="flex flex-1 flex-col overflow-hidden rounded-lg bg-surface p-card shadow-sm">
          <div className="flex items-start justify-between">
            <div>
              <h1 className="font-display text-headline-lg text-accent-darker">Ventas</h1>
              <p className="mt-1 font-sans text-body-md text-ink-soft">
                {activeTicket.cliente ? activeTicket.cliente.nombre : 'Consumidor final'}
              </p>
            </div>
            <ClienteSelector cliente={activeTicket.cliente} onChange={setCliente} />
          </div>

          <div className="mt-stack-md">
            <ProductoBusqueda inputRef={searchInputRef} onAgregar={agregarProducto} />
          </div>

          <CarritoTabla items={activeTicket.cart} onCantidadChange={cambiarCantidad} onQuitar={quitarItem} />
        </section>

        <aside className="flex w-[340px] flex-shrink-0 flex-col overflow-y-auto rounded-lg bg-surface p-card-sm shadow-sm">
          <p className="text-right font-sans text-label-bold text-ink-soft">TOTAL A PAGAR</p>
          <p className="text-right font-display text-display-total text-accent-darker">{formatCurrency(total)}</p>
          {(activeTicket.descuentoPorcentaje > 0 || activeTicket.recargoPorcentaje > 0) && (
            <div className="mt-1 flex flex-col items-end gap-0.5 font-sans text-label-md text-ink-soft">
              <p>Subtotal {formatCurrency(subtotal)}</p>
              <div className="flex gap-2">
                {activeTicket.descuentoPorcentaje > 0 && (
                  <span className="rounded bg-accent-light px-2 py-0.5 text-accent-darker">
                    Desc. {activeTicket.descuentoPorcentaje}%
                  </span>
                )}
                {activeTicket.recargoPorcentaje > 0 && (
                  <span className="rounded bg-error/10 px-2 py-0.5 text-error">Rec. {activeTicket.recargoPorcentaje}%</span>
                )}
              </div>
            </div>
          )}

          <div className="mt-stack-md">
            <FormaPagoSelector
              value={activeTicket.formaPago}
              disponibleCuentaCorriente={activeTicket.cliente !== null}
              onChange={setFormaPago}
              onCombinado={() => setPagoCombinadoModalOpen(true)}
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

          <div className="mt-stack-sm grid grid-cols-3 gap-2">
            <button
              type="button"
              onClick={() => setDescuentoModalOpen(true)}
              disabled={confirmandoId !== null}
              className="rounded-lg border border-line px-4 py-2.5 font-sans text-label-bold text-ink-soft hover:border-accent disabled:opacity-50"
            >
              Descuento (D)
            </button>
            <button
              type="button"
              onClick={() => setRecargoModalOpen(true)}
              disabled={confirmandoId !== null}
              className="rounded-lg border border-line px-4 py-2.5 font-sans text-label-bold text-ink-soft hover:border-accent disabled:opacity-50"
            >
              Recargo (R)
            </button>
            <button
              type="button"
              onClick={limpiarTicketActivo}
              className="rounded-lg border border-error px-4 py-2.5 font-sans text-label-bold text-error hover:bg-error/10"
            >
              Cancelar (Esc)
            </button>
          </div>

          <button
            type="button"
            onClick={iniciarCobro}
            disabled={activeTicket.cart.length === 0 || !activeTicket.formaPago || confirmandoId !== null}
            className="mt-stack-sm flex items-center justify-center gap-2 rounded-lg bg-accent px-4 py-4 font-display text-headline-md text-white transition hover:bg-accent-dark disabled:opacity-50"
          >
            COBRAR (Enter)
          </button>
        </aside>
      </div>

      {confirmandoId !== null && (
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

      {eliminarConfirmId && (
        <ConfirmDialog
          title="Eliminar ticket"
          mensaje="¿Eliminar este ticket? Se perderán los productos cargados."
          confirmLabel="Eliminar ticket"
          onCancel={() => setEliminarConfirmId(null)}
          onConfirm={confirmarEliminarTicket}
        />
      )}

      {descuentoModalOpen && (
        <AjustePorcentajeModal
          titulo="Aplicar descuento"
          etiqueta="Descuento sobre el total (%)"
          valorActual={activeTicket.descuentoPorcentaje}
          max={100}
          onClose={() => setDescuentoModalOpen(false)}
          onAplicar={(v) => actualizarTicket(activeTicketId, { descuentoPorcentaje: v })}
        />
      )}

      {recargoModalOpen && (
        <AjustePorcentajeModal
          titulo="Aplicar recargo"
          etiqueta="Recargo sobre el total (%)"
          valorActual={activeTicket.recargoPorcentaje}
          max={999}
          onClose={() => setRecargoModalOpen(false)}
          onAplicar={(v) => actualizarTicket(activeTicketId, { recargoPorcentaje: v })}
        />
      )}

      {pagoCombinadoModalOpen && (
        <PagoCombinadoModal
          total={total}
          valorActual={activeTicket.pagosCombinados}
          onClose={() => setPagoCombinadoModalOpen(false)}
          onAplicar={aplicarPagoCombinado}
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
