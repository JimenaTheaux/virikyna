// Medios de un pago a proveedor con varios medios (docs/65): lo que edita MediosPagoEditor y se
// manda a registrar_pago_proveedor_v3. Las cuentas van en centavos para que 3 cheques de un total
// repartido sumen exacto. El RPC vuelve a validar todo; esto evita el viaje y arma la vista.
// Sin imports de valores: lo corre node --test directo (tests/mediosPago.test.ts).
import type { FormaPagoEgreso } from '../types/database'

export type MedioPagoForm = {
  key: string // estable para React (no se manda)
  medio: FormaPagoEgreso
  monto: string // lo que está escrito en el campo
  numero: string // cheque / eCheq
  banco: string
  fechaPago: string // 'AAAA-MM-DD', cuándo se cobra el cheque
}

export function esChequeMedio(medio: FormaPagoEgreso): boolean {
  return medio === 'cheque' || medio === 'echeq'
}

let secuencia = 0
export function nuevoMedio(medio: FormaPagoEgreso = 'efectivo', monto = '', extra: Partial<MedioPagoForm> = {}): MedioPagoForm {
  secuencia += 1
  return { key: `medio-${secuencia}`, medio, monto, numero: '', banco: '', fechaPago: '', ...extra }
}

const centavos = (n: number) => Math.round(n * 100)

// NaN si el campo está vacío o no es un número.
export function montoDe(m: Pick<MedioPagoForm, 'monto'>): number {
  return m.monto.trim() === '' ? NaN : Number(m.monto)
}

export function totalMedios(medios: Pick<MedioPagoForm, 'monto'>[]): number {
  return medios.reduce((acc, m) => acc + (Number.isFinite(montoDe(m)) ? centavos(montoDe(m)) : 0), 0) / 100
}

// Cuánto falta (o sobra) para que los medios sumen el total del pago.
export function diferenciaMedios(total: number, medios: Pick<MedioPagoForm, 'monto'>[]): { estado: 'cierra' | 'falta' | 'sobra'; monto: number } {
  const dif = centavos(total) - centavos(totalMedios(medios))
  if (dif === 0) return { estado: 'cierra', monto: 0 }
  return { estado: dif > 0 ? 'falta' : 'sobra', monto: Math.abs(dif) / 100 }
}

// null si se puede guardar. `fechaPago` del pago: un cheque no puede cobrarse antes de salir.
export function validarMedios(
  medios: MedioPagoForm[],
  total: number,
  { permiteSinMedios = false, fechaPagoProveedor = '' }: { permiteSinMedios?: boolean; fechaPagoProveedor?: string } = {},
): string | null {
  if (medios.length === 0) return permiteSinMedios && total === 0 ? null : 'Agregá al menos un medio de pago.'
  for (const [i, m] of medios.entries()) {
    const n = i + 1
    const monto = montoDe(m)
    if (!Number.isFinite(monto) || monto <= 0) return `Ingresá el monto del medio ${n}.`
    if (esChequeMedio(m.medio)) {
      if (!m.numero.trim()) return `Ingresá el número del cheque (medio ${n}).`
      if (!m.fechaPago) return `Ingresá la fecha de pago del cheque ${m.numero.trim()}.`
      if (fechaPagoProveedor && m.fechaPago < fechaPagoProveedor) {
        return `El cheque ${m.numero.trim()} se cobra antes de la fecha del pago.`
      }
    }
  }
  const dif = diferenciaMedios(total, medios)
  if (dif.estado !== 'cierra') {
    return `Los medios suman ${totalMedios(medios).toFixed(2)} y el pago es de ${total.toFixed(2)}: ${
      dif.estado === 'falta' ? 'falta' : 'sobra'
    } ${dif.monto.toFixed(2)}.`
  }
  return null
}

// 'AAAA-MM-DD' + días, sin husos horarios de por medio.
export function sumarDias(fecha: string, dias: number): string {
  const [a, m, d] = fecha.split('-').map(Number)
  const f = new Date(Date.UTC(a, m - 1, d + dias))
  return f.toISOString().slice(0, 10)
}

// "00123" → "00124": siguiente número conservando el prefijo y los ceros. Sin dígitos al final: ''.
function numeroSiguiente(base: string, salto: number): string {
  const match = base.trim().match(/^(.*?)(\d+)$/)
  if (!match) return ''
  const [, prefijo, digitos] = match
  return prefijo + String(Number(digitos) + salto).padStart(digitos.length, '0')
}

export type GenerarChequesInput = {
  medio: 'cheque' | 'echeq'
  cantidad: number
  modo: 'cada' | 'total' // monto de cada cheque, o un total a repartir en partes iguales
  monto: number
  cadaDias: number
  desde: string // el primero se cobra `cadaDias` después
  banco: string
  numeroInicial: string // opcional: si termina en dígitos, los siguientes son correlativos
}

// "Generar cheques 30/60/90": arma las filas. Con total a repartir, el último absorbe los
// centavos que no dividen exacto.
export function generarCheques(input: GenerarChequesInput): MedioPagoForm[] {
  const cantidad = Math.floor(input.cantidad)
  if (!(cantidad > 0)) return []
  const totalCent = centavos(input.modo === 'total' ? input.monto : input.monto * cantidad)
  const base = input.modo === 'total' ? Math.floor(totalCent / cantidad) : centavos(input.monto)
  return Array.from({ length: cantidad }, (_, k) => {
    const cent = input.modo === 'total' && k === cantidad - 1 ? totalCent - base * (cantidad - 1) : base
    return nuevoMedio(input.medio, (cent / 100).toFixed(2), {
      numero: input.numeroInicial.trim() ? (k === 0 ? input.numeroInicial.trim() : numeroSiguiente(input.numeroInicial, k)) : '',
      banco: input.banco.trim(),
      fechaPago: sumarDias(input.desde, input.cadaDias * (k + 1)),
    })
  })
}

// p_medios de registrar_pago_proveedor_v3. La fecha de salida de los cheques es la del pago (la
// pone el RPC).
export function payloadMedios(medios: MedioPagoForm[]) {
  return medios.map((m) => {
    const cheque = esChequeMedio(m.medio)
    return {
      medio: m.medio,
      monto: Math.round(montoDe(m) * 100) / 100,
      ...(cheque ? { numero: m.numero.trim(), banco: m.banco.trim() || null, fecha_pago: m.fechaPago, propio: true } : {}),
    }
  })
}
