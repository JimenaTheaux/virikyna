// Totales e IVA de una factura de compra — la parte pura de lib/facturasCompra.ts (que la
// re-exporta). Sin imports de runtime a propósito: lo corre también `node --test` (packages/shared/tests).

import type { TipoComprobanteCompra } from '../types/database'
import type { ItemFacturaCompra } from './facturasCompra'

// IVA del comprobante de compra completo (docs/45): 21 % o exento. No es el IVA del producto
// (IVA_PRODUCTO_DEFAULT, lib/inventario.ts) y no cambia el costo: ese sale siempre sin IVA.
export type AlicuotaIvaCompra = 21 | 0
export const ALICUOTAS_IVA_COMPRA: AlicuotaIvaCompra[] = [21, 0]

// Único lugar con el default por tipo, para las 3 apps. Cambiar el tipo en un formulario resetea
// la alícuota a este valor; después se puede cambiar a mano. El RPC no lo aplica solo (su default
// es 21, para las apps viejas que no mandan la alícuota).
export function alicuotaDefault(tipo: TipoComprobanteCompra): AlicuotaIvaCompra {
  return tipo === 'factura' || tipo === 'nota_debito' || tipo === 'nota_credito' ? 21 : 0
}

// Lo que viene de la base (numeric, a veces como texto) llevado a una alícuota válida.
export function aAlicuotaIvaCompra(valor: number | string): AlicuotaIvaCompra {
  return Number(valor) === 0 ? 0 : 21
}

// "IVA (21%)" / "Exento": rótulo del renglón de IVA en totales y detalles.
export function etiquetaAlicuotaIva(alicuota: number | string): string {
  return Number(alicuota) === 0 ? 'Exento' : `IVA (${Number(alicuota)}%)`
}

// "IVA 21%" / "Exento": opciones del selector y marca chica en listados.
export function etiquetaCortaAlicuotaIva(alicuota: number | string): string {
  return Number(alicuota) === 0 ? 'Exento' : `IVA ${Number(alicuota)}%`
}

// Mismo redondeo que cargar_factura_compra / editar_factura_compra: ROUND(sin IVA × alícuota / 100, 2).
export function ivaDeCompra(totalSinIva: number, alicuota: number): number {
  return Math.round(totalSinIva * (alicuota / 100) * 100) / 100
}

export function totalItemFacturaCompra(item: ItemFacturaCompra): number {
  const cantidad = Number(item.cantidad) || 0
  const precio = Number(item.precioUnitarioSinIva) || 0
  const descuento = Number(item.descuentoPorcentaje) || 0
  return Math.round(cantidad * precio * (1 - descuento / 100) * 100) / 100
}

// Mismo criterio que usa el RPC para descartar filas en blanco: sin descripción o sin
// cantidad no cuenta como ítem cargado.
export function itemsValidosFacturaCompra<T extends ItemFacturaCompra>(items: T[]): T[] {
  return items.filter((it) => it.descripcion.trim() && Number(it.cantidad) > 0)
}

// `descuento` es informativo: lo que restan los % de descuento por ítem, ya descontado del
// subtotal (no se resta de nuevo del total). `saldoPendiente`: al cargar la factura todavía no
// hay pagos (el RPC no registra ninguno, ni siquiera en contado), así que es igual al total.
// `alicuota`: la del comprobante (docs/45); exento da IVA 0.
export function calcularTotalesFacturaCompra(
  items: ItemFacturaCompra[],
  alicuota: AlicuotaIvaCompra,
): {
  subtotalSinIva: number
  descuento: number
  iva: number
  total: number
  saldoPendiente: number
} {
  const validos = itemsValidosFacturaCompra(items)
  const subtotalSinIva = validos.reduce((acc, it) => acc + totalItemFacturaCompra(it), 0)
  const bruto = validos.reduce((acc, it) => acc + (Number(it.cantidad) || 0) * (Number(it.precioUnitarioSinIva) || 0), 0)
  const descuento = Math.max(0, Math.round((bruto - subtotalSinIva) * 100) / 100)
  const iva = ivaDeCompra(subtotalSinIva, alicuota)
  const total = subtotalSinIva + iva
  return { subtotalSinIva, descuento, iva, total, saldoPendiente: total }
}
