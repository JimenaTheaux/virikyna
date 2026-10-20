import { formatCurrency } from '../../lib/format'

type Props = {
  checked: boolean
  onChange: (llevaIva: boolean) => void
  // Cajero: lo ve pero no lo cambia (el servidor también lo rechaza, docs/47). El porqué lo dice
  // la nota de márgenes de cada formulario.
  disabled?: boolean
  // El producto sigue con precio manual: el switch no cambia el precio hasta que tenga costo.
  conPrecioManual?: boolean
  // Vista previa cuando el switch quedó distinto de lo guardado: precio de venta antes → después.
  cambioPrecio?: { antes: number; despues: number } | null
  // 'touch' (Inventario): fila completa de 48px de alto.
  size?: 'compact' | 'touch'
}

// "Lleva IVA" del producto (docs/47): 21 % o sin IVA en productos.iva_porcentaje. Es un checkbox
// nativo con role="switch": el teclado (espacio) funciona solo y el `change` llega al
// onChangeCapture del formulario, que marca "hay cambios" sin código extra.
export function InterruptorLlevaIva({ checked, onChange, disabled = false, conPrecioManual = false, cambioPrecio, size = 'compact' }: Props) {
  const touch = size === 'touch'
  return (
    <div className="flex flex-col gap-1">
      <label
        className={`flex items-center justify-between gap-3 ${touch ? 'min-h-12' : ''} ${
          disabled ? 'cursor-not-allowed opacity-60' : 'cursor-pointer'
        }`}
      >
        <span className={`font-sans text-ink ${touch ? 'text-body-md' : 'text-label-md'}`}>Lleva IVA</span>
        <span className="relative inline-flex items-center">
          <input
            type="checkbox"
            role="switch"
            checked={checked}
            disabled={disabled}
            onChange={(e) => onChange(e.target.checked)}
            className="peer sr-only"
          />
          <span
            aria-hidden="true"
            className={`block rounded-full bg-line transition peer-checked:bg-accent peer-focus-visible:outline peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-accent-dark ${
              touch ? 'h-7 w-12' : 'h-5 w-9'
            }`}
          />
          <span
            aria-hidden="true"
            className={`absolute left-0.5 rounded-full bg-surface shadow-sm transition ${
              touch ? 'h-6 w-6 peer-checked:translate-x-5' : 'h-4 w-4 peer-checked:translate-x-4'
            }`}
          />
        </span>
      </label>
      {conPrecioManual ? (
        <p role="status" className="font-sans text-label-md text-ink-soft">
          Tiene precio manual. El IVA se aplicará cuando tenga costo cargado.
        </p>
      ) : (
        cambioPrecio &&
        cambioPrecio.antes !== cambioPrecio.despues && (
          <p role="status" className="font-sans text-label-md text-ink-soft">
            Precio de venta: {formatCurrency(cambioPrecio.antes)} → <span className="font-semibold text-ink">{formatCurrency(cambioPrecio.despues)}</span>
          </p>
        )
      )}
    </div>
  )
}
