import { useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { FacturaCompraSaldo, FormaPagoCompra, TipoComprobanteCompra } from '../../types/database'
import {
  aAlicuotaIvaCompra,
  alicuotaDefault,
  editarFacturaCompra,
  etiquetaAlicuotaIva,
  ivaDeCompra,
  tieneAplicacionesVigentes,
  TIPO_COMPROBANTE_COMPRA_LABEL,
  TIPOS_COMPROBANTE_COMPRA,
  type AlicuotaIvaCompra,
} from '../../lib/facturasCompra'
import { formatCurrency } from '../../lib/format'
import { friendlyError } from '../../lib/supabaseErrors'
import { Modal } from './Modal'
import { ConfirmDialog } from './ConfirmDialog'
import { Field, ErrorText, inputClass, selectClass } from './FormField'
import { SelectorAlicuotaIva } from './SelectorAlicuotaIva'

type Props = {
  supabase: SupabaseClient
  factura: FacturaCompraSaldo
  onClose: () => void
  onSaved: () => void
}

// editar_factura_compra (docs/06_estructura_de_datos.md, RPC 10) — datos del comprobante, no ítems.
// Si el error está en los ítems, la corrección real es anular la factura y recargarla de nuevo —
// este formulario ni siquiera ofrece esos campos. Hoy solo lo habilita Virikyna Gestión (prop
// permitirEditarAnular de ProveedorCuentaCorriente y su propio detalle de factura).
// Tipo e IVA (docs/45): cambiar el tipo vuelve la alícuota al default del tipo nuevo, y el RPC
// recalcula IVA y total sobre el total sin IVA guardado. Con pagos o NC aplicados los dos quedan
// bloqueados (el RPC también lo rechaza): cambiarían lo que ya se imputó.
export function EditarFacturaCompraModal({ supabase, factura, onClose, onSaved }: Props) {
  const [tipoComprobante, setTipoComprobante] = useState<TipoComprobanteCompra>(factura.tipo_comprobante)
  const [ivaAlicuota, setIvaAlicuota] = useState<AlicuotaIvaCompra>(aAlicuotaIvaCompra(factura.iva_alicuota))
  const bloqueado = tieneAplicacionesVigentes(factura)
  const totalSinIva = Number(factura.total_sin_iva)
  const ivaNuevo = ivaDeCompra(totalSinIva, ivaAlicuota)
  const cambiaTotal = Math.round((totalSinIva + ivaNuevo) * 100) !== Math.round(Number(factura.total) * 100)
  const [numeroComprobante, setNumeroComprobante] = useState(factura.numero_comprobante ?? '')
  const [fechaComprobante, setFechaComprobante] = useState(factura.fecha_comprobante)
  const [formaPago, setFormaPago] = useState<FormaPagoCompra>(factura.forma_pago)
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [dirty, setDirty] = useState(false)
  const [confirmCerrar, setConfirmCerrar] = useState(false)

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

    if (!fechaComprobante) {
      setError('La fecha del comprobante es obligatoria.')
      return
    }

    setSaving(true)
    const { error: rpcError } = await editarFacturaCompra(supabase, {
      facturaId: factura.id,
      tipoComprobante,
      numeroComprobante: numeroComprobante.trim() || null,
      fechaComprobante,
      formaPago,
      ivaAlicuota,
    })
    setSaving(false)

    if (rpcError) {
      setError(friendlyError(rpcError))
      return
    }
    onSaved()
  }

  return (
    <Modal
      title="Editar factura de compra"
      onClose={pedirCierre}
      widthClassName="max-w-[480px]"
      cambiosSinGuardar={dirty}
      // Pie fijo: con el selector de IVA el formulario ya no entra en 720 px de alto y los botones
      // quedaban abajo del scroll.
      footer={
        <div className="flex flex-col gap-stack-sm">
          {error && <ErrorText>{error}</ErrorText>}
          <div className="flex justify-end gap-3">
            <button
              type="button"
              onClick={pedirCierre}
              className="rounded px-4 py-3 font-sans text-label-bold text-ink-soft hover:bg-bg"
            >
              Cancelar
            </button>
            <button
              type="submit"
              form="form-editar-factura-compra"
              disabled={saving}
              className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
            >
              {saving ? 'Guardando...' : 'Guardar cambios'}
            </button>
          </div>
        </div>
      }
    >
      <form
        id="form-editar-factura-compra"
        onSubmit={handleSubmit}
        onChangeCapture={() => setDirty(true)}
        className="flex flex-col gap-stack-md"
      >
        <p className="font-sans text-body-md text-ink-soft">
          Los ítems no se editan acá. Queda registrado en el Historial con el antes y el después.
        </p>

        <Field label="Tipo de comprobante">
          <select
            value={tipoComprobante}
            disabled={bloqueado}
            onChange={(e) => {
              const tipo = e.target.value as TipoComprobanteCompra
              setTipoComprobante(tipo)
              setIvaAlicuota(alicuotaDefault(tipo))
            }}
            className={`${selectClass} disabled:cursor-not-allowed disabled:opacity-60`}
          >
            {TIPOS_COMPROBANTE_COMPRA.map((t) => (
              <option key={t} value={t}>
                {TIPO_COMPROBANTE_COMPRA_LABEL[t]}
              </option>
            ))}
          </select>
        </Field>

        <div className="flex flex-col gap-2">
          <SelectorAlicuotaIva value={ivaAlicuota} onChange={setIvaAlicuota} disabled={bloqueado} />
          {bloqueado ? (
            <p className="font-sans text-label-md text-ink-soft">
              Este comprobante ya tiene pagos o notas de crédito aplicados: el tipo y el IVA no se pueden
              cambiar. Para corregirlos, revertí primero esos pagos desde el Historial.
            </p>
          ) : (
            <p className="font-sans text-label-md text-ink-soft" aria-live="polite">
              {etiquetaAlicuotaIva(ivaAlicuota)}: {formatCurrency(ivaNuevo)} · Total:{' '}
              <span className={cambiaTotal ? 'font-semibold text-ink' : ''}>{formatCurrency(totalSinIva + ivaNuevo)}</span>
              {cambiaTotal && <> (antes {formatCurrency(Number(factura.total))})</>}
            </p>
          )}
        </div>

        <Field label="Número de comprobante">
          <input
            data-autofocus
            value={numeroComprobante}
            onChange={(e) => setNumeroComprobante(e.target.value)}
            className={inputClass}
          />
        </Field>

        <Field label="Fecha del comprobante">
          <input
            type="date"
            value={fechaComprobante}
            onChange={(e) => setFechaComprobante(e.target.value)}
            className={inputClass}
          />
        </Field>

        {/* docs/57: acá es solo una etiqueta (no crea ni borra pagos). Con pagos aplicados queda fija;
            el RPC también lo rechaza. */}
        <Field
          label="Forma de pago"
          hint={
            bloqueado
              ? 'Tiene pagos aplicados: la forma de pago no se cambia.'
              : 'Cambiarla acá no registra ni borra pagos.'
          }
        >
          <select
            value={formaPago}
            disabled={bloqueado}
            onChange={(e) => setFormaPago(e.target.value as FormaPagoCompra)}
            className={`${selectClass} disabled:cursor-not-allowed disabled:opacity-60`}
          >
            <option value="contado">Contado</option>
            <option value="cuenta_corriente">Cuenta corriente</option>
          </select>
        </Field>

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
