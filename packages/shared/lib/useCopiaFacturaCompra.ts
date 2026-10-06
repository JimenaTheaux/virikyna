// Copiar una factura de compra (docs/33) — todo lo que no es dibujo, una sola copia para las dos
// presentaciones: el modal de escritorio (CargarFacturaCompraModal, Local y Gestión) y la pantalla
// de celular (Virikyna Inventario). Cada pantalla solo pone el markup (Modal / BottomSheet).

import { useEffect, useId, useRef, useState, type KeyboardEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { ComprobanteCompraExistente, LetraComprobanteCompra, TipoComprobanteCompra } from '../types/database'
import {
  existeComprobanteCompra,
  facturaACopia,
  obtenerFacturaParaCopiar,
  useFacturasRecientes,
  type ValoresFacturaCompra,
} from './facturasCompra'
import { friendlyError } from './supabaseErrors'
import { useDebouncedValue } from './useDebouncedValue'

// ─────────────────────────────────────────────────────────────
// Aviso de comprobante repetido
// ─────────────────────────────────────────────────────────────

type DatosComprobante = {
  proveedorId: string
  tipoComprobante: TipoComprobanteCompra
  letra: LetraComprobanteCompra | ''
  puntoVenta: string
  numeroComprobante: string
}

// Se verifica al salir de "Número" (verificar), con proveedor, tipo y número completos. El aviso se
// borra apenas cambia cualquiera de los 5 campos que definen el comprobante — un resultado viejo
// nunca queda mostrado para datos nuevos (ni llega tarde: cada consulta lleva su número de turno).
// Solo avisa: no bloquea el guardado.
export function useComprobanteDuplicado(supabase: SupabaseClient, datos: DatosComprobante) {
  const [coincidencias, setCoincidencias] = useState<ComprobanteCompraExistente[]>([])
  const turno = useRef(0)
  const { proveedorId, tipoComprobante, letra, puntoVenta, numeroComprobante } = datos

  useEffect(() => {
    turno.current += 1
    setCoincidencias([])
  }, [proveedorId, tipoComprobante, letra, puntoVenta, numeroComprobante])

  async function verificar() {
    const numero = numeroComprobante.trim()
    if (!proveedorId || !tipoComprobante || !numero) return
    const miTurno = ++turno.current
    const { data, error } = await existeComprobanteCompra(supabase, {
      proveedorId,
      tipo: tipoComprobante,
      letra: letra || null,
      puntoVenta: puntoVenta.trim() || null,
      numero,
    })
    // Error de red o de permisos: sin aviso (es una ayuda, no una validación).
    if (miTurno !== turno.current || error) return
    setCoincidencias((data ?? []) as ComprobanteCompraExistente[])
  }

  return { coincidencias, verificar }
}

// ─────────────────────────────────────────────────────────────
// Cargar una copia (con confirmación si el formulario ya tiene datos)
// ─────────────────────────────────────────────────────────────

type OpcionesCopia = {
  supabase: SupabaseClient
  // true si aplicar la copia pisaría algo: lo tipeado o una copia ya cargada.
  tieneDatos: boolean
  onAplicar: (valores: ValoresFacturaCompra) => void
}

export function useCopiaFacturaCompra({ supabase, tieneDatos, onAplicar }: OpcionesCopia) {
  const [cargando, setCargando] = useState(false)
  const [error, setError] = useState<string | null>(null)
  // Factura elegida que espera "Reemplazar" (el formulario tenía datos).
  const [pendiente, setPendiente] = useState<string | null>(null)
  const turno = useRef(0)

  async function cargar(id: string) {
    const miTurno = ++turno.current
    setCargando(true)
    setError(null)
    try {
      const factura = await obtenerFacturaParaCopiar(supabase, id)
      if (miTurno === turno.current) onAplicar(facturaACopia(factura))
    } catch (e) {
      if (miTurno === turno.current) setError(friendlyError(e as Error))
    } finally {
      if (miTurno === turno.current) setCargando(false)
    }
  }

  // `forzar`: precarga al abrir el formulario ya en modo copia — no hay nada que reemplazar.
  function pedirCopia(id: string, forzar = false) {
    if (tieneDatos && !forzar) {
      setPendiente(id)
      return
    }
    void cargar(id)
  }

  function confirmarReemplazo() {
    if (!pendiente) return
    const id = pendiente
    setPendiente(null)
    void cargar(id)
  }

  return {
    cargando,
    error,
    pendiente,
    pedirCopia,
    confirmarReemplazo,
    cancelarReemplazo: () => setPendiente(null),
    limpiarError: () => setError(null),
  }
}

// ─────────────────────────────────────────────────────────────
// Selector "Copiar desde…" (combobox + listbox)
// ─────────────────────────────────────────────────────────────

type OpcionesSelector = {
  supabase: SupabaseClient
  proveedorInicial?: string
  onElegir: (id: string) => void
}

// Filtro por proveedor y número sobre las últimas 20 facturas, y navegación con teclado del patrón
// combobox: ↑/↓ mueven la opción activa, Home/End van a los extremos, Enter elige. El foco se queda
// en el campo de búsqueda (aria-activedescendant), así se puede seguir tipeando.
export function useSelectorFacturaCopia({ supabase, proveedorInicial = '', onElegir }: OpcionesSelector) {
  const [proveedorId, setProveedorId] = useState(proveedorInicial)
  const [q, setQ] = useState('')
  const qDebounced = useDebouncedValue(q, 250)
  const { facturas, cargando, error } = useFacturasRecientes(supabase, proveedorId || undefined, qDebounced)
  const [activa, setActiva] = useState(0)
  const listId = useId()

  // Lista nueva → la activa vuelve a la primera.
  useEffect(() => setActiva(0), [facturas])

  function onKeyDown(e: KeyboardEvent<HTMLElement>) {
    if (facturas.length === 0) return
    const ultima = facturas.length - 1
    const destino =
      e.key === 'ArrowDown' ? Math.min(activa + 1, ultima)
      : e.key === 'ArrowUp' ? Math.max(activa - 1, 0)
      : e.key === 'Home' ? 0
      : e.key === 'End' ? ultima
      : -1
    if (destino >= 0) {
      e.preventDefault()
      setActiva(destino)
      document.getElementById(opcionId(facturas[destino].id))?.scrollIntoView({ block: 'nearest' })
      return
    }
    if (e.key === 'Enter') {
      e.preventDefault()
      const f = facturas[activa]
      if (f) onElegir(f.id)
    }
  }

  function opcionId(facturaId: string) {
    return `${listId}-${facturaId}`
  }

  const activaId = facturas[activa] ? opcionId(facturas[activa].id) : undefined

  return {
    proveedorId,
    setProveedorId,
    q,
    setQ,
    facturas,
    cargando,
    error: error ? friendlyError(error) : null,
    activa,
    setActiva,
    onKeyDown,
    elegir: onElegir,
    listId,
    opcionId,
    activaId,
  }
}

export type SelectorFacturaCopia = ReturnType<typeof useSelectorFacturaCopia>
