import { useEffect, useState, type FormEvent } from 'react'
import type {
  FormaPagoCompra,
  LetraComprobanteCompra,
  Proveedor,
  TipoComprobanteCompra,
} from '@virikyna/shared'
import {
  cargarFacturaCompra,
  calcularTotalesFacturaCompra,
  fechaHoyISO,
  formatCurrency,
  friendlyError,
  itemsValidosFacturaCompra,
  nuevoItemFacturaCompra,
  type ItemFacturaCompra,
} from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { usePerfil } from '../../auth/AuthContext'
import { Field, ErrorText, inputClass, selectClass } from '../../components/FormField'
import { IconMas } from '../../components/icons'
import { ItemFacturaRow } from './ItemFacturaRow'

const TIPOS: { value: TipoComprobanteCompra; label: string }[] = [
  { value: 'factura', label: 'Factura' },
  { value: 'remito', label: 'Remito' },
  { value: 'cupon', label: 'Cupón (no facturado)' },
  { value: 'nota_credito', label: 'Nota de crédito' },
  { value: 'nota_debito', label: 'Nota de débito' },
]

const LETRAS: LetraComprobanteCompra[] = ['A', 'B', 'R', 'X']

// Acceso directo a carga de facturas de proveedor desde el celular (docs/04_modulos_y_funciones.md,
// módulo 5.1) — usa el mismo RPC atómico `cargar_factura_compra` que actualiza stock por ubicación
// (docs/06_estructura_de_datos.md), sin reimplementar esa lógica en el cliente: acá solo se arma el
// payload y se muestra una vista previa de los totales.
export function CargarFacturaPage() {
  const { rol } = usePerfil()
  const [proveedores, setProveedores] = useState<Proveedor[]>([])
  const [proveedorId, setProveedorId] = useState('')
  const [tipoComprobante, setTipoComprobante] = useState<TipoComprobanteCompra>('factura')
  const [letra, setLetra] = useState<LetraComprobanteCompra | ''>('')
  const [puntoVenta, setPuntoVenta] = useState('')
  const [numeroComprobante, setNumeroComprobante] = useState('')
  const [fechaComprobante, setFechaComprobante] = useState(fechaHoyISO())
  const [fechaFiscal, setFechaFiscal] = useState('')
  const [formaPago, setFormaPago] = useState<FormaPagoCompra>('contado')
  const [items, setItems] = useState<ItemFacturaCompra[]>([nuevoItemFacturaCompra()])
  const [error, setError] = useState<string | null>(null)
  const [exito, setExito] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    supabase
      .from('proveedores')
      .select('*')
      .order('razon_social')
      .then(({ data }) => setProveedores((data ?? []) as Proveedor[]))
  }, [])

  function actualizarItem(key: string, cambios: Partial<ItemFacturaCompra>) {
    setItems((prev) => prev.map((it) => (it.key === key ? { ...it, ...cambios } : it)))
  }

  function eliminarItem(key: string) {
    setItems((prev) => prev.filter((it) => it.key !== key))
  }

  const { subtotalSinIva: subtotalPreview, iva: ivaPreview, total: totalPreview } = calcularTotalesFacturaCompra(items)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setExito(null)

    if (!proveedorId) {
      setError('Elegí un proveedor.')
      return
    }
    if (!fechaComprobante) {
      setError('La fecha del comprobante es obligatoria.')
      return
    }
    if (itemsValidosFacturaCompra(items).length === 0) {
      setError('Agregá al menos un ítem con descripción y cantidad mayor a cero.')
      return
    }

    setSaving(true)
    const { error: dbError } = await cargarFacturaCompra(supabase, {
      proveedorId,
      tipoComprobante,
      letra: letra || null,
      puntoVenta: puntoVenta.trim() || null,
      numeroComprobante: numeroComprobante.trim() || null,
      fechaComprobante,
      fechaFiscal: fechaFiscal || null,
      formaPago,
      items,
    })
    setSaving(false)

    if (dbError) {
      setError(friendlyError(dbError))
      return
    }

    setExito('Factura cargada y stock actualizado correctamente.')
    setProveedorId('')
    setTipoComprobante('factura')
    setLetra('')
    setPuntoVenta('')
    setNumeroComprobante('')
    setFechaComprobante(fechaHoyISO())
    setFechaFiscal('')
    setFormaPago('contado')
    setItems([nuevoItemFacturaCompra()])
  }

  if (!rol) return null

  return (
    <div className="flex flex-col gap-stack-md pb-stack-lg">
      <div>
        <h1 className="font-display text-headline-lg text-accent-darker">Carga de factura</h1>
        <p className="mt-1 font-sans text-body-md text-ink-soft">
          Registrá una factura de proveedor — actualiza el stock automáticamente por ítem.
        </p>
      </div>

      {exito && <p className="rounded bg-success/10 px-4 py-3 font-sans text-body-md text-success">{exito}</p>}
      {error && <ErrorText>{error}</ErrorText>}

      <form onSubmit={handleSubmit} className="flex flex-col gap-stack-md">
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

        <div className="grid grid-cols-2 gap-stack-sm">
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

        <div className="grid grid-cols-2 gap-stack-sm">
          <Field label="Punto de venta">
            <input value={puntoVenta} onChange={(e) => setPuntoVenta(e.target.value)} className={inputClass} />
          </Field>
          <Field label="Número de comprobante">
            <input
              value={numeroComprobante}
              onChange={(e) => setNumeroComprobante(e.target.value)}
              className={inputClass}
            />
          </Field>
        </div>

        <div className="grid grid-cols-2 gap-stack-sm">
          <Field label="Fecha del comprobante">
            <input
              type="date"
              value={fechaComprobante}
              onChange={(e) => setFechaComprobante(e.target.value)}
              className={inputClass}
            />
          </Field>
          <Field label="Fecha fiscal" hint="Opcional">
            <input
              type="date"
              value={fechaFiscal}
              onChange={(e) => setFechaFiscal(e.target.value)}
              className={inputClass}
            />
          </Field>
        </div>

        <Field label="Forma de pago">
          <select
            value={formaPago}
            onChange={(e) => setFormaPago(e.target.value as FormaPagoCompra)}
            className={selectClass}
          >
            <option value="contado">Contado</option>
            <option value="cuenta_corriente">Cuenta corriente</option>
          </select>
        </Field>

        <div className="flex items-center justify-between">
          <p className="font-sans text-label-bold text-ink">Ítems</p>
          <button
            type="button"
            onClick={() => setItems((prev) => [...prev, nuevoItemFacturaCompra()])}
            className="flex items-center gap-1 rounded px-3 py-2 font-sans text-label-bold text-accent-dark hover:bg-accent-light"
          >
            <IconMas className="h-5 w-5" />
            Agregar ítem
          </button>
        </div>

        <div className="flex flex-col gap-stack-sm">
          {items.map((item, i) => (
            <ItemFacturaRow
              key={item.key}
              item={item}
              index={i}
              puedeEliminar={items.length > 1}
              proveedores={proveedores}
              rol={rol}
              onChange={(cambios) => actualizarItem(item.key, cambios)}
              onEliminar={() => eliminarItem(item.key)}
            />
          ))}
        </div>

        <div className="rounded-lg border border-line bg-surface p-4">
          <div className="flex justify-between font-sans text-body-md text-ink-soft">
            <span>Total sin IVA</span>
            <span>{formatCurrency(subtotalPreview)}</span>
          </div>
          <div className="mt-1 flex justify-between font-sans text-body-md text-ink-soft">
            <span>IVA (21%)</span>
            <span>{formatCurrency(ivaPreview)}</span>
          </div>
          <div className="mt-2 flex justify-between font-display text-headline-md text-accent-darker">
            <span>Total</span>
            <span>{formatCurrency(totalPreview)}</span>
          </div>
        </div>

        <button
          type="submit"
          disabled={saving}
          className="rounded bg-accent px-4 py-4 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
        >
          {saving ? 'Guardando...' : 'Guardar factura'}
        </button>
      </form>
    </div>
  )
}
