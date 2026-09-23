import { useEffect, useState, type FormEvent } from 'react'
import { Pencil } from 'lucide-react'
import type { CuentaSaldo, MovimientoCuenta } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { friendlyError, nombresPorId } from '@virikyna/shared'
import { formatCurrency, formatFechaHora } from '@virikyna/shared'
import { TIPO_MOVIMIENTO_CUENTA_LABEL, esMovimientoManualEditable } from '../../lib/caja'
import { Field, ErrorText, inputClass, selectClass } from '../../components/FormField'
import { EditarMovimientoModal } from './EditarMovimientoModal'
import type { MovimientoCuentaConUsuario } from './types'

type TipoManual = 'ingreso_manual' | 'egreso'

export function MovimientosManualesTab() {
  const [cuentas, setCuentas] = useState<CuentaSaldo[]>([])
  const [historial, setHistorial] = useState<MovimientoCuentaConUsuario[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const [cuentaId, setCuentaId] = useState('')
  const [tipo, setTipo] = useState<TipoManual>('ingreso_manual')
  const [monto, setMonto] = useState('')
  const [descripcion, setDescripcion] = useState('')
  const [formError, setFormError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)

  const [origenId, setOrigenId] = useState('')
  const [destinoId, setDestinoId] = useState('')
  const [montoTransferencia, setMontoTransferencia] = useState('')
  const [descripcionTransferencia, setDescripcionTransferencia] = useState('')
  const [transferError, setTransferError] = useState<string | null>(null)
  const [transferSaving, setTransferSaving] = useState(false)
  const [transferResult, setTransferResult] = useState<{
    origen: string
    destino: string
    monto: number
  } | null>(null)

  const [editando, setEditando] = useState<MovimientoCuentaConUsuario | null>(null)

  async function cargar() {
    setLoading(true)
    setError(null)

    const [cuentasRes, historialRes] = await Promise.all([
      supabase.from('cuentas_saldo').select('*').order('nombre'),
      supabase.from('movimientos_cuenta').select('*').order('created_at', { ascending: false }).limit(50),
    ])

    if (cuentasRes.error || historialRes.error) {
      setError(friendlyError(cuentasRes.error || historialRes.error))
      setLoading(false)
      return
    }

    const cuentasData = (cuentasRes.data ?? []) as CuentaSaldo[]
    setCuentas(cuentasData)
    if (!cuentaId && cuentasData[0]) setCuentaId(cuentasData[0].id)
    if (!origenId && cuentasData[0]) setOrigenId(cuentasData[0].id)
    if (!destinoId && cuentasData[1]) setDestinoId(cuentasData[1].id)

    const historialSinUsuario = (historialRes.data ?? []) as unknown as MovimientoCuenta[]
    const nombrePorUsuario = await nombresPorId(
      supabase,
      historialSinUsuario.map((m) => m.usuario_id),
    )
    setHistorial(
      historialSinUsuario.map((m) => ({
        ...m,
        usuario: nombrePorUsuario.has(m.usuario_id) ? { nombre: nombrePorUsuario.get(m.usuario_id)! } : null,
      })),
    )
    setLoading(false)
  }

  useEffect(() => {
    cargar()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setFormError(null)

    const montoNum = Number(monto)
    if (!montoNum || montoNum <= 0) {
      setFormError('Ingresá un monto mayor a cero.')
      return
    }
    if (!descripcion.trim()) {
      setFormError('La descripción es obligatoria para un movimiento manual.')
      return
    }
    if (!cuentaId) {
      setFormError('Elegí una cuenta.')
      return
    }

    setSaving(true)
    const { error: rpcError } = await supabase.rpc('registrar_movimiento_caja_general', {
      p_cuenta_id: cuentaId,
      p_monto: montoNum,
      p_tipo: tipo,
      p_descripcion: descripcion.trim(),
    })
    setSaving(false)

    if (rpcError) {
      setFormError(friendlyError(rpcError))
      return
    }
    setMonto('')
    setDescripcion('')
    cargar()
  }

  async function handleTransferir(e: FormEvent) {
    e.preventDefault()
    setTransferError(null)
    setTransferResult(null)

    const montoNum = Number(montoTransferencia)
    if (!montoNum || montoNum <= 0) {
      setTransferError('Ingresá un monto mayor a cero.')
      return
    }
    if (!descripcionTransferencia.trim()) {
      setTransferError('La descripción es obligatoria para una transferencia.')
      return
    }
    if (!origenId || !destinoId) {
      setTransferError('Elegí cuenta de origen y de destino.')
      return
    }
    if (origenId === destinoId) {
      setTransferError('La cuenta de origen y destino no pueden ser la misma.')
      return
    }

    setTransferSaving(true)
    const { error: rpcError } = await supabase.rpc('transferir_entre_cuentas', {
      p_cuenta_origen_id: origenId,
      p_cuenta_destino_id: destinoId,
      p_monto: montoNum,
      p_descripcion: descripcionTransferencia.trim(),
    })
    setTransferSaving(false)

    if (rpcError) {
      setTransferError(friendlyError(rpcError))
      return
    }

    setTransferResult({
      origen: cuentas.find((c) => c.id === origenId)?.nombre ?? '—',
      destino: cuentas.find((c) => c.id === destinoId)?.nombre ?? '—',
      monto: montoNum,
    })
    setMontoTransferencia('')
    setDescripcionTransferencia('')
    cargar()
  }

  return (
    <div className="flex flex-col gap-stack-md">
      <div className="flex flex-wrap items-center gap-x-4 gap-y-1 rounded border border-line bg-bg px-4 py-2">
        {cuentas.map((cuenta) => (
          <p key={cuenta.id} className="font-sans text-label-md text-ink-soft">
            {cuenta.nombre}: <span className="font-sans text-label-bold text-ink">{formatCurrency(cuenta.saldo_actual)}</span>
          </p>
        ))}
      </div>

      {error && <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>}

      <form onSubmit={handleSubmit} className="rounded-lg border border-line p-4">
        <p className="font-sans text-label-bold text-ink-soft">Registrar movimiento manual</p>
        <div className="mt-3 grid grid-cols-4 gap-stack-md">
          <Field label="Cuenta">
            <select value={cuentaId} onChange={(e) => setCuentaId(e.target.value)} className={selectClass}>
              {cuentas.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.nombre}
                </option>
              ))}
            </select>
          </Field>
          <Field label="Tipo">
            <select value={tipo} onChange={(e) => setTipo(e.target.value as TipoManual)} className={selectClass}>
              <option value="ingreso_manual">Ingreso</option>
              <option value="egreso">Egreso</option>
            </select>
          </Field>
          <Field label="Monto">
            <input type="number" step="0.01" value={monto} onChange={(e) => setMonto(e.target.value)} className={inputClass} />
          </Field>
          <Field label="Descripción">
            <input value={descripcion} onChange={(e) => setDescripcion(e.target.value)} className={inputClass} />
          </Field>
        </div>

        {formError && (
          <div className="mt-3">
            <ErrorText>{formError}</ErrorText>
          </div>
        )}

        <div className="mt-3 flex justify-end">
          <button
            type="submit"
            disabled={saving}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
          >
            {saving ? 'Guardando...' : 'Registrar movimiento'}
          </button>
        </div>
      </form>

      <form onSubmit={handleTransferir} className="rounded-lg border border-line p-4">
        <p className="font-sans text-label-bold text-ink-soft">Transferir entre cuentas</p>
        <div className="mt-3 grid grid-cols-4 gap-stack-md">
          <Field label="Cuenta origen">
            <select value={origenId} onChange={(e) => setOrigenId(e.target.value)} className={selectClass}>
              {cuentas.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.nombre}
                </option>
              ))}
            </select>
          </Field>
          <Field label="Cuenta destino">
            <select value={destinoId} onChange={(e) => setDestinoId(e.target.value)} className={selectClass}>
              {cuentas.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.nombre}
                </option>
              ))}
            </select>
          </Field>
          <Field label="Monto">
            <input
              type="number"
              step="0.01"
              value={montoTransferencia}
              onChange={(e) => setMontoTransferencia(e.target.value)}
              className={inputClass}
            />
          </Field>
          <Field label="Descripción">
            <input
              value={descripcionTransferencia}
              onChange={(e) => setDescripcionTransferencia(e.target.value)}
              className={inputClass}
            />
          </Field>
        </div>

        {transferError && (
          <div className="mt-3">
            <ErrorText>{transferError}</ErrorText>
          </div>
        )}

        {transferResult && (
          <div className="mt-3 rounded border border-line bg-bg px-4 py-3">
            <p className="font-sans text-label-bold text-ink-soft">Transferencia registrada — 2 movimientos:</p>
            <ul className="mt-1 font-sans text-body-md">
              <li className="text-error">
                Egreso en {transferResult.origen}: {formatCurrency(-transferResult.monto)}
              </li>
              <li className="text-success">
                Ingreso en {transferResult.destino}: {formatCurrency(transferResult.monto)}
              </li>
            </ul>
          </div>
        )}

        <div className="mt-3 flex justify-end">
          <button
            type="submit"
            disabled={transferSaving}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
          >
            {transferSaving ? 'Transfiriendo...' : 'Transferir'}
          </button>
        </div>
      </form>

      <div>
        <p className="font-sans text-label-bold text-ink-soft">Últimos movimientos</p>
        <div className="mt-2 max-h-[400px] overflow-auto rounded-lg border border-line">
          <table className="w-full text-left font-sans text-body-md leading-5">
            <thead>
              <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
                <th className="min-w-[120px] whitespace-nowrap px-3 py-2">Fecha</th>
                <th className="whitespace-nowrap px-3 py-2">Cuenta</th>
                <th className="whitespace-nowrap px-3 py-2">Tipo</th>
                <th className="whitespace-nowrap px-3 py-2">Descripción</th>
                <th className="whitespace-nowrap px-3 py-2">Usuario</th>
                <th className="whitespace-nowrap px-3 py-2 text-right">Monto</th>
                <th className="whitespace-nowrap px-3 py-2"></th>
              </tr>
            </thead>
            <tbody>
              {loading && (
                <tr>
                  <td className="px-4 py-4 text-ink-soft" colSpan={7}>
                    Cargando...
                  </td>
                </tr>
              )}
              {!loading && historial.length === 0 && (
                <tr>
                  <td className="px-4 py-4 text-ink-soft" colSpan={7}>
                    Todavía no hay movimientos de cuenta.
                  </td>
                </tr>
              )}
              {historial.map((mov) => (
                <tr key={mov.id} className="border-b border-line last:border-0">
                  <td className="whitespace-nowrap px-3 py-1.5 text-ink-soft">{formatFechaHora(mov.created_at)}</td>
                  <td className="px-3 py-1.5 text-ink">
                    {cuentas.find((c) => c.id === mov.cuenta_id)?.nombre ?? '—'}
                  </td>
                  <td className="px-3 py-1.5 text-ink-soft">{TIPO_MOVIMIENTO_CUENTA_LABEL[mov.tipo]}</td>
                  <td className="px-3 py-1.5 text-ink-soft">{mov.descripcion ?? '—'}</td>
                  <td className="px-3 py-1.5 text-ink-soft">{mov.usuario?.nombre ?? '—'}</td>
                  <td className={`px-3 py-1.5 text-right ${mov.monto < 0 ? 'text-error' : 'text-success'}`}>
                    {formatCurrency(mov.monto)}
                  </td>
                  <td className="px-3 py-1.5 text-right">
                    {esMovimientoManualEditable(mov.tipo) && (
                      <button
                        type="button"
                        onClick={() => setEditando(mov)}
                        title="Editar"
                        aria-label="Editar"
                        className="rounded px-3 py-1.5 text-accent-dark hover:bg-accent-light"
                      >
                        <Pencil size={18} strokeWidth={1.5} />
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {editando && (
        <EditarMovimientoModal
          movimiento={editando}
          onClose={() => setEditando(null)}
          onSaved={() => {
            setEditando(null)
            cargar()
          }}
        />
      )}
    </div>
  )
}
