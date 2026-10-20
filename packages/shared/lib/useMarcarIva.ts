import { useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { friendlyError } from './supabaseErrors'
import { formatAjuste } from './format'
import { nombreConMarca } from './productoTexto'
import { calcularPrecio } from './precios'
import { IVA_PRODUCTO_DEFAULT } from './inventario'
import { useSeleccionProductos } from './useSeleccionProductos'
import type { ProductoParaPrecios } from './useActualizarPrecios'

// Acción masiva "Lleva IVA" (docs/47): marcar productos con IVA (21 %) o sin IVA (0). Una sola
// lógica para el modal de escritorio (MarcarIvaModal, Local y Gestión) y el sheet de Inventario.
// Solo admin: las pantallas no la ofrecen a un cajero y el RPC marcar_iva_productos lo rechaza.
//
// Vista previa con calcularPrecio (misma fórmula que la columna generada, paridad verificada): un
// producto con precio manual no cambia de precio, y uno que ya estaba así tampoco cambia nada.

export type FilaVistaPreviaIva = {
  id: string
  nombre: string
  precioActual: number
  precioNuevo: number
  motivoSinCambio: 'manual' | 'ya_estaba' | null
}

export type VistaPreviaIva = { llevaIva: boolean; filas: FilaVistaPreviaIva[]; cambian: number }

export type AccionIva = 'con' | 'sin'

export const OPCIONES_ACCION_IVA: { value: AccionIva; label: string }[] = [
  { value: 'con', label: 'Marcar con IVA' },
  { value: 'sin', label: 'Marcar sin IVA' },
]

type Opciones = {
  supabase: SupabaseClient
  productos: ProductoParaPrecios[]
  seleccionInicial?: string[]
  onSaved: (cantidad: number) => void
}

export function vistaPreviaIva(productos: ProductoParaPrecios[], llevaIva: boolean): FilaVistaPreviaIva[] {
  const ivaNuevo = llevaIva ? IVA_PRODUCTO_DEFAULT : 0
  return productos.map((p) => {
    const precioActual = Number(p.precio_venta)
    const yaEstaba = Number(p.iva_porcentaje) === ivaNuevo
    if (p.precio_manual !== null) {
      return { id: p.id, nombre: nombreConMarca(p), precioActual, precioNuevo: precioActual, motivoSinCambio: yaEstaba ? 'ya_estaba' : 'manual' }
    }
    const precioNuevo = yaEstaba
      ? precioActual
      : calcularPrecio({ costo: p.costo, margen1: p.margen_1, margen2: p.margen_2, iva: ivaNuevo }).venta
    return { id: p.id, nombre: nombreConMarca(p), precioActual, precioNuevo, motivoSinCambio: yaEstaba ? 'ya_estaba' : null }
  })
}

export function useMarcarIva({ supabase, productos, seleccionInicial = [], onSaved }: Opciones) {
  const sel = useSeleccionProductos(productos, seleccionInicial)
  const [accion, setAccion] = useState<AccionIva>('sin')
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [vistaPrevia, setVistaPrevia] = useState<VistaPreviaIva | null>(null)
  const [confirmando, setConfirmando] = useState(false)

  function verVistaPrevia() {
    setError(null)
    if (sel.seleccion.size === 0) {
      setError('Tildá al menos un producto.')
      return
    }
    const llevaIva = accion === 'con'
    const filas = vistaPreviaIva(
      productos.filter((p) => sel.seleccion.has(p.id)),
      llevaIva,
    )
    setVistaPrevia({ llevaIva, filas, cambian: filas.filter((f) => f.motivoSinCambio !== 'ya_estaba').length })
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
    const { data, error: dbError } = await supabase.rpc('marcar_iva_productos', {
      p_ids: vistaPrevia.filas.map((f) => f.id),
      p_lleva_iva: vistaPrevia.llevaIva,
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
    accion,
    setAccion,
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
  if (f.motivoSinCambio === 'manual') return { texto: 'Sin cambio (precio manual)', sinCambio: true }
  if (f.motivoSinCambio === 'ya_estaba') return { texto: 'Ya estaba así', sinCambio: true }
  const diferencia = f.precioNuevo - f.precioActual
  return diferencia === 0 ? { texto: 'Sin cambio', sinCambio: true } : { texto: formatAjuste(diferencia), sinCambio: false }
}

// "Marcar 3 productos sin IVA" / "… con IVA".
export function textoAccionIva(n: number, llevaIva: boolean): string {
  return `Marcar ${n} producto${n === 1 ? '' : 's'} ${llevaIva ? 'con' : 'sin'} IVA`
}
