import { useEffect, useMemo, useRef, useState } from 'react'
import type { FormaPagoVenta } from '@virikyna/shared'
import { supabase } from '../lib/supabaseClient'
import { mensajeErrorGuardado } from '@virikyna/shared'
import { formatCurrency, nombreConMarca } from '@virikyna/shared'
import type { DatosComprobante } from '../lib/comprobante'
import { ComprobanteModal } from '../components/ComprobanteModal'
import { Modal } from '../components/Modal'
import { ConfirmDialog } from '../components/ConfirmDialog'
import { Field, inputClass } from '../components/FormField'
import { showToast } from '../lib/toast'
import { marcarCobroEnCurso } from '../lib/proteccionVentana'
import { ProductoBusqueda, type ProductoBusquedaControl } from './Ventas/ProductoBusqueda'
import { CarritoTabla } from './Ventas/CarritoTabla'
import { ClienteSelector } from './Ventas/ClienteSelector'
import { FormaPagoSelector } from './Ventas/FormaPagoSelector'
import { AjustePorcentajeModal } from './Ventas/AjustePorcentajeModal'
import { PagoCombinadoModal } from './Ventas/PagoCombinadoModal'
import { TicketsBar } from './Ventas/TicketsBar'
import { MAX_TICKETS, cargarTicketsGuardados, crearTicketVacio, guardarTickets } from './Ventas/ticketsStorage'
import type { TicketsPersistState } from './Ventas/ticketsStorage'
import type { CartItem, ClienteSeleccionado, PagoParcial, Ticket } from './Ventas/types'

// Atajos con letras de Ventas (docs/04, módulo 3). Solo con el foco fuera de los campos de texto.
const ATAJOS_FORMA_PAGO: Record<string, FormaPagoVenta> = {
  e: 'efectivo',
  t: 'transferencia',
  q: 'qr',
  z: 'tarjeta_debito',
  c: 'tarjeta_credito',
}

function esCampoDeTexto(el: Element | null) {
  if (!(el instanceof HTMLElement)) return false
  return el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT' || el.isContentEditable
}

function avisoTicketYaCobrado(numeroTicket: number, numeroVenta: number) {
  showToast(`El Ticket ${numeroTicket} ya se había cobrado (venta ${numeroVenta}). Se cerró para no cobrarlo dos veces.`)
}

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
  const [vaciarConfirmOpen, setVaciarConfirmOpen] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [comprobante, setComprobante] = useState<DatosComprobante | null>(null)
  const [confirmandoId, setConfirmandoId] = useState<string | null>(null)
  const [pagoCombinadoModalOpen, setPagoCombinadoModalOpen] = useState(false)
  // Precio final a cobrar (punto 4 del pedido): precargado con el precio oficial al abrir la
  // confirmación, editable por el cajero (redondeo manual, sin restricción de monto).
  const [precioCobradoStr, setPrecioCobradoStr] = useState('')

  const searchInputRef = useRef<HTMLInputElement>(null)
  const buscadorRef = useRef<ProductoBusquedaControl>(null)
  const precioCobradoInputRef = useRef<HTMLInputElement>(null)
  const confirmarBtnRef = useRef<HTMLButtonElement>(null)

  // Foco fuera de los campos de texto = atajos con letras activos (se muestra cerca de forma de pago).
  const [focoEnCampo, setFocoEnCampo] = useState(true)
  useEffect(() => {
    function actualizar() {
      setFocoEnCampo(esCampoDeTexto(document.activeElement))
    }
    // En focusout el activeElement todavía es el body: se mira en el tick siguiente.
    function alSalir() {
      setTimeout(actualizar, 0)
    }
    actualizar()
    document.addEventListener('focusin', actualizar)
    document.addEventListener('focusout', alSalir)
    return () => {
      document.removeEventListener('focusin', actualizar)
      document.removeEventListener('focusout', alSalir)
    }
  }, [])

  // Después de un clic en un botón de Ventas o al cerrar un modal, el foco vuelve al buscador para
  // que el próximo escaneo entre ahí. En el tick siguiente: al desmontarse, un modal con
  // useFocoAtrapado devuelve el foco a donde estaba antes de abrirse.
  function focoBuscador() {
    setTimeout(() => searchInputRef.current?.focus(), 0)
  }

  useEffect(() => {
    guardarTickets(ticketsState)
  }, [ticketsState])

  // Idempotencia del cobro (docs/43): un ticket con un intento pendiente que en la base ya es una
  // venta se cobró (la app se cerró o perdió la respuesta antes de sacarlo de la barra). Se cierra.
  useEffect(() => {
    const pendientes = ticketsState.tickets.filter((t) => t.cobroClientId)
    if (pendientes.length === 0) return
    let cancelado = false
    supabase
      .from('ventas')
      .select('numero, client_id')
      .in(
        'client_id',
        pendientes.map((t) => t.cobroClientId as string),
      )
      .then(({ data }) => {
        if (cancelado) return
        for (const v of data ?? []) {
          const t = pendientes.find((p) => p.cobroClientId === v.client_id)
          if (!t) continue
          quitarTicket(t.id)
          avisoTicketYaCobrado(t.numero, v.numero)
        }
      })
    return () => {
      cancelado = true
    }
    // Solo al abrir la pantalla, con los tickets recuperados de localStorage.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

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

  // Valores en vivo del recuadro "Precio final a cobrar" de la confirmación (docs/23) — para
  // mostrar la diferencia contra el precio oficial (`total`) antes de que el cajero confirme.
  const precioCobradoNum = Math.round((Number(precioCobradoStr.replace(',', '.')) || 0) * 100) / 100
  const diferenciaPrecioCobrado = Math.round((precioCobradoNum - total) * 100) / 100

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
    focoBuscador()
  }

  function setFormaPago(formaPago: FormaPagoVenta | null) {
    actualizarTicket(activeTicketId, { formaPago, pagosCombinados: null })
  }

  // Clic en un botón de forma de pago (el atajo con letra usa setFormaPago y deja el foco donde está).
  function elegirFormaPago(formaPago: FormaPagoVenta) {
    setFormaPago(formaPago)
    focoBuscador()
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
      // Lo que se cargue después es otra venta: si hubo un intento pendiente, no se arrastra.
      cobroClientId: null,
    })
    setError(null)
    setConfirmandoId(null)
  }

  function confirmarVaciarTicket() {
    limpiarTicketActivo()
    setVaciarConfirmOpen(false)
    focoBuscador()
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
    focoBuscador()
  }

  function nuevoTicket() {
    if (bloqueado) return
    setTicketsState((prev) => {
      if (prev.tickets.length >= MAX_TICKETS) return prev
      const t = crearTicketVacio(prev.nextNumero)
      return { tickets: [...prev.tickets, t], activeTicketId: t.id, nextNumero: prev.nextNumero + 1 }
    })
    setError(null)
    focoBuscador()
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
    focoBuscador()
  }

  function cancelarEliminarTicket() {
    setEliminarConfirmId(null)
    focoBuscador()
  }

  function intentarCobrar(id: string) {
    if (bloqueado) return
    const ticket = tickets.find((t) => t.id === id)
    if (!ticket) return
    setTicketsState((prev) => (prev.tickets.some((t) => t.id === id) ? { ...prev, activeTicketId: id } : prev))
    const mensaje = validarTicket(ticket)
    if (mensaje) {
      setError(mensaje)
      focoBuscador()
      return
    }
    setError(null)
    setConfirmandoId(id)
    setPrecioCobradoStr(String(calcularTotales(ticket).total))
  }

  function iniciarCobro() {
    intentarCobrar(activeTicketId)
  }

  function cancelarConfirmacion() {
    setConfirmandoId(null)
    setPrecioCobradoStr('')
    focoBuscador()
  }

  function cerrarComprobante() {
    setComprobante(null)
    focoBuscador()
  }

  async function confirmarCobro() {
    if (saving || !confirmandoId) return
    const ticket = tickets.find((t) => t.id === confirmandoId)
    if (!ticket || !ticket.formaPago) return

    setError(null)
    setSaving(true)
    // Mientras dura el cobro no se puede cerrar la ventana ni recargar (lib/proteccionVentana.ts).
    marcarCobroEnCurso(true)
    try {
      await cobrar(ticket)
    } finally {
      marcarCobroEnCurso(false)
    }
  }

  async function cobrar(ticket: Ticket) {
    if (!ticket.formaPago) return

    // Idempotencia (docs/43). Con un intento pendiente (el anterior falló o no llegó la respuesta),
    // primero se mira si ya es una venta. Si no hay, se crea el intento y se guarda en localStorage
    // ANTES de llamar al RPC — sin esperar al efecto de guardarTickets —, así un cierre en el medio
    // no lo pierde. confirmar_venta con un client_id que ya existe devuelve esa misma venta.
    let clientId = ticket.cobroClientId
    if (clientId) {
      const { data: previa } = await supabase.from('ventas').select('numero').eq('client_id', clientId).maybeSingle()
      if (previa) {
        setSaving(false)
        setConfirmandoId(null)
        quitarTicket(ticket.id)
        avisoTicketYaCobrado(ticket.numero, previa.numero)
        focoBuscador()
        return
      }
    } else {
      const intentos = ticket.intentosCobro + 1
      clientId = `${ticket.id}:${intentos}`
      const conIntento: TicketsPersistState = {
        ...ticketsState,
        tickets: ticketsState.tickets.map((t) =>
          t.id === ticket.id ? { ...t, cobroClientId: clientId, intentosCobro: intentos } : t,
        ),
      }
      guardarTickets(conIntento)
      setTicketsState(conIntento)
    }

    const subtotalTicket = ticket.cart.reduce((acc, it) => acc + it.cantidad * it.precioUnitario, 0)
    const totalTicket =
      Math.round(subtotalTicket * (1 - ticket.descuentoPorcentaje / 100) * (1 + ticket.recargoPorcentaje / 100) * 100) / 100

    const precioCobradoNum = Math.round((Number(precioCobradoStr.replace(',', '.')) || 0) * 100) / 100
    if (precioCobradoNum <= 0) {
      setSaving(false)
      setError('El precio final a cobrar debe ser mayor a $0.')
      return
    }

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
      // Precio final a cobrar (docs/23): precargado con totalTicket, editable por el cajero antes
      // de confirmar. El backend guarda ambos valores (precio_oficial y precio_cobrado).
      p_precio_cobrado: precioCobradoNum,
      p_client_id: clientId,
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

    // Si el precio final a cobrar cambió, el backend reescala cada parte del pago combinado
    // (docs/23) — se trae el reparto real desde venta_pagos en vez de reusar el que se armó en
    // PagoCombinadoModal (que sigue sumando al precio oficial, no al cobrado).
    let pagosComprobante = ticket.pagosCombinados ?? undefined
    if (esCombinado) {
      const { data: pagosData } = await supabase
        .from('venta_pagos')
        .select('forma_pago, monto')
        .eq('venta_id', ventaId)
      pagosComprobante = (pagosData ?? []).map((p) => ({ formaPago: p.forma_pago, monto: p.monto }))
    }

    setSaving(false)
    setComprobante({
      tipo: 'comprobante_x',
      numero: ventaRow ? String(ventaRow.numero) : '',
      fecha: ventaRow?.created_at ?? new Date().toISOString(),
      clienteNombre: ticket.cliente?.nombre ?? 'Consumidor final',
      clienteMail: ticket.cliente?.mail ?? null,
      clienteCelular: ticket.cliente?.celular ?? null,
      formaPago: ticket.formaPago,
      pagos: pagosComprobante,
      items: ticket.cart.map((it) => ({
        nombre: nombreConMarca(it),
        codigo: it.codigo,
        cantidad: it.cantidad,
        precioUnitario: it.precioUnitario,
        importe: it.cantidad * it.precioUnitario,
      })),
      subtotal: subtotalTicket,
      descuentoPorcentaje: ticket.descuentoPorcentaje,
      recargoPorcentaje: ticket.recargoPorcentaje,
      precioOficial: totalTicket,
      total: precioCobradoNum,
      cae: null,
    })
    setConfirmandoId(null)
    quitarTicket(ticket.id)
  }

  // Referencia con el estado más reciente para que el listener global de teclado (registrado una sola vez)
  // no quede con closures viejas — ver docs/04_modulos_y_funciones.md, atajos de la pantalla de Ventas.
  const modalOpen =
    descuentoModalOpen ||
    recargoModalOpen ||
    pagoCombinadoModalOpen ||
    comprobante !== null ||
    eliminarConfirmId !== null ||
    vaciarConfirmOpen
  const stateRef = useRef({ saving, confirmando: confirmandoId !== null, modalOpen })
  useEffect(() => {
    stateRef.current = { saving, confirmando: confirmandoId !== null, modalOpen }
  })
  const actionsRef = useRef({ iniciarCobro, confirmarCobro, cancelarConfirmacion, setFormaPago })
  useEffect(() => {
    actionsRef.current = { iniciarCobro, confirmarCobro, cancelarConfirmacion, setFormaPago }
  })

  // Teclado de Ventas (docs/04, módulo 3). Regla del buscador: las letras son texto mientras el foco
  // está en un campo (buscador incluido, vacío o no) y atajos solo con el foco afuera — Esc en el
  // buscador vacío saca el foco. Así un código del lector que empieza con E, T, D… nunca dispara nada.
  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      // Los modales de Ventas manejan su propio teclado (useFocoAtrapado).
      if (stateRef.current.modalOpen) return
      const { confirmando, saving } = stateRef.current

      const target = e.target as HTMLElement
      const isSearch = target === searchInputRef.current
      const enCampo = esCampoDeTexto(target)
      const enBoton = target.tagName === 'BUTTON'

      if (e.key === 'Escape') {
        // Con texto, el buscador ya lo limpió (y frenó el evento). Esc nunca vacía el ticket.
        if (confirmando) {
          e.preventDefault()
          actionsRef.current.cancelarConfirmacion()
        } else if (isSearch) {
          e.preventDefault()
          searchInputRef.current?.blur()
        }
        return
      }

      if (e.key === 'Enter') {
        if (saving) {
          e.preventDefault()
          return
        }
        if (confirmando) {
          // En la confirmación Enter confirma, salvo en un botón: el de Confirmar se dispara solo
          // (clic nativo) y los demás (Cancelar, ✕) no hacen nada con Enter.
          if (target === confirmarBtnRef.current) return
          e.preventDefault()
          if (!enBoton) actionsRef.current.confirmarCobro()
          return
        }
        // Enter en un botón de Ventas no lo dispara ni cobra: si el foco quedó ahí, el Enter del
        // lector no puede vaciar, restar ni crear nada. (Espacio sigue activando el botón.)
        if (enBoton) {
          e.preventDefault()
          return
        }
        if (enCampo && !isSearch) return
        // Buscador vacío (con texto no llega: ProductoBusqueda lo frena) o foco fuera de los campos.
        e.preventDefault()
        actionsRef.current.iniciarCobro()
        return
      }

      if (confirmando || saving || enCampo) return
      if (e.ctrlKey || e.altKey || e.metaKey || e.repeat || e.isComposing) return

      const key = e.key.toLowerCase()
      const formaPago = ATAJOS_FORMA_PAGO[key]
      if (formaPago) {
        e.preventDefault()
        actionsRef.current.setFormaPago(formaPago)
      } else if (key === 'd') {
        e.preventDefault()
        setDescuentoModalOpen(true)
      } else if (key === 'r') {
        e.preventDefault()
        setRecargoModalOpen(true)
      } else if (e.key.length === 1 && e.key !== ' ') {
        // Cualquier otra tecla imprimible vuelve al buscador y se escribe ahí (un escaneo con el foco
        // afuera no se pierde, salvo un primer carácter que sea atajo).
        e.preventDefault()
        buscadorRef.current?.escribir(e.key)
      }
    }

    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [])

  const atajosActivos = !focoEnCampo && !modalOpen && !bloqueado
  const ticketVacio =
    activeTicket.cart.length === 0 &&
    !activeTicket.cliente &&
    !activeTicket.formaPago &&
    activeTicket.descuentoPorcentaje === 0 &&
    activeTicket.recargoPorcentaje === 0 &&
    !activeTicket.nota

  return (
    <div className="flex h-full flex-col gap-stack-sm">
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
            <ProductoBusqueda
              inputRef={searchInputRef}
              controlRef={buscadorRef}
              onElegir={(p) =>
                agregarProducto({
                  productoId: p.id,
                  nombre: p.nombre,
                  marca: p.marca ?? '',
                  descripcion: p.descripcion ?? '',
                  codigo: p.codigo_barras ?? p.codigo_interno ?? '',
                  precioUnitario: p.precio_venta,
                })
              }
            />
          </div>

          <CarritoTabla
            items={activeTicket.cart}
            onCantidadChange={cambiarCantidad}
            onQuitar={quitarItem}
            onBotonUsado={focoBuscador}
          />
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

          <div className="mt-2">
            <FormaPagoSelector
              value={activeTicket.formaPago}
              disponibleCuentaCorriente={activeTicket.cliente !== null}
              onChange={elegirFormaPago}
              onCombinado={() => setPagoCombinadoModalOpen(true)}
            />
            {/* Regla del buscador (docs/04, módulo 3): las letras son atajos solo con el foco afuera. */}
            <p
              aria-live="polite"
              className={`mt-1 text-right font-sans text-label-md ${atajosActivos ? 'text-accent-darker' : 'text-ink-soft'}`}
            >
              {atajosActivos ? 'Atajos activos (E T Q Z C · D R)' : 'Esc en el buscador vacío para usar atajos'}
            </p>
          </div>

          <div className="mt-2">
            <input
              value={nota}
              onChange={(e) => setNota(e.target.value)}
              placeholder="Nota (opcional)"
              className="w-full rounded border border-line bg-surface px-3 py-1.5 font-sans text-body-md text-ink outline-none placeholder:text-ink-soft focus:border-accent"
            />
          </div>

          {error && (
            <p className="mt-2 rounded bg-error/10 px-4 py-2 font-sans text-body-md text-error">{error}</p>
          )}

          <div className="mt-2 grid grid-cols-3 gap-2">
            <button
              type="button"
              onClick={() => setDescuentoModalOpen(true)}
              disabled={confirmandoId !== null}
              className="rounded-lg border border-line px-4 py-2 font-sans text-label-bold text-ink-soft hover:border-accent disabled:opacity-50"
            >
              Descuento (D)
            </button>
            <button
              type="button"
              onClick={() => setRecargoModalOpen(true)}
              disabled={confirmandoId !== null}
              className="rounded-lg border border-line px-4 py-2 font-sans text-label-bold text-ink-soft hover:border-accent disabled:opacity-50"
            >
              Recargo (R)
            </button>
            <button
              type="button"
              onClick={() => setVaciarConfirmOpen(true)}
              disabled={ticketVacio || confirmandoId !== null}
              className="rounded-lg border border-error px-4 py-2 font-sans text-label-bold text-error hover:bg-error/10 disabled:opacity-50"
            >
              Vaciar ticket
            </button>
          </div>

          <button
            type="button"
            onClick={iniciarCobro}
            disabled={activeTicket.cart.length === 0 || !activeTicket.formaPago || confirmandoId !== null}
            className="mt-2 flex items-center justify-center gap-2 rounded-lg bg-accent px-4 py-3.5 font-display text-headline-md text-white transition hover:bg-accent-dark disabled:opacity-50"
          >
            COBRAR (Enter)
          </button>
        </aside>
      </div>

      {confirmandoId !== null && (
        <Modal
          title="Confirmar venta"
          onClose={cancelarConfirmacion}
          widthClassName="max-w-[400px]"
          dialogo={{ onEscape: cancelarConfirmacion }}
        >
          <p className="text-center font-sans text-label-bold text-accent-darker">
            ¿Confirmar venta por {formatCurrency(total)}?
          </p>

          <div className="mt-stack-md rounded-lg border border-line p-4">
            <Field label="Precio final a cobrar">
              <input
                ref={precioCobradoInputRef}
                autoFocus
                type="number"
                step="0.01"
                min="0"
                value={precioCobradoStr}
                onChange={(e) => setPrecioCobradoStr(e.target.value)}
                onFocus={(e) => e.target.select()}
                className={inputClass}
              />
            </Field>
            {diferenciaPrecioCobrado !== 0 && (
              <p
                className={`mt-2 font-sans text-label-md ${diferenciaPrecioCobrado > 0 ? 'text-success' : 'text-error'}`}
              >
                Diferencia respecto al precio oficial: {diferenciaPrecioCobrado > 0 ? '+' : ''}
                {formatCurrency(diferenciaPrecioCobrado)}
              </p>
            )}
          </div>

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
              ref={confirmarBtnRef}
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
          onCancel={cancelarEliminarTicket}
          onConfirm={confirmarEliminarTicket}
        />
      )}

      {vaciarConfirmOpen && (
        <ConfirmDialog
          title="Vaciar ticket"
          mensaje="¿Vaciar este ticket? Se quitan los productos, el cliente, la forma de pago, el descuento, el recargo y la nota."
          confirmLabel="Vaciar ticket"
          onCancel={() => {
            setVaciarConfirmOpen(false)
            focoBuscador()
          }}
          onConfirm={confirmarVaciarTicket}
        />
      )}

      {descuentoModalOpen && (
        <AjustePorcentajeModal
          titulo="Aplicar descuento"
          etiqueta="Descuento sobre el total (%)"
          valorActual={activeTicket.descuentoPorcentaje}
          max={100}
          onClose={() => {
            setDescuentoModalOpen(false)
            focoBuscador()
          }}
          onAplicar={(v) => actualizarTicket(activeTicketId, { descuentoPorcentaje: v })}
        />
      )}

      {recargoModalOpen && (
        <AjustePorcentajeModal
          titulo="Aplicar recargo"
          etiqueta="Recargo sobre el total (%)"
          valorActual={activeTicket.recargoPorcentaje}
          max={999}
          onClose={() => {
            setRecargoModalOpen(false)
            focoBuscador()
          }}
          onAplicar={(v) => actualizarTicket(activeTicketId, { recargoPorcentaje: v })}
        />
      )}

      {pagoCombinadoModalOpen && (
        <PagoCombinadoModal
          total={total}
          valorActual={activeTicket.pagosCombinados}
          onClose={() => {
            setPagoCombinadoModalOpen(false)
            focoBuscador()
          }}
          onAplicar={aplicarPagoCombinado}
        />
      )}

      {comprobante && (
        <ComprobanteModal
          datos={comprobante}
          onClose={cerrarComprobante}
          dialogo
          footer={
            <button
              type="button"
              // Foco inicial del comprobante: Enter (o el Enter del lector) pasa a la venta siguiente.
              data-autofocus
              onClick={cerrarComprobante}
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
