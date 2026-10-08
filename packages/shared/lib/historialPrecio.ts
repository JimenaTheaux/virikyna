// Historial de margen/precio de un producto — no es una tabla nueva: se deriva de `auditoria`,
// que ya guarda el before/after completo de cada UPDATE de productos vía el trigger genérico
// (docs/06_estructura_de_datos.md sección 8, docs/10_historial_auditoria_reversiones.sql). Acá
// se filtra, de las ediciones de un producto, cuáles tocaron el precio (costo, margen_1, margen_2
// o precio_manual) — una edición de nombre/descripción/estado no cuenta como cambio de margen.
import type { Auditoria } from '../types/database'

// precio_manual (docs/34): las ediciones anteriores no lo traen en el JSON; ausente = null.
const CAMPOS_PRECIO = ['costo', 'margen_1', 'margen_2', 'precio_manual'] as const

export type CambioMargenProducto = {
  auditoriaId: string
  createdAt: string
  usuarioId: string
  costoAnterior: number | null // null = sin costo (carga inicial)
  costoNuevo: number | null
  margen1Anterior: number
  margen1Nuevo: number
  margen2Anterior: number
  margen2Nuevo: number
  precioManualAnterior: number | null
  precioManualNuevo: number | null
  precioVentaAnterior: number
  precioVentaNuevo: number
}

// null/ausente se mantiene null: Number(null) daría 0 y un costo vacío se vería como $0.
function numeroONull(v: unknown): number | null {
  return v === null || v === undefined ? null : Number(v)
}

export function esCambioDePrecio(auditoria: Auditoria): boolean {
  if (auditoria.accion !== 'edicion') return false
  const antes = auditoria.valores_anteriores
  const despues = auditoria.valores_nuevos
  if (!antes || !despues) return false
  return CAMPOS_PRECIO.some((campo) => numeroONull(antes[campo]) !== numeroONull(despues[campo]))
}

// Asume que `auditoria` ya pasó esCambioDePrecio — ahí valores_anteriores/valores_nuevos
// están garantizados no-nulos.
function comoCambioMargen(auditoria: Auditoria): CambioMargenProducto {
  const antes = auditoria.valores_anteriores as Record<string, unknown>
  const despues = auditoria.valores_nuevos as Record<string, unknown>
  return {
    auditoriaId: auditoria.id,
    createdAt: auditoria.created_at,
    usuarioId: auditoria.usuario_id,
    costoAnterior: numeroONull(antes.costo),
    costoNuevo: numeroONull(despues.costo),
    margen1Anterior: Number(antes.margen_1),
    margen1Nuevo: Number(despues.margen_1),
    margen2Anterior: Number(antes.margen_2),
    margen2Nuevo: Number(despues.margen_2),
    precioManualAnterior: numeroONull(antes.precio_manual),
    precioManualNuevo: numeroONull(despues.precio_manual),
    precioVentaAnterior: Number(antes.precio_venta),
    precioVentaNuevo: Number(despues.precio_venta),
  }
}

// Filtra + mapea de una — lo que consumen las apps directo sobre el resultado crudo de `auditoria`
// (ya ordenado desc por created_at desde la query), así el primer elemento es el cambio más reciente.
export function historialDeMargen(filas: Auditoria[]): CambioMargenProducto[] {
  return filas.filter(esCambioDePrecio).map(comoCambioMargen)
}
