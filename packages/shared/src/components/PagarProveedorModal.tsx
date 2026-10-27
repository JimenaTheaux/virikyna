import { useId, useMemo, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { FacturaCompraSaldo, FormaPagoEgreso, OrigenEgreso } from '../../types/database'
import {
  ErrorRegistrarPago,
  esCheque,
  etiquetaComprobanteCompra,
  FORMA_PAGO_EGRESO_LABEL,
  FORMAS_PAGO_EGRESO,
  useRegistrarPagoProveedorV2,
  useRegistrarPagoProveedorV3,
  validarPagoProveedor,
} from '../../lib/facturasCompra'
import { diferenciaMedios, validarMedios } from '../../lib/mediosPago'
import { simularRepartoPago } from '../../lib/repartoPagoProveedor'
import { MediosPagoEditor, ResumenMedios, useMediosPago } from './MediosPagoEditor'
import { fechaHoyISO, formatCurrency } from '../../lib/format'
import { friendlyError, mensajeErrorGuardado } from '../../lib/supabaseErrors'
import { Modal } from './Modal'
import { ConfirmDialog } from './ConfirmDialog'
import { Field, ErrorText, inputClass, selectClass } from './FormField'
import { EstadoBadge } from './EstadoBadge'

type Props = {
  supabase: SupabaseClient
  proveedorId: string
  proveedorNombre: string
  comprobantes: FacturaCompraSaldo[] // todos los del proveedor: la vista previa necesita los pendientes
  facturaIds: string[] // vacío = se aplica a los más viejos
  notaCreditoIds: string[]
  origen: OrigenEgreso
  aCuenta?: number // docs/52: pagos del proveedor sin comprobante, para avisar antes de pagar de nuevo
  onAplicarACuenta?: () => void // sin esto el aviso no ofrece aplicar
  onClose: () => void
  onPagado: () => void
}

const montoTexto = (n: number) => (Math.round(n * 100) / 100).toFixed(2).replace(/\.00$/, '')

// Pago a proveedor desde la cuenta corriente (docs/31): uno o varios comprobantes, con o sin
// notas de crédito. La vista previa del reparto sale de simularRepartoPago (espejo del RPC
// registrar_pago_proveedor_v2); la escritura es una sola llamada al RPC, que vuelve a validar todo.
// Desde Gestión (origen 'general') el pago puede tener varios medios (docs/65, v3); desde Local
// sigue siendo un solo medio (v2) — los pagos con cheques se registran en Gestión.
export function PagarProveedorModal({
  supabase,
  proveedorId,
  proveedorNombre,
  comprobantes,
  facturaIds,
  notaCreditoIds,
  origen,
  aCuenta = 0,
  onAplicarACuenta,
  onClose,
  onPagado,
}: Props) {
  const conSeleccion = facturaIds.length > 0
  const hayNotas = notaCreditoIds.length > 0
  const porId = useMemo(() => new Map(comprobantes.map((c) => [c.id, c])), [comprobantes])

  // Monto precargado: lo que queda tras las NC (con selección) o todo lo pendiente (sin selección).
  const aPagar = useMemo(
    () => simularRepartoPago({ comprobantes, facturaIds, notaCreditoIds, monto: 0 }).restanteTrasNotas,
    [comprobantes, facturaIds, notaCreditoIds],
  )

  const [monto, setMonto] = useState(montoTexto(aPagar))
  const [formaPago, setFormaPago] = useState<FormaPagoEgreso>('efectivo')
  const [chequeNumero, setChequeNumero] = useState('')
  const [chequeFechaSalida, setChequeFechaSalida] = useState(fechaHoyISO())
  const [chequeFechaVencimiento, setChequeFechaVencimiento] = useState('')
  const [fecha, setFecha] = useState(fechaHoyISO())
  const [nota, setNota] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [dirty, setDirty] = useState(false)
  const [confirmCerrar, setConfirmCerrar] = useState(false)
  const formId = useId()
  const avisoId = useId()

  const variosMedios = origen === 'general'
  const mutationV2 = useRegistrarPagoProveedorV2(supabase)
  const mutationV3 = useRegistrarPagoProveedorV3(supabase)
  const guardando = mutationV2.isPending || mutationV3.isPending
  const { medios, cambiar: cambiarMedios } = useMediosPago(monto)
  const montoNum = monto.trim() === '' ? NaN : Number(monto)
  const soloCredito = hayNotas && montoNum === 0
  // Con varios medios no se guarda hasta que sumen el total del pago.
  const mediosNoCierran =
    variosMedios && !soloCredito && Number.isFinite(montoNum) && diferenciaMedios(montoNum, medios).estado !== 'cierra'

  const reparto = useMemo(
    () =>
      simularRepartoPago({
        comprobantes,
        facturaIds,
        notaCreditoIds,
        monto: Number.isFinite(montoNum) ? montoNum : 0,
      }),
    [comprobantes, facturaIds, notaCreditoIds, montoNum],
  )

  // Una fila por comprobante alcanzado: cuánto le llega de NC y de plata, y cómo queda.
  const filasPreview = useMemo(() => {
    const porComprobante = new Map<string, { nc: number; pago: number }>()
    for (const a of reparto.aplicaciones) {
      const fila = porComprobante.get(a.comprobanteId) ?? { nc: 0, pago: 0 }
      if (a.fuente === 'nota_credito') fila.nc += a.monto
      else fila.pago += a.monto
      porComprobante.set(a.comprobanteId, fila)
    }
    return Array.from(porComprobante.entries()).map(([id, { nc, pago }]) => ({
      comprobante: porId.get(id)!,
      nc,
      pago,
      saldoFinal: reparto.saldoFinal.get(id) ?? 0,
    }))
  }, [reparto, porId])

  function pedirCierre() {
    if (dirty) setConfirmCerrar(true)
    else onClose()
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)

    const invalido = variosMedios
      ? !Number.isFinite(montoNum) || montoNum < 0
        ? 'Ingresá un monto válido.'
        : montoNum === 0 && !hayNotas
          ? 'Ingresá un monto mayor a cero.'
          : soloCredito
            ? null
            : validarMedios(medios, montoNum, { fechaPagoProveedor: fecha })
      : validarPagoProveedor({
          monto: montoNum,
          formaPago,
          permiteMontoCero: hayNotas,
          chequeNumero,
          chequeFechaSalida,
          chequeFechaVencimiento,
        })
    if (invalido) {
      setError(invalido)
      return
    }
    if (reparto.error) {
      setError(reparto.error)
      return
    }
    if (!fecha) {
      setError('Ingresá la fecha del pago.')
      return
    }

    try {
      if (variosMedios) {
        await mutationV3.mutateAsync({
          proveedorId,
          monto: montoNum,
          medios: soloCredito ? [] : medios,
          facturaIds,
          notaCreditoIds,
          origen,
          fecha,
          nota,
        })
      } else {
        await mutationV2.mutateAsync({
          proveedorId,
          monto: montoNum,
          formaPago,
          facturaIds,
          notaCreditoIds,
          origen,
          fecha,
          nota,
          chequeNumero,
          chequeFechaSalida,
          chequeFechaVencimiento,
        })
      }
      onPagado()
    } catch (err) {
      setError(
        err instanceof ErrorRegistrarPago
          ? mensajeErrorGuardado(err.causa, err.status, 'registrar el pago', 'los datos siguen acá')
          : friendlyError(err as Error),
      )
    }
  }

  return (
    <Modal
      title="Registrar pago a proveedor"
      onClose={pedirCierre}
      widthClassName={variosMedios ? 'max-w-[720px]' : 'max-w-[640px]'}
      cambiosSinGuardar={dirty}
      footer={
        <div className="flex items-center justify-end gap-3">
          {variosMedios && !soloCredito && <ResumenMedios medios={medios} total={montoNum} className="mr-auto" />}
          <button
            type="button"
            onClick={pedirCierre}
            className="rounded px-4 py-3 font-sans text-label-bold text-ink-soft hover:bg-bg"
          >
            Cancelar
          </button>
          <button
            type="submit"
            form={formId}
            disabled={guardando || Boolean(reparto.error) || mediosNoCierran}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
          >
            {guardando ? 'Guardando...' : soloCredito ? 'Aplicar crédito' : 'Registrar pago'}
          </button>
        </div>
      }
    >
      <form
        id={formId}
        onSubmit={handleSubmit}
        onChangeCapture={() => setDirty(true)}
        className="flex flex-col gap-stack-md"
      >
        <p className="font-sans text-body-md text-ink-soft">
          Proveedor: <span className="text-ink">{proveedorNombre}</span>
        </p>

        {aCuenta > 0 && (
          <div
            role="note"
            className="flex flex-wrap items-center justify-between gap-stack-sm rounded border border-accent bg-accent-light px-4 py-3"
          >
            <p className="font-sans text-body-md text-accent-darker">
              Este proveedor tiene <span className="font-semibold tabular-nums">{formatCurrency(aCuenta)}</span> a cuenta (pagos
              sin comprobante). Antes de registrar plata nueva, revisá si corresponde aplicarlos.
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
            Se aplica a los comprobantes más antiguos. Lo que sobre queda a cuenta del proveedor.
          </p>
        )}

        <div className="grid grid-cols-2 gap-stack-sm">
          <Field
            label={variosMedios ? 'Total del pago' : 'Monto'}
            hint={conSeleccion ? `A pagar: ${formatCurrency(aPagar)} — si pagás más, lo que sobre queda a cuenta` : undefined}
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
          <Field label="Fecha del pago">
            <input type="date" value={fecha} onChange={(e) => setFecha(e.target.value)} className={inputClass} />
          </Field>
        </div>

        {soloCredito ? (
          <p className="rounded bg-badge-green-bg px-4 py-3 font-sans text-body-md text-badge-green-text">
            Se aplica solo crédito de notas de crédito — no sale plata ni se registra un egreso.
          </p>
        ) : variosMedios ? (
          <MediosPagoEditor medios={medios} onChange={cambiarMedios} total={montoNum} fechaPago={fecha} conResumen={false} />
        ) : (
          <>
            <Field label="Forma de pago">
              <select
                value={formaPago}
                onChange={(e) => setFormaPago(e.target.value as FormaPagoEgreso)}
                className={selectClass}
              >
                {FORMAS_PAGO_EGRESO.map((f) => (
                  <option key={f} value={f}>
                    {FORMA_PAGO_EGRESO_LABEL[f]}
                  </option>
                ))}
              </select>
            </Field>

            {esCheque(formaPago) && (
              <div className="flex flex-col gap-stack-sm">
                <Field label="Nro. de cheque">
                  <input value={chequeNumero} onChange={(e) => setChequeNumero(e.target.value)} className={inputClass} />
                </Field>
                <div className="grid grid-cols-2 gap-stack-sm">
                  <Field label="Fecha de salida">
                    <input
                      type="date"
                      value={chequeFechaSalida}
                      onChange={(e) => setChequeFechaSalida(e.target.value)}
                      className={inputClass}
                    />
                  </Field>
                  <Field label="Fecha de vencimiento">
                    <input
                      type="date"
                      value={chequeFechaVencimiento}
                      onChange={(e) => setChequeFechaVencimiento(e.target.value)}
                      className={inputClass}
                    />
                  </Field>
                </div>
              </div>
            )}
          </>
        )}

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
                {filasPreview.map(({ comprobante, nc, pago, saldoFinal }) => (
                  <tr key={comprobante.id} className="border-b border-table-divider last:border-0 even:bg-table-row-alt">
                    <td className="px-3 py-3 text-ink [overflow-wrap:anywhere]">
                      {etiquetaComprobanteCompra(comprobante)}
                      {nc > 0 && (
                        <span className="block text-ink-soft">
                          {formatCurrency(nc)} con nota de crédito{pago > 0 ? ` + ${formatCurrency(pago)} del pago` : ''}
                        </span>
                      )}
                    </td>
                    <td className="px-3 py-3 text-right font-semibold tabular-nums text-ink">{formatCurrency(nc + pago)}</td>
                    <td className="px-3 py-3 text-right tabular-nums text-ink-soft">{formatCurrency(saldoFinal)}</td>
                    <td className="px-3 py-3">
                      {saldoFinal <= 0 ? (
                        <EstadoBadge variant="green">Pagada</EstadoBadge>
                      ) : (
                        <EstadoBadge variant="amber">Parcial</EstadoBadge>
                      )}
                    </td>
                  </tr>
                ))}
                {Array.from(reparto.creditoFinal.entries()).map(([id, queda]) => {
                  const notaCredito = porId.get(id)!
                  const usa = Number(notaCredito.credito_disponible) - queda
                  return (
                    <tr key={id} className="border-b border-table-divider last:border-0 even:bg-table-row-alt">
                      <td className="px-3 py-3 text-success [overflow-wrap:anywhere]">{etiquetaComprobanteCompra(notaCredito)}</td>
                      <td className="px-3 py-3 text-right font-semibold tabular-nums text-success">−{formatCurrency(usa)}</td>
                      <td className="px-3 py-3 text-right tabular-nums text-success">−{formatCurrency(queda)}</td>
                      <td className="px-3 py-3">
                        {queda <= 0 ? (
                          <EstadoBadge variant="neutral">Agotada</EstadoBadge>
                        ) : (
                          <EstadoBadge variant="green">Con crédito</EstadoBadge>
                        )}
                      </td>
                    </tr>
                  )
                })}
                {reparto.aCuenta > 0 && (
                  <tr className="border-b border-table-divider last:border-0 even:bg-table-row-alt">
                    <td className="px-3 py-3 text-ink">Queda a cuenta del proveedor</td>
                    <td className="px-3 py-3 text-right font-semibold tabular-nums text-ink">{formatCurrency(reparto.aCuenta)}</td>
                    <td className="px-3 py-3" />
                    <td className="px-3 py-3" />
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </section>

        {/* El botón queda deshabilitado mientras haya error en el reparto: el motivo tiene que verse. */}
        {reparto.error && Number.isFinite(montoNum) && !error && <ErrorText>{reparto.error}</ErrorText>}
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
