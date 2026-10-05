// Vista previa del reparto de un pago a proveedor — espejo en TS de registrar_pago_proveedor_v2
// (docs/31_cuenta_corriente_proveedor.sql, sección 5). La fuente de verdad es el RPC: esto solo
// le muestra al usuario, ANTES de confirmar, qué comprobante cancela cuánto y cómo queda cada uno.
// Si alguna vez cambia la regla en SQL, cambia acá también (tests: tests/repartoPago.test.ts,
// mismos casos que la parte C de docs/31).
//
// Regla:
//   1. Comprobantes a cancelar: los elegidos, o todos los pendientes si no se eligió ninguno.
//      Nunca NC ni anulados. Orden: fecha_comprobante, created_at, id (más viejos primero).
//   2. Primero se aplica el crédito de las NC elegidas (más viejas primero).
//   3. Después se reparte el monto en el mismo orden. Con selección, el monto no puede superar lo
//      que queda tras las NC. Sin selección, lo que sobra queda a cuenta.
//   4. Monto 0 solo vale si se aplica crédito de alguna NC.
//
// Sin imports en runtime a propósito: lo importa `node --test` directo desde el .ts.

import type { TipoComprobanteCompra } from '../types/database'

export type ComprobanteReparto = {
  id: string
  tipo_comprobante: TipoComprobanteCompra
  fecha_comprobante: string
  created_at: string
  anulada: boolean
  saldo_pendiente: number | string
  credito_disponible: number | string
}

export type AplicacionReparto = {
  comprobanteId: string
  monto: number
  fuente: 'pago' | 'nota_credito'
  notaCreditoId: string | null
}

export type ResultadoReparto = {
  aplicaciones: AplicacionReparto[]
  aplicadoNotaCredito: number
  aplicadoPago: number
  aCuenta: number
  // Lo que queda por pagar de los comprobantes alcanzados después de aplicar las NC: con
  // selección, es el tope del monto (y el "A pagar" de la barra de selección).
  restanteTrasNotas: number
  saldoFinal: Map<string, number> // por comprobante alcanzado
  creditoFinal: Map<string, number> // por NC elegida
  error: string | null
}

// Todo en centavos enteros: sumar/restar montos con decimales en float acumula error.
const aCentavos = (v: number | string) => Math.round(Number(v) * 100)
const aPesos = (c: number) => c / 100

function porAntiguedad(a: ComprobanteReparto, b: ComprobanteReparto): number {
  if (a.fecha_comprobante !== b.fecha_comprobante) return a.fecha_comprobante < b.fecha_comprobante ? -1 : 1
  if (a.created_at !== b.created_at) return a.created_at < b.created_at ? -1 : 1
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0
}

export function esNotaCredito(c: { tipo_comprobante: TipoComprobanteCompra }): boolean {
  return c.tipo_comprobante === 'nota_credito'
}

// Se puede elegir para pagar (o usar su crédito): comprobante con saldo, o NC con crédito.
export function esSeleccionableParaPago(c: ComprobanteReparto): boolean {
  if (c.anulada) return false
  return esNotaCredito(c) ? Number(c.credito_disponible) > 0 : Number(c.saldo_pendiente) > 0
}

export function simularRepartoPago(input: {
  comprobantes: ComprobanteReparto[]
  facturaIds: string[] // vacío = todos los pendientes
  notaCreditoIds: string[]
  monto: number
}): ResultadoReparto {
  const seleccion = new Set(input.facturaIds)
  const conSeleccion = seleccion.size > 0
  const ncElegidas = new Set(input.notaCreditoIds)

  const docs = input.comprobantes
    .filter((c) => !c.anulada && !esNotaCredito(c) && aCentavos(c.saldo_pendiente) > 0)
    .filter((c) => !conSeleccion || seleccion.has(c.id))
    .sort(porAntiguedad)
  const ncs = input.comprobantes
    .filter((c) => ncElegidas.has(c.id) && !c.anulada && esNotaCredito(c) && aCentavos(c.credito_disponible) > 0)
    .sort(porAntiguedad)

  const saldos = docs.map((d) => aCentavos(d.saldo_pendiente))
  const creditos = ncs.map((n) => aCentavos(n.credito_disponible))
  const aplicaciones: AplicacionReparto[] = []

  // Paso 1: crédito de NC contra los comprobantes.
  let totalNc = 0
  for (let i = 0, j = 0; i < docs.length && j < ncs.length; ) {
    const aplicar = Math.min(saldos[i], creditos[j])
    aplicaciones.push({ comprobanteId: docs[i].id, monto: aPesos(aplicar), fuente: 'nota_credito', notaCreditoId: ncs[j].id })
    saldos[i] -= aplicar
    creditos[j] -= aplicar
    totalNc += aplicar
    if (saldos[i] <= 0) i++
    if (creditos[j] <= 0) j++
  }

  const restante = saldos.reduce((acc, s) => acc + s, 0)
  const monto = aCentavos(input.monto)

  let error: string | null = null
  if (!(monto >= 0)) error = 'El monto no puede ser negativo.'
  else if (monto === 0 && ncs.length === 0) error = 'Ingresá un monto mayor a cero o elegí una nota de crédito.'
  else if (monto === 0 && totalNc === 0) error = 'No hay saldo pendiente al que aplicar la nota de crédito.'
  else if (conSeleccion && monto > restante) error = 'El monto supera el saldo de los comprobantes elegidos.'

  // Paso 2: repartir el pago.
  let rest = Math.max(0, monto)
  for (let i = 0; i < docs.length && rest > 0; i++) {
    const aplicar = Math.min(saldos[i], rest)
    if (aplicar <= 0) continue
    aplicaciones.push({ comprobanteId: docs[i].id, monto: aPesos(aplicar), fuente: 'pago', notaCreditoId: null })
    saldos[i] -= aplicar
    rest -= aplicar
  }

  return {
    aplicaciones,
    aplicadoNotaCredito: aPesos(totalNc),
    aplicadoPago: aPesos(Math.max(0, monto) - rest),
    aCuenta: aPesos(rest),
    restanteTrasNotas: aPesos(restante),
    saldoFinal: new Map(docs.map((d, i) => [d.id, aPesos(saldos[i])])),
    creditoFinal: new Map(ncs.map((n, j) => [n.id, aPesos(creditos[j])])),
    error,
  }
}
