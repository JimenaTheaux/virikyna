import type { FormaPagoVenta } from '@virikyna/shared'

// Atajos exactos de docs/04_modulos_y_funciones.md (módulo 3).
const OPCIONES: { value: FormaPagoVenta; label: string; atajo?: string }[] = [
  { value: 'efectivo', label: 'Efectivo', atajo: 'E' },
  { value: 'transferencia', label: 'Transferencia', atajo: 'T' },
  { value: 'qr', label: 'QR', atajo: 'Q' },
  { value: 'tarjeta_debito', label: 'Débito', atajo: 'Z' },
  { value: 'tarjeta_credito', label: 'Crédito', atajo: 'C' },
  { value: 'cuenta_corriente', label: 'Cta. Cte.' },
]

type Props = {
  value: FormaPagoVenta | null
  disponibleCuentaCorriente: boolean
  onChange: (value: FormaPagoVenta) => void
}

export function FormaPagoSelector({ value, disponibleCuentaCorriente, onChange }: Props) {
  return (
    <div>
      <p className="font-sans text-label-bold text-ink-soft">Forma de pago</p>
      <div className="mt-2 grid grid-cols-2 gap-2">
        {OPCIONES.map((opt) => {
          const deshabilitado = opt.value === 'cuenta_corriente' && !disponibleCuentaCorriente
          const activo = value === opt.value
          return (
            <button
              key={opt.value}
              type="button"
              disabled={deshabilitado}
              onClick={() => onChange(opt.value)}
              title={deshabilitado ? 'Elegí un cliente para vender a cuenta corriente.' : undefined}
              className={[
                'flex items-center justify-between rounded-lg border px-4 py-3 font-sans text-label-bold transition',
                activo ? 'border-accent bg-accent text-white' : 'border-line bg-surface text-ink-soft hover:border-accent',
                deshabilitado ? 'cursor-not-allowed opacity-50' : '',
              ].join(' ')}
            >
              <span>{opt.label}</span>
              {opt.atajo && <span className={activo ? 'text-white/80' : 'text-ink-soft'}>({opt.atajo})</span>}
            </button>
          )
        })}
      </div>
    </div>
  )
}
