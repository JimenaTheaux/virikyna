import { formatCurrency } from '@virikyna/shared'

// Cómo quedó leído un monto tipeado en un <input type="number">, en formato argentino. En esos
// campos el punto es siempre decimal: "632.250" se guarda como 632,25. Pasó en el Cierre Z del
// 20/10 (contado $632,25 en vez de $632.250); mostrando el monto leído el error se ve antes de
// confirmar. Va debajo del campo, en vivo; vacío o inválido no muestra nada.
export function MontoLeido({ valor }: { valor: string }) {
  const n = Number(valor)
  if (valor.trim() === '' || Number.isNaN(n)) return null
  return (
    <p aria-live="polite" className="font-sans text-body-md text-ink-soft">
      Se va a registrar: <strong className="tabular-nums text-ink">{formatCurrency(n)}</strong>
    </p>
  )
}
