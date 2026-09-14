// Historial y Auditoría (docs/04_modulos_y_funciones.md, módulo 10) — labels, la regla de qué
// es reversible y desde dónde, y los wrappers de las RPCs reales de
// docs/10_historial_auditoria_reversiones.sql (reemplazan el pseudo-código de docs/06 sección 7).
import type { Auditoria, TipoAccionAuditoria } from '@virikyna/shared'
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
  pagos_cliente: 'Pagos de cliente',
  movimientos_cuenta: 'Movimientos de cuenta',
  cierres_caja: 'Cierres de caja',
  retiros_caja: 'Retiros de caja',
  facturas_compra: 'Facturas de compra',
}

export function tablaLabel(tabla: string): string {
  return TABLA_LABEL[tabla] ?? tabla
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
