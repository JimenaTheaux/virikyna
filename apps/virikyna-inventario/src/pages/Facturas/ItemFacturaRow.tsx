import { useRef } from 'react'
import type { Proveedor, RolUsuario, UbicacionStock } from '@virikyna/shared'
import {
  AvisoCambioPrecioFactura,
  AvisoCodigoFactura,
  AvisoProductoInactivoFactura,
  formatCurrency,
  ScanButton,
  SugerenciasProductoFactura,
  totalItemFacturaCompra,
  useItemFacturaBusqueda,
  type CambioPrecioFactura,
  type ItemFacturaCompraUI,
} from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { Field, inputClass, selectClass } from '../../components/FormField'
import { IconPapelera } from '../../components/icons'
import { ProductoFormSheet } from '../Inventario/ProductoFormSheet'

type Props = {
  item: ItemFacturaCompraUI
  index: number
  puedeEliminar: boolean
  proveedores: Proveedor[]
  rol: RolUsuario
  // Marcado por la validación de "Guardar factura" (ej. sin producto seleccionado).
  error?: string
  // Cómo queda el precio de venta del producto al guardar (cambiosPrecioFactura, lo calcula la página).
  cambioPrecio?: CambioPrecioFactura
  // Ver useItemFacturaBusqueda: foco en "Cód. barras" y avance con el lector.
  focoCodigo?: number
  onAvanzar: () => void
  onChange: (cambios: Partial<ItemFacturaCompraUI>) => void
  onEliminar: () => void
}

// Botón de escaneo con la altura de los inputs (~56px) para que sea cómodo de tocar con el dedo.
// Mismo criterio de tamaño táctil que el resto de los botones de esta app (mínimo 44px).
const SCAN_BUTTON_CLASS =
  'flex w-14 flex-shrink-0 items-center justify-center rounded border border-accent/40 bg-accent-light text-accent-darker active:bg-accent active:text-white'

// Tarjeta de ítem de una factura de compra en el celular — mismos campos y mismo orden que la
// planilla de Virikyna Local/Gestión (Cód. barras → Producto → Marca → Cant. → Precio → Desc. →
// Depósito → Subtotal), pero apilados: una planilla no entra en 360px. Toda la lógica de
// búsqueda/escaneo/alta vive en useItemFacturaBusqueda (@virikyna/shared), la misma que usa la
// fila de escritorio; acá solo va el markup táctil y el botón de cámara.
export function ItemFacturaRow({
  item,
  index,
  puedeEliminar,
  proveedores,
  rol,
  error,
  cambioPrecio,
  focoCodigo,
  onAvanzar,
  onChange,
  onEliminar,
}: Props) {
  const tarjetaRef = useRef<HTMLDivElement>(null)
  const busqueda = useItemFacturaBusqueda({ supabase, item, onChange, onAvanzar, focoCodigo, contenedorRef: tarjetaRef })
  const { codigoRef, productoRef } = busqueda

  return (
    <div
      ref={tarjetaRef}
      data-item-key={item.key}
      className={`scroll-mt-4 rounded-lg border bg-surface p-4 shadow-sm ${error ? 'border-2 border-error' : 'border-line'}`}
    >
      <div className="flex items-center justify-between">
        <span className="font-sans text-label-bold text-ink-soft">Ítem {index + 1}</span>
        {puedeEliminar && (
          <button
            type="button"
            onClick={onEliminar}
            aria-label={`Quitar ítem ${index + 1}`}
            className="-mr-2 flex h-11 w-11 items-center justify-center rounded text-error active:bg-error/10"
          >
            <IconPapelera className="h-5 w-5" />
          </button>
        )}
      </div>

      {error && (
        <p role="alert" className="mt-1 rounded bg-error/10 px-3 py-2 font-sans text-label-bold text-error">
          {error}
        </p>
      )}

      <div className="mt-1 flex flex-col gap-stack-sm">
        <Field label="Cód. barras">
          <div className="flex items-stretch gap-2">
            <input
              ref={codigoRef}
              value={item.codigoBarras}
              onChange={(e) => busqueda.buscarPorCodigo(e.target.value)}
              onFocus={() => busqueda.setCampoActivo('codigo')}
              onBlur={() => busqueda.setCampoActivo(null)}
              onKeyDown={busqueda.onKeyDownCodigo}
              placeholder="Escaneá o tipeá el código"
              className={`${inputClass} min-w-0 flex-1`}
            />
            <ScanButton
              onDetect={(codigo) => {
                busqueda.resolverCodigo(codigo)
              }}
              onFocusCampo={() => codigoRef.current?.focus()}
              className={SCAN_BUTTON_CLASS}
            />
          </div>
        </Field>
        {busqueda.mostrarDropdownCodigo && (
          <SugerenciasProductoFactura busqueda={busqueda} campo="codigo" anchorRef={codigoRef} size="touch" />
        )}

        <AvisoCodigoFactura busqueda={busqueda} size="touch" />

        {/* Ítem copiado de otra factura cuyo producto hoy está inactivo (docs/33): bloquea el
            guardado hasta "Usarlo igual" o elegir otro (problemasItemsFacturaCompra). */}
        {item.productoId && item.productoInactivo && (
          <AvisoProductoInactivoFactura
            size="touch"
            nombre={item.descripcion}
            onUsar={() => onChange({ productoInactivo: false })}
            onBuscarOtro={() => {
              onChange({ productoId: null, productoPrecio: null, productoInactivo: false, descripcion: '', codigoBarras: '', marca: '' })
              busqueda.buscarPorNombre()
            }}
          />
        )}

        <Field
          label="Producto"
          hint={item.productoId ? 'Vinculado a un producto del catálogo' : 'Ítem libre — escribí nombre o marca para buscar'}
        >
          <input
            ref={productoRef}
            value={item.descripcion}
            onChange={(e) => busqueda.buscarPorProducto(e.target.value)}
            onFocus={() => busqueda.setCampoActivo('producto')}
            onBlur={() => busqueda.setCampoActivo(null)}
            onKeyDown={busqueda.onKeyDownProducto}
            placeholder="Buscar por nombre o marca"
            className={inputClass}
          />
        </Field>
        {busqueda.mostrarDropdownProducto && (
          <SugerenciasProductoFactura busqueda={busqueda} campo="producto" anchorRef={productoRef} size="touch" />
        )}

        <Field label="Marca">
          <input
            value={item.marca}
            onChange={(e) => onChange({ marca: e.target.value })}
            placeholder="—"
            className={inputClass}
          />
        </Field>

        <div className="grid grid-cols-2 gap-stack-sm">
          <Field label="Cantidad">
            <input
              type="number"
              inputMode="decimal"
              min="0"
              step="0.01"
              value={item.cantidad}
              onChange={(e) => onChange({ cantidad: e.target.value })}
              className={inputClass}
            />
          </Field>
          <Field label="Precio unit. sin IVA">
            <input
              type="number"
              inputMode="decimal"
              min="0"
              step="0.01"
              value={item.precioUnitarioSinIva}
              onChange={(e) => onChange({ precioUnitarioSinIva: e.target.value })}
              className={inputClass}
            />
          </Field>
        </div>

        <div className="grid grid-cols-2 gap-stack-sm">
          <Field label="Descuento %">
            <input
              type="number"
              inputMode="decimal"
              min="0"
              max="100"
              step="0.01"
              value={item.descuentoPorcentaje}
              onChange={(e) => onChange({ descuentoPorcentaje: e.target.value })}
              className={inputClass}
            />
          </Field>
          <Field label="Depósito">
            <select
              value={item.ubicacion}
              onChange={(e) => onChange({ ubicacion: e.target.value as UbicacionStock })}
              className={selectClass}
            >
              <option value="local">Local</option>
              <option value="deposito">Depósito</option>
            </select>
          </Field>
        </div>

        <p className="text-right font-sans text-label-bold text-ink">
          Subtotal: {formatCurrency(totalItemFacturaCompra(item))}
        </p>
        <AvisoCambioPrecioFactura cambio={cambioPrecio} className="text-right" />
      </div>

      {busqueda.creandoProducto && (
        <ProductoFormSheet
          proveedores={proveedores}
          rol={rol}
          nombreInicial={busqueda.crearInicial.nombre}
          codigoBarrasInicial={busqueda.crearInicial.codigoBarras}
          accionExistente="usar"
          onEditarExistente={busqueda.usarExistente}
          onClose={busqueda.cerrarCrear}
          onSaved={busqueda.alCrear}
          onStockChanged={() => {}}
        />
      )}
    </div>
  )
}
