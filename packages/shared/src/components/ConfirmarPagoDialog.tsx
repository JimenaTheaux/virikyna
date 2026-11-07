import { useId } from 'react'
import { formatAjuste, formatCurrency, formatFechaCorta } from '../../lib/format'
import { ConfirmDialog } from './ConfirmDialog'

// Confirmación antes de registrar un pago a proveedor o un cobro a cliente: el último control antes
// de que se mueva plata. Foco inicial en "Volver" (un Enter apurado no confirma) y Esc vuelve.

export type MedioConfirmacion = { etiqueta: string; monto: number; detalle?: string } // detalle: N° de cheque, banco, fecha
export type FilaRepartoConfirmacion = { etiqueta: string; aplica: number; queda?: number; negativo?: boolean }

// Reparto de un pago desde el detalle de una factura: hasta su saldo a la factura, el sobrante a
// cuenta (si el proveedor tiene saldo inicial pendiente, la base lo usa primero para cancelarlo).
// Sin factura (etiqueta null): va a los comprobantes pendientes más viejos.
export function repartoPagoAFactura(monto: number, etiqueta: string | null, saldoPendiente?: number): FilaRepartoConfirmacion[] {
  if (!etiqueta || saldoPendiente === undefined) {
    return [{ etiqueta: 'Comprobantes pendientes más viejos (lo que sobre queda a cuenta)', aplica: monto }]
  }
  const montoC = Math.round(monto * 100)
  const aplicaC = Math.min(montoC, Math.max(Math.round(saldoPendiente * 100), 0))
  const filas: FilaRepartoConfirmacion[] = [{ etiqueta, aplica: aplicaC / 100, queda: (Math.round(saldoPendiente * 100) - aplicaC) / 100 }]
  if (montoC > aplicaC) filas.push({ etiqueta: 'Sobrante: a cuenta del proveedor', aplica: (montoC - aplicaC) / 100 })
  return filas
}

// Medios del formulario (MediosPagoEditor) → renglones del resumen, con el detalle de cada cheque.
export function mediosParaConfirmar<M extends string>(
  medios: { medio: M; monto: string; numero: string; banco: string; fechaPago: string }[],
  etiqueta: (m: M) => string,
): MedioConfirmacion[] {
  return medios.map((m) => ({
    etiqueta: etiqueta(m.medio),
    monto: Number(m.monto),
    detalle:
      [m.numero.trim() && `N° ${m.numero.trim()}`, m.banco.trim(), m.fechaPago && `se cobra el ${formatFechaCorta(m.fechaPago)}`]
        .filter(Boolean)
        .join(' · ') || undefined,
  }))
}

type Props = {
  titulo: string // "Confirmar pago" / "Confirmar cobro"
  confirmLabel: string // "Confirmar pago" / "Confirmar cobro"
  titularLabel: string // "Proveedor" / "Cliente"
  titular: string
  total: number
  fecha: string | null // 'AAAA-MM-DD'
  origen?: string // "Caja Gestión" / "Caja Local"
  medios: MedioConfirmacion[]
  reparto: FilaRepartoConfirmacion[]
  nota?: string
  ajuste?: number // docs/71: ajuste por redondeo (no es plata); se muestra si ≠ 0
  confirmando: boolean
  onVolver: () => void
  onConfirmar: () => void
}

export function ConfirmarPagoDialog({
  titulo,
  confirmLabel,
  titularLabel,
  titular,
  total,
  fecha,
  origen,
  medios,
  reparto,
  nota,
  ajuste = 0,
  confirmando,
  onVolver,
  onConfirmar,
}: Props) {
  const idBase = useId()
  return (
    <ConfirmDialog
      title={titulo}
      mensaje=""
      variant="primario"
      confirmLabel={confirmLabel}
      cancelLabel="Volver"
      confirmando={confirmando}
      widthClassName="max-w-[560px]"
      onCancel={onVolver}
      onConfirm={onConfirmar}
    >
      <div className="flex flex-col gap-stack-md font-sans text-body-md">
        <dl className="grid grid-cols-[auto_1fr] items-baseline gap-x-stack-md gap-y-1 rounded-lg border border-line p-4">
          <dt className="text-ink-soft">{titularLabel}</dt>
          <dd className="text-ink [overflow-wrap:anywhere]">{titular}</dd>
          <dt className="text-ink-soft">Total</dt>
          <dd className="font-display text-headline-md tabular-nums text-accent-darker">{formatCurrency(total)}</dd>
          {ajuste !== 0 && (
            <>
              <dt className="text-ink-soft">Ajuste por redondeo</dt>
              <dd className="text-ink">
                <span className="tabular-nums">{formatAjuste(ajuste)}</span>
                <span className="text-ink-soft"> · no es plata: cancela {formatCurrency(Math.round((total + ajuste) * 100) / 100)}</span>
              </dd>
            </>
          )}
          <dt className="text-ink-soft">Fecha</dt>
          <dd className="text-ink">{fecha ? formatFechaCorta(fecha) : '—'}</dd>
          {origen && (
            <>
              <dt className="text-ink-soft">Desde</dt>
              <dd className="text-ink">{origen}</dd>
            </>
          )}
          {nota && (
            <>
              <dt className="text-ink-soft">Nota</dt>
              <dd className="text-ink [overflow-wrap:anywhere]">“{nota}”</dd>
            </>
          )}
        </dl>

        {medios.length > 0 && (
          <section aria-labelledby={`${idBase}-medios`}>
            <h3 id={`${idBase}-medios`} className="font-sans text-label-bold text-ink-soft">
              {medios.length === 1 ? 'Medio' : `Medios (${medios.length})`}
            </h3>
            <ul className="mt-1 max-h-[12rem] overflow-y-auto rounded-lg border border-line">
              {medios.map((m, i) => (
                <li key={i} className="flex items-baseline justify-between gap-3 border-b border-line px-4 py-2 last:border-0">
                  <span className="min-w-0 text-ink [overflow-wrap:anywhere]">
                    {m.etiqueta}
                    {m.detalle && <span className="block text-label-md text-ink-soft">{m.detalle}</span>}
                  </span>
                  <span className="shrink-0 font-semibold tabular-nums text-ink">{formatCurrency(m.monto)}</span>
                </li>
              ))}
            </ul>
          </section>
        )}

        {reparto.length > 0 && (
          <section aria-labelledby={`${idBase}-reparto`}>
            <h3 id={`${idBase}-reparto`} className="font-sans text-label-bold text-ink-soft">
              Cómo se reparte
            </h3>
            <ul className="mt-1 max-h-[12rem] overflow-y-auto rounded-lg border border-line">
              {reparto.map((r, i) => (
                <li key={i} className="flex items-baseline justify-between gap-3 border-b border-line px-4 py-2 last:border-0">
                  <span className={`min-w-0 [overflow-wrap:anywhere] ${r.negativo ? 'text-success' : 'text-ink'}`}>
                    {r.etiqueta}
                    {r.queda !== undefined && (
                      <span className="block text-label-md text-ink-soft">
                        {r.queda > 0 ? `Queda ${formatCurrency(r.queda)}` : 'Queda cancelado'}
                      </span>
                    )}
                  </span>
                  <span className={`shrink-0 font-semibold tabular-nums ${r.negativo ? 'text-success' : 'text-ink'}`}>
                    {r.negativo ? `−${formatCurrency(r.aplica)}` : formatCurrency(r.aplica)}
                  </span>
                </li>
              ))}
            </ul>
          </section>
        )}
      </div>
    </ConfirmDialog>
  )
}
