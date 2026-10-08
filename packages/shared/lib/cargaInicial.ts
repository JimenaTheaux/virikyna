// Carga inicial de inventario (docs/34, docs/34b, docs/06 sección 24, docs/04 módulo 5.2): hooks de
// TanStack Query sobre la tabla configuracion, los borradores propios y las RPCs carga_inicial_*,
// más el guardado en el navegador de las filas que todavía no llegaron al servidor.
//
// Keys (todas bajo 'carga-inicial' salvo la configuración, que es global):
//   ['configuracion']                          fila única de configuracion
//   ['carga-inicial', 'mios', usuarioId]       mis borradores (con el usuario: en Local se cambia
//                                              de usuario sin recargar y el caché no se mezcla)
//   ['carga-inicial', 'total', busqueda]       inventario total, paginado
//   ['carga-inicial', 'resumen']               carga_inicial_resumen

import { useEffect, useState } from 'react'
import { useInfiniteQuery, useMutation, useQuery, useQueryClient, type QueryClient } from '@tanstack/react-query'
import type { PostgrestError, SupabaseClient } from '@supabase/supabase-js'
import type {
  AccionCargaInicial,
  CargaInicialBusqueda,
  CargaInicialEditarResultado,
  CargaInicialFinalizarResultado,
  CargaInicialItem,
  CargaInicialResumen,
  CerrarCargaInicialResultado,
  Configuracion,
} from '../types/database'
import { friendlyError, isNetworkError } from './supabaseErrors'
import { armarFiltroBusquedaProducto, variantesCodigoBarras } from './productoBusqueda'

export const KEY_CONFIGURACION = ['configuracion'] as const
export const KEY_CARGA_INICIAL = ['carga-inicial'] as const
const keyMios = (usuarioId: string) => ['carga-inicial', 'mios', usuarioId] as const
const KEY_TOTAL = ['carga-inicial', 'total'] as const
const KEY_RESUMEN = ['carga-inicial', 'resumen'] as const

// Con la carga abierta, la configuración se vuelve a leer cada tanto: si un admin la cierra con la
// pantalla abierta, Local e Inventario se enteran solos (además del error de las RPCs).
const INTERVALO_REFRESCO_MS = 15_000
export const PAGINA_INVENTARIO_TOTAL = 50

// ─────────────────────────────────────────────────────────────
// Errores
// ─────────────────────────────────────────────────────────────

// Error de una RPC de carga inicial con lo que la pantalla necesita para decidir qué mostrar.
export class ErrorCargaInicial extends Error {
  sinConexion: boolean
  cerrada: boolean
  constructor(mensaje: string, sinConexion: boolean, cerrada: boolean) {
    super(mensaje)
    this.sinConexion = sinConexion
    this.cerrada = cerrada
  }
}

const MENSAJE_CERRADA = 'La carga inicial está cerrada'

function errorCarga(error: PostgrestError, status: number): ErrorCargaInicial {
  const sinConexion = isNetworkError(status)
  return new ErrorCargaInicial(
    sinConexion ? 'Sin conexión — no se pudo guardar. Reintentá cuando vuelva internet.' : friendlyError(error),
    sinConexion,
    !sinConexion && (error.message ?? '').startsWith(MENSAJE_CERRADA),
  )
}

export function esCargaCerrada(error: unknown): boolean {
  return error instanceof ErrorCargaInicial && error.cerrada
}

async function rpc<T>(supabase: SupabaseClient, nombre: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error, status } = await supabase.rpc(nombre, args)
  if (error) throw errorCarga(error, status)
  return data as T
}

// ─────────────────────────────────────────────────────────────
// Lecturas
// ─────────────────────────────────────────────────────────────

export function useConfiguracion(supabase: SupabaseClient) {
  return useQuery({
    queryKey: KEY_CONFIGURACION,
    queryFn: async () => {
      const { data, error } = await supabase.from('configuracion').select('*').single()
      if (error) throw error
      return data as Configuracion
    },
    refetchInterval: INTERVALO_REFRESCO_MS,
  })
}

export function useMisBorradores(supabase: SupabaseClient, usuarioId: string) {
  return useQuery({
    queryKey: keyMios(usuarioId),
    queryFn: async () => {
      // RLS: cada usuario lee solo los suyos.
      const { data, error } = await supabase
        .from('carga_inicial_items')
        .select('*')
        .order('created_at', { ascending: false })
      if (error) throw error
      return (data ?? []) as CargaInicialItem[]
    },
  })
}

export type ProductoInventarioTotal = {
  id: string
  nombre: string
  marca: string | null
  descripcion: string | null
  codigo_barras: string | null
  codigo_interno: string | null
  costo: number | null
  precio_manual: number | null
  precio_venta: number
  stock_local: number
}

type FilaProductoTotal = Omit<ProductoInventarioTotal, 'stock_local'> & {
  stock_ubicaciones: { ubicacion: string; cantidad: number }[]
}

// Productos activos con su stock local, de a PAGINA_INVENTARIO_TOTAL y con la búsqueda resuelta en
// el servidor: así funciona igual con 70 o con 5000 productos (la API corta en 1000 filas) y la
// pantalla nunca dibuja miles de filas de golpe. Se refresca solo mientras la pestaña está activa
// (`activo`) y la ventana visible (TanStack no corre el intervalo con la pestaña del navegador
// oculta: refetchIntervalInBackground es false por defecto).
export function useInventarioTotal(supabase: SupabaseClient, busqueda: string, activo: boolean) {
  const q = busqueda.trim()
  return useInfiniteQuery({
    queryKey: [...KEY_TOTAL, q],
    enabled: activo,
    refetchInterval: activo ? INTERVALO_REFRESCO_MS : false,
    initialPageParam: 0,
    queryFn: async ({ pageParam }) => {
      let consulta = supabase
        .from('productos')
        .select(
          'id, nombre, marca, descripcion, codigo_barras, codigo_interno, costo, precio_manual, precio_venta, stock_ubicaciones(ubicacion, cantidad)',
          { count: 'exact' },
        )
        .eq('estado', 'activo')
        .eq('stock_ubicaciones.ubicacion', 'local')
        .order('nombre')
        .order('id')
        .range(pageParam, pageParam + PAGINA_INVENTARIO_TOTAL - 1)
      if (q) {
        // Un código escaneado puede venir con o sin el 0 inicial (UPC-A ↔ EAN-13): además del
        // "contiene", se buscan sus variantes exactas.
        const variantes = variantesCodigoBarras(q)
        const exactos = variantes.length > 1 ? `,codigo_barras.in.(${variantes.join(',')})` : ''
        consulta = consulta.or(armarFiltroBusquedaProducto(q) + exactos)
      }
      const { data, error, count } = await consulta
      if (error) throw error
      const productos = ((data ?? []) as unknown as FilaProductoTotal[]).map(({ stock_ubicaciones, ...p }) => ({
        ...p,
        stock_local: Number(stock_ubicaciones[0]?.cantidad ?? 0),
      }))
      return { productos, total: count ?? 0, desde: pageParam }
    },
    getNextPageParam: (ultima) => {
      const siguiente = ultima.desde + PAGINA_INVENTARIO_TOTAL
      return siguiente < ultima.total ? siguiente : undefined
    },
  })
}

export function useResumenCarga(supabase: SupabaseClient, enabled = true) {
  return useQuery({
    queryKey: KEY_RESUMEN,
    queryFn: () => rpc<CargaInicialResumen>(supabase, 'carga_inicial_resumen'),
    enabled,
    refetchInterval: enabled ? INTERVALO_REFRESCO_MS : false,
  })
}

// Consulta puntual al salir del campo Código (no se cachea: tiene que ver lo último de los demás).
export function buscarCodigoCarga(supabase: SupabaseClient, codigo: string): Promise<CargaInicialBusqueda> {
  return rpc<CargaInicialBusqueda>(supabase, 'carga_inicial_buscar_codigo', { p_codigo: codigo })
}

// ─────────────────────────────────────────────────────────────
// Escrituras
// ─────────────────────────────────────────────────────────────

export type DatosBorrador = {
  // docs/34c: identifica la operación. Un reintento manda el MISMO: la base no la aplica dos veces.
  // Cada alta o edición nueva genera uno nuevo (crypto.randomUUID).
  clientId: string
  id: string | null // null = alta; con id = edición de ese borrador
  codigo: string
  nombre: string
  marca: string
  descripcion: string
  precio: number
  cantidad: number
  accion: AccionCargaInicial
}

// Sin conexión, TanStack pausa las mutaciones (networkMode 'online') y la fila quedaba en
// "Guardando…" hasta que volviera internet. Con 'always' fallan enseguida: la fila pasa a
// "No guardada" con Reintentar, que es seguro porque reusa el clientId (docs/34c).
const SIN_PAUSA = 'always' as const

function invalidar(queryClient: QueryClient, ...keys: readonly (readonly unknown[])[]) {
  return Promise.all(keys.map((queryKey) => queryClient.invalidateQueries({ queryKey })))
}

export function useGuardarBorrador(supabase: SupabaseClient, usuarioId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    networkMode: SIN_PAUSA,
    mutationFn: (d: DatosBorrador) =>
      rpc<CargaInicialItem>(supabase, 'carga_inicial_guardar_item', {
        p_client_id: d.clientId,
        p_codigo_barras: d.codigo || null,
        p_nombre: d.nombre,
        p_marca: d.marca || null,
        p_descripcion: d.descripcion || null,
        p_precio: d.precio,
        p_cantidad: d.cantidad,
        p_accion: d.accion,
        p_id: d.id,
      }),
    // La fila guardada entra al caché antes del refetch: la pendiente se saca de la lista en el
    // mismo momento y no "parpadea" (desaparece y vuelve). Si el código ya estaba en mis borradores,
    // la base devuelve esa misma fila con la cantidad sumada. Un reintento de una operación cuya
    // fila ya se finalizó o eliminó vuelve solo con el id (resto null): no se agrega nada.
    onSuccess: (fila) =>
      queryClient.setQueryData<CargaInicialItem[]>(keyMios(usuarioId), (prev) =>
        fila.nombre
          ? [fila, ...(prev ?? []).filter((f) => f.id !== fila.id)].sort((a, b) => b.created_at.localeCompare(a.created_at))
          : prev,
      ),
    onSettled: () => invalidar(queryClient, keyMios(usuarioId), KEY_RESUMEN),
  })
}

export function useEliminarBorrador(supabase: SupabaseClient, usuarioId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    networkMode: SIN_PAUSA,
    mutationFn: (id: string) => rpc<null>(supabase, 'carga_inicial_eliminar_item', { p_id: id }),
    onSuccess: (_, id) =>
      queryClient.setQueryData<CargaInicialItem[]>(keyMios(usuarioId), (prev) => prev?.filter((f) => f.id !== id)),
    onSettled: () => invalidar(queryClient, keyMios(usuarioId), KEY_RESUMEN),
  })
}

export function useFinalizarCarga(supabase: SupabaseClient, usuarioId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    networkMode: SIN_PAUSA,
    mutationFn: () => rpc<CargaInicialFinalizarResultado>(supabase, 'carga_inicial_finalizar'),
    onSettled: () => invalidar(queryClient, keyMios(usuarioId), KEY_TOTAL, KEY_RESUMEN),
  })
}

export type DatosEdicionProducto = {
  clientId: string // docs/34c: mismo criterio que DatosBorrador.clientId
  productoId: string
  nombre: string
  marca: string
  descripcion: string
  precio: number | null // null = no tocar (producto con costo)
  cantidadLocal: number
}

export function useEditarProductoCarga(supabase: SupabaseClient) {
  const queryClient = useQueryClient()
  return useMutation({
    networkMode: SIN_PAUSA,
    mutationFn: (d: DatosEdicionProducto) =>
      rpc<CargaInicialEditarResultado>(supabase, 'carga_inicial_editar_producto', {
        p_client_id: d.clientId,
        p_producto_id: d.productoId,
        p_nombre: d.nombre,
        p_marca: d.marca || null,
        p_descripcion: d.descripcion || null,
        p_precio: d.precio,
        p_cantidad_local: d.cantidadLocal,
      }),
    onSettled: () => invalidar(queryClient, KEY_TOTAL, KEY_RESUMEN),
  })
}

export function useAbrirCarga(supabase: SupabaseClient) {
  const queryClient = useQueryClient()
  return useMutation({
    networkMode: SIN_PAUSA,
    mutationFn: () => rpc<Configuracion>(supabase, 'abrir_carga_inicial'),
    onSettled: () => invalidar(queryClient, KEY_CONFIGURACION, KEY_RESUMEN),
  })
}

export function useCerrarCarga(supabase: SupabaseClient) {
  const queryClient = useQueryClient()
  return useMutation({
    networkMode: SIN_PAUSA,
    mutationFn: () => rpc<CerrarCargaInicialResultado>(supabase, 'cerrar_carga_inicial'),
    onSettled: () => invalidar(queryClient, KEY_CONFIGURACION, KEY_RESUMEN),
  })
}

// ─────────────────────────────────────────────────────────────
// Filas que todavía no llegaron al servidor
// ─────────────────────────────────────────────────────────────

// Una fila tipeada que se está guardando o que falló (sin conexión, o la base la rechazó). Con
// `id` es la edición de un borrador ya guardado; sin `id`, un alta. Se guarda en el navegador por
// usuario —con su clientId— para no perder lo tipeado si se recarga la página o se corta la luz, y
// para que el reintento sea la misma operación (docs/34c).
export type FilaPendiente = Omit<DatosBorrador, 'precio' | 'cantidad'> & {
  idLocal: string
  precio: string
  cantidad: string
  estado: 'guardando' | 'error'
  error: string | null
  creadaAt: number
}

type GuardadoLocal = {
  // configuracion.datos_reset_at que se vio al guardar. Si después la base se vació
  // (datos_reset_at posterior), lo guardado ya no corresponde y se descarta.
  marca: string | null
  filas: FilaPendiente[]
}

const claveStorage = (usuarioId: string) => `virikyna:carga-inicial:pendientes:${usuarioId}:v1`

function leerGuardado(usuarioId: string): GuardadoLocal | null {
  try {
    const raw = localStorage.getItem(claveStorage(usuarioId))
    if (!raw) return null
    const parsed = JSON.parse(raw) as Partial<GuardadoLocal>
    if (!Array.isArray(parsed.filas)) return null
    return { marca: parsed.marca ?? null, filas: parsed.filas }
  } catch {
    return null
  }
}

function escribirGuardado(usuarioId: string, guardado: GuardadoLocal) {
  try {
    if (guardado.filas.length === 0) localStorage.removeItem(claveStorage(usuarioId))
    else localStorage.setItem(claveStorage(usuarioId), JSON.stringify(guardado))
  } catch {
    // Cuota llena o modo restringido: las filas siguen en memoria mientras la pantalla esté abierta.
  }
}

// true si lo guardado es anterior al último vaciado de la base.
export function guardadoVencido(marca: string | null, datosResetAt: string | null): boolean {
  if (!datosResetAt) return false
  if (!marca) return true
  return new Date(datosResetAt).getTime() > new Date(marca).getTime()
}

// Estado de las filas pendientes del usuario, sincronizado con localStorage. Espera a tener la
// configuración (`datosResetAt` !== undefined) para decidir si lo guardado sigue valiendo. Al
// cambiar de usuario se recarga desde la clave del nuevo.
export function useFilasPendientes(usuarioId: string, datosResetAt: string | null | undefined) {
  const [estado, setEstado] = useState<{ usuarioId: string; filas: FilaPendiente[] } | null>(null)
  const cargado = estado !== null && estado.usuarioId === usuarioId

  useEffect(() => {
    if (datosResetAt === undefined || cargado) return
    const guardado = leerGuardado(usuarioId)
    let filas = guardado?.filas ?? []
    if (guardado && guardadoVencido(guardado.marca, datosResetAt)) {
      filas = []
      escribirGuardado(usuarioId, { marca: datosResetAt, filas })
    }
    // Lo que quedó "guardando" cuando se cerró la pantalla queda para reintentar: con el mismo
    // clientId, si ya había llegado la base no lo aplica de nuevo. Filas guardadas antes de docs/34c
    // no traen clientId: se les asigna uno.
    setEstado({
      usuarioId,
      filas: filas.map((f) => ({
        ...f,
        clientId: f.clientId ?? crypto.randomUUID(),
        ...(f.estado === 'guardando' ? { estado: 'error' as const, error: null } : {}),
      })),
    })
  }, [usuarioId, datosResetAt, cargado])

  function actualizar(cambio: (filas: FilaPendiente[]) => FilaPendiente[]) {
    setEstado((prev) => {
      const base = prev && prev.usuarioId === usuarioId ? prev.filas : []
      const filas = cambio(base)
      escribirGuardado(usuarioId, { marca: datosResetAt ?? null, filas })
      return { usuarioId, filas }
    })
  }

  return { filas: cargado ? estado.filas : [], cargado, actualizar }
}

// ─────────────────────────────────────────────────────────────
// Helpers de pantalla
// ─────────────────────────────────────────────────────────────

export type ErroresFila = Partial<Record<'nombre' | 'precio' | 'cantidad', string>>

export function validarFila(f: { nombre: string; precio: string; cantidad: string }): ErroresFila {
  const errores: ErroresFila = {}
  if (!f.nombre.trim()) errores.nombre = 'El nombre es obligatorio.'
  if (!(Number(f.precio) > 0)) errores.precio = 'El precio tiene que ser mayor a 0.'
  if (!(Number(f.cantidad) > 0)) errores.cantidad = 'La cantidad tiene que ser mayor a 0.'
  return errores
}

// "08/10" — fecha corta del encabezado ("Abierta desde 08/10 por Ana").
export function formatDiaMes(iso: string): string {
  const d = new Date(iso)
  return `${String(d.getDate()).padStart(2, '0')}/${String(d.getMonth() + 1).padStart(2, '0')}`
}

export function formatCantidad(n: number): string {
  return new Intl.NumberFormat('es-AR', { maximumFractionDigits: 2 }).format(n)
}
