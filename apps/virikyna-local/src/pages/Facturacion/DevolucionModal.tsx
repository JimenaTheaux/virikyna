import { useEffect, useId, useMemo, useRef, useState } from 'react'
import { X } from 'lucide-react'
import type { FormaPagoVenta, MotivoDevolucion, ResolucionDevolucion } from '@virikyna/shared'
import {
  MAX_TICKETS_DEVOLUCION,
  MOTIVOS_DEVOLUCION,
  MOTIVO_DEVOLUCION_LABEL,
  crearDevolucionTickets,
  formatCurrency,
  formatFechaCortaLocal,
  friendlyError,
  mensajeErrorGuardado,
  nombreConMarca,
  nombreItemVendido,
  ProductoLinea,
  type ProductoTexto,
  type ResultadoDevolucionTickets,
  precioPagadoLinea,
  redondear2,
  totalLineas,
  ventaDentroDePlazoDevolucion,
} from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { showToast } from '../../lib/toast'
import { Modal } from '../../components/Modal'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, inputClass, selectClass } from '../../components/FormField'
import { FORMA_PAGO_LABEL } from '../../lib/comprobante'
import { FormaPagoSelector } from '../Ventas/FormaPagoSelector'
import { PagoCombinadoModal } from '../Ventas/PagoCombinadoModal'
import { ProductoBusqueda, type ProductoVenta } from '../Ventas/ProductoBusqueda'
import type { PagoParcial } from '../Ventas/types'

// Devolución / cambio con 1 a 3 tickets (docs/74). Cada producto devuelto queda atado a SU línea de
// venta; lo que se lleva va a precio de lista. Una sola llamada a crear_devolucion_tickets (todo o
// nada): precios, cantidades y plazos los valida la base; acá es la vista previa y el aviso temprano.
// Lo cargado se guarda en este equipo (localStorage) mientras se trabaja: sobrevive a un error de red
// o a cerrar el modal sin querer. Se borra al confirmar o al cancelar.

type Props = {
  // Desde el ⋮ de un ticket: entra ya cargado como ticket 1. Sin esto: "Nueva devolución".
  ventaInicialId?: string | null
  onClose: () => void
  onDone: () => void
}

type LineaTicket = {
  ventaItemId: string
  productoId: string
  nombre: string // nombre · marca (mensajes)
  producto: ProductoTexto
  vendida: number
  yaDevuelta: number
  precioUnitario: number // lo que el cliente pagó por unidad (prorrateado)
}

type TicketCargado = {
  id: string
  numero: number
  createdAt: string
  total: number
  formaPago: FormaPagoVenta
  tieneFactura: boolean
  lineas: LineaTicket[]
}

type ItemNuevo = {
  productoId: string
  nombre: string
  producto: ProductoTexto
  precioUnitario: number // precio de lista actual
  cantidad: string
}

type ResolucionNegativa = 'reintegro' | 'a_favor'

type Borrador = {
  tickets: string[] // ids, en orden
  cantidades: Record<string, string>
  // Solo cuenta con motivo "defectuoso": líneas destildadas (sanas, sí vuelven al stock).
  sanos: Record<string, boolean>
  nuevos: ItemNuevo[]
  motivo: MotivoDevolucion | ''
  motivoDetalle: string
  observaciones: string
  formaPago: FormaPagoVenta | null
  pagosCombinados: PagoParcial[] | null
  resolucionNegativa: ResolucionNegativa | null
  notaAFavor: string
}

const CLAVE_BORRADOR = 'virikyna-local:devolucion:borrador:v1'

function leerBorrador(): Borrador | null {
  try {
    const raw = localStorage.getItem(CLAVE_BORRADOR)
    if (!raw) return null
    const b = JSON.parse(raw) as Partial<Borrador>
    if (!Array.isArray(b.tickets)) return null
    return {
      tickets: b.tickets.filter((t): t is string => typeof t === 'string').slice(0, MAX_TICKETS_DEVOLUCION),
      cantidades: b.cantidades ?? {},
      // Un borrador de la versión anterior (campo "defectuosos") se ignora: manda el motivo.
      sanos: b.sanos ?? {},
      nuevos: Array.isArray(b.nuevos) ? b.nuevos : [],
      motivo: b.motivo ?? '',
      motivoDetalle: b.motivoDetalle ?? '',
      observaciones: b.observaciones ?? '',
      formaPago: b.formaPago ?? null,
      pagosCombinados: b.pagosCombinados ?? null,
      resolucionNegativa: b.resolucionNegativa ?? null,
      notaAFavor: b.notaAFavor ?? '',
    }
  } catch {
    return null
  }
}

function guardarBorrador(b: Borrador | null) {
  try {
    if (b) localStorage.setItem(CLAVE_BORRADOR, JSON.stringify(b))
    else localStorage.removeItem(CLAVE_BORRADOR)
  } catch {
    // Cuota llena o modo restringido: se sigue en memoria, se reintenta en el próximo cambio.
  }
}

type VentaItemRow = {
  id: string
  producto_id: string
  cantidad: number
  importe: number
  producto_nombre: string | null
  producto_marca: string | null
  producto: {
    nombre: string
    marca: string | null
    descripcion: string | null
    codigo_barras: string | null
    codigo_interno: string | null
  } | null
}

type VentaRow = {
  id: string
  numero: number
  created_at: string
  total: number
  subtotal: number
  forma_pago: FormaPagoVenta
  estado: 'sin_facturar' | 'facturado' | 'anulada'
  estado_interno: string | null
  factura_c: { id: string } | { id: string }[] | null
  items: VentaItemRow[] | null
}

type DevueltoRow = { venta_item_id: string | null; producto_id: string; cantidad: number }

const SELECT_TICKET =
  'id, numero, created_at, total, subtotal, forma_pago, estado, estado_interno, factura_c:facturas_c(id), ' +
  'items:venta_items(id, producto_id, cantidad, importe, producto_nombre, producto_marca, ' +
  'producto:productos(nombre, marca, descripcion, codigo_barras, codigo_interno))'

// Ticket con lo ya devuelto por línea (devoluciones activas). Los registros anteriores a docs/74 sin
// línea se reparten entre las líneas de ese producto, igual que hace la base.
async function leerTicket(filtro: { numero: number } | { id: string }): Promise<
  { ok: true; ticket: TicketCargado; venta: VentaRow } | { ok: false; error: string }
> {
  let q = supabase.from('ventas').select(SELECT_TICKET)
  q = 'numero' in filtro ? q.eq('numero', filtro.numero) : q.eq('id', filtro.id)
  const { data, error } = await q.maybeSingle()
  if (error) return { ok: false, error: friendlyError(error) }
  if (!data) return { ok: false, error: 'numero' in filtro ? `No existe el ticket N° ${filtro.numero}.` : 'No se encontró el ticket.' }
  const venta = data as unknown as VentaRow

  const { data: dev, error: errDev } = await supabase
    .from('devolucion_items')
    .select('venta_item_id, producto_id, cantidad, devolucion:devoluciones!inner(estado)')
    .eq('venta_id', venta.id)
    .eq('tipo', 'devuelto')
    .eq('devolucion.estado', 'activa')
  if (errDev) return { ok: false, error: friendlyError(errDev) }

  const items = [...(venta.items ?? [])].sort((a, b) => (a.id < b.id ? -1 : 1))
  const yaPorLinea = new Map<string, number>()
  const sinLinea = new Map<string, number>()
  for (const d of (dev ?? []) as unknown as DevueltoRow[]) {
    if (d.venta_item_id) yaPorLinea.set(d.venta_item_id, (yaPorLinea.get(d.venta_item_id) ?? 0) + Number(d.cantidad))
    else sinLinea.set(d.producto_id, (sinLinea.get(d.producto_id) ?? 0) + Number(d.cantidad))
  }
  for (const it of items) {
    const resto = sinLinea.get(it.producto_id) ?? 0
    if (resto <= 0) continue
    const libre = Number(it.cantidad) - (yaPorLinea.get(it.id) ?? 0)
    const toma = Math.min(resto, Math.max(libre, 0))
    yaPorLinea.set(it.id, (yaPorLinea.get(it.id) ?? 0) + toma)
    sinLinea.set(it.producto_id, resto - toma)
  }

  const lineas: LineaTicket[] = items
    .map((it) => ({
      ventaItemId: it.id,
      productoId: it.producto_id,
      nombre: nombreItemVendido(it, it.producto),
      producto: {
        ...it.producto,
        // Nombre y marca guardados al vender (docs/42); en ventas anteriores, los actuales.
        nombre: it.producto_nombre ?? it.producto?.nombre ?? 'Producto',
        marca: it.producto_nombre ? it.producto_marca : it.producto?.marca ?? null,
      },
      vendida: Number(it.cantidad),
      yaDevuelta: redondear2(yaPorLinea.get(it.id) ?? 0),
      precioUnitario: precioPagadoLinea({ cantidad: Number(it.cantidad), importe: Number(it.importe) }, venta),
    }))
    .sort((a, b) => a.nombre.localeCompare(b.nombre, 'es'))

  const factura = Array.isArray(venta.factura_c) ? venta.factura_c.length > 0 : Boolean(venta.factura_c)
  return {
    ok: true,
    venta,
    ticket: {
      id: venta.id,
      numero: venta.numero,
      createdAt: venta.created_at,
      total: Number(venta.total),
      formaPago: venta.forma_pago,
      tieneFactura: factura,
      lineas,
    },
  }
}

function disponible(l: LineaTicket): number {
  return redondear2(l.vendida - l.yaDevuelta)
}

// Reglas al agregar un ticket (las mismas que la base, con el motivo a la vista).
function motivoRechazo(venta: VentaRow, ticket: TicketCargado, actuales: TicketCargado[]): string | null {
  if (venta.estado === 'anulada') return `El ticket N° ${venta.numero} está anulado.`
  if (venta.estado_interno) return `El ticket N° ${venta.numero} es un consumo interno: no se devuelve desde acá.`
  if (!ventaDentroDePlazoDevolucion(venta.created_at)) {
    return `El ticket N° ${venta.numero} supera los 15 días permitidos para devolución/cambio.`
  }
  if (actuales.length > 0 && (venta.forma_pago === 'cuenta_corriente' || actuales.some((t) => t.formaPago === 'cuenta_corriente'))) {
    return 'Un ticket a cuenta corriente se devuelve solo, sin otros tickets.'
  }
  if (ticket.lineas.every((l) => disponible(l) <= 0)) return `Ticket N° ${venta.numero}: ya devuelto completo.`
  return null
}

function ErrorCampo({ id, children }: { id: string; children: string | null }) {
  if (!children) return null
  return (
    <p id={id} role="alert" className="mt-1 font-sans text-label-md text-error">
      {children}
    </p>
  )
}

export function DevolucionModal({ ventaInicialId, onClose, onDone }: Props) {
  const ids = useId()
  const [tickets, setTickets] = useState<TicketCargado[]>([])
  const [cantidades, setCantidades] = useState<Record<string, string>>({})
  const [sanos, setSanos] = useState<Record<string, boolean>>({})
  const [nuevos, setNuevos] = useState<ItemNuevo[]>([])
  const [motivo, setMotivo] = useState<MotivoDevolucion | ''>('')
  const [motivoDetalle, setMotivoDetalle] = useState('')
  const [observaciones, setObservaciones] = useState('')
  const [formaPago, setFormaPago] = useState<FormaPagoVenta | null>(null)
  const [pagosCombinados, setPagosCombinados] = useState<PagoParcial[] | null>(null)
  const [combinadoOpen, setCombinadoOpen] = useState(false)
  const [resolucionNegativa, setResolucionNegativa] = useState<ResolucionNegativa | null>(null)
  const [notaAFavor, setNotaAFavor] = useState('')

  const [numeroTicket, setNumeroTicket] = useState('')
  const [agregando, setAgregando] = useState(false)
  const [errorTicket, setErrorTicket] = useState<string | null>(null)
  const [preparando, setPreparando] = useState(true)
  const [avisoBorrador, setAvisoBorrador] = useState<string | null>(null)

  const [errores, setErrores] = useState<{ motivo?: string; detalle?: string; resolucion?: string; nota?: string }>({})
  const [error, setError] = useState<string | null>(null)
  const [aConfirmar, setAConfirmar] = useState(false)
  const [guardando, setGuardando] = useState(false)
  const [confirmDescartar, setConfirmDescartar] = useState(false)
  const inputTicketRef = useRef<HTMLInputElement>(null)

  // ── Arranque: borrador guardado y/o ticket del ⋮ ──
  useEffect(() => {
    let cancelado = false
    async function arrancar() {
      const borrador = leerBorrador()
      const cargados: TicketCargado[] = []
      const avisos: string[] = []
      if (borrador) {
        for (const id of borrador.tickets) {
          const r = await leerTicket({ id })
          if (cancelado) return
          if (!r.ok) {
            avisos.push(r.error)
            continue
          }
          const rechazo = motivoRechazo(r.venta, r.ticket, cargados)
          if (rechazo) avisos.push(rechazo)
          else cargados.push(r.ticket)
        }
        setCantidades(borrador.cantidades)
        setSanos(borrador.sanos)
        setNuevos(borrador.nuevos)
        setMotivo(borrador.motivo)
        setMotivoDetalle(borrador.motivoDetalle)
        setObservaciones(borrador.observaciones)
        setFormaPago(borrador.formaPago)
        setPagosCombinados(borrador.pagosCombinados)
        setResolucionNegativa(borrador.resolucionNegativa)
        setNotaAFavor(borrador.notaAFavor)
      }
      if (ventaInicialId && !cargados.some((t) => t.id === ventaInicialId)) {
        if (cargados.length >= MAX_TICKETS_DEVOLUCION) {
          avisos.push(`No se agregó el ticket elegido: ya hay ${MAX_TICKETS_DEVOLUCION} tickets cargados.`)
        } else {
          const r = await leerTicket({ id: ventaInicialId })
          if (cancelado) return
          const rechazo = r.ok ? motivoRechazo(r.venta, r.ticket, cargados) : r.error
          if (rechazo) setErrorTicket(rechazo)
          else if (r.ok) cargados.push(r.ticket)
        }
      }
      if (cancelado) return
      setTickets(cargados)
      if (borrador && (borrador.tickets.length > 0 || borrador.nuevos.length > 0)) {
        setAvisoBorrador(
          ['Se recuperó una devolución que no se terminó de registrar.', ...avisos].join(' '),
        )
      } else if (avisos.length > 0) {
        setAvisoBorrador(avisos.join(' '))
      }
      setPreparando(false)
      if (cargados.length === 0) inputTicketRef.current?.focus()
    }
    arrancar()
    return () => {
      cancelado = true
    }
    // Solo al abrir.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // ── Cálculos ──
  // Stock: con motivo Defectuoso, lo devuelto NO vuelve al stock salvo las líneas que se destilden
  // (sanas). Con cualquier otro motivo todo vuelve al stock y la columna "Defectuoso" no se muestra.
  const conDefectuosos = motivo === 'defectuoso'
  const esDefectuoso = (ventaItemId: string) => conDefectuosos && !sanos[ventaItemId]
  const lineasDevueltas = useMemo(
    () =>
      tickets.flatMap((t) =>
        t.lineas
          .map((l) => ({ ticket: t, linea: l, cantidad: Number(cantidades[l.ventaItemId]) || 0 }))
          .filter((x) => x.cantidad > 0),
      ),
    [tickets, cantidades],
  )
  const subtotalTicket = (t: TicketCargado) =>
    totalLineas(
      lineasDevueltas.filter((x) => x.ticket.id === t.id).map((x) => ({ cantidad: x.cantidad, precioUnitario: x.linea.precioUnitario })),
    )
  const totalDevuelto = totalLineas(lineasDevueltas.map((x) => ({ cantidad: x.cantidad, precioUnitario: x.linea.precioUnitario })))
  const totalNuevo = totalLineas(nuevos.map((n) => ({ cantidad: Number(n.cantidad) || 0, precioUnitario: n.precioUnitario })))
  const diferencia = redondear2(totalNuevo - totalDevuelto)

  // docs/68 (D12): un ticket a cuenta corriente (siempre solo) imputa la diferencia a la cuenta.
  const ctaCteUnica = tickets.length === 1 && tickets[0].formaPago === 'cuenta_corriente'
  const resolucion: ResolucionDevolucion | null =
    ctaCteUnica && (diferencia <= 0 || formaPago === 'cuenta_corriente')
      ? 'cuenta_corriente'
      : diferencia === 0
        ? 'sin_diferencia'
        : diferencia > 0
          ? 'cobro'
          : resolucionNegativa
  const pideMedio = resolucion === 'cobro' || resolucion === 'reintegro'

  const hayCambios =
    tickets.length > 0 ||
    nuevos.length > 0 ||
    motivo !== '' ||
    motivoDetalle.trim() !== '' ||
    observaciones.trim() !== '' ||
    notaAFavor.trim() !== ''

  // ── Borrador en este equipo ──
  useEffect(() => {
    if (preparando) return
    guardarBorrador(
      hayCambios
        ? {
            tickets: tickets.map((t) => t.id),
            cantidades,
            sanos,
            nuevos,
            motivo,
            motivoDetalle,
            observaciones,
            formaPago,
            pagosCombinados,
            resolucionNegativa,
            notaAFavor,
          }
        : null,
    )
  }, [preparando, hayCambios, tickets, cantidades, sanos, nuevos, motivo, motivoDetalle, observaciones, formaPago, pagosCombinados, resolucionNegativa, notaAFavor])

  // ── Tickets ──
  async function agregarTicket() {
    setErrorTicket(null)
    const texto = numeroTicket.trim()
    if (!/^\d+$/.test(texto)) return setErrorTicket('Escribí el N° de ticket (solo números).')
    const numero = Number(texto)
    if (tickets.some((t) => t.numero === numero)) return setErrorTicket(`El ticket N° ${numero} ya está agregado.`)
    if (tickets.length >= MAX_TICKETS_DEVOLUCION) return setErrorTicket(`Máximo ${MAX_TICKETS_DEVOLUCION} tickets por devolución.`)
    setAgregando(true)
    const r = await leerTicket({ numero })
    setAgregando(false)
    if (!r.ok) return setErrorTicket(r.error)
    const rechazo = motivoRechazo(r.venta, r.ticket, tickets)
    if (rechazo) return setErrorTicket(rechazo)
    setTickets((prev) => [...prev, r.ticket])
    setNumeroTicket('')
    setFormaPago(null)
    setPagosCombinados(null)
  }

  function quitarTicket(t: TicketCargado) {
    setTickets((prev) => prev.filter((x) => x.id !== t.id))
    const lineasIds = new Set(t.lineas.map((l) => l.ventaItemId))
    setCantidades((prev) => Object.fromEntries(Object.entries(prev).filter(([k]) => !lineasIds.has(k))))
    setSanos((prev) => Object.fromEntries(Object.entries(prev).filter(([k]) => !lineasIds.has(k))))
    setFormaPago(null)
    setPagosCombinados(null)
    setErrorTicket(null)
    inputTicketRef.current?.focus()
  }

  function agregarNuevo(p: ProductoVenta) {
    setNuevos((prev) => {
      const existente = prev.find((n) => n.productoId === p.id)
      if (existente) {
        return prev.map((n) => (n.productoId === p.id ? { ...n, cantidad: String((Number(n.cantidad) || 0) + 1) } : n))
      }
      return [...prev, { productoId: p.id, nombre: nombreConMarca(p), producto: p, precioUnitario: p.precio_venta, cantidad: '1' }]
    })
  }

  // ── Confirmar ──
  function validar(): boolean {
    setError(null)
    const nuevosErrores: typeof errores = {}
    let general: string | null = null

    if (tickets.length === 0) general = 'Agregá al menos un ticket.'
    else if (lineasDevueltas.length === 0) general = 'Indicá la cantidad a devolver de al menos un producto.'
    else {
      const excedida = lineasDevueltas.find((x) => x.cantidad > disponible(x.linea))
      const sinLineas = tickets.find((t) => !lineasDevueltas.some((x) => x.ticket.id === t.id))
      if (excedida) {
        general = `Del ticket N° ${excedida.ticket.numero}, de "${excedida.linea.nombre}" solo se pueden devolver ${disponible(excedida.linea)}.`
      } else if (sinLineas) {
        general = `El ticket N° ${sinLineas.numero} no tiene productos para devolver: quitalo o indicá qué se devuelve.`
      } else if (nuevos.some((n) => !(Number(n.cantidad) > 0))) {
        general = 'Los productos que se lleva necesitan una cantidad mayor a 0.'
      }
    }
    if (!motivo) nuevosErrores.motivo = 'Elegí el motivo.'
    if (motivo === 'otro' && !motivoDetalle.trim()) nuevosErrores.detalle = 'Con motivo "Otro" el detalle es obligatorio.'
    if (diferencia < 0 && !ctaCteUnica && !resolucionNegativa) {
      nuevosErrores.resolucion = 'Elegí si se devuelve la plata o queda a favor.'
    }
    if (resolucion === 'a_favor' && !notaAFavor.trim()) nuevosErrores.nota = 'La nota es obligatoria.'
    if (pideMedio) {
      if (!formaPago) nuevosErrores.resolucion = 'Elegí el medio de pago.'
      else if (formaPago === 'combinado') {
        const suma = redondear2((pagosCombinados ?? []).reduce((acc, p) => acc + p.monto, 0))
        if (!pagosCombinados || pagosCombinados.length !== 2 || suma !== Math.abs(diferencia)) {
          nuevosErrores.resolucion = 'El pago combinado no coincide con la diferencia. Volvé a repartirlo.'
        }
      }
    }
    setErrores(nuevosErrores)
    setError(general)
    return !general && Object.keys(nuevosErrores).length === 0
  }

  async function registrar() {
    if (guardando || !motivo) return
    setGuardando(true)
    const { data, error: rpcError, status } = await crearDevolucionTickets(supabase, {
      tickets: tickets.map((t) => t.id),
      motivo,
      motivoDetalle: motivoDetalle.trim() || null,
      observaciones: observaciones.trim() || null,
      itemsDevueltos: lineasDevueltas.map((x) => ({
        ventaItemId: x.linea.ventaItemId,
        cantidad: x.cantidad,
        defectuoso: esDefectuoso(x.linea.ventaItemId),
      })),
      itemsNuevos: nuevos.map((n) => ({ productoId: n.productoId, cantidad: Number(n.cantidad) })),
      resolucion,
      formaPago: pideMedio && formaPago !== 'combinado' ? formaPago : resolucion === 'cuenta_corriente' && diferencia > 0 ? 'cuenta_corriente' : null,
      pagos: pideMedio && formaPago === 'combinado' ? pagosCombinados : null,
      notaAFavor: resolucion === 'a_favor' ? notaAFavor.trim() : null,
    })
    setGuardando(false)
    setAConfirmar(false)
    if (rpcError) {
      setError(mensajeErrorGuardado(rpcError, status, 'registrar la devolución', 'lo cargado sigue guardado en este equipo'))
      return
    }
    guardarBorrador(null)
    const r = data as unknown as ResultadoDevolucionTickets | null
    showToast(`Devolución N° ${r?.numero ?? ''} registrada.`)
    onDone()
  }

  // ✕: cierra y conserva lo cargado (borrador). Cancelar: descarta, con confirmación.
  function cerrarConservando() {
    if (hayCambios) showToast('La devolución quedó guardada en este equipo: al abrirla de nuevo sigue donde estaba.')
    onClose()
  }
  function pedirCancelar() {
    if (hayCambios) setConfirmDescartar(true)
    else {
      guardarBorrador(null)
      onClose()
    }
  }

  const sinDevueltos = lineasDevueltas.length === 0
  const textoDiferencia = sinDevueltos
    ? 'Elegí qué se devuelve'
    : resolucion === 'cuenta_corriente'
      ? diferencia > 0
        ? `A la cuenta corriente: ${formatCurrency(diferencia)}`
        : `Se descuenta de la cuenta: ${formatCurrency(Math.abs(diferencia))}`
      : diferencia > 0
        ? `El cliente paga ${formatCurrency(diferencia)}`
        : diferencia < 0
          ? `A favor del cliente: ${formatCurrency(Math.abs(diferencia))}`
          : 'Saldado justo'
  const claseDiferencia = sinDevueltos
    ? 'text-ink-soft'
    : diferencia === 0
      ? 'text-success'
      : diferencia > 0
        ? 'text-accent-darker'
        : 'text-error'

  const footer = (
    <div className="flex flex-wrap items-center gap-x-6 gap-y-2">
      <dl className="flex flex-wrap gap-x-6 gap-y-1 font-sans">
        <div>
          <dt className="text-label-md text-ink-soft">Devuelto</dt>
          <dd className="text-label-bold text-ink">{formatCurrency(totalDevuelto)}</dd>
        </div>
        <div>
          <dt className="text-label-md text-ink-soft">Se lleva</dt>
          <dd className="text-label-bold text-ink">{formatCurrency(totalNuevo)}</dd>
        </div>
        <div>
          <dt className="text-label-md text-ink-soft">Diferencia</dt>
          <dd className={`text-label-bold ${claseDiferencia}`} aria-live="polite">
            {textoDiferencia}
          </dd>
        </div>
      </dl>
      <div className="ml-auto flex gap-3">
        <button
          type="button"
          onClick={pedirCancelar}
          className="min-h-11 rounded px-4 py-2.5 font-sans text-label-bold text-ink-soft hover:bg-bg"
        >
          Cancelar
        </button>
        <button
          type="button"
          onClick={() => validar() && setAConfirmar(true)}
          disabled={guardando || preparando}
          className="min-h-11 rounded bg-accent px-5 py-2.5 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-50"
        >
          Confirmar devolución
        </button>
      </div>
    </div>
  )

  const idErrTicket = `${ids}-err-ticket`
  const idErrMotivo = `${ids}-err-motivo`
  const idErrDetalle = `${ids}-err-detalle`
  const idErrResolucion = `${ids}-err-resolucion`
  const idErrNota = `${ids}-err-nota`
  const hayFactura = tickets.some((t) => t.tieneFactura)

  return (
    <Modal
      title="Devolución / Cambio"
      onClose={cerrarConservando}
      widthClassName="max-w-[1120px]"
      footer={footer}
      cambiosSinGuardar={hayCambios}
    >
      <div className="grid gap-stack-md lg:grid-cols-[minmax(0,1fr)_300px]">
        {/* ── Columna principal ── */}
        <div className="flex min-w-0 flex-col gap-stack-md">
          {avisoBorrador && (
            <div className="flex items-start justify-between gap-3 rounded bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">
              <p>{avisoBorrador}</p>
              <button
                type="button"
                onClick={() => setAvisoBorrador(null)}
                aria-label="Cerrar aviso"
                className="shrink-0 rounded p-1 hover:bg-white/60"
              >
                <X size={16} aria-hidden />
              </button>
            </div>
          )}

          {/* Tickets */}
          <section aria-labelledby={`${ids}-tickets`}>
            <h3 id={`${ids}-tickets`} className="font-display text-label-bold text-ink">
              Tickets <span className="font-sans text-label-md text-ink-soft">({tickets.length} de {MAX_TICKETS_DEVOLUCION})</span>
            </h3>
            <div className="mt-2 flex items-end gap-2">
              <label className="flex w-[12rem] flex-col gap-1">
                <span className="font-sans text-label-md text-ink">N° de ticket</span>
                <input
                  ref={inputTicketRef}
                  value={numeroTicket}
                  inputMode="numeric"
                  autoComplete="off"
                  onChange={(e) => {
                    setNumeroTicket(e.target.value)
                    if (errorTicket) setErrorTicket(null)
                  }}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') {
                      e.preventDefault()
                      void agregarTicket()
                    }
                  }}
                  disabled={tickets.length >= MAX_TICKETS_DEVOLUCION || preparando}
                  placeholder="Ej. 1234"
                  aria-invalid={Boolean(errorTicket)}
                  aria-describedby={errorTicket ? idErrTicket : undefined}
                  className={`${inputClass} py-2`}
                />
              </label>
              <button
                type="button"
                onClick={() => void agregarTicket()}
                disabled={agregando || preparando || tickets.length >= MAX_TICKETS_DEVOLUCION}
                className="min-h-11 rounded border border-accent px-4 py-2 font-sans text-label-bold text-accent-dark transition hover:bg-accent-light disabled:opacity-50"
              >
                {agregando ? 'Buscando...' : 'Agregar'}
              </button>
            </div>
            <ErrorCampo id={idErrTicket}>{errorTicket}</ErrorCampo>
            {preparando && <p className="mt-2 font-sans text-body-md text-ink-soft">Cargando...</p>}

            {tickets.length > 0 && (
              <ul className="mt-3 grid gap-2 sm:grid-cols-3">
                {tickets.map((t, i) => (
                  <li key={t.id} className="flex items-start justify-between gap-2 rounded-lg border border-line bg-surface px-3 py-2">
                    <div className="min-w-0 font-sans">
                      <p className="text-label-bold text-ink">
                        Ticket {i + 1} · N° {t.numero}
                      </p>
                      <p className="text-label-md text-ink-soft">
                        {formatFechaCortaLocal(t.createdAt)} · {formatCurrency(t.total)}
                      </p>
                      <p className="mt-0.5 flex flex-wrap gap-1 text-label-md">
                        {t.tieneFactura && <span className="rounded bg-amarillo/30 px-1.5 text-ink">Factura C</span>}
                        {t.formaPago === 'cuenta_corriente' && <span className="rounded bg-accent-light px-1.5 text-accent-darker">Cta. cte.</span>}
                      </p>
                    </div>
                    <button
                      type="button"
                      onClick={() => quitarTicket(t)}
                      aria-label={`Quitar ticket N° ${t.numero}`}
                      title="Quitar"
                      className="flex h-9 w-9 shrink-0 items-center justify-center rounded text-ink-soft hover:bg-bg hover:text-error"
                    >
                      <X size={18} aria-hidden />
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </section>

          {hayFactura && (
            <p className="rounded bg-amarillo/20 px-4 py-3 font-sans text-body-md text-ink">
              Hay tickets con Factura C. La devolución queda como registro interno: no genera nota de crédito.
            </p>
          )}

          {/* Productos a devolver */}
          {tickets.length > 0 && (
            <section aria-labelledby={`${ids}-devolver`}>
              <h3 id={`${ids}-devolver`} className="font-display text-label-bold text-ink">
                Productos a devolver
              </h3>
              <div className="mt-2 overflow-hidden rounded-lg border border-line">
                <table className="w-full table-fixed text-left font-sans text-body-md leading-5">
                  <colgroup>
                    <col />
                    <col className="w-[4.25rem]" />
                    <col className="w-[4.25rem]" />
                    <col className="w-[4.25rem]" />
                    <col className="w-[5.5rem]" />
                    {conDefectuosos && <col className="w-[6.5rem]" />}
                  </colgroup>
                  <thead>
                    <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
                      <th className="px-3 py-2">Producto · precio pagado</th>
                      <th className="px-2 py-2 text-right">Vend.</th>
                      <th className="px-2 py-2 text-right" title="Ya devuelta">Ya dev.</th>
                      <th className="px-2 py-2 text-right" title="Disponible">Disp.</th>
                      <th className="px-2 py-2 text-right">Devolver</th>
                      {conDefectuosos && (
                        <th className="px-2 py-2 text-center" title="Tildado: no vuelve al stock">
                          Defectuoso
                        </th>
                      )}
                    </tr>
                  </thead>
                  {tickets.map((t, i) => (
                    <tbody key={t.id}>
                      <tr className="border-b border-line bg-accent-light/60">
                        <th colSpan={4} scope="rowgroup" className="px-3 py-1.5 text-label-bold text-accent-darker">
                          Ticket {i + 1} — N° {t.numero} ({formatFechaCortaLocal(t.createdAt)})
                        </th>
                        <td colSpan={conDefectuosos ? 2 : 1} className="px-3 py-1.5 text-right text-label-bold text-accent-darker">
                          {formatCurrency(subtotalTicket(t))}
                        </td>
                      </tr>
                      {t.lineas.map((l) => {
                        const disp = disponible(l)
                        const cant = cantidades[l.ventaItemId] ?? ''
                        const excede = (Number(cant) || 0) > disp
                        return (
                          <tr key={l.ventaItemId} className="border-b border-line last:border-0">
                            <td className="px-3 py-1.5 align-top">
                              <ProductoLinea producto={l.producto} precio={l.precioUnitario} />
                            </td>
                            <td className="px-2 py-1.5 text-right text-ink-soft">{l.vendida}</td>
                            <td className="px-2 py-1.5 text-right text-ink-soft">{l.yaDevuelta}</td>
                            <td className="px-2 py-1.5 text-right text-ink">{disp}</td>
                            <td className="px-2 py-1.5 text-right">
                              <input
                                type="number"
                                min="0"
                                max={disp}
                                step="any"
                                disabled={disp <= 0}
                                value={cant}
                                onChange={(e) => setCantidades((prev) => ({ ...prev, [l.ventaItemId]: e.target.value }))}
                                placeholder="0"
                                aria-label={`Cantidad a devolver de ${l.nombre}, ticket N° ${t.numero}`}
                                aria-invalid={excede}
                                className={`w-full rounded border bg-surface px-2 py-1.5 text-right font-sans text-body-md text-ink outline-none focus:border-accent disabled:bg-bg ${excede ? 'border-error' : 'border-line'}`}
                              />
                            </td>
                            {conDefectuosos && (
                              <td className="px-2 py-1.5 text-center">
                                <input
                                  type="checkbox"
                                  checked={!sanos[l.ventaItemId]}
                                  disabled={disp <= 0}
                                  onChange={(e) => setSanos((prev) => ({ ...prev, [l.ventaItemId]: !e.target.checked }))}
                                  aria-label={`${l.nombre} defectuoso (no vuelve al stock)`}
                                  className="h-5 w-5 cursor-pointer accent-accent disabled:cursor-not-allowed"
                                />
                              </td>
                            )}
                          </tr>
                        )
                      })}
                    </tbody>
                  ))}
                </table>
              </div>
              <p className="mt-1 font-sans text-label-md text-ink-soft">
                {conDefectuosos
                  ? 'Motivo Defectuoso: lo tildado no vuelve al stock (queda separado para revisión). Destildá los productos que estén sanos.'
                  : 'Lo devuelto vuelve al stock del local.'}
              </p>
            </section>
          )}

          {/* Se lleva */}
          <section aria-labelledby={`${ids}-lleva`}>
            <h3 id={`${ids}-lleva`} className="font-display text-label-bold text-ink">
              Se lleva <span className="font-sans text-label-md text-ink-soft">(opcional, a precio de lista)</span>
            </h3>
            <div className="mt-2">
              {/* Mismo buscador que Ventas: misma consulta y mismo renglón (ProductoLinea). */}
              <ProductoBusqueda variante="compacto" onElegir={agregarNuevo} />
            </div>
            {nuevos.length > 0 && (
              <div className="mt-2 overflow-hidden rounded-lg border border-line">
                <table className="w-full table-fixed text-left font-sans text-body-md leading-5">
                  <colgroup>
                    <col />
                    <col className="w-[5.5rem]" />
                    <col className="w-[7.5rem]" />
                    <col className="w-12" />
                  </colgroup>
                  <tbody>
                    {nuevos.map((n) => (
                      <tr key={n.productoId} className="border-b border-line last:border-0">
                        <td className="px-3 py-1.5 align-top">
                          <ProductoLinea producto={n.producto} precio={n.precioUnitario} />
                        </td>
                        <td className="px-2 py-1.5">
                          <input
                            type="number"
                            min="0"
                            step="any"
                            value={n.cantidad}
                            onChange={(e) =>
                              setNuevos((prev) => prev.map((x) => (x.productoId === n.productoId ? { ...x, cantidad: e.target.value } : x)))
                            }
                            aria-label={`Cantidad de ${n.nombre}`}
                            className="w-full rounded border border-line bg-surface px-2 py-1.5 text-right font-sans text-body-md text-ink outline-none focus:border-accent"
                          />
                        </td>
                        <td className="px-2 py-1.5 text-right text-ink">
                          {formatCurrency(redondear2((Number(n.cantidad) || 0) * n.precioUnitario))}
                        </td>
                        <td className="px-1 py-1.5 text-right">
                          <button
                            type="button"
                            onClick={() => setNuevos((prev) => prev.filter((x) => x.productoId !== n.productoId))}
                            aria-label={`Quitar ${n.nombre}`}
                            className="flex h-9 w-9 items-center justify-center rounded text-ink-soft hover:bg-bg hover:text-error"
                          >
                            <X size={18} aria-hidden />
                          </button>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>

          {/* Motivo */}
          <section className="grid gap-3 sm:grid-cols-[220px_1fr]">
            <div>
              <Field label="Motivo" compact>
                <select
                  value={motivo}
                  onChange={(e) => {
                    setMotivo(e.target.value as MotivoDevolucion | '')
                    setErrores((p) => ({ ...p, motivo: undefined }))
                  }}
                  aria-invalid={Boolean(errores.motivo)}
                  aria-describedby={errores.motivo ? idErrMotivo : undefined}
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
              <ErrorCampo id={idErrMotivo}>{errores.motivo ?? null}</ErrorCampo>
            </div>
            <div>
              <Field
                label={motivo === 'otro' ? 'Detalle del motivo (obligatorio)' : 'Detalle del motivo (opcional)'}
                compact
                hint={conDefectuosos ? 'Lo tildado como Defectuoso no vuelve al stock. Destildá los productos sanos.' : undefined}
              >
                <input
                  value={motivoDetalle}
                  onChange={(e) => {
                    setMotivoDetalle(e.target.value)
                    setErrores((p) => ({ ...p, detalle: undefined }))
                  }}
                  aria-invalid={Boolean(errores.detalle)}
                  aria-describedby={errores.detalle ? idErrDetalle : undefined}
                  className={inputClass}
                />
              </Field>
              <ErrorCampo id={idErrDetalle}>{errores.detalle ?? null}</ErrorCampo>
            </div>
          </section>

          <Field label="Observaciones (opcional)" compact hint="Cualquier aclaración. Queda solo como nota interna.">
            <textarea value={observaciones} onChange={(e) => setObservaciones(e.target.value)} rows={2} className={inputClass} />
          </Field>

          {error && (
            <p role="alert" className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">
              {error}
            </p>
          )}
        </div>

        {/* ── Columna de la diferencia (queda a la vista al scrollear) ── */}
        <aside aria-labelledby={`${ids}-dif`} className="self-start lg:sticky lg:top-0">
          <div className="rounded-lg border border-line bg-surface p-4">
            <h3 id={`${ids}-dif`} className="font-display text-label-bold text-ink">
              Diferencia
            </h3>
            <p className={`mt-1 font-display text-headline-md ${claseDiferencia}`}>{formatCurrency(Math.abs(diferencia))}</p>
            <p className={`font-sans text-label-bold ${claseDiferencia}`}>{textoDiferencia}</p>

            {tickets.length === 0 ? (
              <p className="mt-3 font-sans text-body-md text-ink-soft">Agregá el primer ticket para empezar.</p>
            ) : sinDevueltos ? (
              <p className="mt-3 font-sans text-body-md text-ink-soft">Indicá la cantidad a devolver en cada ticket.</p>
            ) : resolucion === 'cuenta_corriente' && diferencia <= 0 ? (
              <p className="mt-3 font-sans text-body-md text-ink-soft">
                El ticket es a cuenta corriente: no se devuelve plata y no entra al cierre de caja.
              </p>
            ) : diferencia === 0 ? (
              <p className="mt-3 font-sans text-body-md text-ink-soft">No hay nada para cobrar ni devolver.</p>
            ) : (
              <div className="mt-3 flex flex-col gap-3">
                {diferencia < 0 && !ctaCteUnica && (
                  <fieldset>
                    <legend className="font-sans text-label-bold text-ink-soft">¿Qué se hace con la diferencia?</legend>
                    <div className="mt-1.5 grid gap-1" role="radiogroup">
                      {(
                        [
                          { v: 'reintegro', label: 'Devolver la plata', ayuda: 'Sale de la caja con el medio que elijas.' },
                          { v: 'a_favor', label: 'Queda a favor', ayuda: 'Sin plata ni caja. El vale se hace a mano.' },
                        ] as const
                      ).map((op) => (
                        <label
                          key={op.v}
                          className={`flex min-h-11 cursor-pointer items-start gap-2 rounded-lg border px-3 py-2 font-sans transition ${
                            resolucionNegativa === op.v ? 'border-accent bg-accent-light' : 'border-line hover:border-accent'
                          }`}
                        >
                          <input
                            type="radio"
                            name={`${ids}-resolucion`}
                            value={op.v}
                            checked={resolucionNegativa === op.v}
                            onChange={() => {
                              setResolucionNegativa(op.v)
                              setErrores((p) => ({ ...p, resolucion: undefined }))
                            }}
                            className="mt-1 h-4 w-4 accent-accent"
                          />
                          <span>
                            <span className="block text-label-bold text-ink">{op.label}</span>
                            <span className="block text-label-md text-ink-soft">{op.ayuda}</span>
                          </span>
                        </label>
                      ))}
                    </div>
                  </fieldset>
                )}

                {(pideMedio || (ctaCteUnica && diferencia > 0)) && (
                  <div>
                    {ctaCteUnica && diferencia > 0 && (
                      <p className="mb-1 font-sans text-label-md text-ink-soft">Podés cobrarla ahora o cargarla a la cuenta corriente.</p>
                    )}
                    <FormaPagoSelector
                      value={formaPago}
                      disponibleCuentaCorriente={ctaCteUnica && diferencia > 0}
                      mostrarAtajos={false}
                      onChange={(v) => {
                        setFormaPago(v)
                        setPagosCombinados(null)
                        setErrores((p) => ({ ...p, resolucion: undefined }))
                      }}
                      onCombinado={() => setCombinadoOpen(true)}
                    />
                    {formaPago === 'combinado' && pagosCombinados && (
                      <p className="mt-1.5 font-sans text-label-md text-ink-soft">
                        {pagosCombinados.map((p) => `${FORMA_PAGO_LABEL[p.formaPago]} ${formatCurrency(p.monto)}`).join(' + ')}
                      </p>
                    )}
                  </div>
                )}

                {resolucion === 'a_favor' && (
                  <div>
                    <label className="flex flex-col gap-1">
                      <span className="font-sans text-label-md text-ink">Nota (obligatoria)</span>
                      <textarea
                        value={notaAFavor}
                        onChange={(e) => {
                          setNotaAFavor(e.target.value)
                          setErrores((p) => ({ ...p, nota: undefined }))
                        }}
                        rows={3}
                        placeholder="Ej: vale manual a nombre de…"
                        aria-invalid={Boolean(errores.nota)}
                        aria-describedby={errores.nota ? idErrNota : undefined}
                        className={inputClass}
                      />
                    </label>
                    <ErrorCampo id={idErrNota}>{errores.nota ?? null}</ErrorCampo>
                  </div>
                )}
                <ErrorCampo id={idErrResolucion}>{errores.resolucion ?? null}</ErrorCampo>
              </div>
            )}
          </div>
        </aside>
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

      {aConfirmar && (
        <ConfirmDialog
          title="Confirmar devolución"
          mensaje=""
          variant="primario"
          confirmLabel={guardando ? 'Guardando...' : 'Registrar devolución'}
          confirmando={guardando}
          widthClassName="max-w-[520px]"
          onCancel={() => setAConfirmar(false)}
          onConfirm={() => void registrar()}
        >
          <ResumenConfirmacion
            tickets={tickets}
            subtotalTicket={subtotalTicket}
            nuevos={nuevos}
            totalDevuelto={totalDevuelto}
            totalNuevo={totalNuevo}
            textoDiferencia={textoDiferencia}
            detalleResolucion={
              resolucion === 'a_favor'
                ? `Queda a favor (vale manual): ${notaAFavor.trim()}`
                : pideMedio && formaPago
                  ? `${resolucion === 'cobro' ? 'Se cobra' : 'Se devuelve'} en ${
                      formaPago === 'combinado' && pagosCombinados
                        ? pagosCombinados.map((p) => `${FORMA_PAGO_LABEL[p.formaPago]} ${formatCurrency(p.monto)}`).join(' + ')
                        : FORMA_PAGO_LABEL[formaPago]
                    }`
                  : resolucion === 'cuenta_corriente'
                    ? 'Se imputa a la cuenta corriente del cliente'
                    : null
            }
            cantidadDefectuosos={lineasDevueltas.filter((x) => esDefectuoso(x.linea.ventaItemId)).length}
            cantidadAlStock={lineasDevueltas.filter((x) => !esDefectuoso(x.linea.ventaItemId)).length}
          />
        </ConfirmDialog>
      )}

      {confirmDescartar && (
        <ConfirmDialog
          title="Descartar la devolución"
          mensaje="Se borra todo lo cargado en esta devolución (tickets, productos y notas). ¿Descartar?"
          confirmLabel="Descartar"
          cancelLabel="Seguir editando"
          onCancel={() => setConfirmDescartar(false)}
          onConfirm={() => {
            guardarBorrador(null)
            onClose()
          }}
        />
      )}
    </Modal>
  )
}

function ResumenConfirmacion({
  tickets,
  subtotalTicket,
  nuevos,
  totalDevuelto,
  totalNuevo,
  textoDiferencia,
  detalleResolucion,
  cantidadDefectuosos,
  cantidadAlStock,
}: {
  tickets: TicketCargado[]
  subtotalTicket: (t: TicketCargado) => number
  nuevos: ItemNuevo[]
  totalDevuelto: number
  totalNuevo: number
  textoDiferencia: string
  detalleResolucion: string | null
  cantidadDefectuosos: number
  cantidadAlStock: number
}) {
  return (
    <dl className="flex flex-col gap-1 font-sans text-body-md text-ink">
      {tickets.map((t, i) => (
        <div key={t.id} className="flex justify-between gap-3">
          <dt className="text-ink-soft">
            Devuelto del ticket {i + 1} (N° {t.numero})
          </dt>
          <dd className="whitespace-nowrap">{formatCurrency(subtotalTicket(t))}</dd>
        </div>
      ))}
      <div className="flex justify-between gap-3 border-t border-line pt-1">
        <dt className="text-label-bold">Total devuelto</dt>
        <dd className="whitespace-nowrap text-label-bold">{formatCurrency(totalDevuelto)}</dd>
      </div>
      <div className="flex justify-between gap-3">
        <dt className="text-ink-soft">
          Se lleva ({nuevos.length} producto{nuevos.length === 1 ? '' : 's'})
        </dt>
        <dd className="whitespace-nowrap">{formatCurrency(totalNuevo)}</dd>
      </div>
      <div className="mt-1 rounded bg-bg px-3 py-2">
        <p className="text-label-bold">{textoDiferencia}</p>
        {detalleResolucion && <p className="text-ink-soft [overflow-wrap:anywhere]">{detalleResolucion}</p>}
      </div>
      {cantidadAlStock > 0 && (
        <p className="text-label-md text-ink-soft">
          {cantidadAlStock} producto{cantidadAlStock === 1 ? '' : 's'} vuelve{cantidadAlStock === 1 ? '' : 'n'} al stock.
        </p>
      )}
      {cantidadDefectuosos > 0 && (
        <p className="text-label-md text-error">
          {cantidadDefectuosos} producto{cantidadDefectuosos === 1 ? '' : 's'} defectuoso{cantidadDefectuosos === 1 ? '' : 's'}: no vuelve{cantidadDefectuosos === 1 ? '' : 'n'} al stock.
        </p>
      )}
    </dl>
  )
}
