import { useMemo, useState, type ReactNode } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { FacturaCompraSaldo } from '../../types/database'
import { ErrorRegistrarPago, etiquetaComprobanteCompra } from '../../lib/facturasCompra'
import { useAplicarPagosACuenta, type AplicarPagosACuentaResultado } from '../../lib/pagosACuenta'
import { esNotaCredito, simularRepartoPago, type ResultadoReparto } from '../../lib/repartoPagoProveedor'
import { formatCurrency } from '../../lib/format'
import { friendlyError, mensajeErrorGuardado } from '../../lib/supabaseErrors'
import { Modal } from './Modal'
import { ErrorText } from './FormField'
import { EstadoBadge } from './EstadoBadge'

type BaseProps = {
  titulo: string
  cancelarLabel: string
  contraparte: { label: string; nombre: string } // "Proveedor: X" / "Cliente: X"
  aviso: ReactNode // qué se aplica y a qué
  reparto: ResultadoReparto // vista previa (monto = lo a cuenta)
  etiqueta: (comprobanteId: string) => string
  sigueACuentaTexto: string
  accionError: string // "aplicar los pagos a cuenta"
  aplicando: boolean
  onAplicar: () => Promise<void> // tira el error tal cual (ErrorRegistrarPago u otro)
  onClose: () => void
}

// Aplicar lo que una cuenta tiene a cuenta (pagos o cobros sin comprobante) a comprobantes
// pendientes, con vista previa. No mueve plata. Lo usan proveedores (docs/52) y clientes (docs/68).
export function AplicarACuentaModalBase({
  titulo,
  cancelarLabel,
  contraparte,
  aviso,
  reparto,
  etiqueta,
  sigueACuentaTexto,
  accionError,
  aplicando,
  onAplicar,
  onClose,
}: BaseProps) {
  const [error, setError] = useState<string | null>(null)

  async function aplicar() {
    setError(null)
    try {
      await onAplicar()
    } catch (err) {
      setError(
        err instanceof ErrorRegistrarPago
          ? mensajeErrorGuardado(err.causa, err.status, accionError, 'no se aplicó nada')
          : friendlyError(err as Error),
      )
    }
  }

  const nada = reparto.aplicadoPago <= 0

  return (
    <Modal
      title={titulo}
      onClose={onClose}
      widthClassName="max-w-[640px]"
      dialogo={{ onEscape: onClose }}
      footer={
        <div className="flex justify-end gap-3">
          <button
            type="button"
            data-autofocus
            onClick={onClose}
            className="rounded px-4 py-3 font-sans text-label-bold text-ink-soft hover:bg-bg"
          >
            {cancelarLabel}
          </button>
          <button
            type="button"
            onClick={aplicar}
            disabled={aplicando || nada}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
          >
            {aplicando ? 'Aplicando...' : `Aplicar ${formatCurrency(reparto.aplicadoPago)}`}
          </button>
        </div>
      }
    >
      <div className="flex flex-col gap-stack-md">
        <p className="font-sans text-body-md text-ink-soft">
          {contraparte.label}: <span className="text-ink">{contraparte.nombre}</span>
        </p>
        <p className="rounded bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">{aviso}</p>

        <section aria-label="Vista previa">
          <div className="overflow-hidden rounded-xl shadow-sm">
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
                {reparto.aplicaciones.length === 0 && (
                  <tr>
                    <td colSpan={4} className="px-3 py-3 text-ink-soft">No hay comprobantes pendientes a los que aplicar.</td>
                  </tr>
                )}
                {reparto.aplicaciones.map((a) => {
                  const queda = reparto.saldoFinal.get(a.comprobanteId) ?? 0
                  return (
                    <tr key={a.comprobanteId} className="border-b border-table-divider last:border-0 even:bg-table-row-alt">
                      <td className="px-3 py-3 text-ink [overflow-wrap:anywhere]">{etiqueta(a.comprobanteId)}</td>
                      <td className="px-3 py-3 text-right font-semibold tabular-nums text-ink">{formatCurrency(a.monto)}</td>
                      <td className="px-3 py-3 text-right tabular-nums text-ink-soft">{formatCurrency(queda)}</td>
                      <td className="px-3 py-3">
                        {queda <= 0 ? (
                          <EstadoBadge variant="green">Pagada</EstadoBadge>
                        ) : (
                          <EstadoBadge variant="amber">Parcial</EstadoBadge>
                        )}
                      </td>
                    </tr>
                  )
                })}
                {reparto.aCuenta > 0 && (
                  <tr className="border-b border-table-divider last:border-0 even:bg-table-row-alt">
                    <td className="px-3 py-3 text-ink">{sigueACuentaTexto}</td>
                    <td className="px-3 py-3 text-right font-semibold tabular-nums text-ink">{formatCurrency(reparto.aCuenta)}</td>
                    <td className="px-3 py-3" />
                    <td className="px-3 py-3" />
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </section>

        {error && <ErrorText>{error}</ErrorText>}
      </div>
    </Modal>
  )
}

// "a este comprobante" / "a los comprobantes elegidos" / "a los comprobantes más viejos"
export function destinoAplicacion(elegidas: number): string {
  return elegidas === 1 ? ' a este comprobante' : elegidas > 1 ? ' a los comprobantes elegidos' : ' a los comprobantes más viejos'
}

type Props = {
  supabase: SupabaseClient
  proveedorId: string
  proveedorNombre: string
  comprobantes: FacturaCompraSaldo[] // los del proveedor (o solo el recién cargado): la vista previa usa los pendientes
  facturaIds: string[] // vacío = los pendientes más viejos
  aCuenta: number // total a cuenta del proveedor (proveedores_a_cuenta)
  titulo?: string
  cancelarLabel?: string
  onClose: () => void
  onAplicado: (resultado: AplicarPagosACuentaResultado) => void
}

// Aplicar lo que el proveedor tiene a cuenta (pagos sin comprobante) a comprobantes pendientes
// (docs/52). La vista previa sale de simularRepartoPago con monto = lo a cuenta: mismo orden que el
// RPC aplicar_pagos_a_cuenta (más viejos primero). No sale plata: no hay egreso ni cambia la caja.
export function AplicarACuentaModal({
  supabase,
  proveedorId,
  proveedorNombre,
  comprobantes,
  facturaIds,
  aCuenta,
  titulo = 'Aplicar pagos a cuenta',
  cancelarLabel = 'Cancelar',
  onClose,
  onAplicado,
}: Props) {
  // Solo comprobantes a pagar: una NC elegida en la cuenta corriente no entra acá.
  const elegidas = useMemo(
    () => facturaIds.filter((id) => comprobantes.some((c) => c.id === id && !esNotaCredito(c))),
    [facturaIds, comprobantes],
  )
  const porId = useMemo(() => new Map(comprobantes.map((c) => [c.id, c])), [comprobantes])
  const reparto = useMemo(
    () => simularRepartoPago({ comprobantes, facturaIds: elegidas, notaCreditoIds: [], monto: aCuenta }),
    [comprobantes, elegidas, aCuenta],
  )
  const mutation = useAplicarPagosACuenta(supabase)

  return (
    <AplicarACuentaModalBase
      titulo={titulo}
      cancelarLabel={cancelarLabel}
      contraparte={{ label: 'Proveedor', nombre: proveedorNombre }}
      aviso={
        <>
          Este proveedor tiene <span className="font-semibold tabular-nums">{formatCurrency(aCuenta)}</span> a cuenta (pagos
          sin comprobante). Se aplican los pagos más viejos primero
          {destinoAplicacion(elegidas.length)}
          . No sale plata: no se
          registra un egreso ni cambia la caja.
        </>
      }
      reparto={reparto}
      etiqueta={(id) => etiquetaComprobanteCompra(porId.get(id)!)}
      sigueACuentaTexto="Sigue a cuenta del proveedor"
      accionError="aplicar los pagos a cuenta"
      aplicando={mutation.isPending}
      onAplicar={async () => onAplicado(await mutation.mutateAsync({ proveedorId, facturaIds: elegidas }))}
      onClose={onClose}
    />
  )
}
