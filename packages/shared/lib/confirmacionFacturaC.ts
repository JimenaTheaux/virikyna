// Texto de la confirmación antes de emitir Factura C (Local, Gestión y Ventas del día). Muestra el
// documento tal como lo manda arca-emitir-factura (supabase/functions/arca-emitir-factura,
// armarComprobante): solo un CUIT de 11 dígitos se informa; cualquier otra cosa —un DNI, un CUIT
// mal cargado o ningún cliente— sale como consumidor final sin documento (DocTipo 99).
// Sin imports de valores a propósito: lo corre node --test directo (tests/confirmacionFacturaC.test.ts).
import type { Cliente } from '../types/database'

export type VentaAConfirmar = {
  numero: number
  total: number
  cliente: Pick<Cliente, 'razon_social' | 'nombre_fantasia' | 'cuit'> | null
}

export type DocumentoArca =
  | { tipo: 'cuit'; texto: string }
  | { tipo: 'consumidor_final'; texto: string; aviso: string | null }

// Mismo formato que formatCurrency (lib/format), repetido para no importar valores.
const moneda = new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' })

export function documentoParaArca(cuit: string | null | undefined): DocumentoArca {
  const digitos = (cuit ?? '').replace(/\D/g, '')
  if (digitos.length === 11) {
    return { tipo: 'cuit', texto: `CUIT ${digitos.slice(0, 2)}-${digitos.slice(2, 10)}-${digitos.slice(10)}` }
  }
  const texto = 'Consumidor final (sin documento)'
  if (!digitos) return { tipo: 'consumidor_final', texto, aviso: null }
  if (digitos.length === 7 || digitos.length === 8) {
    return { tipo: 'consumidor_final', texto, aviso: 'El DNI no se informa: sale como consumidor final.' }
  }
  return { tipo: 'consumidor_final', texto, aviso: `El CUIT cargado (${cuit}) no tiene 11 dígitos: sale como consumidor final.` }
}

export function nombreClienteFactura(cliente: VentaAConfirmar['cliente']): string {
  if (!cliente) return 'Consumidor final'
  return cliente.razon_social ?? cliente.nombre_fantasia ?? 'Cliente'
}

// Título, texto (una línea por renglón, ConfirmDialog usa pre-line) y botón de confirmar.
export function confirmacionFacturaC(
  ventas: VentaAConfirmar[],
  puntoVenta: string | null,
): { titulo: string; mensaje: string; confirmLabel: string } {
  const lineas: string[] = []
  const pie = [...(puntoVenta ? [`Punto de venta: ${puntoVenta}`] : []), 'Esta acción no se puede deshacer.']

  if (ventas.length === 1) {
    const [v] = ventas
    const doc = documentoParaArca(v.cliente?.cuit)
    lineas.push(`Cliente: ${nombreClienteFactura(v.cliente)}`)
    lineas.push(`Documento: ${doc.texto}`)
    if (doc.tipo === 'consumidor_final' && doc.aviso) lineas.push(`⚠ ${doc.aviso}`)
    lineas.push(`Ticket: ${v.numero} · Total: ${moneda.format(v.total)}`)
    return { titulo: 'Emitir Factura C', mensaje: [...lineas, ...pie].join('\n'), confirmLabel: 'Emitir factura' }
  }

  let conAviso = false
  for (const v of ventas) {
    const doc = documentoParaArca(v.cliente?.cuit)
    const nombre = nombreClienteFactura(v.cliente)
    let cliente = nombre
    if (doc.tipo === 'cuit') cliente = `${nombre} (${doc.texto})`
    else if (v.cliente && doc.aviso) {
      cliente = `${nombre} ⚠ sale como consumidor final`
      conAviso = true
    }
    lineas.push(`Ticket ${v.numero} · ${cliente} · ${moneda.format(v.total)}`)
  }
  const total = ventas.reduce((acc, v) => acc + v.total, 0)
  return {
    titulo: `Emitir ${ventas.length} Facturas C`,
    mensaje: [
      ...lineas,
      '',
      `Total: ${moneda.format(total)}`,
      ...(conAviso ? ['⚠ Los marcados no tienen CUIT válido (DNI u otro): el documento no se informa.'] : []),
      ...pie,
    ].join('\n'),
    confirmLabel: `Emitir ${ventas.length} facturas`,
  }
}
