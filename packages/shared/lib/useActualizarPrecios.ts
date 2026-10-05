import { useMemo, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { friendlyError } from './supabaseErrors'
import { coincideBusquedaProducto } from './productoBusqueda'
import { fijadosPrimero } from './listaSeleccion'
import { calcularPrecio, costoConPorcentaje } from './precios'
import { PAGINA_LISTA as PAGINA_LISTA_PRECIOS } from '../src/components/MostrarMas'

// Actualización masiva de precios — toda la lógica en un solo lugar para las dos presentaciones:
// el modal de escritorio (ActualizarPreciosModal, Local y Gestión) y el bottom sheet de Virikyna
// Inventario. Cada pantalla solo pone el markup.
//
// El % se aplica sobre el costo vía RPC actualizar_precios_masivo (docs/06, sección 11), que
// recalcula precio_venta con el margen vigente de cada producto. Antes de aplicar se muestra una
// vista previa por producto calculada con la misma fórmula que la base (lib/precios.ts; paridad
// verificada con `npm run paridad-precios`). Proveedor y selección puntual son excluyentes.

export type ModoActualizarPrecios = 'proveedor' | 'seleccion'

// Lo mínimo que necesita: cada app pasa sus productos con relaciones (ProductoConRelaciones).
export type ProductoParaPrecios = {
  id: string
  nombre: string
  marca: string | null
  codigo_barras: string | null
  codigo_interno: string | null
  proveedor_id: string | null
  proveedor: { razon_social: string } | null
  costo: number
  margen_1: number
  margen_2: number
  iva_porcentaje: number
  precio_venta: number
}

export type FilaVistaPreviaPrecio = {
  id: string
  nombre: string
  costoActual: number
  costoNuevo: number
  precioActual: number
  precioNuevo: number
  ajuste: number // redondeo del precio nuevo: venta − calculado
  sinCambio: boolean // el precio de venta no cambia (el redondeo absorbe la variación de costo)
}

export type VistaPreviaPrecios = { porcentaje: number; filas: FilaVistaPreviaPrecio[]; sinCambio: number }

export const PAGINA_VISTA_PREVIA = 50

type Opciones = {
  supabase: SupabaseClient
  productos: ProductoParaPrecios[]
  seleccionInicial?: string[]
  onSaved: (cantidad: number) => void
}

export function useActualizarPrecios({ supabase, productos, seleccionInicial = [], onSaved }: Opciones) {
  const [modo, setModo] = useState<ModoActualizarPrecios>(seleccionInicial.length > 0 ? 'seleccion' : 'proveedor')
  const [proveedorId, setProveedorId] = useState('')
  const [seleccion, setSeleccion] = useState<Set<string>>(new Set(seleccionInicial))
  const [busqueda, setBusqueda] = useState('')
  const [visibles, setVisibles] = useState(PAGINA_LISTA_PRECIOS)
  // Ids que se muestran primero: la selección con la que se abrió y, cada vez que cambia la
  // búsqueda, lo que estaba tildado hasta ese momento (ver fijadosPrimero).
  const [fijados, setFijados] = useState<Set<string>>(new Set(seleccionInicial))
  const [porcentaje, setPorcentaje] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [vistaPrevia, setVistaPrevia] = useState<VistaPreviaPrecios | null>(null)
  const [filasVisibles, setFilasVisibles] = useState(PAGINA_VISTA_PREVIA)

  const productosFiltrados = useMemo(() => {
    const q = busqueda.trim().toLowerCase()
    const filtrados = !q
      ? productos
      : productos.filter(
          (p) => coincideBusquedaProducto(p, q) || (p.proveedor?.razon_social ?? '').toLowerCase().includes(q),
        )
    return fijadosPrimero(filtrados, fijados)
  }, [productos, busqueda, fijados])

  function buscar(texto: string) {
    setBusqueda(texto)
    setFijados(new Set(seleccion))
    setVisibles(PAGINA_LISTA_PRECIOS)
  }

  function toggle(id: string) {
    setSeleccion((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  // Valida y arma la vista previa con los mismos productos que va a tocar el RPC: todos los del
  // proveedor (activos o no, igual que el RPC) o los tildados.
  function verVistaPrevia() {
    setError(null)
    const porcentajeNum = Number(porcentaje)
    if (!porcentaje.trim() || Number.isNaN(porcentajeNum) || porcentajeNum === 0) {
      setError('Ingresá un porcentaje distinto de cero (positivo para aumentar, negativo para bajar).')
      return
    }
    if (modo === 'proveedor' && !proveedorId) {
      setError('Elegí un proveedor.')
      return
    }
    if (modo === 'seleccion' && seleccion.size === 0) {
      setError('Tildá al menos un producto.')
      return
    }

    const afectados = productos.filter((p) =>
      modo === 'proveedor' ? p.proveedor_id === proveedorId : seleccion.has(p.id),
    )
    if (afectados.length === 0) {
      setError('Ese proveedor no tiene productos cargados.')
      return
    }

    const filas = afectados.map((p): FilaVistaPreviaPrecio => {
      const costoNuevo = costoConPorcentaje(p.costo, porcentaje)
      const nuevo = calcularPrecio({ costo: costoNuevo, margen1: p.margen_1, margen2: p.margen_2, iva: p.iva_porcentaje })
      return {
        id: p.id,
        nombre: p.nombre,
        costoActual: Number(p.costo),
        costoNuevo,
        precioActual: Number(p.precio_venta),
        precioNuevo: nuevo.venta,
        ajuste: nuevo.ajuste,
        sinCambio: nuevo.venta === Number(p.precio_venta),
      }
    })
    setFilasVisibles(PAGINA_VISTA_PREVIA)
    setVistaPrevia({ porcentaje: porcentajeNum, filas, sinCambio: filas.filter((f) => f.sinCambio).length })
  }

  function volver() {
    setVistaPrevia(null)
    setError(null)
  }

  async function aplicar() {
    if (!vistaPrevia) return
    setError(null)
    setSaving(true)
    const { data, error: dbError } = await supabase.rpc('actualizar_precios_masivo', {
      p_porcentaje: vistaPrevia.porcentaje,
      p_proveedor_id: modo === 'proveedor' ? proveedorId : null,
      p_producto_ids: modo === 'seleccion' ? Array.from(seleccion) : null,
    })
    setSaving(false)
    if (dbError) {
      setError(friendlyError(dbError))
      return
    }
    onSaved(Number(data) || 0)
  }

  return {
    modo,
    setModo,
    proveedorId,
    setProveedorId,
    seleccion,
    toggle,
    busqueda,
    buscar,
    productosVisibles: productosFiltrados.slice(0, visibles),
    sinResultados: productosFiltrados.length === 0,
    restantes: productosFiltrados.length - visibles,
    verMas: () => setVisibles((n) => n + PAGINA_LISTA_PRECIOS),
    porcentaje,
    setPorcentaje,
    error,
    saving,
    vistaPrevia,
    filasVisibles: vistaPrevia?.filas.slice(0, filasVisibles) ?? [],
    filasRestantes: (vistaPrevia?.filas.length ?? 0) - filasVisibles,
    verMasFilas: () => setFilasVisibles((n) => n + PAGINA_VISTA_PREVIA),
    verVistaPrevia,
    volver,
    aplicar,
  }
}
