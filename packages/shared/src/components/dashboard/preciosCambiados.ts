import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import type { SupabaseClient } from '@supabase/supabase-js'

// Alerta de cambios de precio (docs/67): un producto está pendiente de etiquetar cuando su precio
// de venta es distinto del de su etiqueta en el local (o es un alta sin etiquetar). La base decide
// qué es pendiente y arma una fila por producto; el cliente solo muestra y marca.

export type OrigenPrecio = 'manual' | 'factura' | 'masivo' | 'margen' | 'iva' | 'reversion' | 'alta'

export const ORIGEN_PRECIO_LABEL: Record<OrigenPrecio, string> = {
  manual: 'Manual',
  factura: 'Factura',
  masivo: 'Masivo',
  margen: 'Margen',
  iva: 'IVA',
  reversion: 'Reversión',
  alta: 'Alta',
}

export type CambioPrecio = {
  productoId: string
  nombre: string
  marca: string | null
  codigoBarras: string | null
  codigoInterno: string | null
  fechaCambio: string // timestamptz
  precioAnterior: number | null // pendientes: el de la etiqueta; null = alta sin etiquetar
  precioActual: number
  variacion: number | null // %
  origen: OrigenPrecio
  pendiente: boolean
  marcadoPor: string | null // nombre
  marcadoAt: string | null
}

export type VistaCambiosPrecio = 'pendientes' | 'ultimos30'

// ['precios'] es el prefijo de todas: marcar invalida contador y listados juntos.
const CLAVE = ['precios'] as const

export async function fetchAlertaPrecios(supabase: SupabaseClient): Promise<number> {
  const { data, error } = await supabase.rpc('alerta_precios_pendientes')
  if (error) throw error
  return Number(data ?? 0)
}

export async function fetchCambiosPrecio(supabase: SupabaseClient, vista: VistaCambiosPrecio): Promise<CambioPrecio[]> {
  // Últimos 30 días: el default de la RPC (now() - 30 días, en la base).
  const { data, error } = await supabase.rpc('precios_cambiados', { p_solo_pendientes: vista === 'pendientes' })
  if (error) throw error
  type Fila = {
    producto_id: string
    nombre: string
    marca: string | null
    codigo_barras: string | null
    codigo_interno: string | null
    fecha_cambio: string
    precio_anterior: number | string | null
    precio_actual: number | string
    variacion_porcentaje: number | string | null
    origen: OrigenPrecio
    pendiente: boolean
    marcado_por: string | null
    marcado_at: string | null
  }
  return ((data ?? []) as Fila[]).map((f) => ({
    productoId: f.producto_id,
    nombre: f.nombre,
    marca: f.marca,
    codigoBarras: f.codigo_barras,
    codigoInterno: f.codigo_interno,
    fechaCambio: f.fecha_cambio,
    precioAnterior: f.precio_anterior === null ? null : Number(f.precio_anterior),
    precioActual: Number(f.precio_actual),
    variacion: f.variacion_porcentaje === null ? null : Number(f.variacion_porcentaje),
    origen: f.origen,
    pendiente: f.pendiente,
    marcadoPor: f.marcado_por,
    marcadoAt: f.marcado_at,
  }))
}

export function useAlertaPrecios(supabase: SupabaseClient) {
  return useQuery({
    queryKey: [...CLAVE, 'alerta'],
    queryFn: () => fetchAlertaPrecios(supabase),
    staleTime: 60_000,
  })
}

export function useCambiosPrecio(supabase: SupabaseClient, vista: VistaCambiosPrecio) {
  return useQuery({
    queryKey: [...CLAVE, 'cambios', vista],
    queryFn: () => fetchCambiosPrecio(supabase, vista),
  })
}

// "Etiqueta actualizada": manda el precio que se vio en pantalla; si cambió mientras tanto (o ya
// lo marcó otro), la base no lo marca. Devuelve cuántos marcó.
export function useMarcarEtiquetas(supabase: SupabaseClient) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (filas: Pick<CambioPrecio, 'productoId' | 'precioActual'>[]) => {
      const { data, error } = await supabase.rpc('marcar_etiquetas', {
        p_producto_ids: filas.map((f) => f.productoId),
        p_precios: filas.map((f) => f.precioActual),
      })
      if (error) throw error
      return Number(data ?? 0)
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: CLAVE }),
  })
}
