import { useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { friendlyError } from './supabaseErrors'
import { formatAjuste } from './format'
import { nombreConMarca } from './productoTexto'
import { calcularPrecio } from './precios'
import { IVA_PRODUCTO_DEFAULT } from './inventario'
import { useSeleccionProductos } from './useSeleccionProductos'
import type { ProductoParaPrecios } from './useActualizarPrecios'

// IVA de productos (docs/47, docs/62): la lista muestra el estado real. Tildado = exento (sin IVA);
// abre con los exentos ya tildados, se tilda o destilda, y al aplicar fijar_iva_productos recibe
// los que pasan a sin IVA y los que vuelven a llevar IVA en una sola llamada. Una sola lógica para
// el modal de escritorio (MarcarIvaModal, Local y Gestión) y el sheet de Inventario. Solo admin:
// las pantallas no la ofrecen a un cajero y el RPC lo rechaza.
//
// Vista previa con calcularPrecio (misma fórmula que la columna generada, paridad verificada): un
// producto con precio manual cambia el IVA pero no el precio.

export type FilaVistaPreviaIva = {
  id: string
  nombre: string
  // Estado nuevo: true = vuelve a llevar IVA, false = pasa a sin IVA.
  llevaIva: boolean
  precioActual: number
  precioNuevo: number
  manual: boolean
}

export type VistaPreviaIva = { filas: FilaVistaPreviaIva[]; aSinIva: number; aConIva: number }

export function esExento(p: Pick<ProductoParaPrecios, 'iva_porcentaje'>): boolean {
  return Number(p.iva_porcentaje) === 0
}

function filaVistaPreviaIva(p: ProductoParaPrecios, llevaIva: boolean): FilaVistaPreviaIva {
  const precioActual = Number(p.precio_venta)
  const manual = p.precio_manual !== null
  const precioNuevo = manual
    ? precioActual
    : calcularPrecio({ costo: p.costo, margen1: p.margen_1, margen2: p.margen_2, iva: llevaIva ? IVA_PRODUCTO_DEFAULT : 0 }).venta
  return { id: p.id, nombre: nombreConMarca(p), llevaIva, precioActual, precioNuevo, manual }
}

type Opciones = {
  supabase: SupabaseClient
  productos: ProductoParaPrecios[]
  onSaved: (cantidad: number) => void
}

export function useMarcarIva({ supabase, productos, onSaved }: Opciones) {
  // Se calcula una vez al abrir: la selección parte del estado guardado.
  const [exentosIniciales] = useState(() => productos.filter(esExento).map((p) => p.id))
  const sel = useSeleccionProductos(productos, exentosIniciales)
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [vistaPrevia, setVistaPrevia] = useState<VistaPreviaIva | null>(null)
  const [confirmando, setConfirmando] = useState(false)

  function verVistaPrevia() {
    setError(null)
    // Solo los que difieren de lo guardado: tildado y con IVA → sin IVA; destildado y exento → con IVA.
    const filas = productos
      .filter((p) => sel.seleccion.has(p.id) !== esExento(p))
      .map((p) => filaVistaPreviaIva(p, !sel.seleccion.has(p.id)))
    if (filas.length === 0) {
      setError('No hay cambios: tildá los productos exentos (sin IVA) o destildá los que sí llevan IVA.')
      return
    }
    const aConIva = filas.filter((f) => f.llevaIva).length
    setVistaPrevia({ filas, aSinIva: filas.length - aConIva, aConIva })
  }

  function volver() {
    setVistaPrevia(null)
    setConfirmando(false)
    setError(null)
  }

  async function aplicar() {
    if (!vistaPrevia) return
    setConfirmando(false)
    setError(null)
    setSaving(true)
    const { data, error: dbError } = await supabase.rpc('fijar_iva_productos', {
      p_sin_iva: vistaPrevia.filas.filter((f) => !f.llevaIva).map((f) => f.id),
      p_con_iva: vistaPrevia.filas.filter((f) => f.llevaIva).map((f) => f.id),
    })
    setSaving(false)
    if (dbError) {
      setError(friendlyError(dbError))
      return
    }
    onSaved(Number(data) || 0)
  }

  return {
    ...sel,
    error,
    saving,
    vistaPrevia,
    verVistaPrevia,
    volver,
    // Confirmación con la cantidad antes de llamar al RPC.
    confirmando,
    pedirConfirmacion: () => setConfirmando(true),
    cancelarConfirmacion: () => setConfirmando(false),
    aplicar,
  }
}

// Lo que dice la columna "Cambio" de una fila de la vista previa (modal y sheet).
export function estadoFilaIva(f: FilaVistaPreviaIva): { texto: string; sinCambio: boolean } {
  if (f.manual) return { texto: 'Precio manual, no cambia', sinCambio: true }
  const diferencia = f.precioNuevo - f.precioActual
  return diferencia === 0 ? { texto: 'Sin cambio', sinCambio: true } : { texto: formatAjuste(diferencia), sinCambio: false }
}

// "Pasa a sin IVA" / "Vuelve a llevar IVA".
export function textoIvaNuevo(llevaIva: boolean): string {
  return llevaIva ? 'Vuelve a llevar IVA' : 'Pasa a sin IVA'
}

// Resumen de la vista previa: "2 pasan a sin IVA y 1 vuelve a llevar IVA".
export function resumenCambiosIva(v: VistaPreviaIva): string {
  const partes: string[] = []
  if (v.aSinIva > 0) partes.push(`${v.aSinIva} ${v.aSinIva === 1 ? 'pasa' : 'pasan'} a sin IVA`)
  if (v.aConIva > 0) partes.push(`${v.aConIva} ${v.aConIva === 1 ? 'vuelve' : 'vuelven'} a llevar IVA`)
  return partes.join(' y ')
}

// "Cambiar IVA de 3 productos".
export function textoAccionIva(n: number): string {
  return `Cambiar IVA de ${n} producto${n === 1 ? '' : 's'}`
}

// Contador de la lista: "502 exentos".
export function contadorExentos(n: number): string {
  return `${n} exento${n === 1 ? '' : 's'} (sin IVA)`
}
