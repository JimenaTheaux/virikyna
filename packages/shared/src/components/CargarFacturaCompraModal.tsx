import { useEffect, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { FormaPagoCompra, LetraComprobanteCompra, Proveedor, TipoComprobanteCompra } from '../../types/database'
import {
  cargarFacturaCompra,
  calcularTotalesFacturaCompra,
  integrarMarcaEnItemsLibres,
  itemsValidosFacturaCompra,
  nuevoItemFacturaCompraUI,
  problemasItemsFacturaCompra,
  type ItemFacturaCompraUI,
} from '../../lib/facturasCompra'
import { fechaHoyISO, formatCurrency } from '../../lib/format'
import { mensajeErrorGuardado } from '../../lib/supabaseErrors'
import { Modal } from './Modal'
import { ConfirmDialog } from './ConfirmDialog'
import { Field, ErrorText, inputClass, selectClass } from './FormField'
import { ItemFacturaRow, type CrearProductoRender } from './ItemFacturaRow'

const TIPOS: { value: TipoComprobanteCompra; label: string }[] = [
  { value: 'factura', label: 'Factura' },
  { value: 'remito', label: 'Remito' },
  { value: 'cupon', label: 'Cupón (no facturado)' },
  { value: 'nota_credito', label: 'Nota de crédito' },
  { value: 'nota_debito', label: 'Nota de débito' },
]

const LETRAS: LetraComprobanteCompra[] = ['A', 'B', 'R', 'X']

const COLUMNAS_ITEMS = [
  { label: 'Cód. barras', align: 'left', width: '15%' },
  { label: 'Producto', align: 'left', width: '22%' },
  { label: 'Marca', align: 'left', width: '15%' },
  { label: 'Cant.', align: 'right', width: '7%' },
  { label: 'P. unitario', align: 'right', width: '10%' },
  { label: 'Desc. %', align: 'right', width: '6%' },
  { label: 'Depósito', align: 'left', width: '10%' },
  { label: 'Subtotal', align: 'right', width: '11%' },
  { label: '', align: 'center', width: '4%' },
] as const

type Props = {
  supabase: SupabaseClient
  // Formulario de producto de cada app, para "+ Crear producto nuevo" desde un ítem.
  crearProducto: CrearProductoRender
  onClose: () => void
  onSaved: () => void
}

// Carga de factura de compra de escritorio, compartida por Virikyna Local y Virikyna Gestión (una
// sola copia — antes cada app tenía la suya y Gestión quedó con la versión vieja de tarjetas).
// Misma lógica de negocio (lib/facturasCompra.ts) y mismo RPC atómico `cargar_factura_compra` que
// Virikyna Inventario (celular), solo cambia la UI: acá va en un modal tipo planilla (una fila por
// ítem, editable celda por celda), con totales y botones en el footer fijo del Modal, y la
// búsqueda de producto por ítem es por tipeo/lector en vez de cámara (ver ItemFacturaRow).
export function CargarFacturaCompraModal({ supabase, crearProducto, onClose, onSaved }: Props) {
  const [proveedores, setProveedores] = useState<Proveedor[]>([])
  const [proveedorId, setProveedorId] = useState('')
  const [tipoComprobante, setTipoComprobante] = useState<TipoComprobanteCompra>('factura')
  const [letra, setLetra] = useState<LetraComprobanteCompra | ''>('')
  const [puntoVenta, setPuntoVenta] = useState('')
  const [numeroComprobante, setNumeroComprobante] = useState('')
  const [fechaComprobante, setFechaComprobante] = useState(fechaHoyISO())
  const [fechaFiscal, setFechaFiscal] = useState('')
  const [mostrarFechaFiscal, setMostrarFechaFiscal] = useState(false)
  const [formaPago, setFormaPago] = useState<FormaPagoCompra>('contado')
  const [items, setItems] = useState<ItemFacturaCompraUI[]>([nuevoItemFacturaCompraUI()])
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [dirty, setDirty] = useState(false)
  const [confirmCerrar, setConfirmCerrar] = useState(false)
  // Ítems marcados por la última validación de "Guardar factura"; se desmarcan al editarlos.
  const [itemsConError, setItemsConError] = useState<Set<string>>(new Set())

  function pedirCierre() {
    if (dirty) {
      setConfirmCerrar(true)
    } else {
      onClose()
    }
  }

  useEffect(() => {
    supabase
      .from('proveedores')
      .select('*')
      .order('razon_social')
      .then(({ data }) => setProveedores((data ?? []) as Proveedor[]))
  }, [])

  function actualizarItem(key: string, cambios: Partial<ItemFacturaCompraUI>) {
    setItemsConError((prev) => {
      if (!prev.has(key)) return prev
      const sig = new Set(prev)
      sig.delete(key)
      return sig
    })
    setItems((prev) => prev.map((it) => (it.key === key ? { ...it, ...cambios } : it)))
  }

  function eliminarItem(key: string) {
    setItems((prev) => prev.filter((it) => it.key !== key))
  }

  const {
    subtotalSinIva: subtotalPreview,
    descuento: descuentoPreview,
    iva: ivaPreview,
    total: totalPreview,
    saldoPendiente: saldoPendientePreview,
  } = calcularTotalesFacturaCompra(items)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)

    if (!proveedorId) {
      setError('Elegí un proveedor.')
      return
    }
    if (!fechaComprobante) {
      setError('La fecha del comprobante es obligatoria.')
      return
    }
    // Un ítem empezado pero incompleto se descartaba en silencio al guardar: ahora bloquea, se
    // marca en rojo y se lleva la vista hasta el primero.
    const problemas = problemasItemsFacturaCompra(items)
    setItemsConError(new Set(problemas.map((p) => p.key)))
    if (problemas.length > 0) {
      setError(problemas.map((p) => p.mensaje).join(' '))
      document
        .querySelector(`[data-item-key="${problemas[0].key}"]`)
        ?.scrollIntoView({ behavior: 'smooth', block: 'center' })
      return
    }
    if (itemsValidosFacturaCompra(items).length === 0) {
      setError('Agregá al menos un ítem con descripción y cantidad mayor a cero.')
      return
    }

    setSaving(true)
    const { error: dbError, status } = await cargarFacturaCompra(supabase, {
      proveedorId,
      tipoComprobante,
      letra: letra || null,
      puntoVenta: puntoVenta.trim() || null,
      numeroComprobante: numeroComprobante.trim() || null,
      fechaComprobante,
      fechaFiscal: fechaFiscal || null,
      formaPago,
      items: integrarMarcaEnItemsLibres(items),
    })
    setSaving(false)

    if (dbError) {
      setError(mensajeErrorGuardado(dbError, status, 'cargar la factura', 'lo que cargaste sigue acá'))
      return
    }

    onSaved()
  }

  return (
    <Modal
      title="Nueva factura de compra"
      onClose={pedirCierre}
      widthClassName="max-w-[1180px]"
      footer={
        <div className="flex flex-col gap-stack-sm">
          <div className="flex items-center justify-between gap-stack-md">
            <div className="flex gap-stack-lg">
              <div>
                <p className="font-sans text-label-md text-ink-soft">Subtotal</p>
                <p className="font-sans text-body-md text-ink">{formatCurrency(subtotalPreview)}</p>
              </div>
              <div>
                <p className="font-sans text-label-md text-ink-soft">Descuento</p>
                <p className="font-sans text-body-md text-ink">{formatCurrency(descuentoPreview)}</p>
              </div>
              <div>
                <p className="font-sans text-label-md text-ink-soft">IVA (21%)</p>
                <p className="font-sans text-body-md text-ink">{formatCurrency(ivaPreview)}</p>
              </div>
              <div>
                <p className="font-sans text-label-md text-ink-soft">Saldo pendiente</p>
                <p className="font-sans text-body-md text-ink">{formatCurrency(saldoPendientePreview)}</p>
              </div>
            </div>
            <div className="text-right">
              <p className="font-sans text-label-md text-ink-soft">Total factura</p>
              <p className="font-display text-headline-md text-accent-darker">{formatCurrency(totalPreview)}</p>
            </div>
          </div>

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
              form="form-factura-compra"
              disabled={saving}
              className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
            >
              {saving ? 'Guardando...' : 'Guardar factura'}
            </button>
          </div>
        </div>
      }
    >
      <form
        id="form-factura-compra"
        onSubmit={handleSubmit}
        onChangeCapture={() => setDirty(true)}
        // El lector de código de barras manda Enter al terminar cada lectura. En un <form> con
        // botón submit, Enter en cualquier input dispara el envío implícito: con los ítems de
        // arriba ya completos, escanear en una fila nueva guardaba la factura a medio cargar.
        // Acá Enter en un campo nunca guarda — solo el botón "Guardar factura".
        onKeyDown={(e) => {
          if (e.key === 'Enter' && e.target instanceof HTMLInputElement) {
            e.preventDefault()
            e.stopPropagation()
          }
        }}
        className="flex flex-col gap-stack-md"
      >
        {/* Franja superior — datos del comprobante en una sola fila compacta */}
        <div className="grid grid-cols-2 items-end gap-stack-sm md:grid-cols-8">
          <div className="col-span-2 md:col-span-4">
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
          </div>
          <div className="col-span-1 md:col-span-3">
            <Field label="Tipo de comprobante">
              <select
                value={tipoComprobante}
                onChange={(e) => setTipoComprobante(e.target.value as TipoComprobanteCompra)}
                className={selectClass}
              >
                {TIPOS.map((t) => (
                  <option key={t.value} value={t.value}>
                    {t.label}
                  </option>
                ))}
              </select>
            </Field>
          </div>
          <div className="col-span-1 md:col-span-1">
            <Field label="Letra">
              <select
                value={letra}
                onChange={(e) => setLetra(e.target.value as LetraComprobanteCompra | '')}
                className={selectClass}
              >
                <option value="">—</option>
                {LETRAS.map((l) => (
                  <option key={l} value={l}>
                    {l}
                  </option>
                ))}
              </select>
            </Field>
          </div>
          <div className="col-span-1 md:col-span-2">
            <Field label="Punto de venta">
              <input value={puntoVenta} onChange={(e) => setPuntoVenta(e.target.value)} className={inputClass} />
            </Field>
          </div>
          <div className="col-span-1 md:col-span-2">
            <Field label="Número">
              <input
                value={numeroComprobante}
                onChange={(e) => setNumeroComprobante(e.target.value)}
                className={inputClass}
              />
            </Field>
          </div>
          <div className="col-span-1 md:col-span-2">
            <Field label="Fecha comprobante">
              <input
                type="date"
                value={fechaComprobante}
                onChange={(e) => setFechaComprobante(e.target.value)}
                className={inputClass}
              />
            </Field>
          </div>
          <div className="col-span-1 md:col-span-2">
            <Field label="Forma de pago">
              <select
                value={formaPago}
                title={formaPago === 'contado' ? 'Contado' : 'Cuenta corriente'}
                onChange={(e) => setFormaPago(e.target.value as FormaPagoCompra)}
                className={selectClass}
              >
                <option value="contado">Contado</option>
                <option value="cuenta_corriente">Cta. cte.</option>
              </select>
            </Field>
          </div>
        </div>

        {mostrarFechaFiscal ? (
          <div className="grid grid-cols-12 gap-stack-sm">
            <div className="col-span-2">
              <Field label="Fecha fiscal" hint="Opcional">
                <input
                  type="date"
                  value={fechaFiscal}
                  onChange={(e) => setFechaFiscal(e.target.value)}
                  className={inputClass}
                />
              </Field>
            </div>
          </div>
        ) : (
          <button
            type="button"
            onClick={() => setMostrarFechaFiscal(true)}
            className="self-start rounded px-1 font-sans text-label-md text-accent-dark hover:underline"
          >
            + Agregar fecha fiscal (opcional)
          </button>
        )}

        {/* Tabla de ítems tipo planilla — sin scroll interno propio, crece con la página */}
        <p className="font-sans text-label-bold text-ink">Ítems de la factura</p>

        <table className="w-full table-fixed border-collapse">
          <colgroup>
            {COLUMNAS_ITEMS.map((c) => (
              <col key={c.label || 'accion'} style={{ width: c.width }} />
            ))}
          </colgroup>
          <thead>
            <tr className="border-b border-line">
              {COLUMNAS_ITEMS.map((c) => (
                <th
                  key={c.label || 'accion'}
                  className={`px-2 py-2 font-sans text-label-md text-ink-soft ${
                    c.align === 'right' ? 'text-right' : c.align === 'center' ? 'text-center' : 'text-left'
                  }`}
                >
                  {c.label}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {items.map((item, i) => (
              <ItemFacturaRow
                key={item.key}
                item={item}
                index={i}
                puedeEliminar={items.length > 1}
                proveedores={proveedores}
                supabase={supabase}
                crearProducto={crearProducto}
                conError={itemsConError.has(item.key)}
                onChange={(cambios) => actualizarItem(item.key, cambios)}
                onEliminar={() => eliminarItem(item.key)}
              />
            ))}
          </tbody>
        </table>

        <button
          type="button"
          onClick={() => setItems((prev) => [...prev, nuevoItemFacturaCompraUI()])}
          className="self-start rounded px-3 py-2 font-sans text-label-bold text-accent-dark hover:bg-accent-light"
        >
          + Agregar ítem
        </button>
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
