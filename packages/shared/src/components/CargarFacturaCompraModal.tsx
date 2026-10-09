import { useEffect, useRef, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { FormaPagoCompra, LetraComprobanteCompra, Proveedor, TipoComprobanteCompra } from '../../types/database'
import {
  cargarFacturaCompra,
  calcularTotalesFacturaCompra,
  errorCabeceraFacturaCompra,
  integrarMarcaEnItemsLibres,
  itemsValidosFacturaCompra,
  nuevoItemFacturaCompraUI,
  problemasItemsFacturaCompra,
  TIPO_COMPROBANTE_COMPRA_LABEL,
  TIPOS_COMPROBANTE_COMPRA,
  valoresFacturaCompraVacios,
  type ItemFacturaCompraUI,
  type OrigenCopiaFactura,
  type ValoresFacturaCompra,
} from '../../lib/facturasCompra'
import { useComprobanteDuplicado, useCopiaFacturaCompra } from '../../lib/useCopiaFacturaCompra'
import { formatCurrency } from '../../lib/format'
import { cambiosPrecioFactura } from '../../lib/precios'
import { mensajeErrorGuardado } from '../../lib/supabaseErrors'
import { Modal } from './Modal'
import { ConfirmDialog } from './ConfirmDialog'
import { Field, ErrorText, inputClass, selectClass } from './FormField'
import { EstadoBadge } from './EstadoBadge'
import { ItemFacturaRow, type CrearProductoRender } from './ItemFacturaRow'
import { AvisoComprobanteDuplicado } from './AvisosCopiaFactura'
import { SelectorFacturaCopiaModal } from './SelectorFacturaCopiaModal'
import { ObservacionesProveedor } from './ObservacionesProveedor'

// Etiquetas compartidas (TIPO_COMPROBANTE_COMPRA_LABEL); acá se aclara cuáles no son fiscales.
// Presupuesto (docs/31) se carga igual que un remito: suma stock y deuda, y actualiza costo.
const SIN_RESPALDO_FISCAL: TipoComprobanteCompra[] = ['cupon', 'presupuesto']
const TIPOS: { value: TipoComprobanteCompra; label: string }[] = TIPOS_COMPROBANTE_COMPRA.map((t) => ({
  value: t,
  label: SIN_RESPALDO_FISCAL.includes(t) ? `${TIPO_COMPROBANTE_COMPRA_LABEL[t]} (no facturado)` : TIPO_COMPROBANTE_COMPRA_LABEL[t],
}))

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
  // Copia (docs/33). Con solo `copiadaDeId` el modal carga la factura él mismo (el mismo camino que
  // "Copiar desde…"); `valoresIniciales` es para quien ya la tiene armada (facturaACopia).
  valoresIniciales?: ValoresFacturaCompra
  copiadaDeId?: string
  // Link "Copia de Factura A 0001-123": cada app abre su propio detalle de factura. Sin esta prop
  // el origen se muestra como texto.
  onVerOriginal?: (facturaId: string) => void
}

// Carga de factura de compra de escritorio, compartida por Virikyna Local y Virikyna Gestión (una
// sola copia — antes cada app tenía la suya y Gestión quedó con la versión vieja de tarjetas).
// Misma lógica de negocio (lib/facturasCompra.ts) y mismo RPC atómico `cargar_factura_compra` que
// Virikyna Inventario (celular), solo cambia la UI: acá va en un modal tipo planilla (una fila por
// ítem, editable celda por celda), con totales y botones en el footer fijo del Modal, y la
// búsqueda de producto por ítem es por tipeo/lector en vez de cámara (ver ItemFacturaRow).
// También sirve para copiar una factura ya cargada (docs/33): la lógica de la copia, el selector y
// el aviso de comprobante repetido viven en lib/useCopiaFacturaCompra.ts, compartida con Inventario.
export function CargarFacturaCompraModal({
  supabase,
  crearProducto,
  onClose,
  onSaved,
  valoresIniciales,
  copiadaDeId,
  onVerOriginal,
}: Props) {
  const inicial = valoresIniciales ?? valoresFacturaCompraVacios()
  // Abierto con solo el id: hasta que llega la factura no se muestra un formulario vacío.
  const [esperandoCopia, setEsperandoCopia] = useState(Boolean(copiadaDeId && !valoresIniciales))

  const [proveedores, setProveedores] = useState<Proveedor[]>([])
  const [proveedorId, setProveedorId] = useState(inicial.proveedorId)
  const [tipoComprobante, setTipoComprobante] = useState<TipoComprobanteCompra>(inicial.tipoComprobante)
  const [letra, setLetra] = useState<LetraComprobanteCompra | ''>(inicial.letra)
  const [puntoVenta, setPuntoVenta] = useState(inicial.puntoVenta)
  const [numeroComprobante, setNumeroComprobante] = useState(inicial.numeroComprobante)
  const [fechaComprobante, setFechaComprobante] = useState(esperandoCopia ? '' : inicial.fechaComprobante)
  const [fechaFiscal, setFechaFiscal] = useState(inicial.fechaFiscal)
  const [mostrarFechaFiscal, setMostrarFechaFiscal] = useState(Boolean(inicial.fechaFiscal))
  const [formaPago, setFormaPago] = useState<FormaPagoCompra>(inicial.formaPago)
  const [items, setItems] = useState<ItemFacturaCompraUI[]>(inicial.items)
  const [copiaDe, setCopiaDe] = useState<OrigenCopiaFactura | null>(inicial.copiaDe)
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [dirty, setDirty] = useState(false)
  const [confirmCerrar, setConfirmCerrar] = useState(false)
  const [selectorAbierto, setSelectorAbierto] = useState(false)
  // Ítems marcados por la última validación de "Guardar factura"; se desmarcan al editarlos.
  const [itemsConError, setItemsConError] = useState<Set<string>>(new Set())
  // Fila que tiene que tomar el foco en "Cód. barras"; `n` cambia en cada pedido para que se pueda
  // volver a enfocar la misma fila.
  const [foco, setFoco] = useState<{ key: string; n: number } | null>(null)
  // En una copia lo que falta es lo propio de la factura nueva: el foco arranca en "Número".
  const numeroRef = useRef<HTMLInputElement>(null)
  const [focoNumero, setFocoNumero] = useState(inicial.copiaDe ? 1 : 0)

  function aplicarValores(v: ValoresFacturaCompra) {
    setProveedorId(v.proveedorId)
    setTipoComprobante(v.tipoComprobante)
    setLetra(v.letra)
    setPuntoVenta(v.puntoVenta)
    setNumeroComprobante(v.numeroComprobante)
    setFechaComprobante(v.fechaComprobante)
    setFechaFiscal(v.fechaFiscal)
    setMostrarFechaFiscal(Boolean(v.fechaFiscal))
    setFormaPago(v.formaPago)
    setItems(v.items)
    setCopiaDe(v.copiaDe)
    setItemsConError(new Set())
    setError(null)
    // Recién copiada no hay nada tipeado que perder: cerrar no pide confirmación.
    setDirty(false)
    setEsperandoCopia(false)
    if (v.copiaDe) setFocoNumero((n) => n + 1)
  }

  const copia = useCopiaFacturaCompra({ supabase, tieneDatos: dirty || copiaDe !== null, onAplicar: aplicarValores })
  const duplicado = useComprobanteDuplicado(supabase, { proveedorId, tipoComprobante, letra, puntoVenta, numeroComprobante })

  useEffect(() => {
    if (copiadaDeId && !valoresIniciales) copia.pedirCopia(copiadaDeId, true)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // Si la precarga falla, se muestra el error sobre un formulario vacío (se puede cargar igual).
  useEffect(() => {
    if (copia.error && esperandoCopia) {
      setEsperandoCopia(false)
      setFechaComprobante(valoresFacturaCompraVacios().fechaComprobante)
    }
  }, [copia.error, esperandoCopia])

  useEffect(() => {
    if (focoNumero) numeroRef.current?.focus()
  }, [focoNumero])

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

  function agregarItem() {
    const nuevo = nuevoItemFacturaCompraUI()
    setItems((prev) => [...prev, nuevo])
    setFoco((prev) => ({ key: nuevo.key, n: (prev?.n ?? 0) + 1 }))
  }

  // Enter del lector en una fila que ya encontró su producto: sigue en la fila de abajo, o crea
  // una nueva si era la última — para escanear varios ítems seguidos sin tocar el mouse.
  function avanzarDesde(key: string) {
    const i = items.findIndex((it) => it.key === key)
    const siguiente = items[i + 1]
    if (siguiente) setFoco((prev) => ({ key: siguiente.key, n: (prev?.n ?? 0) + 1 }))
    else agregarItem()
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
  const cambiosPrecio = cambiosPrecioFactura(items, tipoComprobante, proveedorId, proveedores)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)

    const errorCabecera = errorCabeceraFacturaCompra({ proveedorId, numeroComprobante, fechaComprobante, copiaDe })
    if (errorCabecera) {
      setError(errorCabecera)
      if (copiaDe && !numeroComprobante.trim()) numeroRef.current?.focus()
      return
    }
    // Un ítem empezado pero incompleto se descartaba en silencio al guardar: ahora bloquea, se
    // marca en rojo y se lleva la vista hasta el primero. Incluye un producto inactivo copiado
    // sin confirmar (docs/33).
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
      copiadaDeId: copiaDe?.id ?? null,
    })
    setSaving(false)

    if (dbError) {
      setError(mensajeErrorGuardado(dbError, status, 'cargar la factura', 'lo que cargaste sigue acá'))
      return
    }

    onSaved()
  }

  const ocupado = saving || copia.cargando || esperandoCopia

  return (
    <Modal
      title={copiaDe ? 'Copiar factura' : 'Nueva factura de compra'}
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
              disabled={ocupado}
              className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
            >
              {saving ? 'Guardando...' : 'Guardar factura'}
            </button>
          </div>
        </div>
      }
    >
      {esperandoCopia ? (
        <p role="status" className="font-sans text-body-md text-ink-soft">
          Cargando la factura a copiar…
        </p>
      ) : (
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
          {/* Origen de la copia + "Copiar desde…" */}
          <div className="flex flex-wrap items-center justify-between gap-stack-sm">
            {copiaDe ? (
              <p className="flex flex-wrap items-center gap-2 font-sans text-body-md text-ink-soft">
                Copia de
                {onVerOriginal ? (
                  <button
                    type="button"
                    onClick={() => onVerOriginal(copiaDe.id)}
                    className="rounded text-accent-dark underline hover:text-accent-darker focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
                  >
                    {copiaDe.etiqueta}
                  </button>
                ) : (
                  <span className="text-ink">{copiaDe.etiqueta}</span>
                )}
                {copiaDe.anulada && <EstadoBadge variant="red">Anulada</EstadoBadge>}
              </p>
            ) : (
              <span />
            )}
            <button
              type="button"
              onClick={() => setSelectorAbierto(true)}
              disabled={ocupado}
              className="rounded border border-accent px-3 py-2 font-sans text-label-bold text-accent-darker transition hover:bg-accent-light disabled:opacity-60"
            >
              Copiar desde…
            </button>
          </div>

          {copia.cargando && (
            <p role="status" className="font-sans text-label-md text-ink-soft">
              Cargando la factura a copiar…
            </p>
          )}
          {copia.error && <ErrorText>{copia.error}</ErrorText>}

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
            {/* Fila propia al terminar la del proveedor: dentro de su celda desalinearía la franja. */}
            <ObservacionesProveedor
              observaciones={proveedores.find((p) => p.id === proveedorId)?.observaciones}
              className="col-span-2 md:col-span-8"
            />
            <div className="col-span-1 md:col-span-2">
              <Field label="Punto de venta">
                <input value={puntoVenta} onChange={(e) => setPuntoVenta(e.target.value)} className={inputClass} />
              </Field>
            </div>
            <div className="col-span-1 md:col-span-2">
              <Field label="Número">
                <input
                  ref={numeroRef}
                  value={numeroComprobante}
                  onChange={(e) => setNumeroComprobante(e.target.value)}
                  onBlur={() => void duplicado.verificar()}
                  aria-required={Boolean(copiaDe)}
                  placeholder={copiaDe ? 'Obligatorio' : undefined}
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
                  aria-required
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

          <AvisoComprobanteDuplicado coincidencias={duplicado.coincidencias} />

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
                  cambioPrecio={cambiosPrecio.get(item.key)}
                  focoCodigo={foco?.key === item.key ? foco.n : 0}
                  onAvanzar={() => avanzarDesde(item.key)}
                  onChange={(cambios) => actualizarItem(item.key, cambios)}
                  onEliminar={() => eliminarItem(item.key)}
                />
              ))}
            </tbody>
          </table>

          <button
            type="button"
            onClick={agregarItem}
            className="self-start rounded px-3 py-2 font-sans text-label-bold text-accent-dark hover:bg-accent-light"
          >
            + Agregar ítem
          </button>
        </form>
      )}

      {/* Fuera del <form>: el Enter del buscador del selector no tiene que llegar al formulario. */}
      {selectorAbierto && (
        <SelectorFacturaCopiaModal
          supabase={supabase}
          proveedores={proveedores}
          proveedorInicial={proveedorId}
          onClose={() => setSelectorAbierto(false)}
          onElegir={(id) => {
            setSelectorAbierto(false)
            copia.limpiarError()
            copia.pedirCopia(id)
          }}
        />
      )}

      {copia.pendiente && (
        <ConfirmDialog
          title="Reemplazar lo cargado"
          mensaje="Se reemplaza todo lo que hay en el formulario (cabecera e ítems) por los datos de la factura elegida."
          confirmLabel="Reemplazar"
          onCancel={copia.cancelarReemplazo}
          onConfirm={copia.confirmarReemplazo}
        />
      )}

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
