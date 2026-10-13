// Reglas de negocio de Inventario y Stock compartidas entre Virikyna Local (Caja) y
// Virikyna Inventario (celular) — ver docs/04_modulos_y_funciones.md, módulos 5 y 5.1.

import type { Producto, Proveedor, StockUbicacion } from '../types/database'

export const IVA_DEFAULT = 21

// Producto con lo que traen los listados de Inventario de las tres apps (SELECT_PRODUCTOS_INVENTARIO).
export type ProductoConRelaciones = Producto & {
  proveedor: Pick<Proveedor, 'razon_social' | 'margen_1_default' | 'margen_2_default'> | null
  stock_ubicaciones: Pick<StockUbicacion, 'ubicacion' | 'cantidad'>[]
}

export const SELECT_PRODUCTOS_INVENTARIO =
  '*, proveedor:proveedores(razon_social, margen_1_default, margen_2_default), stock_ubicaciones(ubicacion, cantidad)'

// Stock total = suma de todas las ubicaciones (mismo criterio que Stock bajo, docs/26).
export function stockTotal(p: Pick<ProductoConRelaciones, 'stock_ubicaciones'>): number {
  return p.stock_ubicaciones.reduce((acc, s) => acc + Number(s.cantidad), 0)
}

export function stockEnUbicacion(p: Pick<ProductoConRelaciones, 'stock_ubicaciones'>, ubicacion: StockUbicacion['ubicacion']): number {
  return Number(p.stock_ubicaciones.find((s) => s.ubicacion === ubicacion)?.cantidad ?? 0)
}

// Lista cerrada + "Otro" con detalle libre — ver skill pos-inventory-architecture,
// sección "Ajustes manuales: siempre con motivo y siempre auditados".
export const MOTIVOS_AJUSTE_STOCK = ['Rotura', 'Pérdida', 'Corrección de conteo físico', 'Otro'] as const

export type MotivoAjusteStock = (typeof MOTIVOS_AJUSTE_STOCK)[number]
