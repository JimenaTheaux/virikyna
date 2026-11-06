// Cálculos del comprobante interno (docs/68, D6 y D10) para el modal de edición de Gestión. Espejo
// de editar_venta_interna: importe = round(cantidad × precio registrado × (1 − d/100), 2), total =
// round(Σ importes × (1 + recargo/100), 2). Sin imports en runtime: lo corre node --test directo.

export type ItemInterno = {
  id: string
  cantidad: number
  precio_unitario: number // precio registrado (de lista) — no cambia nunca
  descuento_porcentaje: number // el del ítem hoy
  // Snapshot al vender (docs/68). null en ventas anteriores (ej. la 388): se usa el producto actual.
  costo_unitario: number | null
  producto_con_iva: boolean | null
  producto_costo_actual: number | null
  producto_iva_actual: number | null // 0 o 21
}

export type CostoComparable = { valor: number; fuente: 'snapshot' | 'actual' } | null

const r2 = (n: number) => Math.round(n * 100) / 100

// D10: costo comparable con el precio de venta (que incluye IVA si el producto lo lleva):
// con IVA = costo × 1,21; sin IVA = costo. Producto sin costo cargado (precio manual) → null.
export function costoComparable(it: ItemInterno): CostoComparable {
  if (it.costo_unitario !== null && it.producto_con_iva !== null) {
    return { valor: r2(Number(it.costo_unitario) * (it.producto_con_iva ? 1.21 : 1)), fuente: 'snapshot' }
  }
  if (it.producto_costo_actual === null || it.producto_iva_actual === null) return null
  return { valor: r2(Number(it.producto_costo_actual) * (Number(it.producto_iva_actual) > 0 ? 1.21 : 1)), fuente: 'actual' }
}

export type FilaInterna = {
  precioFinalUnitario: number
  importe: number
  costo: CostoComparable
  margen: number | null // $ del renglón (precio final − costo) × cantidad
  margenPorcentaje: number | null // sobre el precio final
  descuentoMaximo: number | null // % máximo sin perder (precio final = costo)
  bajoCosto: boolean
}

export function calcularFila(it: ItemInterno, descuento: number): FilaInterna {
  const d = Number.isFinite(descuento) ? Math.min(100, Math.max(0, descuento)) : 0
  const precioFinalUnitario = r2(Number(it.precio_unitario) * (1 - d / 100))
  const importe = r2(Number(it.cantidad) * Number(it.precio_unitario) * (1 - d / 100))
  const costo = costoComparable(it)
  if (!costo) return { precioFinalUnitario, importe, costo, margen: null, margenPorcentaje: null, descuentoMaximo: null, bajoCosto: false }
  const margenUnitario = precioFinalUnitario - costo.valor
  const precio = Number(it.precio_unitario)
  return {
    precioFinalUnitario,
    importe,
    costo,
    margen: r2(margenUnitario * Number(it.cantidad)),
    margenPorcentaje: precioFinalUnitario > 0 ? r2((margenUnitario / precioFinalUnitario) * 100) : null,
    // Hacia abajo a 2 decimales: con ese % el precio todavía cubre el costo.
    descuentoMaximo: precio > 0 ? Math.max(0, Math.floor((1 - costo.valor / precio) * 10000) / 100) : null,
    bajoCosto: precioFinalUnitario < costo.valor,
  }
}

// D6: lo que se precarga en cada ítem. Si la venta todavía tiene descuento global (nunca se
// editó), ese % va a cada ítem (sumado al del ítem, que en Local es siempre 0); si ya se editó,
// rige el del ítem.
export function descuentoInicial(it: Pick<ItemInterno, 'descuento_porcentaje'>, descuentoGlobalVigente: number): number {
  if (descuentoGlobalVigente > 0) {
    const combinado = 100 - ((100 - Number(it.descuento_porcentaje)) * (100 - descuentoGlobalVigente)) / 100
    return r2(combinado)
  }
  return Number(it.descuento_porcentaje)
}

export function totalesInternos(items: ItemInterno[], descuentos: Map<string, number>, recargoPorcentaje: number) {
  const lista = r2(items.reduce((acc, it) => acc + Number(it.cantidad) * Number(it.precio_unitario), 0))
  const subtotal = r2(items.reduce((acc, it) => acc + calcularFila(it, descuentos.get(it.id) ?? 0).importe, 0))
  const total = r2(subtotal * (1 + recargoPorcentaje / 100))
  return { lista, subtotal, total }
}
