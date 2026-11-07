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

// ROUND(cantidad × precio × (1 − descuento/100), 2), igual que cargar_factura_compra. Con enteros
// (BigInt) y no con number: en flotante 1,005 × 100 da 100,4999… y la línea redondeaba a 1,00
// mientras la base guardaba 1,01 (docs/71). Mismo método que lib/precios.ts.
export function totalItemFacturaCompra(item: ItemFacturaCompra): number {
  const cantidad = aEscalado(item.cantidad, 6)
  const precio = aEscalado(item.precioUnitarioSinIva, 6)
  const cien = 100n * 10n ** 6n
  const factor = cien - aEscalado(item.descuentoPorcentaje, 6)
  // cantidad × precio lleva 12 decimales; ÷ cien deja el factor de descuento; ÷ 10^10 → centavos.
  return Number(dividirRedondeando(cantidad * precio * factor, cien * 10n ** 10n)) / 100
}

// Pasa un número o texto decimal a entero escalado (valor × 10^escala), redondeando la mitad hacia
// afuera como el cast de Postgres a NUMERIC. Lo que no es un número vale 0 (como `Number(x) || 0`).
function aEscalado(valor: number | string, escala: number): bigint {
  let texto: string
  if (typeof valor === 'number') {
    if (!Number.isFinite(valor)) return 0n
    texto = String(valor)
    if (/e/i.test(texto)) texto = valor.toFixed(20)
  } else {
    texto = String(valor ?? '').trim()
  }
  const m = /^([+-]?)(\d*)(?:\.(\d*))?$/.exec(texto)
  if (!m || (m[2] === '' && (m[3] ?? '') === '')) return 0n
  const decimales = m[3] ?? ''
  const entero = BigInt((m[2] || '0') + decimales.padEnd(escala, '0').slice(0, escala))
  const absoluto = decimales.length > escala && Number(decimales[escala]) >= 5 ? entero + 1n : entero
  return m[1] === '-' ? -absoluto : absoluto
}

// a / b redondeado a entero, la mitad hacia afuera (como ROUND de Postgres sobre NUMERIC).
function dividirRedondeando(a: bigint, b: bigint): bigint {
  const negativo = a < 0n !== b < 0n
  const absA = a < 0n ? -a : a
  const absB = b < 0n ? -b : b
  let q = absA / absB
  if ((absA % absB) * 2n >= absB) q += 1n
  return negativo ? -q : q
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
// `ajuste` (docs/71): ajuste por redondeo con signo, fuera del IVA — se suma al final. Acepta el
// string del formulario ('' o inválido = 0).
export function calcularTotalesFacturaCompra(
  items: ItemFacturaCompra[],
  alicuota: AlicuotaIvaCompra,
  ajuste: number | string = 0,
): {
  subtotalSinIva: number
  descuento: number
  iva: number
  ajuste: number
  total: number
  saldoPendiente: number
} {
  const validos = itemsValidosFacturaCompra(items)
  const subtotalSinIva = redondear2(validos.reduce((acc, it) => acc + totalItemFacturaCompra(it), 0))
  const bruto = validos.reduce((acc, it) => acc + (Number(it.cantidad) || 0) * (Number(it.precioUnitarioSinIva) || 0), 0)
  const descuento = Math.max(0, Math.round((bruto - subtotalSinIva) * 100) / 100)
  const iva = ivaDeCompra(subtotalSinIva, alicuota)
  const ajusteNum = ajusteRedondeoNumero(ajuste)
  const total = redondear2(subtotalSinIva + iva + ajusteNum)
  return { subtotalSinIva, descuento, iva, ajuste: ajusteNum, total, saldoPendiente: total }
}

// Ajuste por redondeo del formulario (docs/71) como número: '' o algo que no es un monto = 0.
// Redondeado a centavos, igual que el RPC.
export function ajusteRedondeoNumero(valor: number | string | null | undefined): number {
  const n = Number(valor)
  return Number.isFinite(n) ? redondear2(n) : 0
}

function redondear2(n: number): number {
  return Math.round(n * 100) / 100
}
