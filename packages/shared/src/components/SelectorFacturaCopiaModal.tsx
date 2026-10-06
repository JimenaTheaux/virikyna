import type { SupabaseClient } from '@supabase/supabase-js'
import type { Proveedor } from '../../types/database'
import { etiquetaComprobanteCompra } from '../../lib/facturasCompra'
import { formatCurrency, formatFechaCorta } from '../../lib/format'
import { useSelectorFacturaCopia } from '../../lib/useCopiaFacturaCompra'
import { Modal } from './Modal'
import { Field, inputClass, selectClass } from './FormField'
import { EstadoBadge } from './EstadoBadge'

type Props = {
  supabase: SupabaseClient
  proveedores: Pick<Proveedor, 'id' | 'razon_social'>[]
  // Arranca filtrado por el proveedor ya elegido en el formulario, si hay.
  proveedorInicial?: string
  onElegir: (id: string) => void
  onClose: () => void
}

// "Copiar desde…" de escritorio (docs/33): dibujo del selector; la búsqueda y el teclado viven en
// useSelectorFacturaCopia, el mismo que usa el BottomSheet de Virikyna Inventario.
export function SelectorFacturaCopiaModal({ supabase, proveedores, proveedorInicial, onElegir, onClose }: Props) {
  const s = useSelectorFacturaCopia({ supabase, proveedorInicial, onElegir })
  const nombrePorId = new Map(proveedores.map((p) => [p.id, p.razon_social]))

  return (
    <Modal title="Copiar desde una factura" onClose={onClose} widthClassName="max-w-[640px]" dialogo={{ onEscape: onClose }}>
      <div className="flex flex-col gap-stack-md">
        <div className="grid grid-cols-2 gap-stack-sm">
          <Field label="Proveedor">
            <select value={s.proveedorId} onChange={(e) => s.setProveedorId(e.target.value)} className={selectClass}>
              <option value="">Todos</option>
              {proveedores.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.razon_social}
                </option>
              ))}
            </select>
          </Field>
          <Field label="Número">
            <input
              data-autofocus
              type="search"
              role="combobox"
              aria-expanded
              aria-controls={s.listId}
              aria-autocomplete="list"
              aria-activedescendant={s.activaId}
              value={s.q}
              onChange={(e) => s.setQ(e.target.value)}
              onKeyDown={s.onKeyDown}
              placeholder="0001-123 o parte del número"
              className={inputClass}
            />
          </Field>
        </div>

        <p aria-live="polite" className="sr-only">
          {s.cargando ? '' : `${s.facturas.length} ${s.facturas.length === 1 ? 'factura' : 'facturas'}`}
        </p>

        {s.error ? (
          <p role="alert" className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">
            {s.error}
          </p>
        ) : (
          <ul
            id={s.listId}
            role="listbox"
            aria-label="Facturas recientes"
            className="max-h-[50vh] overflow-y-auto rounded-lg border border-line"
          >
            {s.cargando && s.facturas.length === 0 && (
              <li className="px-3 py-3 font-sans text-body-md text-ink-soft">Buscando…</li>
            )}
            {!s.cargando && s.facturas.length === 0 && (
              <li className="px-3 py-3 font-sans text-body-md text-ink-soft">No hay facturas con ese filtro.</li>
            )}
            {s.facturas.map((f, i) => (
              <li
                key={f.id}
                id={s.opcionId(f.id)}
                role="option"
                aria-selected={i === s.activa}
                onMouseMove={() => i !== s.activa && s.setActiva(i)}
                onClick={() => s.elegir(f.id)}
                className={`cursor-pointer border-b border-line px-3 py-2 font-sans last:border-0 ${
                  i === s.activa ? 'bg-accent-light' : ''
                } ${f.anulada ? 'text-ink-soft' : ''}`}
              >
                <div className="flex items-baseline justify-between gap-2">
                  <span className={`text-body-md [overflow-wrap:anywhere] ${f.anulada ? '' : 'text-ink'}`}>
                    {etiquetaComprobanteCompra(f)}
                  </span>
                  <span className="shrink-0 text-body-md tabular-nums">{formatCurrency(Number(f.total))}</span>
                </div>
                <div className="flex items-center justify-between gap-2 text-label-md text-ink-soft">
                  <span className="[overflow-wrap:anywhere]">
                    {nombrePorId.get(f.proveedor_id) ?? '—'} · {formatFechaCorta(f.fecha_comprobante)}
                  </span>
                  {f.anulada && <EstadoBadge variant="red">Anulada</EstadoBadge>}
                </div>
              </li>
            ))}
          </ul>
        )}

        <p className="font-sans text-label-md text-ink-soft">
          Últimas 20 cargadas. ↑ ↓ para moverse, Enter para copiar.
        </p>
      </div>
    </Modal>
  )
}
