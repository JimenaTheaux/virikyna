import { useEffect, useState, type FormEvent } from 'react'
import type { CategoriaEgreso, FacturaCompraSaldo, FormaPagoEgreso, Proveedor } from '@virikyna/shared'
import { useAuth } from '../../auth/AuthContext'
import { supabase } from '../../lib/supabaseClient'
import { fechaHoyISO, formatCurrency, friendlyError, registrarEgresoGeneral, registrarPagoProveedor } from '@virikyna/shared'
import { CATEGORIA_EGRESO_LABEL, CATEGORIAS_LOCAL, FORMA_PAGO_EGRESO_LABEL } from '../../lib/caja'
import { Modal } from '../../components/Modal'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, ErrorText, inputClass, selectClass } from '../../components/FormField'

const CATEGORIAS = CATEGORIAS_LOCAL
const FORMAS_PAGO = Object.keys(FORMA_PAGO_EGRESO_LABEL) as FormaPagoEgreso[]
const ES_CHEQUE = (f: FormaPagoEgreso) => f === 'cheque' || f === 'echeq'

export function RegistrarEgresoModal({ onClose, onSaved }: { onClose: () => void; onSaved: () => void }) {
  const { user } = useAuth()
  const [categoria, setCategoria] = useState<CategoriaEgreso>('otro')
  const [monto, setMonto] = useState('')
  const [descripcion, setDescripcion] = useState('')
  const [formaPago, setFormaPago] = useState<FormaPagoEgreso>('efectivo')
  const [chequeNumero, setChequeNumero] = useState('')
  const [chequeFechaSalida, setChequeFechaSalida] = useState(fechaHoyISO())
  const [chequeFechaVencimiento, setChequeFechaVencimiento] = useState('')
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

  // Categoría "Pago a proveedor": segundo punto de entrada al mismo RPC `registrar_pago_proveedor`
  // que usa el detalle de factura (Proveedores/RegistrarPagoProveedorModal) — ver
  // docs/04_modulos_y_funciones.md, módulo 6, "Dos puntos de entrada, una sola operación real".
  const esPagoProveedor = categoria === 'pago_proveedor'
  const [proveedores, setProveedores] = useState<Proveedor[]>([])
  const [proveedorId, setProveedorId] = useState('')
  const [facturas, setFacturas] = useState<FacturaCompraSaldo[]>([])
  const [facturaCompraId, setFacturaCompraId] = useState('')

  useEffect(() => {
    if (!esPagoProveedor) return
    supabase
      .from('proveedores')
      .select('*')
      .order('razon_social')
      .then(({ data }) => setProveedores((data ?? []) as Proveedor[]))
  }, [esPagoProveedor])

  useEffect(() => {
    setFacturaCompraId('')
    if (!esPagoProveedor || !proveedorId) {
      setFacturas([])
      return
    }
    supabase
      .from('facturas_compra_saldo')
      .select('*')
      .eq('proveedor_id', proveedorId)
      .gt('saldo_pendiente', 0)
      .order('fecha_comprobante', { ascending: false })
      .then(({ data }) => setFacturas((data ?? []) as FacturaCompraSaldo[]))
  }, [esPagoProveedor, proveedorId])

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)

    const montoNum = Number(monto)
    if (!montoNum || montoNum <= 0) {
      setError('Ingresá un monto mayor a cero.')
      return
    }
    if (!user) {
      setError('No se pudo identificar al usuario actual.')
      return
    }

    if (esPagoProveedor) {
      if (!proveedorId) {
        setError('Elegí a qué proveedor corresponde el pago.')
        return
      }
      if (ES_CHEQUE(formaPago)) {
        if (!chequeNumero.trim()) {
          setError('Ingresá el número de cheque.')
          return
        }
        if (!chequeFechaSalida) {
          setError('Ingresá la fecha de salida del cheque.')
          return
        }
        if (!chequeFechaVencimiento) {
          setError('Ingresá la fecha de vencimiento del cheque.')
          return
        }
      }
      setSaving(true)
      const { error: dbError } = await registrarPagoProveedor(supabase, {
        proveedorId,
        facturaCompraId: facturaCompraId || null,
        monto: montoNum,
        formaPago,
        chequeNumero: ES_CHEQUE(formaPago) ? chequeNumero.trim() : null,
        chequeFechaSalida: ES_CHEQUE(formaPago) ? chequeFechaSalida : null,
        chequeFechaVencimiento: ES_CHEQUE(formaPago) ? chequeFechaVencimiento : null,
      })
      setSaving(false)
      if (dbError) {
        setError(friendlyError(dbError))
        return
      }
      onSaved()
      return
    }

    if (!descripcion.trim()) {
      setError('La descripción es obligatoria.')
      return
    }

    setSaving(true)
    const { error: dbError } = await registrarEgresoGeneral(supabase, {
      categoria,
      monto: montoNum,
      descripcion: descripcion.trim(),
      formaPago,
      origen: 'turno',
    })
    setSaving(false)

    if (dbError) {
      setError(friendlyError(dbError))
      return
    }
    onSaved()
  }

  return (
    <Modal title="Registrar egreso" onClose={pedirCierre} widthClassName="max-w-[460px]">
      <form onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
        <Field label="Categoría">
          <select
            value={categoria}
            onChange={(e) => setCategoria(e.target.value as CategoriaEgreso)}
            className={selectClass}
          >
            {CATEGORIAS.map((c) => (
              <option key={c} value={c}>
                {CATEGORIA_EGRESO_LABEL[c]}
              </option>
            ))}
          </select>
        </Field>

        {esPagoProveedor && (
          <>
            <Field label="Proveedor">
              <select value={proveedorId} onChange={(e) => setProveedorId(e.target.value)} className={selectClass}>
                <option value="">Elegí un proveedor</option>
                {proveedores.map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.razon_social}
                  </option>
                ))}
              </select>
            </Field>

            {proveedorId && (
              <Field label="Factura" hint="Opcional — sin elegir, el pago queda a cuenta general del proveedor">
                <select
                  value={facturaCompraId}
                  onChange={(e) => setFacturaCompraId(e.target.value)}
                  className={selectClass}
                >
                  <option value="">Sin factura puntual (a cuenta general)</option>
                  {facturas.map((f) => (
                    <option key={f.id} value={f.id}>
                      {(f.numero_comprobante ?? f.id.slice(0, 8))} · saldo {formatCurrency(f.saldo_pendiente)}
                    </option>
                  ))}
                </select>
              </Field>
            )}
          </>
        )}

        <Field label="Monto">
          <input
            type="number"
            step="0.01"
            autoFocus
            value={monto}
            onChange={(e) => setMonto(e.target.value)}
            className={inputClass}
          />
        </Field>

        <Field label="Forma de pago">
          <select
            value={formaPago}
            onChange={(e) => setFormaPago(e.target.value as FormaPagoEgreso)}
            className={selectClass}
          >
            {FORMAS_PAGO.map((f) => (
              <option key={f} value={f}>
                {FORMA_PAGO_EGRESO_LABEL[f]}
              </option>
            ))}
          </select>
        </Field>

        {esPagoProveedor && ES_CHEQUE(formaPago) && (
          <div className="flex flex-col gap-stack-sm">
            <Field label="Nro. de cheque">
              <input
                value={chequeNumero}
                onChange={(e) => setChequeNumero(e.target.value)}
                className={inputClass}
              />
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

        {!esPagoProveedor && (
          <Field label="Descripción">
            <input value={descripcion} onChange={(e) => setDescripcion(e.target.value)} className={inputClass} />
          </Field>
        )}

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
            disabled={saving}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
          >
            {saving ? 'Guardando...' : 'Registrar egreso'}
          </button>
        </div>
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
