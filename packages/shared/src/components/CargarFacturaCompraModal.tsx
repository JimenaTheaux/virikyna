import { useEffect, useRef, useState, type FormEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type {
  FacturaCompraSaldo,
  FormaPagoCompra,
  LetraComprobanteCompra,
  Proveedor,
  TipoComprobanteCompra,
  TipoCompra,
} from '../../types/database'
import {
  alicuotaDefault,
  cargarFacturaCompra,
  calcularTotalesFacturaCompra,
  errorCabeceraFacturaCompra,
  etiquetaAlicuotaIva,
  hayItemsCargadosFacturaCompra,
  integrarMarcaEnItemsLibres,
  itemsLibresFacturaCompra,
  itemsValidosFacturaCompra,
  mensajeItemsLibresFacturaCompra,
  mensajeSinItemsFacturaCompra,
  nuevoItemFacturaCompraUI,
  OPCIONES_TIPO_COMPRA,
  problemasItemsFacturaCompra,
  TIPO_COMPRA_LABEL,
  TIPO_COMPROBANTE_COMPRA_LABEL,
  TIPOS_COMPROBANTE_COMPRA,
  valoresFacturaCompraVacios,
  type AlicuotaIvaCompra,
  type ItemFacturaCompraUI,
  type OrigenCopiaFactura,
  type ValoresFacturaCompra,
} from '../../lib/facturasCompra'
import { useComprobanteDuplicado, useCopiaFacturaCompra } from '../../lib/useCopiaFacturaCompra'
import { useBorrador, type BorradorConNombres, type BorradorFila, type SistemaApp } from '../../lib/borradores'
import {
  payloadBorradorFactura,
  restaurarBorradorFactura,
  resumenBorradorFactura,
  type PayloadBorradorFactura,
} from '../../lib/borradorFactura'
import { esBorradorInexistente } from '../../lib/facturasCompra'
import { AvisosBorrador, IndicadorBorrador } from './Borradores'
import { obtenerACuentaProveedor } from '../../lib/pagosACuenta'
import { formatCurrency } from '../../lib/format'
import { cambiosPrecioFactura } from '../../lib/precios'
import { mensajeErrorGuardado } from '../../lib/supabaseErrors'
import { BotonCerrarModal, Modal } from './Modal'
import { ConfirmDialog } from './ConfirmDialog'
import { Field, ErrorText, inputClass, selectClass } from './FormField'
import { EstadoBadge } from './EstadoBadge'
import { ItemFacturaRow, type CrearProductoRender } from './ItemFacturaRow'
import { AvisoComprobanteDuplicado } from './AvisosCopiaFactura'
import { SelectorFacturaCopiaModal } from './SelectorFacturaCopiaModal'
import { ObservacionesProveedor } from './ObservacionesProveedor'
import { SelectorAlicuotaIva } from './SelectorAlicuotaIva'
import { ControlSegmentado } from './ControlSegmentado'
import { AplicarACuentaModal } from './AplicarACuentaModal'

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

// Servicios (docs/53): sin código, producto, marca ni cantidad. Mismas columnas de importe,
// descuento, depósito y subtotal que artículos, para que el pie de totales se lea igual.
const COLUMNAS_SERVICIOS = [
  { label: 'Descripción', align: 'left', width: '55%' },
  { label: 'Importe s/IVA', align: 'right', width: '12%' },
  { label: 'Desc. %', align: 'right', width: '7%' },
  { label: 'Depósito', align: 'left', width: '11%' },
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
  // docs/52: después de guardar, si el proveedor tiene pagos a cuenta, ofrecer aplicarlos a este
  // comprobante (confirmar o "Ahora no"; nunca automático). Cada app lo habilita.
  ofrecerAplicarACuenta?: boolean
  // Borradores (docs/54): desde qué app se carga, y el borrador a retomar si se abre desde la lista.
  sistema: SistemaApp
  borrador?: BorradorConNombres<PayloadBorradorFactura>
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
  ofrecerAplicarACuenta = false,
  sistema,
  borrador: borradorInicial,
}: Props) {
  const inicial = valoresIniciales ?? valoresFacturaCompraVacios()
  // Abierto con solo el id: hasta que llega la factura no se muestra un formulario vacío. Lo
  // mismo al retomar un borrador, hasta re-leer productos y proveedor.
  const [esperandoCopia, setEsperandoCopia] = useState(Boolean((copiadaDeId && !valoresIniciales) || borradorInicial))

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
  const [ivaAlicuota, setIvaAlicuota] = useState<AlicuotaIvaCompra>(inicial.ivaAlicuota)
  const [tipoCompra, setTipoCompra] = useState<TipoCompra>(inicial.tipoCompra)
  const [items, setItems] = useState<ItemFacturaCompraUI[]>(inicial.items)
  const [copiaDe, setCopiaDe] = useState<OrigenCopiaFactura | null>(inicial.copiaDe)
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [dirty, setDirty] = useState(false)
  // Borrador (docs/54): retomado de la lista (o recargado tras un conflicto), lo que cambió desde
  // que se guardó, y la confirmación de "Guardar igual" si el borrador ya no existe.
  const [retomado, setRetomado] = useState(false)
  const [avisosRestauracion, setAvisosRestauracion] = useState<string[]>([])
  const [confirmSinBorrador, setConfirmSinBorrador] = useState(false)
  const [verificarDuplicado, setVerificarDuplicado] = useState(0)
  // Cambio de artículos ↔ servicios pedido con ítems cargados: se confirma porque los limpia.
  const [tipoCompraPendiente, setTipoCompraPendiente] = useState<TipoCompra | null>(null)
  const [confirmLibres, setConfirmLibres] = useState(false)
  const [selectorAbierto, setSelectorAbierto] = useState(false)
  // Factura ya guardada + lo que el proveedor tiene a cuenta: se ofrece aplicarlo (docs/52).
  const [ofertaACuenta, setOfertaACuenta] = useState<{ factura: FacturaCompraSaldo; aCuenta: number } | null>(null)
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
    setIvaAlicuota(v.ivaAlicuota)
    setTipoCompra(v.tipoCompra)
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
    items,
    copiaDe,
  }
  // Primer dato real: proveedor, número o un ítem empezado. Cambiar solo la fecha no cuenta.
  const hayDatoReal = Boolean(proveedorId) || numeroComprobante.trim() !== '' || hayItemsCargadosFacturaCompra(items)
  const borrador = useBorrador({
    supabase,
    sistema,
    tipo: 'factura_compra',
    payload: payloadBorradorFactura(valoresActuales),
    resumen: resumenBorradorFactura(
      valoresActuales,
      proveedores.find((p) => p.id === proveedorId)?.razon_social ?? '',
      calcularTotalesFacturaCompra(items, ivaAlicuota).total,
    ),
    // Autoguardado desde que el usuario carga algo real (una copia recién aplicada no cuenta), o
    // siempre en un borrador retomado (no se vuelve a subir si no cambia nada).
    activo: (dirty && hayDatoReal) || retomado,
  })
  // Con algo que perder, cerrar pregunta "Guardar borrador / Descartar / Seguir editando".
  const cambiosSinGuardar = dirty && (hayDatoReal || retomado)

  async function abrirBorrador(fila: BorradorFila<unknown>) {
    const { valores, avisos } = await restaurarBorradorFactura(supabase, fila.payload as PayloadBorradorFactura)
    aplicarValores(valores)
    setAvisosRestauracion(avisos)
    setRetomado(true)
    borrador.retomar(fila, payloadBorradorFactura(valores))
    setVerificarDuplicado((n) => n + 1)
  }

  useEffect(() => {
    if (!borradorInicial) return
    abrirBorrador(borradorInicial).catch(() => {
      setEsperandoCopia(false)
      setError('No se pudo abrir el borrador. Revisá la conexión y volvé a intentar.')
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // Después de restaurar, el comprobante puede haberse cargado mientras el borrador esperaba.
  useEffect(() => {
    if (verificarDuplicado) void duplicado.verificar()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [verificarDuplicado])

  async function recargarBorrador() {
    const fila = await borrador.leerDelServidor()
    if (fila) await abrirBorrador(fila)
  }

  useEffect(() => {
    supabase
      .from('proveedores')
      .select('*')
      .order('razon_social')
      .then(({ data }) => setProveedores((data ?? []) as Proveedor[]))
  }, [])

  // Los ítems también cambian sin evento `change` (producto elegido con clic, código de la cámara,
  // Enter del lector, agregar/quitar fila): marcan dirty a mano, onChangeCapture no los ve.
  function actualizarItem(key: string, cambios: Partial<ItemFacturaCompraUI>) {
    setDirty(true)
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
    setDirty(true)
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

  // Cambiar el tipo vuelve la alícuota al default del tipo nuevo (docs/45); después se cambia a mano.
  function cambiarTipo(tipo: TipoComprobanteCompra) {
    setTipoComprobante(tipo)
    setIvaAlicuota(alicuotaDefault(tipo))
  }

  // Artículos ↔ servicios (docs/53): los ítems de uno no sirven en el otro, se arranca con una fila
  // en blanco. Con algo cargado, antes se confirma (tipoCompraPendiente).
  function pedirTipoCompra(tipo: TipoCompra) {
    if (tipo === tipoCompra) return
    if (hayItemsCargadosFacturaCompra(items)) setTipoCompraPendiente(tipo)
    else aplicarTipoCompra(tipo)
  }

  function aplicarTipoCompra(tipo: TipoCompra) {
    const fila = nuevoItemFacturaCompraUI()
    setTipoCompraPendiente(null)
    setTipoCompra(tipo)
    setItems([fila])
    setItemsConError(new Set())
    setError(null)
    setDirty(true)
    setFoco((prev) => ({ key: fila.key, n: (prev?.n ?? 0) + 1 }))
  }

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
    const problemas = problemasItemsFacturaCompra(items, tipoCompra)
    setItemsConError(new Set(problemas.map((p) => p.key)))
    if (problemas.length > 0) {
      setError(problemas.map((p) => p.mensaje).join(' '))
      document
        .querySelector(`[data-item-key="${problemas[0].key}"]`)
        ?.scrollIntoView({ behavior: 'smooth', block: 'center' })
      return
    }
    if (itemsValidosFacturaCompra(items).length === 0) {
      setError(mensajeSinItemsFacturaCompra(tipoCompra))
      return
    }
    // Ítems sin producto del inventario: no suman stock. Se confirman antes de guardar (docs/50).
    // En servicios no hay producto por definición: no se pregunta (docs/53).
    if (tipoCompra === 'articulos' && itemsLibresFacturaCompra(items).length > 0) {
      setConfirmLibres(true)
      return
    }
    await guardar()
  }

  // "Volver y vincular": marca los ítems libres y lleva la vista al primero.
  function volverAVincular() {
    setConfirmLibres(false)
    const libres = itemsLibresFacturaCompra(items)
    setItemsConError(new Set(libres.map((it) => it.key)))
    if (libres[0]) {
      document.querySelector(`[data-item-key="${libres[0].key}"]`)?.scrollIntoView({ behavior: 'smooth', block: 'center' })
    }
  }

  // `conBorrador` false: "Guardar igual" después de que el borrador ya no existía (otro lo confirmó o
  // lo eliminó) — se carga sin borrarlo, con el aviso de comprobante repetido a la vista.
  async function guardar(conBorrador = true) {
    setConfirmLibres(false)
    setConfirmSinBorrador(false)
    setSaving(true)
    // Frena el autoguardado y espera la subida en curso: si no, podría llegar después de que la RPC
    // borró el borrador y dejarlo huérfano.
    const idBorrador = await borrador.prepararConfirmacion()
    const borradorId = conBorrador ? idBorrador : null
    const { data: facturaId, error: dbError, status } = await cargarFacturaCompra(supabase, {
      borradorId,
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
      items: integrarMarcaEnItemsLibres(items),
      copiadaDeId: copiaDe?.id ?? null,
    })

    if (dbError) {
      setSaving(false)
      borrador.cancelarConfirmacion()
      if (esBorradorInexistente(dbError)) {
        setConfirmSinBorrador(true)
        void duplicado.verificar()
        return
      }
      setError(mensajeErrorGuardado(dbError, status, 'cargar la factura', 'lo que cargaste sigue acá'))
      return
    }
    // La RPC ya borró el borrador en la misma transacción; queda la copia del equipo.
    borrador.finalizar()

    // "Guardando..." sigue mientras se consulta: la factura ya está grabada, no se puede volver a guardar.
    const oferta =
      ofrecerAplicarACuenta && tipoComprobante !== 'nota_credito' && typeof facturaId === 'string'
        ? await buscarOfertaACuenta(facturaId)
        : null
    setSaving(false)
    if (oferta) {
      setOfertaACuenta(oferta)
      return
    }
    onSaved()
  }

  // La factura ya está guardada: si algo falla al consultar, no se ofrece nada y se cierra como siempre.
  async function buscarOfertaACuenta(facturaId: string) {
    try {
      const [aCuenta, facturaRes] = await Promise.all([
        obtenerACuentaProveedor(supabase, proveedorId),
        supabase.from('facturas_compra_saldo').select('*').eq('id', facturaId).maybeSingle(),
      ])
      const factura = facturaRes.data as FacturaCompraSaldo | null
      if (aCuenta > 0 && factura && Number(factura.saldo_pendiente) > 0) return { factura, aCuenta }
    } catch {
      // sin oferta
    }
    return null
  }

  const ocupado = saving || copia.cargando || esperandoCopia
  const columnas: readonly { label: string; align: 'left' | 'right' | 'center'; width: string }[] =
    tipoCompra === 'servicios' ? COLUMNAS_SERVICIOS : COLUMNAS_ITEMS

  // La factura ya se guardó: en lugar del formulario, la oferta de aplicar lo a cuenta.
  // Aplicar o "Ahora no" terminan igual que un guardado normal (onSaved).
  if (ofertaACuenta) {
    const { factura, aCuenta } = ofertaACuenta
    const aplicable = Math.min(aCuenta, Number(factura.saldo_pendiente))
    return (
      <AplicarACuentaModal
        supabase={supabase}
        proveedorId={factura.proveedor_id}
        proveedorNombre={proveedores.find((p) => p.id === factura.proveedor_id)?.razon_social ?? ''}
        comprobantes={[factura]}
        facturaIds={[factura.id]}
        aCuenta={aCuenta}
        titulo={`Aplicar ${formatCurrency(aplicable)} a este comprobante`}
        cancelarLabel="Ahora no"
        onClose={onSaved}
        onAplicado={onSaved}
      />
    )
  }

  return (
    <Modal
      title={retomado ? 'Factura de compra · borrador' : copiaDe ? 'Copiar factura' : 'Nueva factura de compra'}
      onClose={onClose}
      cambiosSinGuardar={cambiosSinGuardar}
      cierreBorrador={{ onGuardar: borrador.guardarAhora, onDescartar: borrador.descartar, retomado }}
      widthClassName="max-w-[1180px]"
      footer={
        <div className="flex flex-col gap-stack-sm">
          <div className="flex items-end justify-between gap-stack-md">
            <div className="flex items-end gap-stack-lg">
              {/* Fuera del <form>: onChangeCapture no lo ve, marca "hay cambios" a mano. */}
              <SelectorAlicuotaIva
                value={ivaAlicuota}
                onChange={(a) => {
                  setDirty(true)
                  setIvaAlicuota(a)
                }}
              />
              <div>
                <p className="font-sans text-label-md text-ink-soft">Subtotal</p>
                <p className="font-sans text-body-md text-ink">{formatCurrency(subtotalPreview)}</p>
              </div>
              <div>
                <p className="font-sans text-label-md text-ink-soft">Descuento</p>
                <p className="font-sans text-body-md text-ink">{formatCurrency(descuentoPreview)}</p>
              </div>
              <div>
                <p className="font-sans text-label-md text-ink-soft">{etiquetaAlicuotaIva(ivaAlicuota)}</p>
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

          <div className="flex items-center justify-end gap-3">
            <div className="mr-auto min-w-0">
              <IndicadorBorrador estado={borrador.estado} />
            </div>
            <BotonCerrarModal className="rounded px-4 py-3 font-sans text-label-bold text-ink-soft hover:bg-bg">
              Cancelar
            </BotonCerrarModal>
            <button
              type="button"
              onClick={() => void borrador.guardarAhora()}
              disabled={ocupado || !hayDatoReal}
              title={hayDatoReal ? undefined : 'Cargá un proveedor, un número o un ítem para guardar el borrador'}
              className="rounded border border-accent px-4 py-3 font-sans text-label-bold text-accent-darker transition hover:bg-accent-light disabled:opacity-60"
            >
              Guardar borrador
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
          {borradorInicial ? 'Abriendo el borrador…' : 'Cargando la factura a copiar…'}
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
          <AvisosBorrador
            estado={borrador.estado}
            autorAjeno={
              borradorInicial && borrador.usuarioId && borradorInicial.usuario_id !== borrador.usuarioId
                ? { nombre: borradorInicial.autor, creado: borradorInicial.created_at }
                : null
            }
            avisosRestauracion={avisosRestauracion}
            onRecargar={() => void recargarBorrador()}
            onGuardarComoNuevo={() => void borrador.guardarComoNuevo()}
          />

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
            <div className="flex flex-wrap items-end gap-stack-md">
              <button
                type="button"
                onClick={() => setSelectorAbierto(true)}
                disabled={ocupado}
                className="rounded border border-accent px-3 py-2 font-sans text-label-bold text-accent-darker transition hover:bg-accent-light disabled:opacity-60"
              >
                Copiar desde…
              </button>
              {/* docs/53: define qué columnas tiene la planilla; se elige siempre a mano. */}
              <ControlSegmentado
                legend="Tipo de compra"
                opciones={OPCIONES_TIPO_COMPRA}
                value={tipoCompra}
                onChange={pedirTipoCompra}
                disabled={ocupado}
                resaltado
              />
            </div>
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
          <p className="font-sans text-label-bold text-ink">
            {tipoCompra === 'servicios' ? 'Servicios de la factura' : 'Ítems de la factura'}
          </p>

          <table className="w-full table-fixed border-collapse">
            <colgroup>
              {columnas.map((c) => (
                <col key={c.label || 'accion'} style={{ width: c.width }} />
              ))}
            </colgroup>
            <thead>
              <tr className="border-b border-line">
                {columnas.map((c) => (
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
                  servicios={tipoCompra === 'servicios'}
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

      {tipoCompraPendiente && (
        <ConfirmDialog
          title={`Cambiar a ${TIPO_COMPRA_LABEL[tipoCompraPendiente].toLowerCase()}`}
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
          title="Reemplazar lo cargado"
          mensaje="Se reemplaza todo lo que hay en el formulario (cabecera e ítems) por los datos de la factura elegida."
          confirmLabel="Reemplazar"
          onCancel={copia.cancelarReemplazo}
          onConfirm={copia.confirmarReemplazo}
        />
      )}

      {confirmLibres && (
        <ConfirmDialog
          title="Ítems que no suman stock"
          mensaje={mensajeItemsLibresFacturaCompra(itemsLibresFacturaCompra(items))}
          confirmLabel="Guardar sin sumar stock"
          cancelLabel="Volver y vincular"
          confirmando={saving}
          onCancel={volverAVincular}
          onConfirm={() => void guardar()}
        />
      )}

      {confirmSinBorrador && (
        <ConfirmDialog
          title="El borrador ya no existe"
          mensaje="Otro usuario lo confirmó o lo eliminó mientras lo editabas. La factura no se cargó: revisá en el listado (o el aviso de comprobante repetido) que no esté cargada antes de guardarla igual."
          confirmLabel="Guardar igual"
          cancelLabel="Volver"
          confirmando={saving}
          onCancel={() => setConfirmSinBorrador(false)}
          onConfirm={() => void guardar(false)}
        />
      )}
    </Modal>
  )
}
