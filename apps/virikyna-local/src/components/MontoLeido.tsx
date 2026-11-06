import { formatCurrency } from '@virikyna/shared'

// Cómo quedó leído un monto, en formato argentino, debajo del campo y en vivo (Cierre Z y Abrir
// caja). Nació por el Cierre Z del 20/10: un <input type="number"> leyó "632.250" como 632,25.
// Desde MontoInput "632.250" ya es 632.250 (lib/parseMonto.ts), pero en los dos campos donde un
// error de tipeo descuadra la caja se sigue mostrando lo que se va a registrar antes de confirmar.
// Vacío o inválido no muestra nada.
export function MontoLeido({ valor }: { valor: string }) {
  const n = Number(valor)
  if (valor.trim() === '' || Number.isNaN(n)) return null
  return (
    <p aria-live="polite" className="font-sans text-body-md text-ink-soft">
      Se va a registrar: <strong className="tabular-nums text-ink">{formatCurrency(n)}</strong>
    </p>
  )
}
