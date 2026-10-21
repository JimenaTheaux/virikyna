import { useEffect, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { FacturaCompraItem, Producto } from '../../types/database'
import {
  etiquetaComprobanteCompra,
  vincularItemFacturaCompra,
  vistaPreviaVincularItemFacturaCompra,
  type VistaPreviaVinculoItem,
} from '../../lib/facturasCompra'
import { formatCurrency, formatFechaCorta } from '../../lib/format'
import { armarFiltroBusquedaProducto } from '../../lib/productoBusqueda'
import { friendlyError } from '../../lib/supabaseErrors'
import { useDebouncedValue } from '../../lib/useDebouncedValue'
import { Modal } from './Modal'
import { ErrorText, inputClass } from './FormField'
import { ProductoLinea } from './ProductoLinea'

type ProductoOpcion = Pick<Producto, 'id' | 'nombre' | 'marca' | 'descripcion' | 'codigo_barras' | 'codigo_interno' | 'costo'>

type Props = {
  supabase: SupabaseClient
  item: Pick<FacturaCompraItem, 'id' | 'descripcion' | 'cantidad' | 'ubicacion'>
  onClose: () => void
  onVinculado: () => void
}

// "Vincular a producto" desde el detalle de un comprobante (docs/50): un ítem libre (cargado con el
// nombre tipeado, sin elegir producto) no sumó stock. Acá se elige el producto del inventario y el
// RPC suma la cantidad del ítem una sola vez. Si el comprobante es la compra más nueva del producto,
// también le pone costo / proveedor / márgenes como al cargar la factura (docs/56): antes de
// confirmar se muestra cómo queda. Solo admin (lo valida el RPC; la pantalla solo lo ofrece a
// admin). Lo usan los detalles de factura de Local y Gestión.
export function VincularItemFacturaModal({ supabase, item, onClose, onVinculado }: Props) {
  const [query, setQuery] = useState(item.descripcion)
  const [resultados, setResultados] = useState<ProductoOpcion[]>([])
  const [buscando, setBuscando] = useState(false)
  const [elegido, setElegido] = useState<ProductoOpcion | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [previa, setPrevia] = useState<VistaPreviaVinculoItem | null>(null)
  const [cargandoPrevia, setCargandoPrevia] = useState(false)
  const queryDebounced = useDebouncedValue(query, 250)

  useEffect(() => {
    const q = queryDebounced.trim()
    if (q.length < 2) {
      setResultados([])
      return
    }
    let cancelado = false
    setBuscando(true)
    supabase
      .from('productos')
      .select('id, nombre, marca, descripcion, codigo_barras, codigo_interno, costo')
      .eq('estado', 'activo')
      .or(armarFiltroBusquedaProducto(q))
      .order('nombre')
      .limit(8)
      .then(({ data, error: dbError }) => {
        if (cancelado) return
        setBuscando(false)
        if (dbError) setError(friendlyError(dbError))
        setResultados((data ?? []) as ProductoOpcion[])
      })
    return () => {
      cancelado = true
    }
  }, [supabase, queryDebounced])

  useEffect(() => {
    setPrevia(null)
    setError(null)
    if (!elegido) return
    let cancelado = false
    setCargandoPrevia(true)
    vistaPreviaVincularItemFacturaCompra(supabase, item.id, elegido.id).then(({ data, error: rpcError }) => {
      if (cancelado) return
      setCargandoPrevia(false)
      if (rpcError) setError(friendlyError(rpcError))
      setPrevia((data ?? null) as VistaPreviaVinculoItem | null)
    })
    return () => {
      cancelado = true
    }
  }, [supabase, item.id, elegido])

  async function vincular() {
    if (!elegido) return
    setError(null)
    setSaving(true)
    const { error: rpcError } = await vincularItemFacturaCompra(supabase, item.id, elegido.id)
    setSaving(false)
    if (rpcError) {
      setError(friendlyError(rpcError))
      return
    }
    onVinculado()
  }

  const deposito = item.ubicacion === 'deposito' ? 'Depósito' : 'Local'

  return (
    <Modal
      title="Vincular a producto"
      onClose={onClose}
      widthClassName="max-w-[560px]"
      dialogo={{ onEscape: onClose }}
      footer={
        <div className="flex justify-end gap-3">
          <button type="button" onClick={onClose} className="rounded px-4 py-3 font-sans text-label-bold text-ink-soft hover:bg-bg">
            Cancelar
          </button>
          <button
            type="button"
            onClick={() => void vincular()}
            disabled={!elegido || saving || cargandoPrevia}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
          >
            {saving ? 'Vinculando...' : `Vincular y sumar ${Number(item.cantidad)} al stock`}
          </button>
        </div>
      }
    >
      <div className="flex flex-col gap-stack-md">
        <div className="rounded border border-line bg-bg px-4 py-3 font-sans text-body-md">
          <p className="text-ink-soft">Ítem del comprobante</p>
          <p className="text-ink">
            <strong>{item.descripcion}</strong> · {Number(item.cantidad)} u. · {deposito}
          </p>
          <p className="mt-1 text-label-md text-ink-soft">
            Se suma esa cantidad al stock del producto que elijas, una sola vez. Si es la compra más nueva del producto,
            también actualiza su costo y precio, como al cargar la factura.
          </p>
        </div>

        <input
          data-autofocus
          value={query}
          onChange={(e) => {
            setQuery(e.target.value)
            setElegido(null)
          }}
          placeholder="Buscar por código, nombre o marca..."
          aria-label="Buscar producto"
          className={inputClass}
        />

        <div role="listbox" aria-label="Productos" className="max-h-[320px] overflow-y-auto rounded-lg border border-line">
          {resultados.map((p) => {
            const activo = elegido?.id === p.id
            return (
              <button
                key={p.id}
                type="button"
                role="option"
                aria-selected={activo}
                onClick={() => setElegido(p)}
                className={`block w-full border-b border-line px-3 py-2 text-left last:border-b-0 ${
                  activo ? 'bg-accent-light outline outline-2 -outline-offset-2 outline-accent' : 'hover:bg-bg'
                }`}
              >
                <ProductoLinea producto={p} precio={p.costo === null ? null : Number(p.costo)} etiquetaPrecio="Costo" />
              </button>
            )
          })}
          {resultados.length === 0 && (
            <p className="px-3 py-3 font-sans text-body-md text-ink-soft">
              {buscando
                ? 'Buscando…'
                : query.trim().length < 2
                  ? 'Escribí al menos 2 letras.'
                  : 'No hay productos activos con ese texto. Si no existe, dalo de alta en Inventario y volvé.'}
            </p>
          )}
        </div>

        {elegido && (cargandoPrevia || previa) && (
          <div className="rounded border border-line bg-bg px-4 py-3 font-sans text-body-md text-ink" aria-live="polite">
            {cargandoPrevia || !previa ? (
              <p className="text-ink-soft">Calculando cómo queda el producto…</p>
            ) : (
              <ResumenVistaPrevia previa={previa} />
            )}
          </div>
        )}

        {error && <ErrorText>{error}</ErrorText>}
      </div>
    </Modal>
  )
}

// Cómo queda el producto al confirmar (plan_costo_vinculo_item, docs/56).
function ResumenVistaPrevia({ previa }: { previa: VistaPreviaVinculoItem }) {
  if (!previa.aplica) {
    const post = previa.compra_posterior
    return (
      <p>
        {post
          ? `Solo suma stock: el costo lo define una compra más nueva (${etiquetaComprobanteCompra(post)} del ${formatFechaCorta(post.fecha_comprobante)}).`
          : 'Solo suma stock: el costo y el precio de venta quedan igual.'}
      </p>
    )
  }
  const costo = (v: number | null) => (v === null ? 'sin costo' : formatCurrency(Number(v)))
  const precioNuevo = previa.precio_nuevo === null ? null : Number(previa.precio_nuevo)
  const cambiaCosto = Number(previa.costo_antes) !== Number(previa.costo_nuevo) || previa.costo_antes === null
  return (
    <ul className="flex flex-col gap-1">
      {cambiaCosto && (
        <li>
          Costo: {costo(previa.costo_antes)} → <strong>{costo(previa.costo_nuevo)}</strong>
        </li>
      )}
      {previa.cambia_proveedor && <li>Proveedor: pasa a {previa.proveedor_nuevo}, con sus márgenes</li>}
      <li>
        {previa.precio_manual_antes !== null && previa.pone_costo
          ? `Precio manual ${formatCurrency(Number(previa.precio_manual_antes))} → calculado `
          : 'Precio de venta: '}
        {previa.precio_manual_antes === null && precioNuevo === Number(previa.precio_antes) ? (
          `sigue en ${formatCurrency(precioNuevo)}`
        ) : (
          <>
            {previa.precio_manual_antes === null && `${formatCurrency(Number(previa.precio_antes))} → `}
            <strong>{precioNuevo === null ? '—' : formatCurrency(precioNuevo)}</strong>
          </>
        )}
      </li>
    </ul>
  )
}
