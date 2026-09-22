import { useEffect, useState } from 'react'
import type { Cuenta } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { friendlyError } from '@virikyna/shared'
import { formatCurrency } from '@virikyna/shared'
import { inputClass } from '../../components/FormField'
import type { SaldoCliente, SaldoProveedor } from './types'

type MovimientoInicial = { monto: number; cuenta: { nombre: string } | null }

export function CargaInicialTab() {
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)

  const [yaCargado, setYaCargado] = useState<boolean | null>(null)
  const [movimientosIniciales, setMovimientosIniciales] = useState<MovimientoInicial[]>([])

  const [cuentas, setCuentas] = useState<Cuenta[]>([])
  const [proveedores, setProveedores] = useState<SaldoProveedor[]>([])
  const [clientes, setClientes] = useState<SaldoCliente[]>([])

  const [montosCuenta, setMontosCuenta] = useState<Record<string, string>>({})
  const [montosProveedor, setMontosProveedor] = useState<Record<string, string>>({})
  const [montosCliente, setMontosCliente] = useState<Record<string, string>>({})

  async function cargar() {
    setLoading(true)
    setError(null)

    const [yaCargadoRes, cuentasRes, proveedoresRes, clientesRes] = await Promise.all([
      supabase.from('movimientos_cuenta').select('id').eq('tipo', 'saldo_inicial').limit(1),
      supabase.from('cuentas').select('*').order('nombre'),
      supabase.from('proveedores').select('id, razon_social, saldo_inicial').order('razon_social'),
      supabase
        .from('clientes')
        .select('id, razon_social, nombre_fantasia, saldo_inicial')
        .order('razon_social', { ascending: true, nullsFirst: false }),
    ])

    if (yaCargadoRes.error || cuentasRes.error || proveedoresRes.error || clientesRes.error) {
      setError(
        friendlyError(yaCargadoRes.error || cuentasRes.error || proveedoresRes.error || clientesRes.error),
      )
      setLoading(false)
      return
    }

    const cargado = (yaCargadoRes.data ?? []).length > 0
    setYaCargado(cargado)
    setCuentas((cuentasRes.data ?? []) as Cuenta[])
    setProveedores((proveedoresRes.data ?? []) as SaldoProveedor[])
    setClientes((clientesRes.data ?? []) as SaldoCliente[])

    if (cargado) {
      const { data: movimientosData } = await supabase
        .from('movimientos_cuenta')
        .select('monto, cuenta:cuentas(nombre)')
        .eq('tipo', 'saldo_inicial')
      setMovimientosIniciales((movimientosData ?? []) as unknown as MovimientoInicial[])
    }

    setLoading(false)
  }

  useEffect(() => {
    cargar()
  }, [])

  async function handleSubmit() {
    setError(null)

    const saldosCuentas = cuentas
      .map((c) => ({ cuenta_id: c.id, monto: Number(montosCuenta[c.id] || 0) }))
      .filter((s) => s.monto !== 0)
    const saldosProveedores = proveedores
      .map((p) => ({ proveedor_id: p.id, monto: Number(montosProveedor[p.id] || 0) }))
      .filter((s) => s.monto !== 0)
    const saldosClientes = clientes
      .map((c) => ({ cliente_id: c.id, monto: Number(montosCliente[c.id] || 0) }))
      .filter((s) => s.monto !== 0)

    setSaving(true)
    const { error: rpcError } = await supabase.rpc('cargar_saldos_iniciales', {
      p_saldos_cuentas: saldosCuentas,
      p_saldos_proveedores: saldosProveedores,
      p_saldos_clientes: saldosClientes,
    })
    setSaving(false)

    if (rpcError) {
      setError(friendlyError(rpcError))
      return
    }
    cargar()
  }

  if (loading) return <p className="font-sans text-body-md text-ink-soft">Cargando...</p>

  if (yaCargado) {
    return (
      <div className="flex flex-col gap-stack-md">
        <p className="rounded bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">
          La carga inicial ya se realizó — es de uso único y no se puede repetir.
        </p>

        <div>
          <p className="font-sans text-label-bold text-ink-soft">Saldos iniciales por cuenta</p>
          <div className="mt-2 overflow-auto rounded-lg border border-line">
            <table className="w-full text-left font-sans text-body-md leading-5">
              <tbody>
                {movimientosIniciales.map((m, i) => (
                  <tr key={i} className="border-b border-line last:border-0">
                    <td className="px-3 py-2 text-ink">{m.cuenta?.nombre ?? '—'}</td>
                    <td className="px-3 py-2 text-right text-ink">{formatCurrency(m.monto)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>

        <div>
          <p className="font-sans text-label-bold text-ink-soft">Deuda inicial con proveedores</p>
          <div className="mt-2 overflow-auto rounded-lg border border-line">
            <table className="w-full text-left font-sans text-body-md leading-5">
              <tbody>
                {proveedores.filter((p) => p.saldo_inicial !== 0).length === 0 && (
                  <tr>
                    <td className="px-3 py-2 text-ink-soft">Sin deuda inicial cargada.</td>
                  </tr>
                )}
                {proveedores
                  .filter((p) => p.saldo_inicial !== 0)
                  .map((p) => (
                    <tr key={p.id} className="border-b border-line last:border-0">
                      <td className="px-3 py-2 text-ink">{p.razon_social}</td>
                      <td className="px-3 py-2 text-right text-ink">{formatCurrency(p.saldo_inicial)}</td>
                    </tr>
                  ))}
              </tbody>
            </table>
          </div>
        </div>

        <div>
          <p className="font-sans text-label-bold text-ink-soft">Saldo inicial de cuenta corriente de clientes</p>
          <div className="mt-2 overflow-auto rounded-lg border border-line">
            <table className="w-full text-left font-sans text-body-md leading-5">
              <tbody>
                {clientes.filter((c) => c.saldo_inicial !== 0).length === 0 && (
                  <tr>
                    <td className="px-3 py-2 text-ink-soft">Sin saldo inicial cargado.</td>
                  </tr>
                )}
                {clientes
                  .filter((c) => c.saldo_inicial !== 0)
                  .map((c) => (
                    <tr key={c.id} className="border-b border-line last:border-0">
                      <td className="px-3 py-2 text-ink">{c.razon_social ?? c.nombre_fantasia}</td>
                      <td className="px-3 py-2 text-right text-ink">{formatCurrency(c.saldo_inicial)}</td>
                    </tr>
                  ))}
              </tbody>
            </table>
          </div>
        </div>
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-stack-md">
      <p className="rounded bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">
        Se hace una sola vez, al arrancar el sistema. Dejá en 0 lo que no aplique.
      </p>

      {error && <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>}

      <div>
        <p className="font-sans text-label-bold text-ink-soft">Saldo inicial por cuenta</p>
        <div className="mt-2 grid grid-cols-3 gap-stack-md">
          {cuentas.map((cuenta) => (
            <label key={cuenta.id} className="flex flex-col gap-2">
              <span className="font-sans text-label-md text-ink-soft">{cuenta.nombre}</span>
              <input
                type="number"
                step="0.01"
                value={montosCuenta[cuenta.id] ?? ''}
                onChange={(e) => setMontosCuenta((prev) => ({ ...prev, [cuenta.id]: e.target.value }))}
                className={inputClass}
              />
            </label>
          ))}
        </div>
      </div>

      <div>
        <p className="font-sans text-label-bold text-ink-soft">Deuda inicial con proveedores</p>
        <div className="mt-2 max-h-[240px] overflow-auto rounded-lg border border-line">
          <table className="w-full text-left font-sans text-body-md leading-5">
            <tbody>
              {proveedores.length === 0 && (
                <tr>
                  <td className="px-3 py-2 text-ink-soft">No hay proveedores cargados todavía.</td>
                </tr>
              )}
              {proveedores.map((p) => (
                <tr key={p.id} className="border-b border-line last:border-0">
                  <td className="px-3 py-2 text-ink">{p.razon_social}</td>
                  <td className="px-3 py-2">
                    <input
                      type="number"
                      step="0.01"
                      value={montosProveedor[p.id] ?? ''}
                      onChange={(e) => setMontosProveedor((prev) => ({ ...prev, [p.id]: e.target.value }))}
                      className={`${inputClass} w-40`}
                    />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <div>
        <p className="font-sans text-label-bold text-ink-soft">Saldo inicial de cuenta corriente de clientes</p>
        <div className="mt-2 max-h-[240px] overflow-auto rounded-lg border border-line">
          <table className="w-full text-left font-sans text-body-md leading-5">
            <tbody>
              {clientes.length === 0 && (
                <tr>
                  <td className="px-3 py-2 text-ink-soft">No hay clientes cargados todavía.</td>
                </tr>
              )}
              {clientes.map((c) => (
                <tr key={c.id} className="border-b border-line last:border-0">
                  <td className="px-3 py-2 text-ink">{c.razon_social ?? c.nombre_fantasia}</td>
                  <td className="px-3 py-2">
                    <input
                      type="number"
                      step="0.01"
                      value={montosCliente[c.id] ?? ''}
                      onChange={(e) => setMontosCliente((prev) => ({ ...prev, [c.id]: e.target.value }))}
                      className={`${inputClass} w-40`}
                    />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <div className="flex justify-end">
        <button
          type="button"
          onClick={handleSubmit}
          disabled={saving}
          className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
        >
          {saving ? 'Guardando...' : 'Confirmar carga inicial'}
        </button>
      </div>
    </div>
  )
}
