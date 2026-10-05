import { useEffect, useId, useMemo, useRef, useState, type KeyboardEvent, type ReactNode } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { Ban, Eye, Pencil, Wallet } from 'lucide-react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { EstadoFacturaCompra, FacturaCompraSaldo, OrigenEgreso, TipoComprobanteCompra } from '../../types/database'
import {
  etiquetaComprobanteCompra,
  FORMA_PAGO_EGRESO_LABEL,
  invalidarCuentaProveedor,
  TIPO_COMPROBANTE_COMPRA_LABEL,
  TIPOS_COMPROBANTE_COMPRA,
  useComprobantesProveedor,
  usePagosProveedor,
  useProveedor,
  type PagoProveedorConDetalle,
} from '../../lib/facturasCompra'
import { esNotaCredito, esSeleccionableParaPago, simularRepartoPago } from '../../lib/repartoPagoProveedor'
import { formatCurrency, formatFechaCorta } from '../../lib/format'
import { friendlyError } from '../../lib/supabaseErrors'
import { Field, inputClass, selectClass } from './FormField'
import { EstadoBadge } from './EstadoBadge'
import { RowActionsMenu, type RowActionsMenuItem } from './RowActionsMenu'
import { PagarProveedorModal } from './PagarProveedorModal'
import { EditarFacturaCompraModal } from './EditarFacturaCompraModal'
import { AnularFacturaCompraModal } from './AnularFacturaCompraModal'

export type RenderDetalleComprobante = (args: {
  factura: FacturaCompraSaldo
  proveedorNombre: string
  onClose: () => void
  onChanged: () => void
}) => ReactNode

type Props = {
  supabase: SupabaseClient
  proveedorId: string
  // 'general' en Gestión (el pago no sale de la caja de Local), 'turno' en Local. Obligatorio.
  origen: OrigenEgreso
  permitirEditarAnular?: boolean // Gestión sí; Local no
  onVolver: () => void
  // Detalle de un comprobante: cada app enchufa el suyo (el de Gestión trae Editar/Anular y el
  // historial de aplicaciones). Así este componente no depende de modales propios de una app.
  renderDetalle: RenderDetalleComprobante
}

const TABS = [
  { id: 'pendientes', label: 'Pendientes' },
  { id: 'pagados', label: 'Pagados' },
  { id: 'todos', label: 'Todos' },
  { id: 'pagos', label: 'Pagos' },
] as const
type TabId = (typeof TABS)[number]['id']

const ESTADO_BADGE: Record<EstadoFacturaCompra, { label: string; variant: 'amber' | 'green' | 'red' | 'neutral' }> = {
  pendiente: { label: 'Pendiente', variant: 'amber' },
  parcial: { label: 'Parcial', variant: 'amber' },
  pagada: { label: 'Pagada', variant: 'green' },
  anulada: { label: 'Anulada', variant: 'red' },
}
// En una NC el estado describe su crédito: sin usar / usado en parte / agotado.
const ESTADO_BADGE_NC: Record<EstadoFacturaCompra, { label: string; variant: 'amber' | 'green' | 'red' | 'neutral' }> = {
  pendiente: { label: 'Sin usar', variant: 'green' },
  parcial: { label: 'Con crédito', variant: 'green' },
  pagada: { label: 'Agotada', variant: 'neutral' },
  anulada: { label: 'Anulada', variant: 'red' },
}

const cerrada = (c: FacturaCompraSaldo) => c.anulada || c.estado === 'pagada'
const plural = (n: number, uno: string, varios: string) => `${n} ${n === 1 ? uno : varios}`
const negativo = (n: number) => `−${formatCurrency(Math.abs(n))}`

// Cuenta corriente de un proveedor (docs/04, módulo 6; docs/31): cabecera con KPIs, comprobantes
// por estado, selección múltiple + NC para pagar, y el historial de pagos con lo que cubrió cada uno.
// Pestaña y filtros viven en la URL (search params): se pueden compartir y sobreviven al volver.
export function ProveedorCuentaCorriente({
  supabase,
  proveedorId,
  origen,
  permitirEditarAnular = false,
  onVolver,
  renderDetalle,
}: Props) {
  const queryClient = useQueryClient()
  const [params, setParams] = useSearchParams()
  const proveedorQ = useProveedor(supabase, proveedorId)
  const comprobantesQ = useComprobantesProveedor(supabase, proveedorId)
  const pagosQ = usePagosProveedor(supabase, proveedorId)

  const proveedor = proveedorQ.data
  const comprobantes = useMemo(() => comprobantesQ.data ?? [], [comprobantesQ.data])
  const pagos = useMemo(() => pagosQ.data ?? [], [pagosQ.data])
  const porId = useMemo(() => new Map(comprobantes.map((c) => [c.id, c])), [comprobantes])

  const tab = (TABS.some((t) => t.id === params.get('tab')) ? params.get('tab') : 'pendientes') as TabId
  const tipo = (params.get('tipo') ?? '') as TipoComprobanteCompra | ''
  const desde = params.get('desde') ?? ''
  const hasta = params.get('hasta') ?? ''
  const q = params.get('q') ?? ''
  const hayFiltros = Boolean(tipo || desde || hasta || q)

  function setParam(clave: string, valor: string) {
    setParams(
      (prev) => {
        const next = new URLSearchParams(prev)
        if (valor) next.set(clave, valor)
        else next.delete(clave)
        return next
      },
      { replace: true },
    )
  }
  function limpiarFiltros() {
    setParams(
      (prev) => {
        const next = new URLSearchParams(prev)
        for (const k of ['tipo', 'desde', 'hasta', 'q']) next.delete(k)
        return next
      },
      { replace: true },
    )
  }

  // ── Selección (comprobantes con saldo + NC con crédito) ──
  const [seleccion, setSeleccion] = useState<Set<string>>(new Set())
  useEffect(() => {
    // Tras un pago/edición/anulación, lo que dejó de ser seleccionable se cae solo.
    setSeleccion((prev) => {
      const next = new Set([...prev].filter((id) => {
        const c = porId.get(id)
        return c ? esSeleccionableParaPago(c) : false
      }))
      return next.size === prev.size ? prev : next
    })
  }, [porId])

  const seleccionFacturas = useMemo(
    () => [...seleccion].filter((id) => porId.get(id) && !esNotaCredito(porId.get(id)!)),
    [seleccion, porId],
  )
  const seleccionNotas = useMemo(
    () => [...seleccion].filter((id) => porId.get(id) && esNotaCredito(porId.get(id)!)),
    [seleccion, porId],
  )
  const aPagarSeleccion = useMemo(
    () =>
      simularRepartoPago({ comprobantes, facturaIds: seleccionFacturas, notaCreditoIds: seleccionNotas, monto: 0 })
        .restanteTrasNotas,
    [comprobantes, seleccionFacturas, seleccionNotas],
  )
  const resumenSeleccion =
    seleccion.size === 0
      ? ''
      : [
          seleccionFacturas.length > 0 && plural(seleccionFacturas.length, 'comprobante', 'comprobantes'),
          seleccionNotas.length > 0 && plural(seleccionNotas.length, 'NC', 'NC'),
          seleccionFacturas.length > 0
            ? `A pagar ${formatCurrency(aPagarSeleccion)}`
            : 'Se aplica a los comprobantes más antiguos',
        ]
          .filter(Boolean)
          .join(' · ')

  function toggle(id: string) {
    setSeleccion((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  // ── Modales ──
  const [pago, setPago] = useState<{ facturaIds: string[]; notaCreditoIds: string[] } | null>(null)
  const [detalleId, setDetalleId] = useState<string | null>(null)
  const [editarId, setEditarId] = useState<string | null>(null)
  const [anularId, setAnularId] = useState<string | null>(null)
  const [aviso, setAviso] = useState('')
  const refrescar = () => invalidarCuentaProveedor(queryClient, proveedorId)
  useEffect(() => {
    if (pago) setAviso('')
  }, [pago])

  // ── Comprobantes de la pestaña, con filtros ──
  const visibles = useMemo(() => {
    const texto = q.trim().toLowerCase()
    const filtrados = comprobantes.filter(
      (c) =>
        (!tipo || c.tipo_comprobante === tipo) &&
        (!desde || c.fecha_comprobante >= desde) &&
        (!hasta || c.fecha_comprobante <= hasta) &&
        (!texto ||
          [c.numero_comprobante, [c.punto_venta, c.numero_comprobante].filter(Boolean).join('-')]
            .some((n) => (n ?? '').toLowerCase().includes(texto))),
    )
    const porFechaDesc = (a: FacturaCompraSaldo, b: FacturaCompraSaldo) =>
      b.fecha_comprobante.localeCompare(a.fecha_comprobante) || b.created_at.localeCompare(a.created_at)
    if (tab === 'pendientes') {
      // Más viejos primero: es el orden en que se aplica un pago sin selección.
      return filtrados.filter(esSeleccionableParaPago).sort((a, b) => -porFechaDesc(a, b))
    }
    if (tab === 'pagados') return filtrados.filter((c) => !c.anulada && c.estado === 'pagada').sort(porFechaDesc)
    // Todos: abiertos primero; pagados y anulados al final (atenuados).
    return filtrados.sort((a, b) => Number(cerrada(a)) - Number(cerrada(b)) || porFechaDesc(a, b))
  }, [comprobantes, tab, tipo, desde, hasta, q])

  const pagosVisibles = useMemo(
    () => pagos.filter((p) => (!desde || p.fecha >= desde) && (!hasta || p.fecha <= hasta)),
    [pagos, desde, hasta],
  )

  // ── KPIs ──
  const pendientes = comprobantes.filter((c) => !c.anulada && !esNotaCredito(c) && Number(c.saldo_pendiente) > 0)
  const totalPendiente = pendientes.reduce((acc, c) => acc + Number(c.saldo_pendiente), 0)
  const creditoNc = comprobantes.reduce((acc, c) => acc + Number(c.credito_disponible), 0)
  const ultimoPago = pagos.find((p) => Number(p.monto) > 0 && !p.revierte_pago_proveedor_id && !p.revertido)

  // ── Tabs accesibles (flechas, Home/End) ──
  const idBase = useId()
  const tabRefs = useRef<(HTMLButtonElement | null)[]>([])
  function irATab(id: TabId) {
    setParam('tab', id === 'pendientes' ? '' : id)
  }
  function onTabKeyDown(e: KeyboardEvent<HTMLDivElement>) {
    const i = TABS.findIndex((t) => t.id === tab)
    const destino =
      e.key === 'ArrowRight' ? (i + 1) % TABS.length
      : e.key === 'ArrowLeft' ? (i - 1 + TABS.length) % TABS.length
      : e.key === 'Home' ? 0
      : e.key === 'End' ? TABS.length - 1
      : -1
    if (destino < 0) return
    e.preventDefault()
    irATab(TABS[destino].id)
    tabRefs.current[destino]?.focus()
  }

  // ── Selección de todos los visibles ──
  const seleccionablesVisibles = visibles.filter(esSeleccionableParaPago)
  const todosMarcados = seleccionablesVisibles.length > 0 && seleccionablesVisibles.every((c) => seleccion.has(c.id))
  const algunoMarcado = seleccionablesVisibles.some((c) => seleccion.has(c.id))
  const checkTodosRef = useRef<HTMLInputElement>(null)
  useEffect(() => {
    if (checkTodosRef.current) checkTodosRef.current.indeterminate = algunoMarcado && !todosMarcados
  }, [algunoMarcado, todosMarcados])
  function toggleTodos() {
    setSeleccion((prev) => {
      const next = new Set(prev)
      for (const c of seleccionablesVisibles) {
        if (todosMarcados) next.delete(c.id)
        else next.add(c.id)
      }
      return next
    })
  }

  const error = proveedorQ.error ?? comprobantesQ.error ?? pagosQ.error
  const nombre = proveedor?.razon_social ?? ''

  if (proveedorQ.isPending) {
    return <p className="p-card font-sans text-body-md text-ink-soft">Cargando proveedor...</p>
  }
  if (!proveedor) {
    return (
      <section className="flex flex-col gap-stack-md rounded-lg bg-surface p-card shadow-sm">
        <p className="font-sans text-body-md text-ink">
          {proveedorQ.error ? friendlyError(proveedorQ.error as Error) : 'No se encontró el proveedor.'}
        </p>
        <button type="button" onClick={onVolver} className="self-start font-sans text-label-bold text-accent-dark hover:underline">
          ← Volver a Proveedores
        </button>
      </section>
    )
  }

  const saldo = Number(proveedor.saldo_actual)
  const detalle = detalleId ? porId.get(detalleId) : undefined
  const aEditar = editarId ? porId.get(editarId) : undefined
  const aAnular = anularId ? porId.get(anularId) : undefined

  return (
    <section aria-labelledby={`${idBase}-titulo`} className="flex min-h-full flex-col rounded-lg bg-surface p-card shadow-sm">
      {/* ── Cabecera ── */}
      <div className="flex flex-wrap items-start justify-between gap-stack-md">
        <div className="min-w-0">
          <button
            type="button"
            onClick={onVolver}
            className="rounded font-sans text-label-bold text-accent-dark hover:underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
          >
            ← Proveedores
          </button>
          <h1 id={`${idBase}-titulo`} className="mt-1 font-display text-headline-lg text-accent-darker [overflow-wrap:anywhere]">
            {proveedor.razon_social}
          </h1>
          <dl className="mt-1 flex flex-wrap gap-x-stack-md gap-y-1 font-sans text-label-md text-ink-soft">
            <div className="flex gap-1">
              <dt>CUIT:</dt>
              <dd className="text-ink">{proveedor.cuit || '—'}</dd>
            </div>
            <div className="flex gap-1">
              <dt>Contacto:</dt>
              <dd className="text-ink">
                {[proveedor.contacto, proveedor.telefono, proveedor.mail].filter(Boolean).join(' · ') || '—'}
              </dd>
            </div>
            <div className="flex gap-1">
              <dt>Márgenes:</dt>
              <dd className="text-ink">
                {proveedor.margen_1_default}% · {proveedor.margen_2_default}%
              </dd>
            </div>
          </dl>
        </div>
        <button
          type="button"
          onClick={() => setPago({ facturaIds: [], notaCreditoIds: [] })}
          // Una sola acción teal sólida por pantalla (docs/08 §5): con selección, la protagonista es "Pagar".
          className={
            seleccion.size > 0
              ? 'rounded border border-accent px-4 py-3 font-sans text-label-bold text-accent-darker transition hover:bg-accent-light'
              : 'rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark'
          }
        >
          Registrar pago
        </button>
      </div>

      {/* ── KPIs ── */}
      <ul aria-label="Resumen de la cuenta" className="mt-stack-md grid grid-cols-2 gap-stack-sm lg:grid-cols-4">
        <Kpi label="Saldo">
          <span className={saldo > 0 ? 'text-error' : saldo < 0 ? 'text-success' : 'text-accent-darker'}>
            {formatCurrency(saldo)}
          </span>
          {saldo < 0 && <span className="block font-sans text-label-md text-ink-soft">a favor</span>}
        </Kpi>
        <Kpi label="Comprobantes pendientes">
          {formatCurrency(totalPendiente)}
          <span className="block font-sans text-label-md text-ink-soft">
            {plural(pendientes.length, 'comprobante', 'comprobantes')}
          </span>
        </Kpi>
        <Kpi label="Crédito NC disponible">
          <span className={creditoNc > 0 ? 'text-success' : ''}>{formatCurrency(creditoNc)}</span>
        </Kpi>
        <Kpi label="Último pago">
          {ultimoPago ? (
            <>
              {formatCurrency(Number(ultimoPago.monto))}
              <span className="block font-sans text-label-md text-ink-soft">
                {formatFechaCorta(ultimoPago.fecha)} · {FORMA_PAGO_EGRESO_LABEL[ultimoPago.forma_pago]}
              </span>
            </>
          ) : (
            <span className="text-ink-soft">—</span>
          )}
        </Kpi>
      </ul>

      {/* ── Pestañas ── */}
      <div role="tablist" aria-label="Vista de la cuenta" onKeyDown={onTabKeyDown} className="mt-stack-md flex gap-1 border-b border-line">
        {TABS.map((t, i) => (
          <button
            key={t.id}
            ref={(el) => (tabRefs.current[i] = el)}
            id={`${idBase}-tab-${t.id}`}
            type="button"
            role="tab"
            aria-selected={tab === t.id}
            aria-controls={`${idBase}-panel`}
            tabIndex={tab === t.id ? 0 : -1}
            onClick={() => irATab(t.id)}
            className={[
              'rounded-t px-4 py-2 font-sans text-label-bold focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent',
              tab === t.id ? 'border-b-2 border-accent text-accent-darker' : 'text-ink-soft hover:text-accent-darker',
            ].join(' ')}
          >
            {t.label}
          </button>
        ))}
      </div>

      {/* ── Filtros (en la URL) ── */}
      <form
        role="search"
        aria-label="Filtrar"
        onSubmit={(e) => e.preventDefault()}
        className="mt-stack-md flex flex-wrap items-end gap-stack-sm"
      >
        {tab !== 'pagos' && (
          <div className="w-44">
            <Field label="Tipo" compact>
              <select value={tipo} onChange={(e) => setParam('tipo', e.target.value)} className={selectClass}>
                <option value="">Todos</option>
                {TIPOS_COMPROBANTE_COMPRA.map((t) => (
                  <option key={t} value={t}>
                    {TIPO_COMPROBANTE_COMPRA_LABEL[t]}
                  </option>
                ))}
              </select>
            </Field>
          </div>
        )}
        <div className="w-40">
          <Field label="Desde" compact>
            <input type="date" value={desde} max={hasta || undefined} onChange={(e) => setParam('desde', e.target.value)} className={inputClass} />
          </Field>
        </div>
        <div className="w-40">
          <Field label="Hasta" compact>
            <input type="date" value={hasta} min={desde || undefined} onChange={(e) => setParam('hasta', e.target.value)} className={inputClass} />
          </Field>
        </div>
        {tab !== 'pagos' && (
          <div className="w-48">
            <Field label="Número" compact>
              <input type="search" value={q} onChange={(e) => setParam('q', e.target.value)} placeholder="Buscar número" className={inputClass} />
            </Field>
          </div>
        )}
        {hayFiltros && (
          <button
            type="button"
            onClick={limpiarFiltros}
            className="rounded px-3 py-2.5 font-sans text-label-bold text-ink-soft hover:bg-bg focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
          >
            Limpiar filtros
          </button>
        )}
      </form>

      {error && (
        <p role="alert" className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">
          {friendlyError(error as Error)}
        </p>
      )}
      <p aria-live="polite" className={aviso ? 'mt-stack-md rounded bg-badge-green-bg px-4 py-3 font-sans text-body-md text-badge-green-text' : 'sr-only'}>
        {aviso}
      </p>

      {/* ── Panel ── */}
      <div
        id={`${idBase}-panel`}
        role="tabpanel"
        aria-labelledby={`${idBase}-tab-${tab}`}
        className="mt-stack-md flex-1 overflow-hidden rounded-xl shadow-sm"
      >
        {tab === 'pagos' ? (
          <TablaPagos pagos={pagosVisibles} porId={porId} cargando={pagosQ.isPending} />
        ) : (
          <table className="w-full table-fixed text-left font-sans text-table-row max-xl:[&_td]:px-2 max-xl:[&_th]:px-2">
            <colgroup>
              <col className="w-[2.75rem]" />
              <col className="w-[6.25rem]" />
              <col className="w-[7.5rem]" />
              <col />
              <col className="w-[8rem]" />
              <col className="w-[8rem] max-xl:hidden" />
              <col className="w-[8rem]" />
              <col className="w-[6.5rem]" />
              <col className="w-[3rem]" />
            </colgroup>
            <thead>
              <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
                <th scope="col" className="px-3 py-2.5">
                  <input
                    ref={checkTodosRef}
                    type="checkbox"
                    checked={todosMarcados}
                    disabled={seleccionablesVisibles.length === 0}
                    onChange={toggleTodos}
                    aria-label="Seleccionar todos los comprobantes visibles"
                    className="h-4 w-4 accent-accent"
                  />
                </th>
                <th scope="col" className="px-3 py-2.5">Fecha</th>
                <th scope="col" className="px-3 py-2.5">Tipo</th>
                <th scope="col" className="px-3 py-2.5">Número</th>
                <th scope="col" className="px-3 py-2.5 text-right">Total</th>
                <th scope="col" className="px-3 py-2.5 text-right max-xl:hidden">Aplicado</th>
                <th scope="col" className="px-3 py-2.5 text-right">Saldo</th>
                <th scope="col" className="px-3 py-2.5">Estado</th>
                <th scope="col" className="px-3 py-2.5">
                  <span className="sr-only">Acciones</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {comprobantesQ.isPending && (
                <tr>
                  <td colSpan={9} className="px-4 py-4 text-ink-soft">Cargando...</td>
                </tr>
              )}
              {!comprobantesQ.isPending && visibles.length === 0 && (
                <tr>
                  <td colSpan={9} className="px-4 py-4 text-ink-soft">
                    {hayFiltros
                      ? 'Ningún comprobante coincide con los filtros.'
                      : tab === 'pendientes'
                        ? 'No hay comprobantes pendientes ni notas de crédito con saldo.'
                        : tab === 'pagados'
                          ? 'Todavía no hay comprobantes pagados.'
                          : 'Este proveedor no tiene comprobantes cargados.'}
                  </td>
                </tr>
              )}
              {visibles.map((c) => {
                const nc = esNotaCredito(c)
                const etiqueta = etiquetaComprobanteCompra(c)
                const seleccionable = esSeleccionableParaPago(c)
                const badge = (nc ? ESTADO_BADGE_NC : ESTADO_BADGE)[c.estado]
                const numero = [c.punto_venta, c.numero_comprobante].filter(Boolean).join('-') || 'sin número'
                const acciones: RowActionsMenuItem[] = [
                  { label: 'Ver detalle', icon: Eye, onClick: () => setDetalleId(c.id) },
                  ...(seleccionable && !nc
                    ? [{ label: 'Pagar este comprobante', icon: Wallet, onClick: () => setPago({ facturaIds: [c.id], notaCreditoIds: [] }) }]
                    : []),
                  ...(permitirEditarAnular && !c.anulada
                    ? [
                        { label: 'Editar', icon: Pencil, onClick: () => setEditarId(c.id) },
                        { label: 'Anular', icon: Ban, onClick: () => setAnularId(c.id), destructive: true },
                      ]
                    : []),
                ]
                return (
                  <tr
                    key={c.id}
                    onClick={() => setDetalleId(c.id)}
                    className={`cursor-pointer border-b border-table-divider last:border-0 even:bg-table-row-alt hover:bg-accent-light/40 ${
                      tab === 'todos' && cerrada(c) ? 'opacity-60' : ''
                    } ${seleccion.has(c.id) ? '!bg-accent-light' : ''}`}
                  >
                    <td className="px-3 py-3" onClick={(e) => e.stopPropagation()}>
                      {seleccionable && (
                        <input
                          type="checkbox"
                          checked={seleccion.has(c.id)}
                          onChange={() => toggle(c.id)}
                          aria-label={`Seleccionar ${etiqueta}`}
                          className="h-4 w-4 accent-accent"
                        />
                      )}
                    </td>
                    <td className="px-3 py-3 text-ink-soft tabular-nums">{formatFechaCorta(c.fecha_comprobante)}</td>
                    <td className={`px-3 py-3 [overflow-wrap:anywhere] ${nc ? 'text-success' : 'text-ink'}`}>
                      {TIPO_COMPROBANTE_COMPRA_LABEL[c.tipo_comprobante]}
                      {c.letra ? ` ${c.letra}` : ''}
                    </td>
                    <td className="px-3 py-3 [overflow-wrap:anywhere]">
                      <button
                        type="button"
                        onClick={(e) => {
                          e.stopPropagation()
                          setDetalleId(c.id)
                        }}
                        aria-label={`Ver detalle de ${etiqueta}`}
                        className="rounded text-left text-ink hover:underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
                      >
                        {numero}
                      </button>
                    </td>
                    <td className={`px-3 py-3 text-right font-semibold tabular-nums ${nc ? 'text-success' : 'text-ink'}`}>
                      {nc ? negativo(Number(c.total)) : formatCurrency(Number(c.total))}
                    </td>
                    <td className="px-3 py-3 text-right tabular-nums text-ink-soft max-xl:hidden">
                      {formatCurrency(Number(c.total_aplicado))}
                    </td>
                    <td
                      className={`px-3 py-3 text-right font-semibold tabular-nums ${
                        nc
                          ? Number(c.credito_disponible) > 0 ? 'text-success' : 'text-ink-soft'
                          : Number(c.saldo_pendiente) > 0 ? 'text-error' : 'text-ink-soft'
                      }`}
                    >
                      {nc
                        ? Number(c.credito_disponible) > 0 ? negativo(Number(c.credito_disponible)) : formatCurrency(0)
                        : formatCurrency(Number(c.saldo_pendiente))}
                    </td>
                    <td className="px-3 py-3">
                      <EstadoBadge variant={badge.variant}>{badge.label}</EstadoBadge>
                    </td>
                    <td className="px-3 py-3 text-right" onClick={(e) => e.stopPropagation()}>
                      {/* docs/08 §5.2: menú solo con 2+ acciones; con una sola (ver detalle), la fila ya lo hace. */}
                      {acciones.length >= 2 && <RowActionsMenu ariaLabel={`Acciones para ${etiqueta}`} items={acciones} />}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        )}
      </div>

      {/* ── Barra de selección ── */}
      <p aria-live="polite" className="sr-only">
        {resumenSeleccion}
      </p>
      {seleccion.size > 0 && (
        <div
          role="region"
          aria-label="Comprobantes seleccionados"
          className="sticky bottom-0 z-10 mt-stack-md flex flex-wrap items-center justify-between gap-stack-sm rounded-lg border border-accent bg-accent-light px-4 py-3"
        >
          <p className="font-sans text-body-md font-semibold text-accent-darker tabular-nums">{resumenSeleccion}</p>
          <div className="flex gap-3">
            <button
              type="button"
              onClick={() => setSeleccion(new Set())}
              className="rounded px-4 py-2.5 font-sans text-label-bold text-ink-soft hover:bg-surface focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
            >
              Quitar selección
            </button>
            <button
              type="button"
              onClick={() => setPago({ facturaIds: seleccionFacturas, notaCreditoIds: seleccionNotas })}
              className="rounded bg-accent px-4 py-2.5 font-sans text-label-bold text-white transition hover:bg-accent-dark"
            >
              Pagar
            </button>
          </div>
        </div>
      )}

      {pago && (
        <PagarProveedorModal
          supabase={supabase}
          proveedorId={proveedorId}
          proveedorNombre={nombre}
          comprobantes={comprobantes}
          facturaIds={pago.facturaIds}
          notaCreditoIds={pago.notaCreditoIds}
          origen={origen}
          onClose={() => setPago(null)}
          onPagado={() => {
            setPago(null)
            setSeleccion(new Set())
            setAviso('Pago registrado.')
          }}
        />
      )}

      {detalle &&
        renderDetalle({
          factura: detalle,
          proveedorNombre: nombre,
          onClose: () => setDetalleId(null),
          onChanged: refrescar,
        })}

      {permitirEditarAnular && aEditar && (
        <EditarFacturaCompraModal
          supabase={supabase}
          factura={aEditar}
          onClose={() => setEditarId(null)}
          onSaved={() => {
            setEditarId(null)
            refrescar()
          }}
        />
      )}
      {permitirEditarAnular && aAnular && (
        <AnularFacturaCompraModal
          supabase={supabase}
          factura={aAnular}
          onClose={() => setAnularId(null)}
          onAnulada={() => {
            setAnularId(null)
            refrescar()
          }}
        />
      )}
    </section>
  )
}

function Kpi({ label, children }: { label: string; children: ReactNode }) {
  return (
    <li className="rounded-lg border border-line p-4">
      <p className="font-sans text-label-bold uppercase text-ink-soft">{label}</p>
      <p className="mt-1 font-display text-headline-md text-accent-darker tabular-nums">{children}</p>
    </li>
  )
}

function TablaPagos({
  pagos,
  porId,
  cargando,
}: {
  pagos: PagoProveedorConDetalle[]
  porId: Map<string, FacturaCompraSaldo>
  cargando: boolean
}) {
  return (
    <table className="w-full table-fixed text-left font-sans text-table-row max-xl:[&_td]:px-2 max-xl:[&_th]:px-2">
      <colgroup>
        <col className="w-[6.25rem]" />
        <col className="w-[8rem]" />
        <col className="w-[9rem]" />
        <col className="w-[9rem]" />
        <col />
      </colgroup>
      <thead>
        <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
          <th scope="col" className="px-3 py-2.5">Fecha</th>
          <th scope="col" className="px-3 py-2.5 text-right">Monto</th>
          <th scope="col" className="px-3 py-2.5">Medio</th>
          <th scope="col" className="px-3 py-2.5">Usuario</th>
          <th scope="col" className="px-3 py-2.5">Comprobantes cubiertos</th>
        </tr>
      </thead>
      <tbody>
        {cargando && (
          <tr>
            <td colSpan={5} className="px-4 py-4 text-ink-soft">Cargando...</td>
          </tr>
        )}
        {!cargando && pagos.length === 0 && (
          <tr>
            <td colSpan={5} className="px-4 py-4 text-ink-soft">No hay pagos registrados en este período.</td>
          </tr>
        )}
        {pagos.map((p) => {
          const monto = Number(p.monto)
          const esReversion = Boolean(p.revierte_pago_proveedor_id)
          const deLaPlata = p.aplicaciones.filter((a) => a.pago_proveedor_id).reduce((acc, a) => acc + Number(a.monto), 0)
          const aCuenta = esReversion ? 0 : Math.round((monto - deLaPlata) * 100) / 100
          return (
            <tr
              key={p.id}
              className={`border-b border-table-divider align-top last:border-0 even:bg-table-row-alt ${
                esReversion || p.revertido ? 'opacity-60' : ''
              }`}
            >
              <td className="px-3 py-3 text-ink-soft tabular-nums">{formatFechaCorta(p.fecha)}</td>
              <td className={`px-3 py-3 text-right font-semibold tabular-nums ${monto < 0 ? 'text-error' : 'text-ink'}`}>
                {monto < 0 ? negativo(monto) : formatCurrency(monto)}
              </td>
              <td className="px-3 py-3 text-ink [overflow-wrap:anywhere]">
                {monto === 0 ? 'Solo crédito NC' : FORMA_PAGO_EGRESO_LABEL[p.forma_pago]}
                {p.cheque_numero && <span className="block text-ink-soft">N° {p.cheque_numero}</span>}
              </td>
              <td className="px-3 py-3 text-ink-soft [overflow-wrap:anywhere]">{p.usuario_nombre ?? '—'}</td>
              <td className="px-3 py-3 [overflow-wrap:anywhere]">
                {esReversion ? (
                  <span className="text-ink-soft">Reversión de un pago (Historial)</span>
                ) : (
                  <ul className="flex flex-col gap-0.5">
                    {p.revertido && (
                      <li>
                        <EstadoBadge variant="red">Revertido</EstadoBadge>
                      </li>
                    )}
                    {p.aplicaciones.map((a) => {
                      const comprobante = porId.get(a.factura_compra_id)
                      const notaCredito = a.nota_credito_id ? porId.get(a.nota_credito_id) : undefined
                      return (
                        <li key={a.id} className={a.revertida_at ? 'text-ink-soft line-through' : 'text-ink'}>
                          {comprobante ? etiquetaComprobanteCompra(comprobante) : 'Comprobante'} ·{' '}
                          <span className="tabular-nums">{formatCurrency(Number(a.monto))}</span>
                          {notaCredito && (
                            <span className="text-success"> con {etiquetaComprobanteCompra(notaCredito)}</span>
                          )}
                        </li>
                      )
                    })}
                    {aCuenta > 0 && (
                      <li className="text-ink">
                        A cuenta · <span className="tabular-nums">{formatCurrency(aCuenta)}</span>
                      </li>
                    )}
                    {p.nota && <li className="text-ink-soft">“{p.nota}”</li>}
                  </ul>
                )}
              </td>
            </tr>
          )
        })}
      </tbody>
    </table>
  )
}
