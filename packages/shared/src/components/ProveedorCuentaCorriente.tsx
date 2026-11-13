import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Ban, Copy, Eye, Pencil, Wallet } from 'lucide-react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { EstadoFacturaCompra, FacturaCompraSaldo, OrigenEgreso, TipoComprobanteCompra, TipoCompra } from '../../types/database'
import {
  AJUSTE_REDONDEO_LABEL,
  CAJA_ORIGEN_LABEL,
  etiquetaComprobanteCompra,
  etiquetaCortaAlicuotaIva,
  etiquetaFormaPago,
  FORMA_PAGO_CABECERA_LABEL,
  invalidarCuentaProveedor,
  TIPO_COMPRA_LABEL,
  TIPO_COMPROBANTE_COMPRA_LABEL,
  TIPOS_COMPRA,
  TIPOS_COMPROBANTE_COMPRA,
  tipoCompraDe,
  useComprobantesProveedor,
  usePagosProveedor,
  useProveedor,
  type PagoProveedorConDetalle,
} from '../../lib/facturasCompra'
import { esNotaCredito, esSeleccionableParaPago, simularRepartoPago } from '../../lib/repartoPagoProveedor'
import { usePagosACuenta } from '../../lib/pagosACuenta'
import { formatAjuste, formatCurrency, formatFechaCorta } from '../../lib/format'
import { friendlyError } from '../../lib/supabaseErrors'
import { Field, inputClass, selectClass } from './FormField'
import { ChipTipoCompra, EstadoBadge } from './EstadoBadge'
import { RowActionsMenu, type RowActionsMenuItem } from './RowActionsMenu'
import { PagarProveedorModal } from './PagarProveedorModal'
import { PagoProveedorDocumento } from './PagoProveedorDocumento'
import { useDocumentosAbiertos } from './documentos/DocumentosAbiertos'
import { FormaPagoConDetalle } from './FormaPagoConDetalle'
import { AplicarACuentaModal } from './AplicarACuentaModal'
import { EditarFacturaCompraModal } from './EditarFacturaCompraModal'
import { AnularFacturaCompraModal } from './AnularFacturaCompraModal'
import { ObservacionesProveedor } from './ObservacionesProveedor'
import { datosSaldoInicial, filaSaldoInicial, KpiSaldoInicial, verFilaSaldoInicial } from './SaldoInicialCuenta'
import {
  CuentaCorrienteLayout,
  KpiCuenta,
  TablaComprobantes,
  useParamsCuentaCorriente,
  useSeleccion,
  type ColumnaComprobantes,
} from './CuentaCorrienteLayout'

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
  // Aplicar pagos a cuenta a comprobantes pendientes (docs/52). No mueve plata. Cada app lo habilita.
  permitirAplicarACuenta?: boolean
  // "Copiar" en el menú de cada comprobante, también en anulados (docs/33). Cada app abre su
  // formulario de carga con copiadaDeId; sin esta prop la acción no aparece.
  onCopiar?: (comprobante: FacturaCompraSaldo) => void
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
const FILTROS = ['tipo', 'compra', 'desde', 'hasta', 'q'] as const
const idDe = (c: FacturaCompraSaldo) => c.id

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
// El esqueleto (cabecera, KPIs, pestañas, filtros, tabla con selección) es CuentaCorrienteLayout,
// compartido con la cuenta corriente de clientes (docs/68).
export function ProveedorCuentaCorriente({
  supabase,
  proveedorId,
  origen,
  permitirEditarAnular = false,
  permitirAplicarACuenta = false,
  onCopiar,
  onVolver,
  renderDetalle,
}: Props) {
  const queryClient = useQueryClient()
  const proveedorQ = useProveedor(supabase, proveedorId)
  const comprobantesQ = useComprobantesProveedor(supabase, proveedorId)
  const pagosQ = usePagosProveedor(supabase, proveedorId)
  const aCuentaQ = usePagosACuenta(supabase, proveedorId)

  const proveedor = proveedorQ.data
  const comprobantes = useMemo(() => comprobantesQ.data ?? [], [comprobantesQ.data])
  const pagos = useMemo(() => pagosQ.data ?? [], [pagosQ.data])
  const porId = useMemo(() => new Map(comprobantes.map((c) => [c.id, c])), [comprobantes])

  const { tab, irATab, valores, hayFiltros, setParam, limpiarFiltros } = useParamsCuentaCorriente(TABS, FILTROS)
  const tipo = valores.tipo as TipoComprobanteCompra | ''
  const compra = valores.compra as TipoCompra | '' // docs/53: artículos / servicios
  const { desde, hasta, q } = valores

  // ── Selección (comprobantes con saldo + NC con crédito) ──
  const { seleccion, setSeleccion, toggle } = useSeleccion(comprobantes, idDe, esSeleccionableParaPago)

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

  // ── Modales ──
  const [pago, setPago] = useState<{ facturaIds: string[]; notaCreditoIds: string[] } | null>(null)
  const [aplicar, setAplicar] = useState<{ facturaIds: string[] } | null>(null)
  const [detalleId, setDetalleId] = useState<string | null>(null)
  const [editarId, setEditarId] = useState<string | null>(null)
  const [anularId, setAnularId] = useState<string | null>(null)
  const [aviso, setAviso] = useState('')
  const refrescar = () => invalidarCuentaProveedor(queryClient, proveedorId)
  useEffect(() => {
    if (pago || aplicar) setAviso('')
  }, [pago, aplicar])

  // Bandeja (docs/73): en Local y Gestión el pago se abre como documento y se puede minimizar para
  // ir a otra pantalla. Uno por proveedor: volver a "Pagar" trae al frente el que ya está abierto.
  // Fuera de la bandeja (no debería pasar) sigue siendo el modal de siempre.
  const bandeja = useDocumentosAbiertos()
  function abrirPago(sel: { facturaIds: string[]; notaCreditoIds: string[] }) {
    if (!bandeja) {
      setPago(sel)
      return
    }
    setAviso('')
    bandeja.abrir({
      clave: `pago_proveedor:${proveedorId}`,
      tipo: 'pago_proveedor',
      etiqueta: nombre ? `Pago · ${nombre}` : 'Pago a proveedor',
      render: ({ cerrar }) => (
        <PagoProveedorDocumento
          supabase={supabase}
          proveedorId={proveedorId}
          facturaIds={sel.facturaIds}
          notaCreditoIds={sel.notaCreditoIds}
          origen={origen}
          permitirAplicarACuenta={permitirAplicarACuenta}
          onCerrar={cerrar}
          onTerminado={(texto) => {
            cerrar()
            // Si la cuenta corriente sigue montada (no se navegó a otra pantalla), limpia y avisa.
            setSeleccion(new Set())
            setAviso(texto)
          }}
        />
      ),
    })
  }

  // ── Comprobantes de la pestaña, con filtros ──
  const visibles = useMemo(() => {
    const texto = q.trim().toLowerCase()
    const filtrados = comprobantes.filter(
      (c) =>
        (!tipo || c.tipo_comprobante === tipo) &&
        (!compra || tipoCompraDe(c) === compra) &&
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
  }, [comprobantes, tab, tipo, compra, desde, hasta, q])

  const pagosVisibles = useMemo(
    () => pagos.filter((p) => (!desde || p.fecha >= desde) && (!hasta || p.fecha <= hasta)),
    [pagos, desde, hasta],
  )

  // ── KPIs ──
  const pendientes = comprobantes.filter((c) => !c.anulada && !esNotaCredito(c) && Number(c.saldo_pendiente) > 0)
  const totalPendiente = pendientes.reduce((acc, c) => acc + Number(c.saldo_pendiente), 0)
  const creditoNc = comprobantes.reduce((acc, c) => acc + Number(c.credito_disponible), 0)
  // Pagos sin comprobante (docs/52), calculado por la base (vista pagos_proveedor_a_cuenta).
  const aCuenta = aCuentaQ.data?.total ?? 0
  const ofrecerAplicar = permitirAplicarACuenta && aCuenta > 0 && pendientes.length > 0
  const ultimoPago = pagos.find((p) => Number(p.monto) > 0 && !p.revierte_pago_proveedor_id && !p.revertido)

  function toggleVisibles(ids: string[], marcar: boolean) {
    setSeleccion((prev) => {
      const next = new Set(prev)
      for (const id of ids) {
        if (marcar) next.add(id)
        else next.delete(id)
      }
      return next
    })
  }

  const error = proveedorQ.error ?? comprobantesQ.error ?? pagosQ.error ?? aCuentaQ.error
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
  // docs/69: saldo inicial (único). Los pagos sin comprobante lo cancelan primero.
  const saldoInicial = datosSaldoInicial(proveedor)
  const verSaldoInicial = verFilaSaldoInicial(
    saldoInicial,
    tab === 'pendientes' ? 'pendientes' : tab === 'pagados' ? 'cerrados' : tab === 'todos' ? 'todos' : 'otra',
    { desde, hasta, filtroDeComprobante: Boolean(tipo || compra || q) },
  )
  const detalle = detalleId ? porId.get(detalleId) : undefined
  const aEditar = editarId ? porId.get(editarId) : undefined
  const aAnular = anularId ? porId.get(anularId) : undefined

  const columnas: ColumnaComprobantes<FacturaCompraSaldo>[] = [
    {
      id: 'fecha',
      header: 'Fecha',
      colClassName: 'w-[6.25rem]',
      td: (c) => ({ className: 'px-3 py-3 text-ink-soft tabular-nums', contenido: formatFechaCorta(c.fecha_comprobante) }),
    },
    {
      id: 'tipo',
      header: 'Tipo',
      colClassName: 'w-[7.5rem]',
      td: (c) => ({
        className: `px-3 py-3 [overflow-wrap:anywhere] ${esNotaCredito(c) ? 'text-success' : 'text-ink'}`,
        contenido: (
          <>
            {TIPO_COMPROBANTE_COMPRA_LABEL[c.tipo_comprobante]}
            {c.letra ? ` ${c.letra}` : ''}
          </>
        ),
      }),
    },
    {
      id: 'numero',
      header: 'Número',
      td: (c) => ({
        className: 'px-3 py-3 [overflow-wrap:anywhere]',
        contenido: (
          <>
            <button
              type="button"
              onClick={(e) => {
                e.stopPropagation()
                setDetalleId(c.id)
              }}
              aria-label={`Ver detalle de ${etiquetaComprobanteCompra(c)}`}
              className="rounded text-left text-ink hover:underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
            >
              {[c.punto_venta, c.numero_comprobante].filter(Boolean).join('-') || 'sin número'}
            </button>
            <ChipTipoCompra tipo={c.tipo_compra} className="ml-2" />
          </>
        ),
      }),
    },
    {
      id: 'total',
      header: 'Total',
      colClassName: 'w-[8rem]',
      thClassName: 'text-right',
      td: (c) => {
        const nc = esNotaCredito(c)
        return {
          className: `px-3 py-3 text-right font-semibold tabular-nums ${nc ? 'text-success' : 'text-ink'}`,
          contenido: (
            <>
              {nc ? negativo(Number(c.total)) : formatCurrency(Number(c.total))}
              <span className="block text-label-md font-normal text-ink-soft">{etiquetaCortaAlicuotaIva(c.iva_alicuota)}</span>
            </>
          ),
        }
      },
    },
    {
      id: 'aplicado',
      header: 'Aplicado',
      colClassName: 'w-[8rem] max-xl:hidden',
      thClassName: 'text-right max-xl:hidden',
      td: (c) => ({
        className: 'px-3 py-3 text-right tabular-nums text-ink-soft max-xl:hidden',
        contenido: formatCurrency(Number(c.total_aplicado)),
      }),
    },
    {
      id: 'saldo',
      header: 'Saldo',
      colClassName: 'w-[8rem]',
      thClassName: 'text-right',
      td: (c) => {
        const nc = esNotaCredito(c)
        return {
          className: `px-3 py-3 text-right font-semibold tabular-nums ${
            nc
              ? Number(c.credito_disponible) > 0 ? 'text-success' : 'text-ink-soft'
              : Number(c.saldo_pendiente) > 0 ? 'text-error' : 'text-ink-soft'
          }`,
          contenido: nc
            ? Number(c.credito_disponible) > 0 ? negativo(Number(c.credito_disponible)) : formatCurrency(0)
            : formatCurrency(Number(c.saldo_pendiente)),
        }
      },
    },
    {
      id: 'estado',
      header: 'Estado',
      colClassName: 'w-[6.5rem]',
      td: (c) => {
        const badge = (esNotaCredito(c) ? ESTADO_BADGE_NC : ESTADO_BADGE)[c.estado]
        return { className: 'px-3 py-3', contenido: <EstadoBadge variant={badge.variant}>{badge.label}</EstadoBadge> }
      },
    },
    {
      id: 'acciones',
      header: <span className="sr-only">Acciones</span>,
      colClassName: 'w-[3rem]',
      td: (c) => {
        const nc = esNotaCredito(c)
        const etiqueta = etiquetaComprobanteCompra(c)
        const acciones: RowActionsMenuItem[] = [
          { label: 'Ver detalle', icon: Eye, onClick: () => setDetalleId(c.id) },
          ...(esSeleccionableParaPago(c) && !nc
            ? [{ label: 'Pagar este comprobante', icon: Wallet, onClick: () => abrirPago({ facturaIds: [c.id], notaCreditoIds: [] }) }]
            : []),
          ...(onCopiar ? [{ label: 'Copiar', icon: Copy, onClick: () => onCopiar(c) }] : []),
          ...(permitirEditarAnular && !c.anulada
            ? [
                { label: 'Editar', icon: Pencil, onClick: () => setEditarId(c.id) },
                { label: 'Anular', icon: Ban, onClick: () => setAnularId(c.id), destructive: true },
              ]
            : []),
        ]
        return {
          className: 'px-3 py-3 text-right',
          detenerClick: true,
          // docs/08 §5.2: menú solo con 2+ acciones; con una sola (ver detalle), la fila ya lo hace.
          contenido: acciones.length >= 2 && <RowActionsMenu ariaLabel={`Acciones para ${etiqueta}`} items={acciones} />,
        }
      },
    },
  ]

  return (
    <CuentaCorrienteLayout
      volverLabel="← Proveedores"
      onVolver={onVolver}
      titulo={proveedor.razon_social}
      datos={[
        { label: 'CUIT', valor: proveedor.cuit || '—' },
        { label: 'Contacto', valor: [proveedor.contacto, proveedor.telefono, proveedor.mail].filter(Boolean).join(' · ') || '—' },
        { label: 'Márgenes', valor: <>{proveedor.margen_1_default}% · {proveedor.margen_2_default}%</> },
      ]}
      accionPrincipal={{ label: 'Registrar pago', onClick: () => abrirPago({ facturaIds: [], notaCreditoIds: [] }) }}
      conSeleccion={seleccion.size > 0}
      debajoCabecera={<ObservacionesProveedor observaciones={proveedor.observaciones} className="mt-stack-md" />}
      kpisClassName={saldoInicial ? 'sm:grid-cols-3 2xl:grid-cols-6' : undefined}
      kpis={
        <>
          <KpiCuenta label="Saldo">
            <span className={saldo > 0 ? 'text-error' : saldo < 0 ? 'text-success' : 'text-accent-darker'}>
              {formatCurrency(saldo)}
            </span>
            {saldo < 0 && <span className="block font-sans text-label-md text-ink-soft">a favor</span>}
          </KpiCuenta>
          {saldoInicial && <KpiSaldoInicial datos={saldoInicial} />}
          <KpiCuenta label="Comprobantes pendientes">
            {formatCurrency(totalPendiente)}
            <span className="block font-sans text-label-md text-ink-soft">
              {plural(pendientes.length, 'comprobante', 'comprobantes')}
            </span>
          </KpiCuenta>
          <KpiCuenta label="Crédito NC disponible">
            <span className={creditoNc > 0 ? 'text-success' : ''}>{formatCurrency(creditoNc)}</span>
          </KpiCuenta>
          <KpiCuenta label="A cuenta (pagos)">
            <span className={aCuenta > 0 ? 'text-success' : ''}>{formatCurrency(aCuenta)}</span>
            <span className="block font-sans text-label-md text-ink-soft">sin comprobante</span>
          </KpiCuenta>
          <KpiCuenta label="Último pago">
            {ultimoPago ? (
              <>
                {formatCurrency(Number(ultimoPago.monto))}
                <span className="block font-sans text-label-md text-ink-soft">
                  {formatFechaCorta(ultimoPago.fecha)} · {etiquetaFormaPago(ultimoPago)}
                </span>
              </>
            ) : (
              <span className="text-ink-soft">—</span>
            )}
          </KpiCuenta>
        </>
      }
      tabs={TABS}
      tab={tab}
      onTab={irATab}
      filtros={
        <>
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
          {tab !== 'pagos' && (
            <div className="w-36">
              <Field label="Compra" compact>
                <select value={compra} onChange={(e) => setParam('compra', e.target.value)} className={selectClass}>
                  <option value="">Todas</option>
                  {TIPOS_COMPRA.map((t) => (
                    <option key={t} value={t}>
                      {TIPO_COMPRA_LABEL[t]}
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
        </>
      }
      hayFiltros={hayFiltros}
      onLimpiarFiltros={limpiarFiltros}
      error={error ? friendlyError(error as Error) : null}
      avisos={
        tab === 'pendientes' &&
        ofrecerAplicar && (
          <div className="mt-stack-md flex flex-wrap items-center justify-between gap-stack-sm rounded-lg border border-accent bg-accent-light px-4 py-3">
            <p className="font-sans text-body-md text-accent-darker">
              Hay <span className="font-semibold tabular-nums">{formatCurrency(aCuenta)}</span> a cuenta
              {seleccionFacturas.length > 0 ? ' · se aplican a los comprobantes seleccionados' : ' · se aplican a los comprobantes más viejos'}
            </p>
            <button
              type="button"
              onClick={() => setAplicar({ facturaIds: seleccionFacturas })}
              className="rounded border border-accent bg-surface px-4 py-2.5 font-sans text-label-bold text-accent-darker transition hover:bg-accent-light focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
            >
              Aplicar a comprobantes
            </button>
          </div>
        )
      }
      aviso={aviso}
      panel={
        tab === 'pagos' ? (
          <TablaPagos
            pagos={pagosVisibles}
            porId={porId}
            aCuentaPorPago={aCuentaQ.data?.porPago}
            saldoInicialPorPago={aCuentaQ.data?.saldoInicialPorPago}
            cargando={pagosQ.isPending || aCuentaQ.isPending}
          />
        ) : (
          <TablaComprobantes
            filaInicial={
              verSaldoInicial
                ? filaSaldoInicial(saldoInicial, {
                    columnaTipo: 'tipo',
                    columnaTexto: 'numero',
                    columnaCancelado: 'aplicado',
                    textoCancelado: 'Cancelado con pagos sin comprobante',
                  })
                : null
            }
            filas={visibles}
            columnas={columnas}
            getId={idDe}
            esSeleccionable={esSeleccionableParaPago}
            etiquetaFila={etiquetaComprobanteCompra}
            seleccion={seleccion}
            onToggle={toggle}
            onToggleVisibles={toggleVisibles}
            onAbrir={(c) => setDetalleId(c.id)}
            claseFila={(c) => (tab === 'todos' && cerrada(c) ? 'opacity-60' : '')}
            cargando={comprobantesQ.isPending}
            vacio={
              hayFiltros
                ? 'Ningún comprobante coincide con los filtros.'
                : tab === 'pendientes'
                  ? 'No hay comprobantes pendientes ni notas de crédito con saldo.'
                  : tab === 'pagados'
                    ? 'Todavía no hay comprobantes pagados.'
                    : 'Este proveedor no tiene comprobantes cargados.'
            }
          />
        )
      }
      barraSeleccion={
        seleccion.size > 0
          ? {
              resumen: resumenSeleccion,
              accionLabel: 'Pagar',
              onAccion: () => abrirPago({ facturaIds: seleccionFacturas, notaCreditoIds: seleccionNotas }),
              onQuitar: () => setSeleccion(new Set()),
            }
          : null
      }
    >
      {pago && (
        <PagarProveedorModal
          supabase={supabase}
          proveedorId={proveedorId}
          proveedorNombre={nombre}
          comprobantes={comprobantes}
          facturaIds={pago.facturaIds}
          notaCreditoIds={pago.notaCreditoIds}
          origen={origen}
          aCuenta={aCuenta}
          saldoInicialPendiente={saldoInicial ? Math.max(saldoInicial.pendiente, 0) : 0}
          onAplicarACuenta={
            ofrecerAplicar
              ? () => {
                  setAplicar({ facturaIds: pago?.facturaIds ?? [] })
                  setPago(null)
                }
              : undefined
          }
          onClose={() => setPago(null)}
          onPagado={() => {
            setPago(null)
            setSeleccion(new Set())
            setAviso('Pago registrado.')
          }}
        />
      )}

      {aplicar && (
        <AplicarACuentaModal
          supabase={supabase}
          proveedorId={proveedorId}
          proveedorNombre={nombre}
          comprobantes={comprobantes}
          facturaIds={aplicar.facturaIds}
          aCuenta={aCuenta}
          onClose={() => setAplicar(null)}
          onAplicado={(r) => {
            setAplicar(null)
            setSeleccion(new Set())
            setAviso(
              `Se aplicaron ${formatCurrency(Number(r.aplicado))} de pagos a cuenta.` +
                (Number(r.a_cuenta_restante) > 0 ? ` Siguen a cuenta ${formatCurrency(Number(r.a_cuenta_restante))}.` : ''),
            )
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
    </CuentaCorrienteLayout>
  )
}

function TablaPagos({
  pagos,
  porId,
  aCuentaPorPago,
  saldoInicialPorPago,
  cargando,
}: {
  pagos: PagoProveedorConDetalle[]
  porId: Map<string, FacturaCompraSaldo>
  aCuentaPorPago: Map<string, number> | undefined // vista pagos_proveedor_a_cuenta (docs/52), ya sin lo del saldo inicial
  saldoInicialPorPago?: Map<string, number> // docs/69: parte de cada pago que cancela el saldo inicial
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
          const aCuenta = aCuentaPorPago?.get(p.id) ?? 0
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
                {/* docs/71: el ajuste cancela además de la plata (no es plata). */}
                {Number(p.ajuste_redondeo) !== 0 && (
                  <span className="block font-normal text-label-md text-ink-soft">
                    ajuste {formatAjuste(Number(p.ajuste_redondeo))}
                  </span>
                )}
              </td>
              <td className="px-3 py-3 text-ink [overflow-wrap:anywhere]">
                {p.forma_pago === null ? (
                  AJUSTE_REDONDEO_LABEL
                ) : monto === 0 ? (
                  'Solo crédito NC'
                ) : p.forma_pago === 'mixto' ? (
                  <FormaPagoConDetalle pago={p} />
                ) : (
                  <>
                    {FORMA_PAGO_CABECERA_LABEL[p.forma_pago]}
                    {p.cheque_numero && <span className="block text-ink-soft">N° {p.cheque_numero}</span>}
                  </>
                )}
              </td>
              <td className="px-3 py-3 text-ink-soft [overflow-wrap:anywhere]">
                {p.usuario_nombre ?? '—'}
                {/* docs/57: de qué caja salió la plata (su egreso). */}
                {p.origen && <span className="block">{CAJA_ORIGEN_LABEL[p.origen]}</span>}
              </td>
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
                    {(saldoInicialPorPago?.get(p.id) ?? 0) > 0 && (
                      <li className="text-ink">
                        Saldo inicial · <span className="tabular-nums">{formatCurrency(saldoInicialPorPago!.get(p.id)!)}</span>
                      </li>
                    )}
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
