import { useRef, type ReactNode } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Proveedor, UbicacionStock } from '../../types/database'
import { formatCurrency } from '../../lib/format'
import { totalItemFacturaCompra, type ItemFacturaCompraUI } from '../../lib/facturasCompra'
import type { CambioPrecioFactura } from '../../lib/precios'
import { selectClass } from './FormField'
import { AvisoCambioPrecioFactura } from './AvisoCambioPrecioFactura'
import { AvisoCodigoFactura, SugerenciasProductoFactura, useItemFacturaBusqueda } from './ItemFacturaBusqueda'

// Lo que necesita la planilla de un producto recién creado para dejar el ítem vinculado.
export type ProductoCreadoFactura = {
  id: string
  nombre: string
  costo: number
  marca: string | null
  codigo_barras: string | null
}

// Cada app aporta su propio formulario de producto (Local: ProductoFormSheet con rol; Gestión:
// ProductoFormModal) — la planilla solo lo monta cuando se elige "+ Crear producto nuevo".
export type CrearProductoRender = (args: {
  proveedores: Proveedor[]
  nombreInicial: string
  // Al crear desde la celda "Cód. barras" el código tipeado/escaneado va acá — nunca como nombre.
  codigoBarrasInicial?: string
  onClose: () => void
  onSaved: (creado?: ProductoCreadoFactura) => void
  // Aviso de código duplicado del alta → "Usar este producto existente": vincula el ítem a ese
  // producto en vez de crear otro (pasarlo al formulario con accionExistente="usar").
  onUsarExistente: (id: string) => void
}) => ReactNode

type Props = {
  supabase: SupabaseClient
  item: ItemFacturaCompraUI
  index: number
  puedeEliminar: boolean
  proveedores: Proveedor[]
  crearProducto: CrearProductoRender
  // Ítem marcado por la validación de "Guardar factura" (ej. sin producto seleccionado).
  conError?: boolean
  // Cómo queda el precio de venta del producto al guardar (cambiosPrecioFactura, lo calcula la planilla).
  cambioPrecio?: CambioPrecioFactura
  // Ver useItemFacturaBusqueda: foco en "Cód. barras" y avance con el lector.
  focoCodigo?: number
  onAvanzar?: () => void
  onChange: (cambios: Partial<ItemFacturaCompraUI>) => void
  onEliminar: () => void
}

const cellInputClass =
  'w-full rounded border border-transparent bg-transparent px-2 py-1.5 font-sans text-body-md text-ink outline-none focus:border-accent focus:bg-surface disabled:text-ink-soft'
const cellInputRightClass = `${cellInputClass} text-right`
const cellSelectClass = `${selectClass} !rounded !border-transparent !bg-transparent !px-2 !py-1.5 focus:!border-accent focus:!bg-surface`

// Fila de ítem de una factura de compra, en formato planilla (una <tr>, celdas editables inline)
// — la presentación de escritorio (Local y Gestión). Toda la lógica de búsqueda/escaneo/alta vive
// en useItemFacturaBusqueda, compartida con la tarjeta de celular de Virikyna Inventario; acá solo
// va el markup. El aviso de código no encontrado se muestra en una segunda fila debajo.
export function ItemFacturaRow({
  supabase,
  item,
  index,
  puedeEliminar,
  proveedores,
  crearProducto,
  conError = false,
  cambioPrecio,
  focoCodigo,
  onAvanzar,
  onChange,
  onEliminar,
}: Props) {
  const filaRef = useRef<HTMLTableRowElement>(null)
  const busqueda = useItemFacturaBusqueda({ supabase, item, onChange, onAvanzar, focoCodigo, contenedorRef: filaRef })
  const { codigoRef, productoRef } = busqueda
  const hayAvisoCodigo = busqueda.buscandoCodigo || busqueda.avisoCodigo !== null
  // Segunda fila debajo del ítem: aviso de código no encontrado y/o cambio de precio de venta.
  const hayAviso = hayAvisoCodigo || cambioPrecio !== undefined
  const fondoError = conError ? 'bg-error/10' : ''

  return (
    <>
      <tr
        ref={filaRef}
        data-item-key={item.key}
        className={`${hayAviso ? '' : 'border-b border-line last:border-b-0'} ${
          conError ? `${fondoError} outline outline-2 -outline-offset-2 outline-error` : 'hover:bg-bg/60'
        }`}
      >
        <td className="relative px-2 py-1.5 align-top">
          <input
            ref={codigoRef}
            value={item.codigoBarras}
            title={item.codigoBarras}
            onChange={(e) => busqueda.buscarPorCodigo(e.target.value)}
            onFocus={() => busqueda.setCampoActivo('codigo')}
            onBlur={() => busqueda.setCampoActivo(null)}
            onKeyDown={busqueda.onKeyDownCodigo}
            placeholder="Escaneá o tipeá"
            className={cellInputClass}
          />
          {busqueda.mostrarDropdownCodigo && (
            <SugerenciasProductoFactura busqueda={busqueda} campo="codigo" anchorRef={codigoRef} />
          )}
        </td>
        <td className="relative px-2 py-1.5 align-top">
          <input
            ref={productoRef}
            value={item.descripcion}
            title={item.descripcion}
            onChange={(e) => busqueda.buscarPorProducto(e.target.value)}
            onFocus={() => busqueda.setCampoActivo('producto')}
            onBlur={() => busqueda.setCampoActivo(null)}
            onKeyDown={busqueda.onKeyDownProducto}
            placeholder="Buscar por código, nombre o marca..."
            className={cellInputClass}
          />
          {busqueda.mostrarDropdownProducto && (
            <SugerenciasProductoFactura busqueda={busqueda} campo="producto" anchorRef={productoRef} />
          )}
        </td>
        <td className="px-2 py-1.5 align-top">
          <input
            value={item.marca}
            title={item.marca}
            onChange={(e) => onChange({ marca: e.target.value })}
            placeholder="—"
            className={cellInputClass}
          />
        </td>
        <td className="px-2 py-1.5 align-top">
          <input
            type="number"
            inputMode="decimal"
            min="0"
            step="0.01"
            value={item.cantidad}
            onChange={(e) => onChange({ cantidad: e.target.value })}
            className={cellInputRightClass}
          />
        </td>
        <td className="px-2 py-1.5 align-top">
          <input
            type="number"
            inputMode="decimal"
            min="0"
            step="0.01"
            value={item.precioUnitarioSinIva}
            onChange={(e) => onChange({ precioUnitarioSinIva: e.target.value })}
            className={cellInputRightClass}
          />
        </td>
        <td className="px-2 py-1.5 align-top">
          <input
            type="number"
            inputMode="decimal"
            min="0"
            max="100"
            step="0.01"
            value={item.descuentoPorcentaje}
            onChange={(e) => onChange({ descuentoPorcentaje: e.target.value })}
            className={cellInputRightClass}
          />
        </td>
        <td className="px-2 py-1.5 align-top">
          <select
            value={item.ubicacion}
            title={item.ubicacion === 'deposito' ? 'Depósito' : 'Local'}
            onChange={(e) => onChange({ ubicacion: e.target.value as UbicacionStock })}
            className={cellSelectClass}
          >
            <option value="local">Local</option>
            <option value="deposito">Depósito</option>
          </select>
        </td>
        <td className="px-2 py-1.5 text-right align-top">
          <span className="font-sans text-label-bold text-ink">{formatCurrency(totalItemFacturaCompra(item))}</span>
        </td>
        <td className="px-2 py-1.5 text-center align-top">
          {puedeEliminar && (
            <button
              type="button"
              onClick={onEliminar}
              aria-label={`Quitar ítem ${index + 1}`}
              className="rounded p-1 font-sans text-body-md text-ink-soft hover:bg-error/10 hover:text-error"
            >
              ✕
            </button>
          )}
        </td>

        {busqueda.creandoProducto &&
          crearProducto({
            proveedores,
            nombreInicial: busqueda.crearInicial.nombre,
            codigoBarrasInicial: busqueda.crearInicial.codigoBarras,
            onClose: busqueda.cerrarCrear,
            onSaved: busqueda.alCrear,
            onUsarExistente: busqueda.usarExistente,
          })}
      </tr>

      {hayAviso && (
        <tr className={`border-b border-line last:border-b-0 ${fondoError}`}>
          <td colSpan={9} className="px-2 pb-2">
            {hayAvisoCodigo && <AvisoCodigoFactura busqueda={busqueda} />}
            <AvisoCambioPrecioFactura cambio={cambioPrecio} className="px-2" />
          </td>
        </tr>
      )}
    </>
  )
}
