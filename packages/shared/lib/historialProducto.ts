// Historial de movimientos del producto (docs/70): la línea de tiempo la arma la base
// (historial_producto, SECURITY INVOKER: un cajero no recibe cambios de datos) con el stock
// resultante de cada fila ya calculado. Acá solo se tipa, se agrupa para los filtros y se rotula.
import type { SupabaseClient } from '@supabase/supabase-js'
import type { UbicacionStock } from '../types/database'
import { TIPO_COMPROBANTE_COMPRA_LABEL } from './facturasCompra'
import { formatCurrency as moneda } from './format'

// Origen de un movimiento de stock (movimientos_stock.origen) + eventos sin cantidad.
export type ClaseHistorial =
  | 'venta'
  | 'anulacion_venta'
  | 'devolucion_cliente'
  | 'cambio_entrega'
  | 'anulacion_devolucion'
  | 'compra'
  | 'compra_correccion'
  | 'devolucion_proveedor'
  | 'anulacion_compra'
  | 'ajuste_manual'
  | 'reversion_ajuste'
  | 'carga_inicial'
  | 'carga_inicial_correccion'
  | 'alta'
  | 'precio'
  | 'datos'
  | 'sin_registro'

export type RefHistorial = 'venta' | 'devolucion' | 'factura_compra'

export type CambioCampo = { antes: unknown; despues: unknown }

export type FilaHistorial = {
  orden: number // posición cronológica (estable con o sin filtro); la lista va de mayor a menor
  fecha: string
  clase: ClaseHistorial
  detalle: string | null // motivo del movimiento (sin acentos, como lo guarda la base)
  proveedor: string | null
  ubicacion: UbicacionStock | null
  cantidad: number | null // con signo; null en alta / precio / datos
  stockResultante: number
  usuarioId: string | null
  usuarioNombre: string | null
  refTabla: RefHistorial | null
  refId: string | null
  refNumero: string | null
  precioAnterior: number | null
  precioNuevo: number | null
  precioOrigen: string | null
  cambios: Record<string, CambioCampo> | null
}

export type ResumenHistorial = {
  stockActual: number
  stockInicial: number
  entradas: number
  salidas: number
  ajustes: number
  diferenciaSinRegistro: number
  ultimoMovimientoFecha: string | null
  ultimoMovimientoClase: ClaseHistorial | null
}

const numOrNull = (v: unknown) => (v === null || v === undefined ? null : Number(v))

export async function fetchHistorialProducto(supabase: SupabaseClient, productoId: string): Promise<FilaHistorial[]> {
  const { data, error } = await supabase.rpc('historial_producto', { p_producto_id: productoId })
  if (error) throw error
  return ((data ?? []) as Record<string, unknown>[]).map((f) => ({
    orden: Number(f.orden),
    fecha: f.fecha as string,
    clase: f.clase as ClaseHistorial,
    detalle: (f.detalle as string | null) ?? null,
    proveedor: (f.proveedor as string | null) ?? null,
    ubicacion: (f.ubicacion as UbicacionStock | null) ?? null,
    cantidad: numOrNull(f.cantidad),
    stockResultante: Number(f.stock_resultante),
    usuarioId: (f.usuario_id as string | null) ?? null,
    usuarioNombre: (f.usuario_nombre as string | null) ?? null,
    refTabla: (f.ref_tabla as RefHistorial | null) ?? null,
    refId: (f.ref_id as string | null) ?? null,
    refNumero: (f.ref_numero as string | null) ?? null,
    precioAnterior: numOrNull(f.precio_anterior),
    precioNuevo: numOrNull(f.precio_nuevo),
    precioOrigen: (f.precio_origen as string | null) ?? null,
    cambios: (f.cambios as Record<string, CambioCampo> | null) ?? null,
  }))
}

// rango: timestamps (rangoTimestampsAR). El stock actual y el último movimiento no dependen de él.
export async function fetchResumenHistorial(
  supabase: SupabaseClient,
  productoId: string,
  rango: { desde: string | null; hasta: string | null },
): Promise<ResumenHistorial> {
  const { data, error } = await supabase.rpc('resumen_historial_producto', {
    p_producto_id: productoId,
    p_desde: rango.desde,
    p_hasta: rango.hasta,
  })
  if (error) throw error
  const r = ((data ?? []) as Record<string, unknown>[])[0] ?? {}
  return {
    stockActual: Number(r.stock_actual ?? 0),
    stockInicial: Number(r.stock_inicial ?? 0),
    entradas: Number(r.entradas ?? 0),
    salidas: Number(r.salidas ?? 0),
    ajustes: Number(r.ajustes ?? 0),
    diferenciaSinRegistro: Number(r.diferencia_sin_registro ?? 0),
    ultimoMovimientoFecha: (r.ultimo_movimiento_fecha as string | null) ?? null,
    ultimoMovimientoClase: (r.ultimo_movimiento_clase as ClaseHistorial | null) ?? null,
  }
}

// ─── Filtro por tipo ────────────────────────────────────────────────────────────────────────────
export type GrupoHistorial = 'todos' | 'entradas' | 'salidas' | 'ajustes' | 'precio_datos'

export const GRUPOS_HISTORIAL: { value: GrupoHistorial; label: string }[] = [
  { value: 'todos', label: 'Todos' },
  { value: 'entradas', label: 'Entradas' },
  { value: 'salidas', label: 'Salidas' },
  { value: 'ajustes', label: 'Ajustes' },
  { value: 'precio_datos', label: 'Precio y datos' },
]

// Entradas y Salidas = las del resumen (D3). La carga inicial va con las entradas (es mercadería
// que entra); sus correcciones, la anulación de una devolución (mueve en los dos sentidos) y la
// diferencia sin registro, con los ajustes. El alta va con "Precio y datos" (lleva el precio inicial).
export const GRUPO_DE_CLASE: Record<ClaseHistorial, Exclude<GrupoHistorial, 'todos'>> = {
  compra: 'entradas',
  compra_correccion: 'entradas',
  devolucion_cliente: 'entradas',
  anulacion_venta: 'entradas',
  carga_inicial: 'entradas',
  venta: 'salidas',
  cambio_entrega: 'salidas',
  devolucion_proveedor: 'salidas',
  anulacion_compra: 'salidas',
  ajuste_manual: 'ajustes',
  reversion_ajuste: 'ajustes',
  carga_inicial_correccion: 'ajustes',
  anulacion_devolucion: 'ajustes',
  sin_registro: 'ajustes',
  alta: 'precio_datos',
  precio: 'precio_datos',
  datos: 'precio_datos',
}

// ─── Rótulos ────────────────────────────────────────────────────────────────────────────────────
export type VarianteBadgeHistorial = 'green' | 'red' | 'amber' | 'neutral' | 'violet'

// docs/DIAGNOSTICO_HISTORIAL_MOVIMIENTOS.md §2.3: verde entra mercadería, rojo anulación, ámbar
// ajuste/corrección, neutro venta/alta, violeta precio/datos (no es un movimiento de stock).
export const CLASE_HISTORIAL: Record<ClaseHistorial, { label: string; variant: VarianteBadgeHistorial }> = {
  alta: { label: 'Alta del producto', variant: 'neutral' },
  carga_inicial: { label: 'Carga inicial', variant: 'neutral' },
  carga_inicial_correccion: { label: 'Corrección de carga inicial', variant: 'amber' },
  compra: { label: 'Compra', variant: 'green' },
  compra_correccion: { label: 'Corrección de compra', variant: 'amber' },
  anulacion_compra: { label: 'Anulación de compra', variant: 'red' },
  devolucion_proveedor: { label: 'Devolución a proveedor', variant: 'neutral' },
  venta: { label: 'Venta', variant: 'neutral' },
  anulacion_venta: { label: 'Anulación de venta', variant: 'red' },
  devolucion_cliente: { label: 'Devolución de cliente', variant: 'green' },
  cambio_entrega: { label: 'Cambio (entregado)', variant: 'neutral' },
  anulacion_devolucion: { label: 'Anulación de devolución', variant: 'red' },
  ajuste_manual: { label: 'Ajuste manual', variant: 'amber' },
  reversion_ajuste: { label: 'Reversión de ajuste', variant: 'amber' },
  sin_registro: { label: 'Diferencia sin registro', variant: 'amber' },
  precio: { label: 'Cambio de precio', variant: 'violet' },
  datos: { label: 'Cambio de datos', variant: 'violet' },
}

const nf = new Intl.NumberFormat('es-AR', { maximumFractionDigits: 2 })

// Cantidad de stock: "+3", "−1,5" (signo menos tipográfico). sinSigno para el stock resultante.
export function formatCantidadStock(n: number, conSigno = true): string {
  if (!conSigno) return n < 0 ? `−${nf.format(-n)}` : nf.format(n)
  if (n > 0) return `+${nf.format(n)}`
  if (n < 0) return `−${nf.format(-n)}`
  return '0'
}

// "FACTURA A 0001-123" (así lo arma la base) → "Factura A 0001-123".
export function etiquetaRefFactura(refNumero: string): string {
  for (const [tipo, label] of Object.entries(TIPO_COMPROBANTE_COMPRA_LABEL)) {
    const prefijo = tipo.toUpperCase().replace('_', ' ')
    if (refNumero === prefijo || refNumero.startsWith(prefijo + ' ')) return label + refNumero.slice(prefijo.length)
  }
  return refNumero
}

// Nombre accesible / título del comprobante de una fila (para el botón "Ver …").
export function etiquetaComprobanteFila(f: Pick<FilaHistorial, 'refTabla' | 'refNumero'>): string | null {
  if (!f.refTabla) return null
  if (f.refTabla === 'venta') return `Venta N° ${f.refNumero ?? ''}`.trim()
  if (f.refTabla === 'devolucion') return `Devolución N° ${f.refNumero ?? ''}`.trim()
  return f.refNumero ? etiquetaRefFactura(f.refNumero) : 'Factura de compra'
}

// Texto del motivo después del prefijo fijo que agrega la RPC ("Anulacion de venta: <motivo>").
function motivoLibre(detalle: string | null): string | null {
  if (!detalle) return null
  const i = detalle.indexOf(': ')
  return i >= 0 ? detalle.slice(i + 2).trim() || null : null
}

// Detalle / origen de una fila, en una línea. Los cambios de datos van aparte (lineasCambios).
export function detalleFilaHistorial(f: FilaHistorial, origenPrecioLabel: (o: string) => string): string {
  const ref = etiquetaComprobanteFila(f)
  const partes: (string | null)[] = []
  switch (f.clase) {
    case 'venta':
      partes.push(ref)
      break
    case 'anulacion_venta':
    case 'anulacion_compra':
    case 'anulacion_devolucion':
      partes.push(ref, f.clase === 'anulacion_compra' ? f.proveedor : null, motivoLibre(f.detalle))
      break
    case 'compra':
    case 'devolucion_proveedor':
      partes.push(ref, f.proveedor)
      break
    case 'compra_correccion':
      partes.push(ref, f.proveedor, f.detalle)
      break
    case 'devolucion_cliente':
    case 'cambio_entrega':
      partes.push(ref)
      break
    case 'carga_inicial_correccion': {
      const m = f.detalle?.match(/\((-?[\d.]+) → (-?[\d.]+)\)/)
      partes.push(m ? `De ${nf.format(Number(m[1]))} a ${nf.format(Number(m[2]))}` : f.detalle)
      break
    }
    case 'ajuste_manual':
      partes.push(f.detalle)
      break
    case 'reversion_ajuste':
      partes.push('Revierte un ajuste manual')
      break
    case 'alta':
      partes.push(f.precioNuevo !== null ? `Precio inicial ${moneda(f.precioNuevo)}` : null)
      break
    case 'precio':
      partes.push(
        `${f.precioAnterior !== null ? moneda(f.precioAnterior) : '—'} → ${f.precioNuevo !== null ? moneda(f.precioNuevo) : '—'}`,
        // Con el comprobante a la vista, el origen ("Factura") ya se lee en él.
        ref ?? (f.precioOrigen ? origenPrecioLabel(f.precioOrigen) : null),
      )
      break
    case 'datos':
      partes.push(f.detalle === 'reversion' ? 'Reversión de una edición' : null)
      break
    case 'sin_registro':
      partes.push('El stock no coincide con los movimientos registrados')
      break
    case 'carga_inicial':
      break
  }
  if (f.ubicacion === 'deposito') partes.push('Depósito')
  return partes.filter(Boolean).join(' · ')
}

const CAMPO_LABEL: Record<string, string> = {
  costo: 'Costo',
  margen_1: 'Margen 1',
  margen_2: 'Margen 2',
  iva_porcentaje: 'Lleva IVA',
  proveedor: 'Proveedor',
  nombre: 'Nombre',
  marca: 'Marca',
  codigo_barras: 'Código',
  estado: 'Estado',
  stock_minimo: 'Stock mínimo',
}
const ORDEN_CAMPOS = Object.keys(CAMPO_LABEL)

function valorCampo(campo: string, v: unknown): string {
  if (v === null || v === undefined || v === '') {
    return campo === 'costo' ? 'sin costo' : campo === 'proveedor' ? 'sin proveedor' : '—'
  }
  switch (campo) {
    case 'costo':
      return moneda(Number(v))
    case 'margen_1':
    case 'margen_2':
      return `${nf.format(Number(v))} %`
    case 'iva_porcentaje':
      return Number(v) > 0 ? 'sí' : 'no'
    case 'estado':
      return v === 'activo' ? 'activo' : 'inactivo'
    case 'stock_minimo':
      return nf.format(Number(v))
    default:
      return String(v)
  }
}

// "Costo $ 1.600,00 → $ 2.192,00", "Lleva IVA: sí → no", en el orden de CAMPO_LABEL.
export function lineasCambios(cambios: Record<string, CambioCampo> | null): string[] {
  if (!cambios) return []
  return Object.keys(cambios)
    .sort((a, b) => ORDEN_CAMPOS.indexOf(a) - ORDEN_CAMPOS.indexOf(b))
    .map((campo) => {
      const c = cambios[campo]
      return `${CAMPO_LABEL[campo] ?? campo}: ${valorCampo(campo, c.antes)} → ${valorCampo(campo, c.despues)}`
    })
}
