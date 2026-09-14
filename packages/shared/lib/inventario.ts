// Reglas de negocio de Inventario y Stock compartidas entre Virikyna Local (Caja) y
// Virikyna Inventario (celular) — ver docs/04_modulos_y_funciones.md, módulos 5 y 5.1.

export const IVA_DEFAULT = 21

// Lista cerrada + "Otro" con detalle libre — ver skill pos-inventory-architecture,
// sección "Ajustes manuales: siempre con motivo y siempre auditados".
export const MOTIVOS_AJUSTE_STOCK = ['Rotura', 'Pérdida', 'Corrección de conteo físico', 'Otro'] as const

export type MotivoAjusteStock = (typeof MOTIVOS_AJUSTE_STOCK)[number]
