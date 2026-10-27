import { useId, useState, type FormEvent } from 'react'
import {
  diferenciaMedios,
  ErrorRegistrarPago,
  fechaHoyISO,
  formatCurrency,
  friendlyError,
  MediosPagoEditor,
  mensajeErrorGuardado,
  ResumenMedios,
  useMediosPago,
  usePagosACuenta,
  useRegistrarPagoProveedorV3,
  validarMedios,
} from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { Modal } from '../../components/Modal'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, ErrorText, inputClass } from '../../components/FormField'

type Props = {
  proveedorId: string
  proveedorNombre: string
  facturaCompraId: string | null // null = se aplica a las pendientes más viejas
  saldoPendiente?: number
  onClose: () => void
  onSaved: () => void
}

// Pago de una factura puntual desde Gestión, con uno o varios medios (docs/65): efectivo,
// transferencia, cheques y eCheqs en cualquier combinación. Va por registrar_pago_proveedor_v3 con
// origen 'general': un pago hecho desde Gestión no sale de la caja de Local y no entra en su
// Cierre. Misma mutation que el pago desde la cuenta corriente, que refresca la cuenta del
// proveedor en todas las pantallas abiertas.
export function RegistrarPagoProveedorModal({
  proveedorId,
  proveedorNombre,
  facturaCompraId,
  saldoPendiente,
  onClose,
  onSaved,
}: Props) {
  const [monto, setMonto] = useState(saldoPendiente && saldoPendiente > 0 ? String(saldoPendiente) : '')
  const [fecha, setFecha] = useState(fechaHoyISO())
  const [nota, setNota] = useState('')
  const { medios, cambiar: cambiarMedios } = useMediosPago(monto)
  const [error, setError] = useState<string | null>(null)
  const [dirty, setDirty] = useState(false)
  const [confirmCerrar, setConfirmCerrar] = useState(false)
  const formId = useId()
  const mutation = useRegistrarPagoProveedorV3(supabase)
  // docs/52: si el proveedor ya tiene plata a cuenta, se avisa antes de pagar de nuevo.
  const aCuenta = usePagosACuenta(supabase, proveedorId).data?.total ?? 0

  const montoNum = monto.trim() === '' ? NaN : Number(monto)
  const noCierra = Number.isFinite(montoNum) && diferenciaMedios(montoNum, medios).estado !== 'cierra'

  function pedirCierre() {
    if (dirty) {
      setConfirmCerrar(true)
    } else {
      onClose()
    }
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)

    if (!Number.isFinite(montoNum) || montoNum <= 0) {
      setError('Ingresá un monto mayor a cero.')
      return
    }
    if (!fecha) {
      setError('Ingresá la fecha del pago.')
      return
    }
    const invalido = validarMedios(medios, montoNum, { fechaPagoProveedor: fecha })
    if (invalido) {
      setError(invalido)
      return
    }
    // Un monto mayor al saldo ya no se rechaza (docs/52): el RPC paga la factura y el sobrante
    // queda a cuenta del proveedor.

    try {
      await mutation.mutateAsync({
        proveedorId,
        facturaIds: facturaCompraId ? [facturaCompraId] : [],
        monto: montoNum,
        medios,
        origen: 'general',
        fecha,
        nota,
      })
      onSaved()
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
      cambiosSinGuardar={dirty}
      widthClassName="max-w-[720px]"
      footer={
        <div className="flex items-center justify-end gap-3">
          <ResumenMedios medios={medios} total={montoNum} className="mr-auto" />
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
            disabled={mutation.isPending || noCierra}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
          >
            {mutation.isPending ? 'Guardando...' : 'Registrar pago'}
          </button>
        </div>
      }
    >
      <form id={formId} onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        <p className="font-sans text-body-md text-ink-soft">
          Proveedor: <span className="text-ink">{proveedorNombre}</span>
        </p>
        {saldoPendiente !== undefined && (
          <p className="font-sans text-body-md text-ink-soft">
            Saldo pendiente de esta factura: <span className="text-ink">{formatCurrency(saldoPendiente)}</span>
          </p>
        )}
        {aCuenta > 0 && (
          <p role="note" className="rounded border border-accent bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">
            Este proveedor tiene <span className="font-semibold tabular-nums">{formatCurrency(aCuenta)}</span> a cuenta (pagos sin
            comprobante). Antes de registrar plata nueva, revisá si corresponde aplicarlos desde la cuenta corriente.
          </p>
        )}

        <div className="grid grid-cols-2 gap-stack-sm">
          <Field
            label="Total del pago"
            hint={facturaCompraId && saldoPendiente !== undefined ? 'Si pagás más que el saldo, lo que sobre queda a cuenta' : undefined}
          >
            <input
              type="number"
              step="0.01"
              min={0}
              data-autofocus
              value={monto}
              onChange={(e) => setMonto(e.target.value)}
              className={`${inputClass} text-right tabular-nums`}
            />
          </Field>
          <Field label="Fecha del pago">
            <input type="date" value={fecha} onChange={(e) => setFecha(e.target.value)} className={inputClass} />
          </Field>
        </div>

        <MediosPagoEditor medios={medios} onChange={cambiarMedios} total={montoNum} fechaPago={fecha} conResumen={false} />

        <Field label="Nota (opcional)">
          <input value={nota} onChange={(e) => setNota(e.target.value)} maxLength={200} className={inputClass} />
        </Field>

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
