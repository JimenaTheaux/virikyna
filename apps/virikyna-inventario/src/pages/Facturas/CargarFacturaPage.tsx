import { useEffect, useRef, useState, type FormEvent } from 'react'
import { useBlocker } from 'react-router-dom'
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
  integrarMarcaEnItemsLibres,
  itemsValidosFacturaCompra,
  nuevoItemFacturaCompraUI,
  type ItemFacturaCompraUI,
} from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { usePerfil } from '../../auth/AuthContext'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, inputClass, selectClass } from '../../components/FormField'
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

// Un aviso nuevo es siempre un objeto nuevo: así el scroll automático se dispara también cuando se
// repite el mismo mensaje (ej. dos toques seguidos en Guardar con el mismo error).
type Aviso = { tipo: 'error' | 'exito'; texto: string }

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
  const [mostrarFechaFiscal, setMostrarFechaFiscal] = useState(false)
  const [formaPago, setFormaPago] = useState<FormaPagoCompra>('contado')
  const [items, setItems] = useState<ItemFacturaCompraUI[]>([nuevoItemFacturaCompraUI()])
  const [aviso, setAviso] = useState<Aviso | null>(null)
  const [saving, setSaving] = useState(false)
  const [dirty, setDirty] = useState(false)
  const avisoRef = useRef<HTMLParagraphElement>(null)

  // Cambiar de pestaña (o volver atrás) con lo cargado sin guardar pide confirmación antes de
  // descartarlo. Solo bloquea si de verdad cambia de pantalla.
  const blocker = useBlocker(
    ({ currentLocation, nextLocation }) => dirty && currentLocation.pathname !== nextLocation.pathname,
  )

  useEffect(() => {
    if (!dirty) return
    // Recargar o cerrar la app también descartaría lo cargado (el navegador muestra su propio aviso).
    function avisarAntesDeSalir(e: BeforeUnloadEvent) {
      e.preventDefault()
    }
    window.addEventListener('beforeunload', avisarAntesDeSalir)
    return () => window.removeEventListener('beforeunload', avisarAntesDeSalir)
  }, [dirty])

  useEffect(() => {
    supabase
      .from('proveedores')
      .select('*')
      .order('razon_social')
      .then(({ data }) => setProveedores((data ?? []) as Proveedor[]))
  }, [])

  // El mensaje se muestra arriba de la página, pero "Guardar factura" está al final del formulario:
  // sin esto el resultado quedaba fuera de pantalla.
  useEffect(() => {
    if (aviso) avisoRef.current?.scrollIntoView({ behavior: 'smooth', block: 'center' })
  }, [aviso])

  function actualizarItem(key: string, cambios: Partial<ItemFacturaCompraUI>) {
    setDirty(true)
    setItems((prev) => prev.map((it) => (it.key === key ? { ...it, ...cambios } : it)))
  }

  function eliminarItem(key: string) {
    setDirty(true)
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
    setAviso(null)

    if (!proveedorId) {
      setAviso({ tipo: 'error', texto: 'Elegí un proveedor.' })
      return
    }
    if (!fechaComprobante) {
      setAviso({ tipo: 'error', texto: 'La fecha del comprobante es obligatoria.' })
      return
    }
    if (itemsValidosFacturaCompra(items).length === 0) {
      setAviso({ tipo: 'error', texto: 'Agregá al menos un ítem con descripción y cantidad mayor a cero.' })
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
      items: integrarMarcaEnItemsLibres(items),
    })
    setSaving(false)

    if (dbError) {
      setAviso({ tipo: 'error', texto: friendlyError(dbError) })
      return
    }

    setAviso({ tipo: 'exito', texto: 'Factura cargada y stock actualizado correctamente.' })
    setDirty(false)
    setProveedorId('')
    setTipoComprobante('factura')
    setLetra('')
    setPuntoVenta('')
    setNumeroComprobante('')
    setFechaComprobante(fechaHoyISO())
    setFechaFiscal('')
    setMostrarFechaFiscal(false)
    setFormaPago('contado')
    setItems([nuevoItemFacturaCompraUI()])
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

      {aviso && (
        <p
          ref={avisoRef}
          role={aviso.tipo === 'error' ? 'alert' : 'status'}
          className={`scroll-mt-4 rounded px-4 py-3 font-sans text-body-md ${
            aviso.tipo === 'error' ? 'bg-error/10 text-error' : 'bg-success/10 text-success'
          }`}
        >
          {aviso.texto}
        </p>
      )}

      <form onSubmit={handleSubmit} onChangeCapture={() => setDirty(true)} className="flex flex-col gap-stack-md">
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
          <Field label="Número">
            <input
              value={numeroComprobante}
              onChange={(e) => setNumeroComprobante(e.target.value)}
              className={inputClass}
            />
          </Field>
        </div>

        <div className="grid grid-cols-2 gap-stack-sm">
          <Field label="Fecha comprobante">
            <input
              type="date"
              value={fechaComprobante}
              onChange={(e) => setFechaComprobante(e.target.value)}
              className={inputClass}
            />
          </Field>
          <Field label="Forma de pago">
            <select
              value={formaPago}
              onChange={(e) => setFormaPago(e.target.value as FormaPagoCompra)}
              className={selectClass}
            >
              <option value="contado">Contado</option>
              <option value="cuenta_corriente">Cta. cte.</option>
            </select>
          </Field>
        </div>

        {mostrarFechaFiscal ? (
          <Field label="Fecha fiscal" hint="Opcional">
            <input
              type="date"
              value={fechaFiscal}
              onChange={(e) => setFechaFiscal(e.target.value)}
              className={inputClass}
            />
          </Field>
        ) : (
          <button
            type="button"
            onClick={() => setMostrarFechaFiscal(true)}
            className="flex min-h-11 items-center self-start rounded px-1 font-sans text-label-bold text-accent-dark active:bg-accent-light"
          >
            + Agregar fecha fiscal (opcional)
          </button>
        )}

        <p className="font-sans text-label-bold text-ink">Ítems de la factura</p>

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

        <button
          type="button"
          onClick={() => {
            setDirty(true)
            setItems((prev) => [...prev, nuevoItemFacturaCompraUI()])
          }}
          className="flex min-h-12 items-center justify-center gap-1 rounded border border-dashed border-accent/60 font-sans text-label-bold text-accent-dark active:bg-accent-light"
        >
          <IconMas className="h-5 w-5" />
          Agregar ítem
        </button>

        <div className="rounded-lg border border-line bg-surface p-4">
          <div className="flex justify-between font-sans text-body-md text-ink-soft">
            <span>Subtotal (sin IVA)</span>
            <span>{formatCurrency(subtotalPreview)}</span>
          </div>
          <div className="mt-1 flex justify-between font-sans text-body-md text-ink-soft">
            <span>Descuento aplicado</span>
            <span>{formatCurrency(descuentoPreview)}</span>
          </div>
          <div className="mt-1 flex justify-between font-sans text-body-md text-ink-soft">
            <span>IVA (21%)</span>
            <span>{formatCurrency(ivaPreview)}</span>
          </div>
          <div className="mt-1 flex justify-between font-sans text-body-md text-ink-soft">
            <span>Saldo pendiente</span>
            <span>{formatCurrency(saldoPendientePreview)}</span>
          </div>
          <div className="mt-2 flex justify-between border-t border-line pt-2 font-display text-headline-md text-accent-darker">
            <span>Total factura</span>
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

      {blocker.state === 'blocked' && (
        <ConfirmDialog
          title="¿Salir sin guardar?"
          mensaje="Se perderán los ítems cargados."
          confirmLabel="Salir sin guardar"
          onCancel={() => blocker.reset()}
          onConfirm={() => blocker.proceed()}
        />
      )}
    </div>
  )
}
