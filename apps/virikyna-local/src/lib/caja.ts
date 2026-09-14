// Labels y helpers para Cierre de Caja + Caja Gestión (docs/04_modulos_y_funciones.md, módulos 7 y 7.1).
import type { CategoriaEgreso, FormaPagoEgreso, TipoMovimientoCuenta } from '@virikyna/shared'
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

// Categorías de egreso de turno que ofrece Virikyna-Local (docs/13_categorias_egresos_local.sql).
// "sueldo"/"servicio" quedaron para Virikyna-Gestión — se mantienen en el label de arriba solo
// por si aparece algún egreso viejo, pero ya no se ofrecen para cargar uno nuevo desde Local.
export const CATEGORIAS_LOCAL: CategoriaEgreso[] = ['pago_proveedor', 'agua', 'descartables', 'super', 'otro']

export const FORMA_PAGO_EGRESO_LABEL: Record<FormaPagoEgreso, string> = {
  efectivo: 'Efectivo',
  transferencia: 'Transferencia',
  cheque: 'Cheque',
  echeq: 'E-cheq',
}

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

// diferencia = efectivo_contado - efectivo_esperado (ver RPC cerrar_caja en docs/06_estructura_de_datos.md)
export function diferenciaLabel(diferencia: number | null): { texto: string; className: string } {
  if (diferencia === null) return { texto: 'Sin efectivo contado', className: 'text-ink-soft' }
  if (diferencia === 0) return { texto: 'Coincide', className: 'text-success' }
  if (diferencia > 0) return { texto: `Sobra ${formatCurrency(diferencia)}`, className: 'text-accent-dark' }
  return { texto: `Falta ${formatCurrency(Math.abs(diferencia))}`, className: 'text-error' }
}
