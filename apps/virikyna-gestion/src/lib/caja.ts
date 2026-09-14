// Labels y helpers para Cierre de Caja + Caja Gestión + Egresos (docs/04_modulos_y_funciones.md, módulos 7 y 7.1).
import type { CategoriaEgreso, FormaPagoEgreso, OrigenEgreso, TipoMovimientoCuenta } from '@virikyna/shared'
import { formatCurrency } from '@virikyna/shared'

export const CATEGORIA_EGRESO_LABEL: Record<CategoriaEgreso, string> = {
  pago_proveedor: 'Pago a proveedor',
  sueldo: 'Sueldo',
  servicio: 'Servicio',
  otro: 'Otro',
  agua: 'Agua',
  descartables: 'Descartables',
  super: 'Super',
}

export const FORMA_PAGO_EGRESO_LABEL: Record<FormaPagoEgreso, string> = {
  efectivo: 'Efectivo',
  transferencia: 'Transferencia',
  cheque: 'Cheque',
  echeq: 'E-cheq',
}

export const ORIGEN_EGRESO_LABEL: Record<OrigenEgreso, string> = {
  general: 'Gestión',
  turno: 'Local',
}

// El módulo Egresos (registro desde Gestión) nunca usa la categoría "pago a proveedor" — ese
// caso va por registrar_pago_proveedor, nunca por registrar_egreso_general. Tampoco ofrece
// agua/descartables/super — esas son categorías de turno de Virikyna-Local (docs/13); acá solo
// se mantiene su label para poder mostrarlas en el historial unificado por origen.
const CATEGORIAS_SOLO_LOCAL: CategoriaEgreso[] = ['agua', 'descartables', 'super']
export const CATEGORIAS_EGRESO_GENERAL = (Object.keys(CATEGORIA_EGRESO_LABEL) as CategoriaEgreso[]).filter(
  (c) => c !== 'pago_proveedor' && !CATEGORIAS_SOLO_LOCAL.includes(c),
)

export const TIPO_MOVIMIENTO_CUENTA_LABEL: Record<TipoMovimientoCuenta, string> = {
  saldo_inicial: 'Carga inicial',
  venta: 'Venta',
  pago_cliente: 'Pago de cliente',
  pago_proveedor: 'Pago a proveedor',
  egreso: 'Egreso manual',
  ingreso_manual: 'Ingreso manual',
  cierre_z: 'Cierre Z',
  transferencia_interna: 'Transferencia entre cuentas',
  retiro: 'Retiro de efectivo',
}

// Solo ingreso_manual/egreso se editan directo (editar_movimiento_cuenta, docs/06 sección 12) —
// venta/pago_cliente/pago_proveedor/cierre_z/saldo_inicial/transferencia_interna/retiro son reflejo
// de otro registro (retiro → tabla retiros_caja) y se corrigen desde ese origen.
export function esMovimientoManualEditable(tipo: TipoMovimientoCuenta): boolean {
  return tipo === 'ingreso_manual' || tipo === 'egreso'
}

// diferencia = efectivo_contado - efectivo_esperado (ver RPC cerrar_caja en docs/06_estructura_de_datos.md)
export function diferenciaLabel(diferencia: number | null): { texto: string; className: string } {
  if (diferencia === null) return { texto: 'Sin efectivo contado', className: 'text-ink-soft' }
  if (diferencia === 0) return { texto: 'Coincide', className: 'text-success' }
  if (diferencia > 0) return { texto: `Sobra ${formatCurrency(diferencia)}`, className: 'text-accent-dark' }
  return { texto: `Falta ${formatCurrency(Math.abs(diferencia))}`, className: 'text-error' }
}
