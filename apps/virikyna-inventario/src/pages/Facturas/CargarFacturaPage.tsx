import { useEffect, useRef, useState, type FormEvent } from 'react'
import { useBlocker } from 'react-router-dom'
import type {
  FormaPagoCompra,
  LetraComprobanteCompra,
  OrigenCopiaFactura,
  Proveedor,
  TipoComprobanteCompra,
  ValoresFacturaCompra,
} from '@virikyna/shared'
import {
  AvisoComprobanteDuplicado,
  cargarFacturaCompra,
  calcularTotalesFacturaCompra,
  cambiosPrecioFactura,
  errorCabeceraFacturaCompra,
  EstadoBadge,
  formatCurrency,
  friendlyError,
  integrarMarcaEnItemsLibres,
  itemsValidosFacturaCompra,
  nuevoItemFacturaCompraUI,
  problemasItemsFacturaCompra,
  TIPO_COMPROBANTE_COMPRA_LABEL,
  TIPOS_COMPROBANTE_COMPRA,
  useComprobanteDuplicado,
  useCopiaFacturaCompra,
  valoresFacturaCompraVacios,
  type ItemFacturaCompraUI,
} from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { usePerfil } from '../../auth/AuthContext'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { Field, inputClass, selectClass } from '../../components/FormField'
import { IconMas } from '../../components/icons'
import { ItemFacturaRow } from './ItemFacturaRow'
import { SelectorFacturaCopiaSheet } from './SelectorFacturaCopiaSheet'

// Mismas etiquetas que el escritorio (TIPO_COMPROBANTE_COMPRA_LABEL compartida, incluye
// presupuesto, docs/31); acá se aclara cuáles no son fiscales.
const SIN_RESPALDO_FISCAL: TipoComprobanteCompra[] = ['cupon', 'presupuesto']
const TIPOS: { value: TipoComprobanteCompra; label: string }[] = TIPOS_COMPROBANTE_COMPRA.map((t) => ({
  value: t,
  label: SIN_RESPALDO_FISCAL.includes(t) ? `${TIPO_COMPROBANTE_COMPRA_LABEL[t]} (no facturado)` : TIPO_COMPROBANTE_COMPRA_LABEL[t],
}))

const LETRAS: LetraComprobanteCompra[] = ['A', 'B', 'R', 'X']

// Un aviso nuevo es siempre un objeto nuevo: así el scroll automático se dispara también cuando se
// repite el mismo mensaje (ej. dos toques seguidos en Guardar con el mismo error).
type Aviso = { tipo: 'error' | 'exito'; texto: string }

// Acceso directo a carga de facturas de proveedor desde el celular (docs/04_modulos_y_funciones.md,
// módulo 5.1) — usa el mismo RPC atómico `cargar_factura_compra` que actualiza stock por ubicación
// (docs/06_estructura_de_datos.md), sin reimplementar esa lógica en el cliente: acá solo se arma el
// payload y se muestra una vista previa de los totales. Copiar una factura (docs/33) usa los mismos
// hooks que el escritorio (lib/useCopiaFacturaCompra.ts); acá solo va el dibujo táctil.
export function CargarFacturaPage() {
  const { rol } = usePerfil()
  const vacios = valoresFacturaCompraVacios()
  const [proveedores, setProveedores] = useState<Proveedor[]>([])
  const [proveedorId, setProveedorId] = useState(vacios.proveedorId)
  const [tipoComprobante, setTipoComprobante] = useState<TipoComprobanteCompra>(vacios.tipoComprobante)
  const [letra, setLetra] = useState<LetraComprobanteCompra | ''>(vacios.letra)
  const [puntoVenta, setPuntoVenta] = useState(vacios.puntoVenta)
  const [numeroComprobante, setNumeroComprobante] = useState(vacios.numeroComprobante)
  const [fechaComprobante, setFechaComprobante] = useState(vacios.fechaComprobante)
  const [fechaFiscal, setFechaFiscal] = useState(vacios.fechaFiscal)
  const [mostrarFechaFiscal, setMostrarFechaFiscal] = useState(false)
  const [formaPago, setFormaPago] = useState<FormaPagoCompra>(vacios.formaPago)
  const [items, setItems] = useState<ItemFacturaCompraUI[]>(vacios.items)
  const [copiaDe, setCopiaDe] = useState<OrigenCopiaFactura | null>(null)
  const [aviso, setAviso] = useState<Aviso | null>(null)
  const [saving, setSaving] = useState(false)
  const [dirty, setDirty] = useState(false)
  const [selectorAbierto, setSelectorAbierto] = useState(false)
  // Errores por ítem de la última validación de "Guardar factura" (key → mensaje).
  const [erroresItems, setErroresItems] = useState<Record<string, string>>({})
  // Ítem que tiene que tomar el foco en "Cód. barras"; `n` cambia en cada pedido para que se
  // pueda volver a enfocar el mismo ítem.
  const [foco, setFoco] = useState<{ key: string; n: number } | null>(null)
  const avisoRef = useRef<HTMLParagraphElement>(null)
  // En una copia lo que falta es lo propio de la factura nueva: el foco va a "Número".
  const numeroRef = useRef<HTMLInputElement>(null)
  const [focoNumero, setFocoNumero] = useState(0)

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
  // sin esto el resultado quedaba fuera de pantalla. Si el error es de un ítem, la vista va a esa
  // tarjeta (ItemFacturaRow) en vez de al mensaje general.
  useEffect(() => {
    if (aviso && Object.keys(erroresItems).length === 0) {
      avisoRef.current?.scrollIntoView({ behavior: 'smooth', block: 'center' })
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [aviso])

  useEffect(() => {
    if (!focoNumero) return
    numeroRef.current?.scrollIntoView({ behavior: 'smooth', block: 'center' })
    numeroRef.current?.focus({ preventScroll: true })
  }, [focoNumero])

  // Carga todo el formulario de una vez: una copia (facturaACopia) o el formulario vacío al
  // reiniciar después de guardar. Recién aplicado no hay nada tipeado que perder (dirty = false).
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
    setErroresItems({})
    setDirty(false)
    if (v.copiaDe) {
      setAviso(null)
      setFocoNumero((n) => n + 1)
    }
  }

  const copia = useCopiaFacturaCompra({ supabase, tieneDatos: dirty || copiaDe !== null, onAplicar: aplicarValores })
  const duplicado = useComprobanteDuplicado(supabase, { proveedorId, tipoComprobante, letra, puntoVenta, numeroComprobante })

  function actualizarItem(key: string, cambios: Partial<ItemFacturaCompraUI>) {
    setDirty(true)
    setErroresItems((prev) => {
      if (!(key in prev)) return prev
      const { [key]: _resuelto, ...resto } = prev
      return resto
    })
    setItems((prev) => prev.map((it) => (it.key === key ? { ...it, ...cambios } : it)))
  }

  function agregarItem() {
    const nuevo = nuevoItemFacturaCompraUI()
    setDirty(true)
    setItems((prev) => [...prev, nuevo])
    setFoco((prev) => ({ key: nuevo.key, n: (prev?.n ?? 0) + 1 }))
  }

  // Enter del lector en un ítem que ya encontró su producto: sigue en el ítem de abajo, o crea
  // uno nuevo si era el último.
  function avanzarDesde(key: string) {
    const i = items.findIndex((it) => it.key === key)
    const siguiente = items[i + 1]
    if (siguiente) setFoco((prev) => ({ key: siguiente.key, n: (prev?.n ?? 0) + 1 }))
    else agregarItem()
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
  const cambiosPrecio = cambiosPrecioFactura(items, tipoComprobante, proveedorId, proveedores)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setAviso(null)

    const errorCabecera = errorCabeceraFacturaCompra({ proveedorId, numeroComprobante, fechaComprobante, copiaDe })
    if (errorCabecera) {
      setAviso({ tipo: 'error', texto: errorCabecera })
      if (copiaDe && !numeroComprobante.trim()) setFocoNumero((n) => n + 1)
      return
    }
    // Un ítem empezado pero incompleto (ej. código escaneado sin producto) se descartaba en
    // silencio al guardar: ahora bloquea y se marca en la tarjeta, que se trae a la vista sola.
    // Incluye un producto inactivo copiado sin confirmar (docs/33).
    const problemas = problemasItemsFacturaCompra(items)
    setErroresItems(Object.fromEntries(problemas.map((p) => [p.key, p.mensaje])))
    if (problemas.length > 0) {
      document
        .querySelector(`[data-item-key="${problemas[0].key}"]`)
        ?.scrollIntoView({ behavior: 'smooth', block: 'center' })
      setAviso({
        tipo: 'error',
        texto:
          problemas.length === 1
            ? problemas[0].mensaje
            : `Hay ${problemas.length} ítems incompletos (${problemas.map((p) => p.numero).join(', ')}): completalos o quitalos.`,
      })
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
      copiadaDeId: copiaDe?.id ?? null,
    })
    setSaving(false)

    if (dbError) {
      setAviso({ tipo: 'error', texto: friendlyError(dbError) })
      return
    }

    // Formulario vacío para la próxima, sin copia.
    aplicarValores(valoresFacturaCompraVacios())
    setAviso({
      tipo: 'exito',
      texto: copiaDe ? 'Copia cargada y stock actualizado correctamente.' : 'Factura cargada y stock actualizado correctamente.',
    })
  }

  if (!rol) return null

  const ocupado = saving || copia.cargando

  return (
    <div className="flex flex-col gap-stack-md pb-stack-lg">
      <div>
        <h1 className="font-display text-headline-lg text-accent-darker">{copiaDe ? 'Copiar factura' : 'Carga de factura'}</h1>
        <p className="mt-1 font-sans text-body-md text-ink-soft">
          Registrá una factura de proveedor — actualiza el stock automáticamente por ítem.
        </p>
      </div>

      <button
        type="button"
        onClick={() => setSelectorAbierto(true)}
        disabled={ocupado}
        className="flex min-h-12 items-center justify-center rounded border border-accent font-sans text-label-bold text-accent-darker active:bg-accent-light disabled:opacity-60"
      >
        Copiar desde…
      </button>

      {copia.cargando && (
        <p role="status" className="font-sans text-body-md text-ink-soft">
          Cargando la factura a copiar…
        </p>
      )}
      {copia.error && (
        <p role="alert" className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">
          {copia.error}
        </p>
      )}

      {copiaDe && (
        <div className="flex flex-wrap items-center gap-2 rounded border border-accent/50 bg-accent-light/50 px-4 py-3 font-sans text-body-md text-ink">
          <span>
            Copia de <strong>{copiaDe.etiqueta}</strong>
          </span>
          {copiaDe.anulada && <EstadoBadge variant="red">Anulada</EstadoBadge>}
          <span className="w-full text-label-md text-ink-soft">Completá el número y la fecha de la factura nueva.</span>
        </div>
      )}

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

      <form
        onSubmit={handleSubmit}
        onChangeCapture={() => setDirty(true)}
        // Mismo freno que la planilla de Local/Gestión (commit 97b6a92): Enter en un campo nunca
        // envía la factura — ni el Enter del lector físico ni el "Ir" del teclado del celular, desde
        // ningún campo (antes solo lo frenaban Cód. barras y Producto, y desde Cantidad/Precio/etc.
        // se guardaba la factura a medio cargar y se vaciaba el formulario). Solo guarda el botón.
        onKeyDown={(e) => {
          if (e.key === 'Enter' && e.target instanceof HTMLInputElement) e.preventDefault()
        }}
        className="flex flex-col gap-stack-md"
      >
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
              ref={numeroRef}
              value={numeroComprobante}
              onChange={(e) => setNumeroComprobante(e.target.value)}
              onBlur={() => void duplicado.verificar()}
              aria-required={Boolean(copiaDe)}
              placeholder={copiaDe ? 'Obligatorio' : undefined}
              className={`scroll-mt-4 ${inputClass}`}
            />
          </Field>
        </div>

        <AvisoComprobanteDuplicado coincidencias={duplicado.coincidencias} size="touch" />

        <div className="grid grid-cols-2 gap-stack-sm">
          <Field label="Fecha comprobante">
            <input
              type="date"
              value={fechaComprobante}
              onChange={(e) => setFechaComprobante(e.target.value)}
              aria-required
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
              error={erroresItems[item.key]}
              cambioPrecio={cambiosPrecio.get(item.key)}
              focoCodigo={foco?.key === item.key ? foco.n : 0}
              onChange={(cambios) => actualizarItem(item.key, cambios)}
              onEliminar={() => eliminarItem(item.key)}
              onAvanzar={() => avanzarDesde(item.key)}
            />
          ))}
        </div>

        <button
          type="button"
          onClick={agregarItem}
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
          disabled={ocupado}
          className="rounded bg-accent px-4 py-4 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
        >
          {saving ? 'Guardando...' : 'Guardar factura'}
        </button>
      </form>

      {selectorAbierto && (
        <SelectorFacturaCopiaSheet
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
          title="¿Reemplazar lo cargado?"
          mensaje="Se reemplaza todo lo que hay en el formulario (cabecera e ítems) por los datos de la factura elegida."
          confirmLabel="Reemplazar"
          onCancel={copia.cancelarReemplazo}
          onConfirm={copia.confirmarReemplazo}
        />
      )}

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
