import type { Proveedor } from '@virikyna/shared'
import {
  BottomSheet,
  EstadoBadge,
  etiquetaComprobanteCompra,
  formatCurrency,
  formatFechaCorta,
  useSelectorFacturaCopia,
} from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { Field, inputClass, selectClass } from '../../components/FormField'

type Props = {
  proveedores: Pick<Proveedor, 'id' | 'razon_social'>[]
  // Arranca filtrado por el proveedor ya elegido en el formulario, si hay.
  proveedorInicial?: string
  onElegir: (id: string) => void
  onClose: () => void
}

// "Copiar desde…" en el celular (docs/33): mismo hook que el selector de escritorio
// (useSelectorFacturaCopia — búsqueda, últimas 20, teclado), dibujado en pantalla completa con
// opciones de 56px para tocar con el pulgar.
export function SelectorFacturaCopiaSheet({ proveedores, proveedorInicial, onElegir, onClose }: Props) {
  const s = useSelectorFacturaCopia({ supabase, proveedorInicial, onElegir })
  const nombrePorId = new Map(proveedores.map((p) => [p.id, p.razon_social]))

  return (
    <BottomSheet title="Copiar desde una factura" onClose={onClose} dialogo={{ onEscape: onClose }}>
      <div className="flex flex-col gap-stack-md">
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
            type="search"
            inputMode="search"
            enterKeyHint="search"
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
            className="overflow-hidden rounded-lg border border-line bg-surface"
          >
            {s.cargando && s.facturas.length === 0 && (
              <li className="px-4 py-4 font-sans text-body-md text-ink-soft">Buscando…</li>
            )}
            {!s.cargando && s.facturas.length === 0 && (
              <li className="px-4 py-4 font-sans text-body-md text-ink-soft">No hay facturas con ese filtro.</li>
            )}
            {s.facturas.map((f, i) => (
              <li
                key={f.id}
                id={s.opcionId(f.id)}
                role="option"
                aria-selected={i === s.activa}
                onClick={() => s.elegir(f.id)}
                className={`flex min-h-14 cursor-pointer flex-col justify-center gap-0.5 border-b border-line px-4 py-2.5 font-sans last:border-0 active:bg-accent-light ${
                  f.anulada ? 'text-ink-soft' : ''
                }`}
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

        <p className="font-sans text-label-md text-ink-soft">Últimas 20 facturas cargadas. Tocá una para copiarla.</p>
      </div>
    </BottomSheet>
  )
}
