// Borrador de factura de compra / NC (docs/54, fase 1): qué se guarda del formulario y cómo se
// vuelve a abrir. Lo usan el modal de escritorio (Local, Gestión) y la página de Inventario.

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Producto } from '../types/database'
import {
  etiquetaComprobanteCompra,
  nuevoItemFacturaCompraUI,
  valoresFacturaCompraVacios,
  type ItemFacturaCompraUI,
  type ValoresFacturaCompra,
} from './facturasCompra'
import { formatCurrency } from './format'

// Ítem sin lo que se lee del producto al elegirlo (costo, márgenes, precio, inactivo): eso puede
// cambiar mientras el borrador espera, así que se vuelve a leer al restaurar.
type ItemBorradorFactura = Omit<ItemFacturaCompraUI, 'productoPrecio' | 'productoInactivo'>

export type PayloadBorradorFactura = {
  v: 1
  valores: Omit<ValoresFacturaCompra, 'items'> & { items: ItemBorradorFactura[] }
}

export function payloadBorradorFactura(v: ValoresFacturaCompra): PayloadBorradorFactura {
  return {
    v: 1,
    valores: {
      ...v,
      items: v.items.map(({ productoPrecio: _p, productoInactivo: _i, ...it }) => it),
    },
  }
}

// "AGABELLA · Factura A 0001-123 · 3 ítems · $ 12.100,00" — lo que se ve en el listado.
export function resumenBorradorFactura(v: ValoresFacturaCompra, proveedorNombre: string, total: number): string {
  const comprobante = etiquetaComprobanteCompra({
    tipo_comprobante: v.tipoComprobante,
    letra: v.letra || null,
    punto_venta: v.puntoVenta.trim() || null,
    numero_comprobante: v.numeroComprobante.trim() || null,
  })
  const items = v.items.filter((it) => it.descripcion.trim()).length
  return [
    proveedorNombre || 'Sin proveedor',
    comprobante,
    `${items} ${items === 1 ? 'ítem' : 'ítems'}`,
    formatCurrency(total),
  ].join(' · ')
}

type ProductoActual = Pick<
  Producto,
  | 'id'
  | 'nombre'
  | 'marca'
  | 'codigo_barras'
  | 'estado'
  | 'costo'
  | 'margen_1'
  | 'margen_2'
  | 'iva_porcentaje'
  | 'proveedor_id'
  | 'precio_venta'
  | 'precio_manual'
>

// Vuelve a armar el formulario con los datos de HOY: un producto eliminado pasa a ítem libre (con
// aviso), uno inactivo queda marcado (el formulario ya lo frena hasta "Usarlo igual"), nombre,
// marca, código, costo y precio se leen de nuevo, y un proveedor que ya no existe se vacía. El
// comprobante repetido lo revisa el formulario después (existe_comprobante_compra).
export async function restaurarBorradorFactura(
  supabase: SupabaseClient,
  payload: PayloadBorradorFactura,
): Promise<{ valores: ValoresFacturaCompra; avisos: string[] }> {
  // Lo que falte (payload incompleto o de una versión anterior) toma el valor de un formulario nuevo.
  const guardado = { ...valoresFacturaCompraVacios(), ...(payload?.valores ?? {}) } as PayloadBorradorFactura['valores']
  if (!Array.isArray(guardado.items)) guardado.items = []
  const avisos: string[] = []
  const ids = Array.from(new Set(guardado.items.map((it) => it.productoId).filter((x): x is string => Boolean(x))))

  const [proveedorRes, productosRes] = await Promise.all([
    guardado.proveedorId
      ? supabase.from('proveedores').select('id').eq('id', guardado.proveedorId).maybeSingle()
      : Promise.resolve({ data: null, error: null }),
    ids.length > 0
      ? supabase
          .from('productos')
          .select('id, nombre, marca, codigo_barras, estado, costo, margen_1, margen_2, iva_porcentaje, proveedor_id, precio_venta, precio_manual')
          .in('id', ids)
      : Promise.resolve({ data: [], error: null }),
  ])
  if (proveedorRes.error) throw proveedorRes.error
  if (productosRes.error) throw productosRes.error

  let proveedorId = guardado.proveedorId
  if (proveedorId && !proveedorRes.data) {
    proveedorId = ''
    avisos.push('El proveedor del borrador ya no existe: elegí uno.')
  }

  const productos = new Map(((productosRes.data ?? []) as ProductoActual[]).map((p) => [p.id, p]))
  const items = guardado.items.map((it): ItemFacturaCompraUI => {
    const base: ItemFacturaCompraUI = { ...nuevoItemFacturaCompraUI(), ...it, productoPrecio: null }
    if (!it.productoId) return base
    const p = productos.get(it.productoId)
    if (!p) {
      avisos.push(`"${it.descripcion.trim().toUpperCase()}" ya no está en el inventario: quedó como ítem libre (no va a sumar stock).`)
      return { ...base, productoId: null, codigoBarras: '' }
    }
    if (p.estado === 'inactivo') avisos.push(`"${p.nombre}" está inactivo: confirmá si lo usás igual o elegí otro.`)
    return {
      ...base,
      descripcion: p.nombre,
      marca: p.marca ?? '',
      codigoBarras: p.codigo_barras ?? '',
      productoInactivo: p.estado === 'inactivo',
      productoPrecio: {
        costo: p.costo === null ? null : Number(p.costo),
        margen_1: Number(p.margen_1),
        margen_2: Number(p.margen_2),
        iva_porcentaje: Number(p.iva_porcentaje),
        proveedor_id: p.proveedor_id,
        precio_venta: Number(p.precio_venta),
        precio_manual: p.precio_manual === null ? null : Number(p.precio_manual),
      },
    }
  })

  return {
    valores: { ...guardado, proveedorId, items: items.length > 0 ? items : [nuevoItemFacturaCompraUI()] },
    avisos,
  }
}
