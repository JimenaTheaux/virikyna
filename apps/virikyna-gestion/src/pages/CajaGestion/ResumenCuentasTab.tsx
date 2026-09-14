import { useEffect, useState } from 'react'
import type { CuentaSaldo } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { formatCurrency, friendlyError } from '@virikyna/shared'
import { IconVerDetalle } from '../../components/icons'
import { PendientePagoModal } from './PendientePagoModal'
import { PendienteCobroModal } from './PendienteCobroModal'
import { ChequesEmitidosModal } from './ChequesEmitidosModal'

export function ResumenCuentasTab() {
  const [cuentas, setCuentas] = useState<CuentaSaldo[]>([])
  const [pendientePago, setPendientePago] = useState(0)
  const [pendienteCobro, setPendienteCobro] = useState(0)
  const [chequesEmitidos, setChequesEmitidos] = useState(0)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [modalPago, setModalPago] = useState(false)
  const [modalCobro, setModalCobro] = useState(false)
  const [modalCheques, setModalCheques] = useState(false)

  async function cargar() {
    setLoading(true)
    setError(null)

    const [cuentasRes, proveedoresRes, clientesRes, chequesRes] = await Promise.all([
      supabase.from('cuentas_saldo').select('*').order('nombre'),
      supabase.from('proveedores_saldo').select('saldo_actual').gt('saldo_actual', 0),
      supabase.from('clientes_saldo').select('saldo_actual').gt('saldo_actual', 0),
      supabase.from('pagos_proveedor').select('monto').in('forma_pago', ['cheque', 'echeq']),
    ])

    if (cuentasRes.error || proveedoresRes.error || clientesRes.error || chequesRes.error) {
      setError(friendlyError(cuentasRes.error || proveedoresRes.error || clientesRes.error || chequesRes.error))
      setLoading(false)
      return
    }

    setCuentas((cuentasRes.data ?? []) as CuentaSaldo[])
    setPendientePago(
      ((proveedoresRes.data ?? []) as { saldo_actual: number }[]).reduce((acc, p) => acc + p.saldo_actual, 0),
    )
    setPendienteCobro(
      ((clientesRes.data ?? []) as { saldo_actual: number }[]).reduce((acc, c) => acc + c.saldo_actual, 0),
    )
    setChequesEmitidos(((chequesRes.data ?? []) as { monto: number }[]).reduce((acc, p) => acc + p.monto, 0))
    setLoading(false)
  }

  useEffect(() => {
    cargar()
  }, [])

  return (
    <div className="flex flex-col gap-stack-md">
      <p className="font-sans text-body-md text-ink-soft">Cuánta plata hay en cada cuenta, ahora mismo.</p>

      {error && <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>}

      <div className="grid grid-cols-3 gap-gutter-grid">
        {loading && <p className="col-span-3 font-sans text-body-md text-ink-soft">Cargando...</p>}
        {!loading && cuentas.length === 0 && !error && (
          <p className="col-span-3 font-sans text-body-md text-ink-soft">Todavía no hay cuentas cargadas.</p>
        )}
        {!loading &&
          cuentas.map((cuenta) => (
            <div key={cuenta.id} className="rounded-lg bg-surface p-card shadow-sm">
              <p className="font-sans text-label-bold uppercase text-ink-soft">{cuenta.nombre}</p>
              <p className="mt-2 font-display text-display-card text-accent-darker">
                {formatCurrency(cuenta.saldo_actual)}
              </p>
            </div>
          ))}
      </div>

      {!loading && (
        <div className="grid grid-cols-3 gap-gutter-grid">
          <div className="flex items-start justify-between rounded-lg bg-surface p-card shadow-sm">
            <div>
              <p className="font-sans text-label-bold uppercase text-ink-soft">Pendiente de pago</p>
              <p className="mt-2 font-display text-display-card text-error">{formatCurrency(pendientePago)}</p>
              <p className="mt-1 font-sans text-label-md text-ink-soft">Lo que se le debe a proveedores.</p>
            </div>
            <button
              type="button"
              onClick={() => setModalPago(true)}
              aria-label="Ver detalle de pendiente de pago"
              className="rounded p-2 text-ink-soft transition hover:bg-accent-light hover:text-accent-darker"
            >
              <IconVerDetalle className="h-6 w-6" />
            </button>
          </div>

          <div className="flex items-start justify-between rounded-lg bg-surface p-card shadow-sm">
            <div>
              <p className="font-sans text-label-bold uppercase text-ink-soft">Pendiente de cobro</p>
              <p className="mt-2 font-display text-display-card text-celeste">{formatCurrency(pendienteCobro)}</p>
              <p className="mt-1 font-sans text-label-md text-ink-soft">Lo pendiente en cuentas corrientes de clientes.</p>
            </div>
            <button
              type="button"
              onClick={() => setModalCobro(true)}
              aria-label="Ver detalle de pendiente de cobro"
              className="rounded p-2 text-ink-soft transition hover:bg-accent-light hover:text-accent-darker"
            >
              <IconVerDetalle className="h-6 w-6" />
            </button>
          </div>

          <div className="flex items-start justify-between rounded-lg bg-surface p-card shadow-sm">
            <div>
              <p className="font-sans text-label-bold uppercase text-ink-soft">Cheques emitidos</p>
              <p className="mt-2 font-display text-display-card text-accent-darker">{formatCurrency(chequesEmitidos)}</p>
              <p className="mt-1 font-sans text-label-md text-ink-soft">Cheques y e-cheques entregados a proveedores.</p>
            </div>
            <button
              type="button"
              onClick={() => setModalCheques(true)}
              aria-label="Ver detalle de cheques emitidos"
              className="rounded p-2 text-ink-soft transition hover:bg-accent-light hover:text-accent-darker"
            >
              <IconVerDetalle className="h-6 w-6" />
            </button>
          </div>
        </div>
      )}

      {modalPago && (
        <PendientePagoModal
          onClose={() => setModalPago(false)}
          onChanged={cargar}
        />
      )}

      {modalCobro && (
        <PendienteCobroModal
          onClose={() => setModalCobro(false)}
          onChanged={cargar}
        />
      )}

      {modalCheques && <ChequesEmitidosModal onClose={() => setModalCheques(false)} />}
    </div>
  )
}
