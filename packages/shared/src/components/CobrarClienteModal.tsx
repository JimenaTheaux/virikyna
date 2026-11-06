import { useId, useMemo, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { ClienteSaldo, FormaPagoCobro, OrigenEgreso, VentaCuentaCorrienteSaldo } from '../../types/database'
import { CAJA_ORIGEN_LABEL, ErrorRegistrarPago } from '../../lib/facturasCompra'
import {
  etiquetaVenta,
  nombreCliente,
  OPCIONES_MEDIO_COBRO,
  useRegistrarCobroCliente,
  type RegistrarCobroClienteResultado,
} from '../../lib/cuentaCorrienteCliente'
import { diferenciaMedios, validarMedios } from '../../lib/mediosPago'
import { simularRepartoCobro } from '../../lib/repartoPagoProveedor'
import { MediosPagoEditor, ResumenMedios, useMediosPago } from './MediosPagoEditor'
import { fechaHoyISO, formatCurrency, formatFechaCorta, formatFechaCortaLocal } from '../../lib/format'
import { friendlyError, mensajeErrorGuardado } from '../../lib/supabaseErrors'
import { Modal } from './Modal'
import { ConfirmDialog } from './ConfirmDialog'
import { Field, ErrorText, inputClass } from './FormField'
import { EstadoBadge } from './EstadoBadge'

type Props = {
  supabase: SupabaseClient
  cliente: ClienteSaldo
  comprobantes: VentaCuentaCorrienteSaldo[] // todos los del cliente: la vista previa necesita los pendientes
  ventaIds: string[] // vacío = se aplica a los más viejos
  origen: OrigenEgreso // Local → turno; Gestión → general
  aCuenta?: number // cobros sin comprobante, para avisar antes de cobrar de nuevo
  onAplicarACuenta?: () => void
  onClose: () => void
  onCobrado: (resultado: RegistrarCobroClienteResultado) => void
}

const montoTexto = (n: number) => (Math.round(n * 100) / 100).toFixed(2).replace(/\.00$/, '')

// Cobro de cuenta corriente a un cliente (docs/68): uno o varios comprobantes, uno o varios medios
// (efectivo, transferencia, QR, débito, crédito; sin cheques). La vista previa sale de
// simularRepartoCobro (espejo de registrar_cobro_cliente); la escritura es una sola llamada al RPC,
// que vuelve a validar todo. Desde Local el cobro entra al Cierre del día (turno); desde Gestión,
// directo a la cuenta de cada medio (general).
export function CobrarClienteModal({
  supabase,
  cliente,
  comprobantes,
  ventaIds,
  origen,
  aCuenta = 0,
  onAplicarACuenta,
  onClose,
  onCobrado,
}: Props) {
  const conSeleccion = ventaIds.length > 0
  const porId = useMemo(() => new Map(comprobantes.map((c) => [c.id, c])), [comprobantes])
  const maximo = Math.max(0, Number(cliente.saldo_cobrable))

  // Monto precargado: lo que deben los elegidos, o todo lo pendiente (sin pasar el tope del RPC).
  const aCobrar = useMemo(
    () => simularRepartoCobro({ ventas: comprobantes, ventaIds, monto: 0 }).restanteTrasNotas,
    [comprobantes, ventaIds],
  )

  const [monto, setMonto] = useState(montoTexto(Math.min(aCobrar, maximo)))
  const [fecha, setFecha] = useState(fechaHoyISO())
  const [nota, setNota] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [dirty, setDirty] = useState(false)
  const [confirmCerrar, setConfirmCerrar] = useState(false)
  const formId = useId()
  const avisoId = useId()

  const mutation = useRegistrarCobroCliente(supabase)
  const { medios, cambiar: cambiarMedios } = useMediosPago<FormaPagoCobro>(monto, 'efectivo')
  const montoNum = monto.trim() === '' ? NaN : Number(monto)
  const mediosNoCierran = Number.isFinite(montoNum) && diferenciaMedios(montoNum, medios).estado !== 'cierra'
  const superaMaximo = Number.isFinite(montoNum) && Math.round(montoNum * 100) > Math.round(maximo * 100)

  const reparto = useMemo(
    () => simularRepartoCobro({ ventas: comprobantes, ventaIds, monto: Number.isFinite(montoNum) ? montoNum : 0 }),
    [comprobantes, ventaIds, montoNum],
  )
  const filasPreview = useMemo(
    () =>
      reparto.aplicaciones.map((a) => ({
        venta: porId.get(a.comprobanteId)!,
        aplica: a.monto,
        saldoFinal: reparto.saldoFinal.get(a.comprobanteId) ?? 0,
      })),
    [reparto, porId],
  )

  function pedirCierre() {
    if (dirty) setConfirmCerrar(true)
    else onClose()
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    const invalido =
      !Number.isFinite(montoNum) || montoNum <= 0
        ? 'Ingresá un monto mayor a cero.'
        : superaMaximo
          ? `El cobro supera lo que debe el cliente (${formatCurrency(maximo)}).`
          : validarMedios(medios, montoNum)
    if (invalido) {
      setError(invalido)
      return
    }
    if (origen === 'general' && !fecha) {
      setError('Ingresá la fecha del cobro.')
      return
    }
    try {
      const resultado = await mutation.mutateAsync({
        clienteId: cliente.id,
        monto: montoNum,
        medios,
        ventaIds,
        origen,
        fecha,
        nota,
      })
      onCobrado(resultado)
    } catch (err) {
      setError(
        err instanceof ErrorRegistrarPago
          ? mensajeErrorGuardado(err.causa, err.status, 'registrar el cobro', 'los datos siguen acá')
          : friendlyError(err as Error),
      )
    }
  }

  return (
    <Modal
      title="Registrar cobro"
      onClose={pedirCierre}
      widthClassName="max-w-[720px]"
      cambiosSinGuardar={dirty}
      footer={
        <div className="flex items-center justify-end gap-3">
          <ResumenMedios medios={medios} total={montoNum} className="mr-auto" />
          <button type="button" onClick={pedirCierre} className="rounded px-4 py-3 font-sans text-label-bold text-ink-soft hover:bg-bg">
            Cancelar
          </button>
          <button
            type="submit"
            form={formId}
            disabled={mutation.isPending || mediosNoCierran || superaMaximo}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
          >
            {mutation.isPending ? 'Guardando...' : 'Registrar cobro'}
          </button>
        </div>
      }
    >
      <form id={formId} onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        <p className="font-sans text-body-md text-ink-soft">
          Cliente: <span className="text-ink">{nombreCliente(cliente)}</span>
          <span className="mx-2" aria-hidden="true">·</span>
          Entra en: <span className="text-ink">{CAJA_ORIGEN_LABEL[origen]}</span>
        </p>

        {aCuenta > 0 && (
          <div
            role="note"
            className="flex flex-wrap items-center justify-between gap-stack-sm rounded border border-accent bg-accent-light px-4 py-3"
          >
            <p className="font-sans text-body-md text-accent-darker">
              Este cliente tiene <span className="font-semibold tabular-nums">{formatCurrency(aCuenta)}</span> a cuenta (cobros
              sin comprobante). Antes de cobrar de nuevo, revisá si corresponde aplicarlos.
            </p>
            {onAplicarACuenta && (
              <button
                type="button"
                onClick={onAplicarACuenta}
                className="rounded border border-accent bg-surface px-3 py-2 font-sans text-label-bold text-accent-darker transition hover:bg-accent-light"
              >
                Aplicar a cuenta
              </button>
            )}
          </div>
        )}

        {!conSeleccion && (
          <p id={avisoId} className="rounded bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">
            Se aplica a los comprobantes más antiguos. Lo que sobre queda a cuenta del cliente.
          </p>
        )}

        <div className="grid grid-cols-2 gap-stack-sm">
          <Field
            label="Total del cobro"
            hint={
              conSeleccion
                ? `A cobrar: ${formatCurrency(aCobrar)} — si cobrás más, lo que sobre queda a cuenta (máx. ${formatCurrency(maximo)})`
                : `Debe en total ${formatCurrency(maximo)}`
            }
          >
            <input
              type="number"
              step="0.01"
              min={0}
              data-autofocus
              value={monto}
              onChange={(e) => setMonto(e.target.value)}
              aria-describedby={!conSeleccion ? avisoId : undefined}
              className={`${inputClass} text-right tabular-nums`}
            />
          </Field>
          {origen === 'general' ? (
            <Field label="Fecha del cobro">
              <input type="date" value={fecha} max={fechaHoyISO()} onChange={(e) => setFecha(e.target.value)} className={inputClass} />
            </Field>
          ) : (
            <div className="flex flex-col gap-2">
              <span className="font-sans text-label-md text-ink">Fecha del cobro</span>
              <p className="rounded border border-line bg-bg px-4 py-2.5 font-sans text-body-md text-ink">
                Hoy, {formatFechaCorta(fechaHoyISO())}
              </p>
              <span className="font-sans text-label-md text-ink-soft">Desde la caja de Local el cobro es de hoy y entra al cierre del día.</span>
            </div>
          )}
        </div>

        <MediosPagoEditor<FormaPagoCobro>
          medios={medios}
          onChange={cambiarMedios}
          total={montoNum}
          fechaPago={fecha}
          conResumen={false}
          opciones={OPCIONES_MEDIO_COBRO}
          conCheques={false}
          titulo="Medios de cobro"
        />

        <Field label="Nota (opcional)">
          <input value={nota} onChange={(e) => setNota(e.target.value)} maxLength={200} className={inputClass} />
        </Field>

        <section aria-labelledby={`${formId}-preview`}>
          <h3 id={`${formId}-preview`} className="font-sans text-label-bold text-ink-soft">
            Cómo se reparte
          </h3>
          <div className="mt-2 overflow-hidden rounded-xl shadow-sm">
            <table className="w-full table-fixed text-left font-sans text-table-row">
              <colgroup>
                <col />
                <col className="w-[8.5rem]" />
                <col className="w-[8.5rem]" />
                <col className="w-[6.5rem]" />
              </colgroup>
              <thead>
                <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
                  <th scope="col" className="px-3 py-2.5">Comprobante</th>
                  <th scope="col" className="px-3 py-2.5 text-right">Aplica</th>
                  <th scope="col" className="px-3 py-2.5 text-right">Queda</th>
                  <th scope="col" className="px-3 py-2.5">Estado</th>
                </tr>
              </thead>
              <tbody>
                {filasPreview.length === 0 && (
                  <tr>
                    <td colSpan={4} className="px-3 py-3 text-ink-soft">
                      {reparto.aCuenta > 0 ? 'No hay comprobantes pendientes.' : 'Ingresá un monto para ver el reparto.'}
                    </td>
                  </tr>
                )}
                {filasPreview.map(({ venta, aplica, saldoFinal }) => (
                  <tr key={venta.id} className="border-b border-table-divider last:border-0 even:bg-table-row-alt">
                    <td className="px-3 py-3 text-ink [overflow-wrap:anywhere]">
                      {etiquetaVenta(venta)}
                      <span className="block text-ink-soft">{formatFechaCortaLocal(venta.created_at)}</span>
                    </td>
                    <td className="px-3 py-3 text-right font-semibold tabular-nums text-ink">{formatCurrency(aplica)}</td>
                    <td className="px-3 py-3 text-right tabular-nums text-ink-soft">{formatCurrency(saldoFinal)}</td>
                    <td className="px-3 py-3">
                      {saldoFinal <= 0 ? <EstadoBadge variant="green">Cobrada</EstadoBadge> : <EstadoBadge variant="amber">Parcial</EstadoBadge>}
                    </td>
                  </tr>
                ))}
                {reparto.aCuenta > 0 && (
                  <tr className="border-b border-table-divider last:border-0 even:bg-table-row-alt">
                    <td className="px-3 py-3 text-ink">Queda a cuenta del cliente</td>
                    <td className="px-3 py-3 text-right font-semibold tabular-nums text-ink">{formatCurrency(reparto.aCuenta)}</td>
                    <td className="px-3 py-3" />
                    <td className="px-3 py-3" />
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </section>

        {superaMaximo && !error && <ErrorText>{`El cobro supera lo que debe el cliente (${formatCurrency(maximo)}).`}</ErrorText>}
        {error && <ErrorText>{error}</ErrorText>}
      </form>

      {confirmCerrar && (
        <ConfirmDialog
          title="Cerrar sin guardar"
          mensaje="Hay cambios sin guardar en este formulario. ¿Querés cerrar de todos modos?"
          confirmLabel="Cerrar sin guardar"
          onCancel={() => setConfirmCerrar(false)}
          onConfirm={onClose}
        />
      )}
    </Modal>
  )
}
