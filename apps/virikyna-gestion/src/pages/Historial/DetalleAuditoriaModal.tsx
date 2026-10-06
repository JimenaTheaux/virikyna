import { useEffect, useState, type ReactNode } from 'react'
import { formatFechaHora, friendlyError } from '@virikyna/shared'
import { Modal } from '../../components/Modal'
import { Field, ErrorText, inputClass } from '../../components/FormField'
import {
  ACCION_LABEL,
  accionRevertible,
  CAMPOS_FACTURA_COMPRA_REF,
  etiquetasFacturasCompra,
  anularVenta,
  revertirAlta,
  revertirEdicion,
  revertirMovimiento,
  tablaLabel,
} from '../../lib/historial'
import type { AuditoriaConUsuario } from './types'
import { FacturaCompraDetallePorId } from '../Proveedores/FacturaCompraDetallePorId'

type Props = {
  auditoria: AuditoriaConUsuario
  ventaEstado?: string
  onClose: () => void
  onReverted: () => void
}

function claves(obj: Record<string, unknown> | null): string[] {
  return obj ? Object.keys(obj).sort() : []
}

function valorTexto(v: unknown): string {
  if (v === null || v === undefined) return '—'
  if (typeof v === 'boolean') return v ? 'true' : 'false'
  return String(v)
}

export function DetalleAuditoriaModal({ auditoria, ventaEstado, onClose, onReverted }: Props) {
  const [confirmando, setConfirmando] = useState(false)
  const [motivo, setMotivo] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)

  const antes = auditoria.valores_anteriores as Record<string, unknown> | null
  const despues = auditoria.valores_nuevos as Record<string, unknown> | null
  const todasLasClaves = Array.from(new Set([...claves(antes), ...claves(despues)])).filter(
    (k) => !['id', 'usuario_id', 'created_at'].includes(k),
  )

  const revertible = accionRevertible(auditoria, ventaEstado)

  // Campos que apuntan a otra factura de compra (copiada_de_id, docs/33): se muestran con su
  // comprobante y abren su detalle, en vez del UUID.
  const [etiquetasFactura, setEtiquetasFactura] = useState<Map<string, string>>(new Map())
  const [facturaAbierta, setFacturaAbierta] = useState<string | null>(null)
  const idsFactura = todasLasClaves
    .filter((k) => k in CAMPOS_FACTURA_COMPRA_REF)
    .flatMap((k) => [antes?.[k], despues?.[k]])
    .filter((v): v is string => typeof v === 'string')
  const claveIds = idsFactura.join(',')
  useEffect(() => {
    let cancelado = false
    etiquetasFacturasCompra(idsFactura).then((m) => {
      if (!cancelado) setEtiquetasFactura(m)
    })
    return () => {
      cancelado = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [claveIds])

  function celda(k: string, v: unknown): ReactNode {
    const texto = CAMPOS_FACTURA_COMPRA_REF[k]
    if (!texto || typeof v !== 'string') return valorTexto(v)
    return (
      <button
        type="button"
        onClick={() => setFacturaAbierta(v)}
        className="rounded text-left text-accent-dark underline hover:text-accent-darker focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
      >
        {texto(etiquetasFactura.get(v) ?? 'otra factura')}
      </button>
    )
  }

  async function ejecutarRevertir() {
    setError(null)
    if (revertible?.tipo === 'venta' && !motivo.trim()) {
      setError('Contá el motivo de la anulación.')
      return
    }

    setSaving(true)
    const { error: rpcError } =
      revertible?.tipo === 'edicion'
        ? await revertirEdicion(auditoria.id)
        : revertible?.tipo === 'alta'
          ? await revertirAlta(auditoria.id)
          : revertible?.tipo === 'movimiento'
            ? await revertirMovimiento(auditoria.id)
            : revertible?.tipo === 'venta'
              ? await anularVenta(auditoria.registro_id, motivo.trim())
              : { error: null }
    setSaving(false)

    if (rpcError) {
      setError(friendlyError(rpcError))
      return
    }
    onReverted()
  }

  return (
    <Modal title="Detalle de la acción" onClose={onClose} widthClassName="max-w-[640px]">
      <div className="flex flex-col gap-stack-md">
        <div className="grid grid-cols-2 gap-3 rounded border border-line p-4 font-sans text-body-md">
          <div>
            <p className="text-label-md text-ink-soft">Módulo</p>
            <p className="text-ink">{tablaLabel(auditoria.tabla_afectada)}</p>
          </div>
          <div>
            <p className="text-label-md text-ink-soft">Tipo de acción</p>
            <p className="text-ink">{ACCION_LABEL[auditoria.accion]}</p>
          </div>
          <div>
            <p className="text-label-md text-ink-soft">Usuario</p>
            <p className="text-ink">{auditoria.usuario?.nombre ?? '—'}</p>
          </div>
          <div>
            <p className="text-label-md text-ink-soft">Fecha y hora</p>
            <p className="text-ink">{formatFechaHora(auditoria.created_at)}</p>
          </div>
        </div>

        {auditoria.nota && (
          <div className="rounded bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">
            {auditoria.nota}
          </div>
        )}

        {todasLasClaves.length > 0 && (
          <div className="overflow-auto rounded-lg border border-line">
            <table className="w-full text-left font-sans text-label-md">
              <thead>
                <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
                  <th className="whitespace-nowrap px-3 py-2">Campo</th>
                  <th className="whitespace-nowrap px-3 py-2">Antes</th>
                  <th className="whitespace-nowrap px-3 py-2">Después</th>
                </tr>
              </thead>
              <tbody>
                {todasLasClaves.map((k) => {
                  const vAntes = antes?.[k]
                  const vDespues = despues?.[k]
                  const cambio = antes && despues && valorTexto(vAntes) !== valorTexto(vDespues)
                  return (
                    <tr key={k} className="border-b border-line last:border-0">
                      <td className="px-3 py-2 text-ink-soft">{k}</td>
                      <td className={`px-3 py-2 ${cambio ? 'text-error' : 'text-ink'}`}>
                        {antes ? celda(k, vAntes) : '—'}
                      </td>
                      <td className={`px-3 py-2 ${cambio ? 'font-bold text-success' : 'text-ink'}`}>
                        {despues ? celda(k, vDespues) : '—'}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}

        {auditoria.tabla_afectada === 'ventas' && auditoria.accion === 'alta' && !revertible && (
          <p className="font-sans text-label-md text-ink-soft">
            Esta venta ya está facturada o anulada — no es reversible desde el sistema.
          </p>
        )}

        {revertible && !confirmando && (
          <button
            type="button"
            onClick={() => setConfirmando(true)}
            className="self-start rounded border border-error px-4 py-2.5 font-sans text-label-bold text-error hover:bg-error/10"
          >
            {revertible.tipo === 'venta' ? 'Anular venta' : 'Revertir'}
          </button>
        )}

        {revertible && confirmando && (
          <div className="rounded border border-error/40 bg-error/5 p-4">
            <p className="font-sans text-body-md text-ink">
              {revertible.tipo === 'venta'
                ? 'La venta se anula y el stock vuelto se repone. Esta acción queda registrada como una acción nueva, nunca borra la original.'
                : 'Esto genera una acción nueva que compensa a la original — nunca se borra ni se pisa lo que pasó.'}
            </p>

            {revertible.tipo === 'venta' && (
              <div className="mt-3">
                <Field label="Motivo de la anulación">
                  <input autoFocus value={motivo} onChange={(e) => setMotivo(e.target.value)} className={inputClass} />
                </Field>
              </div>
            )}

            {error && (
              <div className="mt-3">
                <ErrorText>{error}</ErrorText>
              </div>
            )}

            <div className="mt-3 flex justify-end gap-3">
              <button
                type="button"
                onClick={() => {
                  setConfirmando(false)
                  setError(null)
                }}
                className="rounded px-4 py-2.5 font-sans text-label-bold text-ink-soft hover:bg-bg"
              >
                Cancelar
              </button>
              <button
                type="button"
                onClick={ejecutarRevertir}
                disabled={saving}
                className="rounded bg-error px-4 py-2.5 font-sans text-label-bold text-white transition hover:bg-error/90 disabled:opacity-60"
              >
                {saving ? 'Confirmando...' : 'Confirmar'}
              </button>
            </div>
          </div>
        )}
      </div>

      {facturaAbierta && <FacturaCompraDetallePorId facturaId={facturaAbierta} onClose={() => setFacturaAbierta(null)} />}
    </Modal>
  )
}
