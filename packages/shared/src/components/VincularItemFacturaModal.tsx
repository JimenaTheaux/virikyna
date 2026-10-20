import { useEffect, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { FacturaCompraItem, Producto } from '../../types/database'
import { vincularItemFacturaCompra } from '../../lib/facturasCompra'
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
// RPC suma la cantidad del ítem una sola vez. Solo admin (lo valida el RPC; la pantalla solo lo
// ofrece a admin). Lo usan los detalles de factura de Local y Gestión.
export function VincularItemFacturaModal({ supabase, item, onClose, onVinculado }: Props) {
  const [query, setQuery] = useState(item.descripcion)
  const [resultados, setResultados] = useState<ProductoOpcion[]>([])
  const [buscando, setBuscando] = useState(false)
  const [elegido, setElegido] = useState<ProductoOpcion | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
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
            disabled={!elegido || saving}
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
            Se suma esa cantidad al stock del producto que elijas, una sola vez. No cambia el costo ni el proveedor del producto.
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

        {error && <ErrorText>{error}</ErrorText>}
      </div>
    </Modal>
  )
}
