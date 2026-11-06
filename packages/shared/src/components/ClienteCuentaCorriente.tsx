import { useEffect, useMemo, useState, type ComponentType } from 'react'
import { Eye, Wallet } from 'lucide-react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { EstadoCuentaVenta, OrigenEgreso, VentaCuentaCorrienteSaldo } from '../../types/database'
import { CAJA_ORIGEN_LABEL } from '../../lib/facturasCompra'
import {
  CONDICION_IVA_LABEL,
  datosComprobanteVenta,
  etiquetaVenta,
  nombreCliente,
  useAplicarCobrosACuenta,
  useCliente,
  useCobrosACuenta,
  useCobrosCliente,
  useComprobantesCliente,
  type CobroClienteConDetalle,
} from '../../lib/cuentaCorrienteCliente'
import { esCobrable, simularRepartoCobro } from '../../lib/repartoPagoProveedor'
import { FORMA_PAGO_LABEL, type DatosComprobante } from '../../lib/comprobante'
import { fechaLocalDeISO, formatCurrency, formatFechaCorta, formatFechaCortaLocal } from '../../lib/format'
import { friendlyError } from '../../lib/supabaseErrors'
import { Field, inputClass } from './FormField'
import { EstadoBadge } from './EstadoBadge'
import { RowActionsMenu, type RowActionsMenuItem } from './RowActionsMenu'
import { CobrarClienteModal } from './CobrarClienteModal'
import { AplicarACuentaModalBase, destinoAplicacion } from './AplicarACuentaModal'
import type { ComprobanteModalProps } from './ComprobanteModal'
import {
  CuentaCorrienteLayout,
  KpiCuenta,
  TablaComprobantes,
  useParamsCuentaCorriente,
  useSeleccion,
  type ColumnaComprobantes,
} from './CuentaCorrienteLayout'

type Props = {
  supabase: SupabaseClient
  clienteId: string
  // 'turno' en Local (el cobro entra al Cierre del día), 'general' en Gestión (va a la cuenta).
  origen: OrigenEgreso
  onVolver: () => void
  // Detalle de un comprobante: cada app enchufa su ComprobanteModal (Local abre links con Tauri).
  ComprobanteModal: ComponentType<ComprobanteModalProps>
}

const TABS = [
  { id: 'pendientes', label: 'Pendientes' },
  { id: 'cobrados', label: 'Cobrados' },
  { id: 'todos', label: 'Todos' },
  { id: 'cobros', label: 'Cobros' },
] as const
const FILTROS = ['desde', 'hasta', 'q'] as const

const ESTADO_BADGE: Record<EstadoCuentaVenta, { label: string; variant: 'amber' | 'green' | 'red' | 'neutral' | 'violet' }> = {
  pendiente: { label: 'Pendiente', variant: 'amber' },
  parcial: { label: 'Parcial', variant: 'amber' },
  pagada: { label: 'Cobrada', variant: 'green' },
  a_revisar: { label: 'Consumo interno', variant: 'violet' },
  finalizado: { label: 'Finalizado', variant: 'neutral' },
  anulada: { label: 'Anulada', variant: 'red' },
}
const ABIERTOS: EstadoCuentaVenta[] = ['pendiente', 'parcial', 'a_revisar']
const abierta = (v: VentaCuentaCorrienteSaldo) => ABIERTOS.includes(v.estado_cuenta)
const idDe = (v: VentaCuentaCorrienteSaldo) => v.id
const plural = (n: number, uno: string, varios: string) => `${n} ${n === 1 ? uno : varios}`

// Cuenta corriente de un cliente (docs/68): misma pantalla que proveedores (CuentaCorrienteLayout)
// pero para cobrar. Comprobantes con saldo y estado, selección de uno o varios para cobrar, cobros
// con varios medios y lo que cubrió cada uno, cobros a cuenta. Las ventas internas (dueñas y
// empleados) se ven pero no se cobran: se finalizan en Gestión.
export function ClienteCuentaCorriente({ supabase, clienteId, origen, onVolver, ComprobanteModal }: Props) {
  const clienteQ = useCliente(supabase, clienteId)
  const comprobantesQ = useComprobantesCliente(supabase, clienteId)
  const cobrosQ = useCobrosCliente(supabase, clienteId)
  const aCuentaQ = useCobrosACuenta(supabase, clienteId)
  const aplicarMutation = useAplicarCobrosACuenta(supabase)

  const cliente = clienteQ.data
  const comprobantes = useMemo(() => comprobantesQ.data ?? [], [comprobantesQ.data])
  const cobros = useMemo(() => cobrosQ.data ?? [], [cobrosQ.data])
  const porId = useMemo(() => new Map(comprobantes.map((c) => [c.id, c])), [comprobantes])

  const { tab, irATab, valores, hayFiltros, setParam, limpiarFiltros } = useParamsCuentaCorriente(TABS, FILTROS)
  const { desde, hasta, q } = valores

  const { seleccion, setSeleccion, toggle } = useSeleccion(comprobantes, idDe, esCobrable)
  const seleccionIds = useMemo(() => [...seleccion], [seleccion])
  const aCobrarSeleccion = useMemo(
    () => simularRepartoCobro({ ventas: comprobantes, ventaIds: seleccionIds, monto: 0 }).restanteTrasNotas,
    [comprobantes, seleccionIds],
  )

  const [cobro, setCobro] = useState<{ ventaIds: string[] } | null>(null)
  const [aplicar, setAplicar] = useState<{ ventaIds: string[] } | null>(null)
  const [detalle, setDetalle] = useState<DatosComprobante | null>(null)
  const [errorDetalle, setErrorDetalle] = useState<string | null>(null)
  const [aviso, setAviso] = useState('')
  useEffect(() => {
    if (cobro || aplicar) setAviso('')
  }, [cobro, aplicar])

  async function abrirDetalle(v: VentaCuentaCorrienteSaldo) {
    if (!cliente) return
    setErrorDetalle(null)
    try {
      setDetalle(await datosComprobanteVenta(supabase, v.id, cliente))
    } catch (err) {
      setErrorDetalle(friendlyError(err as Error))
    }
  }

  // ── Comprobantes de la pestaña, con filtros (fecha = día argentino de la venta) ──
  const visibles = useMemo(() => {
    const texto = q.trim()
    const filtrados = comprobantes.filter((c) => {
      const dia = fechaLocalDeISO(c.created_at)
      return (!desde || dia >= desde) && (!hasta || dia <= hasta) && (!texto || String(c.numero).includes(texto))
    })
    const porFechaDesc = (a: VentaCuentaCorrienteSaldo, b: VentaCuentaCorrienteSaldo) => b.created_at.localeCompare(a.created_at)
    if (tab === 'pendientes') {
      // Más viejos primero: es el orden en que se aplica un cobro sin selección.
      return filtrados.filter(abierta).sort((a, b) => -porFechaDesc(a, b))
    }
    if (tab === 'cobrados') {
      return filtrados.filter((c) => c.estado_cuenta === 'pagada' || c.estado_cuenta === 'finalizado').sort(porFechaDesc)
    }
    return filtrados.sort((a, b) => Number(!abierta(a)) - Number(!abierta(b)) || porFechaDesc(a, b))
  }, [comprobantes, tab, desde, hasta, q])

  const cobrosVisibles = useMemo(
    () => cobros.filter((p) => (!desde || p.fecha >= desde) && (!hasta || p.fecha <= hasta)),
    [cobros, desde, hasta],
  )

  // ── KPIs ──
  const pendientes = comprobantes.filter(esCobrable)
  const aCuenta = aCuentaQ.data?.total ?? 0
  const ofrecerAplicar = aCuenta > 0 && pendientes.length > 0
  const ultimoCobro = cobros.find((p) => Number(p.monto) > 0 && !p.revierte_pago_cliente_id && !p.revertido)

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

  const error = clienteQ.error ?? comprobantesQ.error ?? cobrosQ.error ?? aCuentaQ.error

  if (clienteQ.isPending) {
    return <p className="p-card font-sans text-body-md text-ink-soft">Cargando cliente...</p>
  }
  if (!cliente) {
    return (
      <section className="flex flex-col gap-stack-md rounded-lg bg-surface p-card shadow-sm">
        <p className="font-sans text-body-md text-ink">
          {clienteQ.error ? friendlyError(clienteQ.error as Error) : 'No se encontró el cliente.'}
        </p>
        <button type="button" onClick={onVolver} className="self-start font-sans text-label-bold text-accent-dark hover:underline">
          ← Volver a Cuentas corrientes
        </button>
      </section>
    )
  }

  const nombre = nombreCliente(cliente)
  const saldo = Number(cliente.saldo_actual)
  const consumoInterno = Number(cliente.consumo_interno_pendiente)

  const columnas: ColumnaComprobantes<VentaCuentaCorrienteSaldo>[] = [
    {
      id: 'fecha',
      header: 'Fecha',
      colClassName: 'w-[6.25rem]',
      td: (c) => ({ className: 'px-3 py-3 text-ink-soft tabular-nums', contenido: formatFechaCortaLocal(c.created_at) }),
    },
    {
      id: 'numero',
      header: 'Comprobante',
      td: (c) => ({
        className: 'px-3 py-3 [overflow-wrap:anywhere]',
        contenido: (
          <>
            <button
              type="button"
              onClick={(e) => {
                e.stopPropagation()
                void abrirDetalle(c)
              }}
              aria-label={`Ver detalle de ${etiquetaVenta(c)}`}
              className="rounded text-left text-ink hover:underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
            >
              {etiquetaVenta(c)}
            </button>
            {c.estado === 'facturado' && <span className="ml-2 font-sans text-label-md text-ink-soft">Factura C</span>}
            {c.nota && <span className="block text-label-md text-ink-soft">“{c.nota}”</span>}
          </>
        ),
      }),
    },
    {
      id: 'total',
      header: 'Total',
      colClassName: 'w-[8rem]',
      thClassName: 'text-right',
      td: (c) => ({ className: 'px-3 py-3 text-right font-semibold tabular-nums text-ink', contenido: formatCurrency(Number(c.total)) }),
    },
    {
      id: 'cobrado',
      header: 'Cobrado',
      colClassName: 'w-[8rem] max-xl:hidden',
      thClassName: 'text-right max-xl:hidden',
      td: (c) => ({
        className: 'px-3 py-3 text-right tabular-nums text-ink-soft max-xl:hidden',
        contenido: (
          <>
            {formatCurrency(Number(c.total_aplicado))}
            {Number(c.total_devuelto) !== 0 && (
              <span className="block text-label-md">devuelto {formatCurrency(Number(c.total_devuelto))}</span>
            )}
          </>
        ),
      }),
    },
    {
      id: 'saldo',
      header: 'Saldo',
      colClassName: 'w-[8rem]',
      thClassName: 'text-right',
      td: (c) => ({
        className: `px-3 py-3 text-right font-semibold tabular-nums ${Number(c.saldo_pendiente) > 0 ? 'text-error' : 'text-ink-soft'}`,
        contenido: formatCurrency(Number(c.saldo_pendiente)),
      }),
    },
    {
      id: 'estado',
      header: 'Estado',
      colClassName: 'w-[8.5rem]',
      td: (c) => {
        const badge = ESTADO_BADGE[c.estado_cuenta]
        return { className: 'px-3 py-3', contenido: <EstadoBadge variant={badge.variant}>{badge.label}</EstadoBadge> }
      },
    },
    {
      id: 'acciones',
      header: <span className="sr-only">Acciones</span>,
      colClassName: 'w-[3rem]',
      td: (c) => {
        const acciones: RowActionsMenuItem[] = [
          { label: 'Ver detalle', icon: Eye, onClick: () => void abrirDetalle(c) },
          ...(esCobrable(c) ? [{ label: 'Cobrar este comprobante', icon: Wallet, onClick: () => setCobro({ ventaIds: [c.id] }) }] : []),
        ]
        return {
          className: 'px-3 py-3 text-right',
          detenerClick: true,
          // docs/08 §5.2: menú solo con 2+ acciones; con una sola (ver detalle), la fila ya lo hace.
          contenido: acciones.length >= 2 && <RowActionsMenu ariaLabel={`Acciones para ${etiquetaVenta(c)}`} items={acciones} />,
        }
      },
    },
  ]

  const reparto = aplicar ? simularRepartoCobro({ ventas: comprobantes, ventaIds: aplicar.ventaIds, monto: aCuenta }) : null

  return (
    <CuentaCorrienteLayout
      volverLabel="← Cuentas corrientes"
      onVolver={onVolver}
      titulo={nombre}
      datos={[
        { label: 'CUIT', valor: cliente.cuit || '—' },
        { label: 'Contacto', valor: [cliente.celular, cliente.mail].filter(Boolean).join(' · ') || '—' },
        { label: 'IVA', valor: CONDICION_IVA_LABEL[cliente.condicion_iva] },
        ...(cliente.tipo === 'interno' ? [{ label: 'Cuenta', valor: 'Interna (dueña o empleado)' }] : []),
      ]}
      accionPrincipal={{
        label: 'Registrar cobro',
        onClick: () => setCobro({ ventaIds: [] }),
        motivoDeshabilitada:
          Number(cliente.saldo_cobrable) > 0
            ? undefined
            : consumoInterno > 0
              ? 'Solo tiene consumo interno: no se cobra, se finaliza en Gestión.'
              : 'No tiene saldo a cobrar.',
      }}
      conSeleccion={seleccion.size > 0}
      kpisClassName="lg:grid-cols-4"
      kpis={
        <>
          <KpiCuenta label="Saldo">
            <span className={saldo > 0 ? 'text-error' : saldo < 0 ? 'text-success' : 'text-accent-darker'}>{formatCurrency(saldo)}</span>
            {saldo < 0 && <span className="block font-sans text-label-md text-ink-soft">a favor</span>}
            {consumoInterno > 0 && (
              <span className="block font-sans text-label-md text-ink-soft">incluye {formatCurrency(consumoInterno)} de consumo interno</span>
            )}
          </KpiCuenta>
          <KpiCuenta label="Comprobantes pendientes">
            {formatCurrency(Number(cliente.deuda_comprobantes))}
            <span className="block font-sans text-label-md text-ink-soft">{plural(pendientes.length, 'comprobante', 'comprobantes')}</span>
          </KpiCuenta>
          <KpiCuenta label="A cuenta (cobros)">
            <span className={aCuenta > 0 ? 'text-success' : ''}>{formatCurrency(aCuenta)}</span>
            <span className="block font-sans text-label-md text-ink-soft">sin comprobante</span>
          </KpiCuenta>
          <KpiCuenta label="Último cobro">
            {ultimoCobro ? (
              <>
                {formatCurrency(Number(ultimoCobro.monto))}
                <span className="block font-sans text-label-md text-ink-soft">
                  {formatFechaCorta(ultimoCobro.fecha)} · {FORMA_PAGO_LABEL[ultimoCobro.forma_pago]}
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
          {tab !== 'cobros' && (
            <div className="w-48">
              <Field label="Número" compact>
                <input
                  type="search"
                  inputMode="numeric"
                  value={q}
                  onChange={(e) => setParam('q', e.target.value.replace(/\D/g, ''))}
                  placeholder="N° de venta"
                  className={inputClass}
                />
              </Field>
            </div>
          )}
        </>
      }
      hayFiltros={hayFiltros}
      onLimpiarFiltros={limpiarFiltros}
      error={error ? friendlyError(error as Error) : errorDetalle}
      avisos={
        tab === 'pendientes' &&
        ofrecerAplicar && (
          <div className="mt-stack-md flex flex-wrap items-center justify-between gap-stack-sm rounded-lg border border-accent bg-accent-light px-4 py-3">
            <p className="font-sans text-body-md text-accent-darker">
              Hay <span className="font-semibold tabular-nums">{formatCurrency(aCuenta)}</span> a cuenta
              {seleccion.size > 0 ? ' · se aplican a los comprobantes seleccionados' : ' · se aplican a los comprobantes más viejos'}
            </p>
            <button
              type="button"
              onClick={() => setAplicar({ ventaIds: seleccionIds })}
              className="rounded border border-accent bg-surface px-4 py-2.5 font-sans text-label-bold text-accent-darker transition hover:bg-accent-light focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
            >
              Aplicar a comprobantes
            </button>
          </div>
        )
      }
      aviso={aviso}
      panel={
        tab === 'cobros' ? (
          <TablaCobros cobros={cobrosVisibles} porId={porId} aCuentaPorPago={aCuentaQ.data?.porPago} cargando={cobrosQ.isPending || aCuentaQ.isPending} />
        ) : (
          <TablaComprobantes
            filas={visibles}
            columnas={columnas}
            getId={idDe}
            esSeleccionable={esCobrable}
            etiquetaFila={etiquetaVenta}
            seleccion={seleccion}
            onToggle={toggle}
            onToggleVisibles={toggleVisibles}
            onAbrir={(c) => void abrirDetalle(c)}
            claseFila={(c) => (tab === 'todos' && !abierta(c) ? 'opacity-60' : '')}
            cargando={comprobantesQ.isPending}
            vacio={
              hayFiltros
                ? 'Ningún comprobante coincide con los filtros.'
                : tab === 'pendientes'
                  ? 'No hay comprobantes pendientes.'
                  : tab === 'cobrados'
                    ? 'Todavía no hay comprobantes cobrados.'
                    : 'Este cliente no tiene ventas a cuenta corriente.'
            }
          />
        )
      }
      barraSeleccion={
        seleccion.size > 0
          ? {
              resumen: `${plural(seleccion.size, 'comprobante', 'comprobantes')} · A cobrar ${formatCurrency(aCobrarSeleccion)}`,
              accionLabel: 'Cobrar',
              onAccion: () => setCobro({ ventaIds: seleccionIds }),
              onQuitar: () => setSeleccion(new Set()),
            }
          : null
      }
    >
      {cobro && (
        <CobrarClienteModal
          supabase={supabase}
          cliente={cliente}
          comprobantes={comprobantes}
          ventaIds={cobro.ventaIds}
          origen={origen}
          aCuenta={aCuenta}
          onAplicarACuenta={
            ofrecerAplicar
              ? () => {
                  setAplicar({ ventaIds: cobro?.ventaIds ?? [] })
                  setCobro(null)
                }
              : undefined
          }
          onClose={() => setCobro(null)}
          onCobrado={(r) => {
            setCobro(null)
            setSeleccion(new Set())
            setAviso(
              `Cobro registrado: ${formatCurrency(Number(r.monto))}.` +
                (Number(r.a_cuenta) > 0 ? ` Quedan ${formatCurrency(Number(r.a_cuenta))} a cuenta.` : ''),
            )
          }}
        />
      )}

      {aplicar && reparto && (
        <AplicarACuentaModalBase
          titulo="Aplicar cobros a cuenta"
          cancelarLabel="Cancelar"
          contraparte={{ label: 'Cliente', nombre }}
          aviso={
            <>
              Este cliente tiene <span className="font-semibold tabular-nums">{formatCurrency(aCuenta)}</span> a cuenta (cobros sin
              comprobante). Se aplican los cobros más viejos primero{destinoAplicacion(aplicar.ventaIds.length)}. No entra plata: no
              cambia la caja.
            </>
          }
          reparto={reparto}
          etiqueta={(id) => (porId.get(id) ? etiquetaVenta(porId.get(id)!) : 'Comprobante')}
          sigueACuentaTexto="Sigue a cuenta del cliente"
          accionError="aplicar los cobros a cuenta"
          aplicando={aplicarMutation.isPending}
          onAplicar={async () => {
            const r = await aplicarMutation.mutateAsync({ clienteId, ventaIds: aplicar.ventaIds })
            setAplicar(null)
            setSeleccion(new Set())
            setAviso(
              `Se aplicaron ${formatCurrency(Number(r.aplicado))} de cobros a cuenta.` +
                (Number(r.a_cuenta_restante) > 0 ? ` Siguen a cuenta ${formatCurrency(Number(r.a_cuenta_restante))}.` : ''),
            )
          }}
          onClose={() => setAplicar(null)}
        />
      )}

      {detalle && (
        <ComprobanteModal
          datos={detalle}
          onClose={() => setDetalle(null)}
        />
      )}
    </CuentaCorrienteLayout>
  )
}

function TablaCobros({
  cobros,
  porId,
  aCuentaPorPago,
  cargando,
}: {
  cobros: CobroClienteConDetalle[]
  porId: Map<string, VentaCuentaCorrienteSaldo>
  aCuentaPorPago: Map<string, number> | undefined
  cargando: boolean
}) {
  return (
    <table className="w-full table-fixed text-left font-sans text-table-row max-xl:[&_td]:px-2 max-xl:[&_th]:px-2">
      <colgroup>
        <col className="w-[6.25rem]" />
        <col className="w-[8rem]" />
        <col className="w-[11rem]" />
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
        {!cargando && cobros.length === 0 && (
          <tr>
            <td colSpan={5} className="px-4 py-4 text-ink-soft">No hay cobros registrados en este período.</td>
          </tr>
        )}
        {cobros.map((p) => {
          const monto = Number(p.monto)
          const esReversion = Boolean(p.revierte_pago_cliente_id)
          const aCuenta = aCuentaPorPago?.get(p.id) ?? 0
          return (
            <tr
              key={p.id}
              className={`border-b border-table-divider align-top last:border-0 even:bg-table-row-alt ${esReversion || p.revertido ? 'opacity-60' : ''}`}
            >
              <td className="px-3 py-3 text-ink-soft tabular-nums">{formatFechaCorta(p.fecha)}</td>
              <td className={`px-3 py-3 text-right font-semibold tabular-nums ${monto < 0 ? 'text-error' : 'text-ink'}`}>
                {monto < 0 ? `−${formatCurrency(Math.abs(monto))}` : formatCurrency(monto)}
              </td>
              <td className="px-3 py-3 text-ink [overflow-wrap:anywhere]">
                {p.medios.length > 1 ? (
                  <ul className="flex flex-col gap-0.5">
                    {p.medios.map((m) => (
                      <li key={m.id}>
                        {FORMA_PAGO_LABEL[m.forma_pago]} · <span className="tabular-nums">{formatCurrency(Math.abs(Number(m.monto)))}</span>
                      </li>
                    ))}
                  </ul>
                ) : (
                  FORMA_PAGO_LABEL[p.medios[0]?.forma_pago ?? p.forma_pago]
                )}
              </td>
              <td className="px-3 py-3 text-ink-soft [overflow-wrap:anywhere]">
                {p.usuario_nombre ?? '—'}
                <span className="block">{CAJA_ORIGEN_LABEL[p.origen]}</span>
              </td>
              <td className="px-3 py-3 [overflow-wrap:anywhere]">
                {esReversion ? (
                  <span className="text-ink-soft">Reversión de un cobro (Historial)</span>
                ) : (
                  <ul className="flex flex-col gap-0.5">
                    {p.revertido && (
                      <li>
                        <EstadoBadge variant="red">Revertido</EstadoBadge>
                      </li>
                    )}
                    {p.aplicaciones.map((a) => {
                      const venta = porId.get(a.venta_id)
                      return (
                        <li key={a.id} className={a.revertida_at ? 'text-ink-soft line-through' : 'text-ink'}>
                          {venta ? etiquetaVenta(venta) : 'Comprobante'} · <span className="tabular-nums">{formatCurrency(Number(a.monto))}</span>
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
