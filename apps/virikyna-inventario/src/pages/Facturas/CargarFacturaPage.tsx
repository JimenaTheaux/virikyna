import { useEffect, useRef, useState, type FormEvent } from 'react'
import type {
  AlicuotaIvaCompra,
  BorradorConNombres,
  BorradorFila,
  IntentoSalir,
  PayloadBorradorFactura,
  FormaPagoCompra,
  LetraComprobanteCompra,
  OrigenCopiaFactura,
  Proveedor,
  TipoComprobanteCompra,
  TipoCompra,
  ValoresFacturaCompra,
} from '@virikyna/shared'
import {
  alicuotaDefault,
  AvisoComprobanteDuplicado,
  AvisosBorrador,
  BottomSheet,
  DialogoCierreBorrador,
  esBorradorInexistente,
  IndicadorBorrador,
  ListaBorradores,
  payloadBorradorFactura,
  restaurarBorradorFactura,
  resumenBorradorFactura,
  useBorrador,
  useBorradores,
  cargarFacturaCompra,
  calcularTotalesFacturaCompra,
  cambiosPrecioFactura,
  ControlSegmentado,
  errorCabeceraFacturaCompra,
  EstadoBadge,
  etiquetaAlicuotaIva,
  formatCurrency,
  friendlyError,
  hayItemsCargadosFacturaCompra,
  integrarMarcaEnItemsLibres,
  itemsLibresFacturaCompra,
  itemsValidosFacturaCompra,
  mensajeItemsLibresFacturaCompra,
  accionStockFacturaCompra,
  puedeDevolverMercaderia,
  mensajeSinItemsFacturaCompra,
  nuevoItemFacturaCompraUI,
  ObservacionesProveedor,
  OPCIONES_TIPO_COMPRA,
  problemasItemsFacturaCompra,
  SelectorAlicuotaIva,
  TIPO_COMPRA_LABEL,
  TIPO_COMPROBANTE_COMPRA_LABEL,
  TIPOS_COMPROBANTE_COMPRA,
  useCambiosSinGuardar,
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
  const [ivaAlicuota, setIvaAlicuota] = useState<AlicuotaIvaCompra>(vacios.ivaAlicuota)
  const [tipoCompra, setTipoCompra] = useState<TipoCompra>(vacios.tipoCompra)
  // docs/55: solo en NC de artículos; sin marcar, la NC no toca el stock.
  const [devuelveMercaderia, setDevuelveMercaderia] = useState(vacios.devuelveMercaderia)
  // Cambio de artículos ↔ servicios pedido con ítems cargados: se confirma porque los limpia.
  const [tipoCompraPendiente, setTipoCompraPendiente] = useState<TipoCompra | null>(null)
  const [items, setItems] = useState<ItemFacturaCompraUI[]>(vacios.items)
  const [copiaDe, setCopiaDe] = useState<OrigenCopiaFactura | null>(null)
  const [aviso, setAviso] = useState<Aviso | null>(null)
  const [saving, setSaving] = useState(false)
  const [dirty, setDirty] = useState(false)
  const [selectorAbierto, setSelectorAbierto] = useState(false)
  const [confirmLibres, setConfirmLibres] = useState(false)
  // Errores por ítem de la última validación de "Guardar factura" (key → mensaje).
  const [erroresItems, setErroresItems] = useState<Record<string, string>>({})
  // Ítem que tiene que tomar el foco en "Cód. barras"; `n` cambia en cada pedido para que se
  // pueda volver a enfocar el mismo ítem.
  const [foco, setFoco] = useState<{ key: string; n: number } | null>(null)
  const avisoRef = useRef<HTMLParagraphElement>(null)
  // En una copia lo que falta es lo propio de la factura nueva: el foco va a "Número".
  const numeroRef = useRef<HTMLInputElement>(null)
  const [focoNumero, setFocoNumero] = useState(0)

  // Borradores (docs/54): el abierto en la página (retomado de la lista o recargado tras un
  // conflicto), lo que cambió desde que se guardó y la lista "Borradores (N)".
  const [borradorAbierto, setBorradorAbierto] = useState<BorradorConNombres<PayloadBorradorFactura> | null>(null)
  const [retomado, setRetomado] = useState(false)
  const [avisosRestauracion, setAvisosRestauracion] = useState<string[]>([])
  const [listaAbierta, setListaAbierta] = useState(false)
  const [confirmSinBorrador, setConfirmSinBorrador] = useState(false)
  const [verificarDuplicado, setVerificarDuplicado] = useState(0)
  const listaBorradores = useBorradores<PayloadBorradorFactura>(supabase, 'factura_compra', 'inventario')

  // Cambiar de pestaña (o volver atrás) con lo cargado: "Guardar borrador / Descartar / Seguir
  // editando"; recargar o cerrar la app muestra el aviso del navegador (y el borrador ya quedó en el
  // equipo). Lo frena GuardiaNavegacion (App) mientras esta página esté anotada con cambios.
  const [salida, setSalida] = useState<IntentoSalir | null>(null)

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
    setIvaAlicuota(v.ivaAlicuota)
    setTipoCompra(v.tipoCompra)
    setDevuelveMercaderia(v.devuelveMercaderia)
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
  } = calcularTotalesFacturaCompra(items, ivaAlicuota)
  const cambiosPrecio = cambiosPrecioFactura(items, tipoComprobante, proveedorId, proveedores)
  // docs/55: 'suma' (factura, remito…), 'resta' (NC con devolución) o null (servicios, NC sin devolución).
  const accionStock = accionStockFacturaCompra({ tipoComprobante, tipoCompra, devuelveMercaderia })

  // ── Borrador (docs/54) ──
  const valoresActuales: ValoresFacturaCompra = {
    proveedorId,
    tipoComprobante,
    letra,
    puntoVenta,
    numeroComprobante,
    fechaComprobante,
    fechaFiscal,
    formaPago,
    ivaAlicuota,
    tipoCompra,
    devuelveMercaderia,
    items,
    copiaDe,
  }
  // Primer dato real: proveedor, número o un ítem empezado. Cambiar solo la fecha no cuenta.
  const hayDatoReal = Boolean(proveedorId) || numeroComprobante.trim() !== '' || hayItemsCargadosFacturaCompra(items)
  const borrador = useBorrador({
    supabase,
    sistema: 'inventario',
    tipo: 'factura_compra',
    payload: payloadBorradorFactura(valoresActuales),
    resumen: resumenBorradorFactura(valoresActuales, proveedores.find((p) => p.id === proveedorId)?.razon_social ?? '', totalPreview),
    activo: (dirty && hayDatoReal) || retomado,
  })
  useCambiosSinGuardar(dirty && (hayDatoReal || retomado), setSalida)

  async function abrirBorrador(fila: BorradorFila<unknown>) {
    const { valores, avisos } = await restaurarBorradorFactura(supabase, fila.payload as PayloadBorradorFactura)
    aplicarValores(valores)
    setAviso(null)
    setAvisosRestauracion(avisos)
    setRetomado(true)
    borrador.retomar(fila, payloadBorradorFactura(valores))
    setVerificarDuplicado((n) => n + 1)
    window.scrollTo({ top: 0, behavior: 'smooth' })
  }

  // Retomar desde "Borradores (N)": lo que había en pantalla ya quedó como borrador; se sube antes
  // de cambiar, por las dudas.
  async function retomarDeLista(fila: BorradorConNombres<PayloadBorradorFactura>) {
    setListaAbierta(false)
    if (hayDatoReal) await borrador.guardarAhora()
    setBorradorAbierto(fila)
    try {
      await abrirBorrador(fila)
    } catch {
      setAviso({ tipo: 'error', texto: 'No se pudo abrir el borrador. Revisá la conexión y volvé a intentar.' })
    }
    listaBorradores.recargar()
  }

  async function recargarBorrador() {
    const fila = await borrador.leerDelServidor()
    if (fila) await abrirBorrador(fila)
  }

  // Después de restaurar, el comprobante puede haberse cargado mientras el borrador esperaba.
  useEffect(() => {
    if (verificarDuplicado) void duplicado.verificar()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [verificarDuplicado])

  // Formulario vacío para la próxima: otro borrador, desde cero.
  function empezarDeNuevo() {
    aplicarValores(valoresFacturaCompraVacios())
    borrador.reiniciar()
    setRetomado(false)
    setBorradorAbierto(null)
    setAvisosRestauracion([])
    listaBorradores.recargar()
  }

  // Cambiar el tipo vuelve la alícuota al default del tipo nuevo (docs/45); después se cambia a mano.
  function cambiarTipo(tipo: TipoComprobanteCompra) {
    setTipoComprobante(tipo)
    setIvaAlicuota(alicuotaDefault(tipo))
    if (tipo !== 'nota_credito') setDevuelveMercaderia(false)
  }

  // Artículos ↔ servicios (docs/53): los ítems de uno no sirven en el otro, se arranca con un ítem
  // en blanco. Con algo cargado, antes se confirma (tipoCompraPendiente).
  function pedirTipoCompra(tipo: TipoCompra) {
    if (tipo === tipoCompra) return
    if (hayItemsCargadosFacturaCompra(items)) setTipoCompraPendiente(tipo)
    else aplicarTipoCompra(tipo)
  }

  function aplicarTipoCompra(tipo: TipoCompra) {
    setTipoCompraPendiente(null)
    setTipoCompra(tipo)
    if (tipo === 'servicios') setDevuelveMercaderia(false)
    setItems([nuevoItemFacturaCompraUI()])
    setErroresItems({})
    setAviso(null)
    setDirty(true)
  }

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
    const problemas = problemasItemsFacturaCompra(items, tipoCompra)
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
      setAviso({ tipo: 'error', texto: mensajeSinItemsFacturaCompra(tipoCompra) })
      return
    }
    // Ítems sin producto del inventario: no suman stock. Se confirman antes de guardar (docs/50).
    // En servicios no hay producto por definición: no se pregunta (docs/53).
    // NC sin devolución no toca el stock: tampoco se pregunta; con devolución, "no van a restar" (docs/55).
    if (accionStock !== null && itemsLibresFacturaCompra(items).length > 0) {
      setConfirmLibres(true)
      return
    }
    await guardar()
  }

  // "Volver y vincular": marca cada ítem libre en su tarjeta y lleva la vista al primero.
  function volverAVincular() {
    setConfirmLibres(false)
    const libres = itemsLibresFacturaCompra(items)
    setErroresItems(
      Object.fromEntries(libres.map((it) => [it.key, 'Sin producto del inventario: elegilo de la lista o creálo para que sume stock.'])),
    )
    if (libres[0]) {
      document.querySelector(`[data-item-key="${libres[0].key}"]`)?.scrollIntoView({ behavior: 'smooth', block: 'center' })
    }
  }

  // `conBorrador` false: "Guardar igual" después de que el borrador ya no existía (otro lo confirmó o
  // lo eliminó) — se carga sin borrarlo, con el aviso de comprobante repetido a la vista.
  async function guardar(conBorrador = true) {
    setConfirmLibres(false)
    setConfirmSinBorrador(false)
    const accion = accionStock
    const nc = tipoComprobante === 'nota_credito'
    const sumaTodo = itemsLibresFacturaCompra(items).length === 0
    setSaving(true)
    // Frena el autoguardado y espera la subida en curso (si no, quedaría un borrador huérfano).
    const idBorrador = await borrador.prepararConfirmacion()
    const { error: dbError } = await cargarFacturaCompra(supabase, {
      borradorId: conBorrador ? idBorrador : null,
      proveedorId,
      tipoComprobante,
      letra: letra || null,
      puntoVenta: puntoVenta.trim() || null,
      numeroComprobante: numeroComprobante.trim() || null,
      fechaComprobante,
      fechaFiscal: fechaFiscal || null,
      formaPago,
      ivaAlicuota,
      tipoCompra,
      devuelveMercaderia,
      items: integrarMarcaEnItemsLibres(items),
      copiadaDeId: copiaDe?.id ?? null,
    })
    setSaving(false)

    if (dbError) {
      borrador.cancelarConfirmacion()
      if (esBorradorInexistente(dbError)) {
        setConfirmSinBorrador(true)
        void duplicado.verificar()
        return
      }
      setAviso({ tipo: 'error', texto: friendlyError(dbError) })
      return
    }

    // La RPC ya borró el borrador; formulario vacío para la próxima, sin copia.
    borrador.finalizar()
    empezarDeNuevo()
    // Con ítems libres confirmados el stock no se actualizó entero: el mensaje no lo afirma. Servicios
    // y una NC sin devolución nunca tocan el stock (docs/53, docs/55).
    const cargada = copiaDe ? 'Copia cargada' : nc ? 'Nota de crédito cargada' : 'Factura cargada'
    const texto =
      accion === null
        ? `${cargada} (no mueve stock).`
        : accion === 'resta'
          ? sumaTodo
            ? `${cargada} y stock descontado (devolución de mercadería).`
            : `${cargada}. Los ítems sin producto no restaron stock.`
          : sumaTodo
            ? `${cargada} y stock actualizado correctamente.`
            : `${cargada}. Los ítems sin producto no sumaron stock.`
    setAviso({ tipo: 'exito', texto })
  }

  if (!rol) return null

  const ocupado = saving || copia.cargando

  return (
    <div className="flex flex-col gap-stack-md pb-stack-lg">
      <div>
        <div className="flex items-start justify-between gap-stack-sm">
          <h1 className="font-display text-headline-lg text-accent-darker">
            {retomado ? 'Borrador de factura' : copiaDe ? 'Copiar factura' : 'Carga de factura'}
          </h1>
          {/* docs/54: Inventario no tiene listado de facturas; los borradores se abren desde acá. */}
          <button
            type="button"
            onClick={() => {
              listaBorradores.recargar()
              setListaAbierta(true)
            }}
            className="flex min-h-11 shrink-0 items-center rounded border border-line bg-surface px-3 font-sans text-label-bold text-ink active:bg-accent-light"
          >
            Borradores ({listaBorradores.borradores.length})
          </button>
        </div>
        <p className="mt-1 font-sans text-body-md text-ink-soft">
          {tipoCompra === 'servicios'
            ? 'Registrá una factura de servicios — suma a la cuenta del proveedor, no mueve stock.'
            : tipoComprobante === 'nota_credito'
              ? 'Nota de crédito — no mueve stock, salvo que marques "Devolución de mercadería".'
              : 'Registrá una factura de proveedor — actualiza el stock automáticamente por ítem.'}
        </p>
      </div>

      {/* docs/53: define qué campos tiene cada ítem; se elige siempre a mano. */}
      <ControlSegmentado
        legend="Tipo de compra"
        opciones={OPCIONES_TIPO_COMPRA}
        value={tipoCompra}
        onChange={pedirTipoCompra}
        disabled={ocupado}
        size="touch"
        resaltado
      />

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

      <AvisosBorrador
        size="touch"
        estado={borrador.estado}
        autorAjeno={
          borradorAbierto && borrador.usuarioId && borradorAbierto.usuario_id !== borrador.usuarioId
            ? { nombre: borradorAbierto.autor, creado: borradorAbierto.created_at }
            : null
        }
        avisosRestauracion={avisosRestauracion}
        onRecargar={() => void recargarBorrador()}
        onGuardarComoNuevo={() => void borrador.guardarComoNuevo()}
      />

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
        <ObservacionesProveedor observaciones={proveedores.find((p) => p.id === proveedorId)?.observaciones} />

        <div className="grid grid-cols-2 gap-stack-sm">
          <Field label="Tipo de comprobante">
            <select
              value={tipoComprobante}
              onChange={(e) => cambiarTipo(e.target.value as TipoComprobanteCompra)}
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

        {/* docs/55: solo en NC de artículos. Sin marcar, la NC no toca el stock. */}
        {puedeDevolverMercaderia(tipoComprobante, tipoCompra) && (
          <label className="flex min-h-12 cursor-pointer items-start gap-3 rounded border border-line bg-surface px-4 py-3 active:bg-accent-light">
            <input
              type="checkbox"
              checked={devuelveMercaderia}
              onChange={(e) => setDevuelveMercaderia(e.target.checked)}
              className="mt-0.5 h-5 w-5 shrink-0 accent-accent"
            />
            <span className="font-sans">
              <span className="block text-label-bold text-ink">Devolución de mercadería</span>
              <span className="block text-label-md text-ink-soft">
                {devuelveMercaderia
                  ? 'Resta del stock la cantidad de cada ítem, en su depósito.'
                  : 'Sin marcar, la nota de crédito no toca el stock.'}
              </span>
            </span>
          </label>
        )}

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

        <p className="font-sans text-label-bold text-ink">
          {tipoCompra === 'servicios' ? 'Servicios de la factura' : 'Ítems de la factura'}
        </p>

        <div className="flex flex-col gap-stack-sm">
          {items.map((item, i) => (
            <ItemFacturaRow
              key={item.key}
              item={item}
              index={i}
              servicios={tipoCompra === 'servicios'}
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
          {/* Dentro del <form>: el cambio lo marca onChangeCapture, como el resto de los campos. */}
          <div className="mb-stack-sm">
            <SelectorAlicuotaIva value={ivaAlicuota} onChange={setIvaAlicuota} size="touch" />
          </div>
          <div className="flex justify-between font-sans text-body-md text-ink-soft">
            <span>Subtotal (sin IVA)</span>
            <span>{formatCurrency(subtotalPreview)}</span>
          </div>
          <div className="mt-1 flex justify-between font-sans text-body-md text-ink-soft">
            <span>Descuento aplicado</span>
            <span>{formatCurrency(descuentoPreview)}</span>
          </div>
          <div className="mt-1 flex justify-between font-sans text-body-md text-ink-soft">
            <span>{etiquetaAlicuotaIva(ivaAlicuota)}</span>
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
        <button
          type="button"
          onClick={() => void borrador.guardarAhora()}
          disabled={ocupado || !hayDatoReal}
          className="min-h-12 rounded border border-accent px-4 font-sans text-label-bold text-accent-darker active:bg-accent-light disabled:opacity-60"
        >
          Guardar borrador
        </button>
        <div className="text-center">
          <IndicadorBorrador estado={borrador.estado} />
        </div>
      </form>

      {listaAbierta && (
        <BottomSheet title="Borradores de facturas" onClose={() => setListaAbierta(false)} dialogo={{ onEscape: () => setListaAbierta(false) }}>
          <ListaBorradores
            supabase={supabase}
            sistema="inventario"
            lista={listaBorradores}
            onRetomar={(b) => void retomarDeLista(b)}
            variante="tarjetas"
          />
        </BottomSheet>
      )}

      {confirmSinBorrador && (
        <ConfirmDialog
          title="El borrador ya no existe"
          mensaje="Otro usuario lo confirmó o lo eliminó mientras lo editabas. La factura no se cargó: revisá que no esté cargada antes de guardarla igual."
          confirmLabel="Guardar igual"
          cancelLabel="Volver"
          onCancel={() => setConfirmSinBorrador(false)}
          onConfirm={() => void guardar(false)}
        />
      )}

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

      {tipoCompraPendiente && (
        <ConfirmDialog
          title={`¿Cambiar a ${TIPO_COMPRA_LABEL[tipoCompraPendiente].toLowerCase()}?`}
          mensaje={`Los ítems cargados se borran: ${
            tipoCompraPendiente === 'servicios'
              ? 'un servicio no lleva producto, código ni cantidad.'
              : 'un artículo lleva producto y cantidad.'
          } La cabecera (proveedor, comprobante, fechas e IVA) queda igual.`}
          confirmLabel="Cambiar y borrar ítems"
          onCancel={() => setTipoCompraPendiente(null)}
          onConfirm={() => aplicarTipoCompra(tipoCompraPendiente)}
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

      {confirmLibres && (
        <ConfirmDialog
          title={accionStock === 'resta' ? 'Ítems que no restan stock' : 'Ítems que no suman stock'}
          mensaje={mensajeItemsLibresFacturaCompra(itemsLibresFacturaCompra(items), accionStock ?? 'suma')}
          confirmLabel={accionStock === 'resta' ? 'Guardar sin restar stock' : 'Guardar sin sumar stock'}
          cancelLabel="Volver y vincular"
          onCancel={volverAVincular}
          onConfirm={() => void guardar()}
        />
      )}

      {salida && (
        <DialogoCierreBorrador
          retomado={retomado}
          onSeguir={() => {
            salida.cancelar()
            setSalida(null)
          }}
          onDescartar={async () => {
            await borrador.descartar()
            setSalida(null)
            salida.continuar()
          }}
          onGuardar={async () => {
            await borrador.guardarAhora()
            setSalida(null)
            salida.continuar()
          }}
        />
      )}
    </div>
  )
}
