import type { CierreCaja } from '../../types/database'
import { formatCurrency } from '../../lib/format'

// Sección "Devoluciones y cambios" del detalle de un cierre (X o Z) — la misma en Local y Gestión.
// docs/24: netos con signo por medio, aparte de las ventas (el efectivo ya está en el esperado).
// docs/74: línea informativa de saldos a favor (vale manual): no suma a la caja ni a los netos.

type CierreDevoluciones = Pick<
  CierreCaja,
  | 'cantidad_devoluciones'
  | 'total_devoluciones_efectivo'
  | 'total_devoluciones_transferencia'
  | 'total_devoluciones_qr'
  | 'total_devoluciones_tarjeta'
> &
  Partial<Pick<CierreCaja, 'cantidad_saldos_a_favor' | 'total_saldos_a_favor'>>

// Neto con signo: "+" el comercio cobró una diferencia, "−" devolvió plata al cliente.
function formatNeto(valor: number): string {
  return valor > 0 ? `+ ${formatCurrency(valor)}` : valor < 0 ? `− ${formatCurrency(Math.abs(valor))}` : formatCurrency(0)
}

function Fila({ label, valor, destacado }: { label: string; valor: string; destacado?: boolean }) {
  return (
    <div className="flex items-center justify-between border-b border-line py-2.5 last:border-0">
      <span className="font-sans text-body-md text-ink-soft">{label}</span>
      <span className={`font-sans ${destacado ? 'text-label-bold text-ink' : 'text-body-md text-ink'}`}>{valor}</span>
    </div>
  )
}

export function SeccionDevolucionesCierre({ cierre }: { cierre: CierreDevoluciones }) {
  // Cierres anteriores a docs/74 no traen estas columnas: 0.
  const cantAFavor = Number(cierre.cantidad_saldos_a_favor ?? 0)
  const totalAFavor = Number(cierre.total_saldos_a_favor ?? 0)
  if (cierre.cantidad_devoluciones <= 0 && cantAFavor <= 0) return null
  const neto =
    Number(cierre.total_devoluciones_efectivo) +
    Number(cierre.total_devoluciones_transferencia) +
    Number(cierre.total_devoluciones_qr) +
    Number(cierre.total_devoluciones_tarjeta)

  return (
    <>
      <p className="mt-stack-md font-sans text-label-bold text-ink-soft">
        Devoluciones y cambios ({cierre.cantidad_devoluciones}) — neto por medio, aparte de las ventas
      </p>
      <Fila label="Efectivo" valor={formatNeto(cierre.total_devoluciones_efectivo)} />
      <Fila label="Transferencia (Mercado Pago)" valor={formatNeto(cierre.total_devoluciones_transferencia)} />
      <Fila label="QR" valor={formatNeto(cierre.total_devoluciones_qr)} />
      <Fila label="Tarjeta (débito/crédito)" valor={formatNeto(cierre.total_devoluciones_tarjeta)} />
      <Fila label="Neto de devoluciones" valor={formatNeto(neto)} destacado />
      <p className="pt-1 font-sans text-label-md text-ink-soft">
        Negativo = se devolvió plata al cliente. El neto en efectivo ya está incluido en el efectivo esperado.
      </p>
      {cantAFavor > 0 && (
        <div className="mt-2 rounded bg-bg px-3 py-2">
          <div className="flex items-center justify-between gap-3">
            <span className="font-sans text-body-md text-ink">Saldos a favor (vale manual) · {cantAFavor}</span>
            <span className="font-sans text-label-bold text-ink">{formatCurrency(totalAFavor)}</span>
          </div>
          <p className="font-sans text-label-md text-ink-soft">Informativo: no suma ni resta a la caja.</p>
        </div>
      )}
    </>
  )
}
