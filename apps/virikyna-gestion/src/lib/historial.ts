// Historial y Auditoría (docs/04_modulos_y_funciones.md, módulo 10) — labels, la regla de qué
// es reversible y desde dónde, y los wrappers de las RPCs reales de
// docs/10_historial_auditoria_reversiones.sql (reemplazan el pseudo-código de docs/06 sección 7).
import { etiquetaComprobanteCompra, type Auditoria, type FacturaCompra, type TipoAccionAuditoria } from '@virikyna/shared'
import { supabase } from './supabaseClient'

export const ACCION_LABEL: Record<TipoAccionAuditoria, string> = {
  alta: 'Alta',
  edicion: 'Edición',
  eliminacion: 'Eliminación',
  anulacion: 'Anulación',
  reversion: 'Reversión',
  nota_correccion: 'Nota de corrección',
}

export const TABLA_LABEL: Record<string, string> = {
  productos: 'Productos',
  proveedores: 'Proveedores',
  clientes: 'Clientes',
  ventas: 'Ventas',
  stock_ubicaciones: 'Stock',
  movimientos_stock: 'Movimientos de stock',
  egresos: 'Egresos',
  pagos_proveedor: 'Pagos a proveedor',
  // docs/31: una fila por "este monto cancela este comprobante". Se revierte desde el pago, no acá
  // (accionRevertible no la incluye): revertir el pago marca revertidas todas sus aplicaciones.
  pagos_proveedor_aplicaciones: 'Aplicación de pago a proveedor',
  pagos_cliente: 'Pagos de cliente',
  movimientos_cuenta: 'Movimientos de cuenta',
  cierres_caja: 'Cierres de caja',
  retiros_caja: 'Retiros de caja',
  facturas_compra: 'Facturas de compra',
  // docs/59: solo la re-emisión en producción de las que salieron en homologación
  facturas_c: 'Facturas C',
}

export function tablaLabel(tabla: string): string {
  return TABLA_LABEL[tabla] ?? tabla
}

// Campos que guardan el id de otra factura de compra y se muestran como su comprobante, no como
// UUID: copiada_de_id (docs/33) → "Copia de Factura A 0001-123".
export const CAMPOS_FACTURA_COMPRA_REF: Record<string, (etiqueta: string) => string> = {
  copiada_de_id: (etiqueta) => `Copia de ${etiqueta}`,
}

// id → "Factura A 0001-123" para las facturas referenciadas en una fila de auditoría. Un id que ya
// no se puede leer queda afuera del mapa (la pantalla muestra un texto genérico).
export async function etiquetasFacturasCompra(ids: string[]): Promise<Map<string, string>> {
  const unicos = [...new Set(ids)]
  if (unicos.length === 0) return new Map()
  const { data } = await supabase
    .from('facturas_compra')
    .select('id, tipo_comprobante, letra, punto_venta, numero_comprobante')
    .in('id', unicos)
  const filas = (data ?? []) as Pick<FacturaCompra, 'id' | 'tipo_comprobante' | 'letra' | 'punto_venta' | 'numero_comprobante'>[]
  return new Map(filas.map((f) => [f.id, etiquetaComprobanteCompra(f)]))
}

// Tablas cuyas filas de Historial pueden ofrecer "Revertir" o abrir un detalle: si el registro ya no
// existe (borrado de datos de prueba, docs/46), la fila se marca "Registro eliminado" y no se revierte.
const TABLAS_CON_REGISTRO = [
  'productos',
  'proveedores',
  'clientes',
  'ventas',
  'movimientos_stock',
  'egresos',
  'pagos_proveedor',
  'pagos_cliente',
  'movimientos_cuenta',
  'facturas_compra',
]

export const claveRegistro = (a: Pick<Auditoria, 'tabla_afectada' | 'registro_id'>) => `${a.tabla_afectada}:${a.registro_id}`

// Claves (tabla:id) de los registros que aparecen en el Historial y ya no existen. Una consulta por
// tabla; si una falla, esa tabla no se marca (mejor ofrecer de más que esconder una reversión válida:
// el RPC igual valida).
export async function registrosEliminados(filas: Auditoria[]): Promise<Set<string>> {
  const porTabla = new Map<string, Set<string>>()
  for (const f of filas) {
    if (f.accion === 'eliminacion' || !TABLAS_CON_REGISTRO.includes(f.tabla_afectada)) continue
    if (!porTabla.has(f.tabla_afectada)) porTabla.set(f.tabla_afectada, new Set())
    porTabla.get(f.tabla_afectada)!.add(f.registro_id)
  }
  // De a 50 ids: 200 UUIDs en un solo `in` arman una URL demasiado larga.
  const consultas: { tabla: string; ids: string[] }[] = []
  for (const [tabla, ids] of porTabla) {
    const lista = [...ids]
    for (let i = 0; i < lista.length; i += 50) consultas.push({ tabla, ids: lista.slice(i, i + 50) })
  }
  const eliminados = new Set<string>()
  await Promise.all(
    consultas.map(async ({ tabla, ids }) => {
      const { data, error } = await supabase.from(tabla).select('id').in('id', ids)
      if (error) return
      const existentes = new Set((data ?? []).map((r) => (r as { id: string }).id))
      for (const id of ids) if (!existentes.has(id)) eliminados.add(`${tabla}:${id}`)
    }),
  )
  return eliminados
}

export type AccionRevertible = { tipo: 'edicion' | 'alta' | 'movimiento' | 'venta' } | null

// Refleja 1:1 la tabla de reglas de docs/04_modulos_y_funciones.md, módulo 10.
// `ventaEstado` es el estado ACTUAL de la venta (no el que quedó guardado en el snapshot de la
// auditoría) — una venta puede haberse facturado después del alta que estamos mirando, y eso es
// justo lo que decide si el botón de revertir aparece o no.
export function accionRevertible(a: Auditoria, ventaEstado?: string): AccionRevertible {
  if (a.accion === 'edicion' && ['productos', 'proveedores', 'clientes'].includes(a.tabla_afectada)) {
    return { tipo: 'edicion' }
  }
  if (a.accion === 'alta' && ['productos', 'clientes', 'proveedores'].includes(a.tabla_afectada)) {
    return { tipo: 'alta' }
  }
  if (a.accion === 'alta' && a.tabla_afectada === 'ventas') {
    // Venta ya facturada (con CAE): no reversible desde el sistema — decisión confirmada,
    // documentada como límite conocido. El botón simplemente no aparece; no es un bug.
    return ventaEstado === 'sin_facturar' ? { tipo: 'venta' } : null
  }
  if (a.accion === 'alta' && a.tabla_afectada === 'movimientos_stock') {
    const v = a.valores_nuevos as { tipo?: string; referencia_id?: string | null } | null
    // Solo un ajuste manual (sin referencia_id) — una venta o una reposición automática por
    // anulación de venta tienen su propio camino, no éste.
    return v?.tipo === 'ajuste' && !v.referencia_id ? { tipo: 'movimiento' } : null
  }
  if (a.accion === 'alta' && a.tabla_afectada === 'egresos') {
    const v = a.valores_nuevos as { categoria?: string } | null
    // Un egreso generado automático por un pago a proveedor se revierte desde ESE pago (revierte
    // las 3 filas relacionadas a la vez) — revertirlo acá dejaría el pago y la cuenta sin tocar.
    // Guarda de flujo para evitar un estado inconsistente por accidente, no una restricción de rol.
    return v?.categoria === 'pago_proveedor' ? null : { tipo: 'movimiento' }
  }
  if (a.accion === 'alta' && ['pagos_proveedor', 'pagos_cliente', 'movimientos_cuenta'].includes(a.tabla_afectada)) {
    return { tipo: 'movimiento' }
  }
  return null
}

export async function revertirEdicion(auditoriaId: string) {
  return supabase.rpc('revertir_edicion', { p_auditoria_id: auditoriaId })
}

export async function revertirAlta(auditoriaId: string) {
  return supabase.rpc('revertir_alta', { p_auditoria_id: auditoriaId })
}

export async function revertirMovimiento(auditoriaId: string) {
  return supabase.rpc('revertir_movimiento', { p_auditoria_id: auditoriaId })
}

export async function anularVenta(ventaId: string, motivo: string) {
  return supabase.rpc('anular_venta', { p_venta_id: ventaId, p_motivo: motivo })
}

export async function agregarNotaCorreccion(cierreId: string, nota: string) {
  return supabase.rpc('agregar_nota_correccion', { p_cierre_id: cierreId, p_nota: nota })
}

// Nunca pisa la fila original — inserta el contra-asiento y la versión corregida (ambas quedan
// en el Historial). Solo para ingreso_manual/egreso; venta/pago_cliente/pago_proveedor/cierre_z
// son reflejo de otro registro y se corrigen desde ahí.
export async function editarMovimientoCuenta(
  movimientoId: string,
  montoNuevo: number,
  descripcionNueva: string,
  motivo: string,
) {
  return supabase.rpc('editar_movimiento_cuenta', {
    p_movimiento_id: movimientoId,
    p_monto_nuevo: montoNuevo,
    p_descripcion_nueva: descripcionNueva,
    p_motivo: motivo,
  })
}
