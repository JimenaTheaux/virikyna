import { Modal } from '../../components/Modal'
import { formatCurrency, formatFechaHora } from '@virikyna/shared'
import { diferenciaLabel } from '../../lib/caja'
import type { CierreCajaConUsuario } from './types'

function Fila({ label, valor, destacado }: { label: string; valor: string; destacado?: boolean }) {
  return (
    <div className="flex items-center justify-between border-b border-line py-2.5 last:border-0">
      <span className="font-sans text-body-md text-ink-soft">{label}</span>
      <span className={`font-sans ${destacado ? 'text-label-bold text-ink' : 'text-body-md text-ink'}`}>{valor}</span>
    </div>
  )
}

export function CierreDetalleModal({ cierre, onClose }: { cierre: CierreCajaConUsuario; onClose: () => void }) {
  const diferencia = diferenciaLabel(cierre.diferencia)
  const totalVentas =
    cierre.total_efectivo +
    cierre.total_transferencia +
    cierre.total_qr +
    cierre.total_tarjeta +
    cierre.total_cuenta_corriente

  return (
    <Modal
      title={cierre.tipo === 'z' ? 'Cierre Z — Cierre del día' : 'Cierre X — Resumen de turno'}
      onClose={onClose}
      widthClassName="max-w-[520px]"
    >
      <div className="flex flex-col">
        <Fila label="Fecha del turno" valor={cierre.turno_fecha} />
        <Fila label="Realizado" valor={formatFechaHora(cierre.created_at)} />
        <Fila label="Usuario" valor={cierre.usuario?.nombre ?? '—'} />

        <p className="mt-stack-md font-sans text-label-bold text-ink-soft">Ventas por medio de pago</p>
        <Fila label="Efectivo" valor={formatCurrency(cierre.total_efectivo)} />
        <Fila label="Transferencia (Mercado Pago)" valor={formatCurrency(cierre.total_transferencia)} />
        <Fila label="QR" valor={formatCurrency(cierre.total_qr)} />
        <Fila label="Tarjeta (débito/crédito)" valor={formatCurrency(cierre.total_tarjeta)} />
        <Fila label="Cuenta corriente" valor={formatCurrency(cierre.total_cuenta_corriente)} />
        <Fila label="Total vendido" valor={formatCurrency(totalVentas)} destacado />

        {cierre.apertura && (
          <>
            <p className="mt-stack-md font-sans text-label-bold text-ink-soft">Apertura del período</p>
            <Fila label="Abierta por" valor={cierre.apertura.usuarioNombre ?? '—'} />
            <Fila label="Abierta el" valor={formatFechaHora(cierre.apertura.abierta_at)} />
            <Fila label="Monto esperado" valor={formatCurrency(cierre.apertura.monto_esperado)} />
            <Fila label="Monto real de apertura" valor={formatCurrency(cierre.apertura.monto_real)} />
            {cierre.apertura.diferencia !== 0 && (
              <Fila
                label="Diferencia de apertura"
                valor={diferenciaLabel(cierre.apertura.diferencia).texto}
                destacado
              />
            )}
          </>
        )}

        <p className="mt-stack-md font-sans text-label-bold text-ink-soft">Efectivo</p>
        <Fila label="Egresos del día" valor={formatCurrency(cierre.total_egresos)} />
        <Fila label="Retiros de efectivo" valor={`- ${formatCurrency(cierre.total_retiros)}`} />
        <Fila label="Efectivo esperado (incluye el monto de apertura)" valor={formatCurrency(cierre.efectivo_esperado)} destacado />
        {cierre.efectivo_contado !== null && (
          <>
            <Fila label="Efectivo contado" valor={formatCurrency(cierre.efectivo_contado)} />
            <div className="flex items-center justify-between border-b border-line py-2.5 last:border-0">
              <span className="font-sans text-body-md text-ink-soft">Diferencia</span>
              <span className={`font-sans text-label-bold ${diferencia.className}`}>{diferencia.texto}</span>
            </div>
          </>
        )}

        {cierre.tipo === 'z' && (
          <>
            <p className="mt-stack-md font-sans text-label-bold text-ink-soft">Validación</p>
            <Fila
              label="Estado"
              valor={cierre.estado_validacion === 'validado' ? 'Validado' : 'Pendiente de validación'}
            />
            {cierre.estado_validacion === 'validado' && (
              <>
                <Fila label="Validado por" valor={cierre.validador?.nombre ?? '—'} />
                <Fila label="Validado el" valor={cierre.validado_at ? formatFechaHora(cierre.validado_at) : '—'} />
              </>
            )}
          </>
        )}

        <div className="mt-stack-md flex justify-end">
          <button
            type="button"
            onClick={onClose}
            className="rounded px-4 py-3 font-sans text-label-bold text-ink-soft hover:bg-bg"
          >
            Cerrar
          </button>
        </div>
      </div>
    </Modal>
  )
}
