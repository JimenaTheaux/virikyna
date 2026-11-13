import { AJUSTE_REDONDEO_LABEL } from '../../lib/facturasCompra'
import { formatAjuste, formatCurrency } from '../../lib/format'
import { Field, inputClass } from './FormField'
import { MontoInput } from './MontoInput'

// Ajuste por redondeo de un pago a proveedor o un cobro a cliente (docs/71). Con signo, sin tope:
// lo que cancela la operación = plata + ajuste. "Ajustar la diferencia" lo completa con lo que falta
// (o sobra) para dejar justo el saldo elegido. No es plata: no entra a la caja.
export function CampoAjusteRedondeo({
  value,
  onChange,
  diferencia,
  plata,
  totalPorAjustar = false,
  onAjustar,
}: {
  value: string // string normalizado del MontoInput ('' = sin ajuste)
  onChange: (valor: string) => void
  diferencia: number // saldo a cancelar − plata (diferenciaParaAjuste); 0 = no hace falta
  plata: number // lo que se paga o cobra en plata (NaN si el campo está vacío)
  // Pago con varios medios: la plata es la suma de los medios. Si el total escrito no coincide con
  // esa suma, el botón sigue habilitado aunque el ajuste ya esté (onAjustar lleva el total a la suma).
  totalPorAjustar?: boolean
  onAjustar?: () => void // además de completar el ajuste
}) {
  const ajuste = Number(value)
  const hayAjuste = value !== '' && Number.isFinite(ajuste) && ajuste !== 0
  const plataNum = Number.isFinite(plata) ? plata : 0
  const ajustado = (diferencia === 0 ? !hayAjuste : hayAjuste && Math.round(ajuste * 100) === Math.round(diferencia * 100)) && !totalPorAjustar
  return (
    <Field
      label={AJUSTE_REDONDEO_LABEL}
      hint={
        hayAjuste
          ? `No es plata: cancela ${formatCurrency(Math.round((plataNum + ajuste) * 100) / 100)} (${formatCurrency(plataNum)} ${formatAjuste(ajuste)}).`
          : 'Para centavos que faltan (+) o sobran (−). Opcional.'
      }
    >
      <div className="flex items-stretch gap-2">
        <MontoInput
          value={value}
          onChange={onChange}
          negativo
          placeholder="Ej.: 0,02 o -0,02"
          aria-label={AJUSTE_REDONDEO_LABEL}
          className={`${inputClass} text-right tabular-nums`}
        />
        <button
          type="button"
          onClick={() => {
            onChange(diferencia === 0 ? '' : String(diferencia))
            onAjustar?.()
          }}
          disabled={ajustado}
          title={
            ajustado
              ? diferencia === 0
                ? 'La plata ya deja el saldo justo'
                : 'El ajuste ya deja el saldo justo'
              : diferencia === 0
                ? 'La plata ya deja el saldo justo: quita el ajuste'
                : `Completa el ajuste con ${formatAjuste(diferencia)} para dejar el saldo en $ 0`
          }
          className="shrink-0 rounded border border-accent px-3 font-sans text-label-bold text-accent-darker transition hover:bg-accent-light disabled:opacity-50"
        >
          Ajustar la diferencia
        </button>
      </div>
    </Field>
  )
}
