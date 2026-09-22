import { useEffect, useState } from 'react'
import { Eye } from 'lucide-react'
import { supabase } from '../../lib/supabaseClient'
import { friendlyError, mensajeErrorGuardado, nombresPorId } from '@virikyna/shared'
import { formatCurrency, formatFechaHora, fechaHoyISO } from '@virikyna/shared'
import { CATEGORIA_EGRESO_LABEL, diferenciaLabel } from '../../lib/caja'
import { CierreDetalleModal } from './CierreDetalleModal'
import { RegistrarEgresoModal } from './RegistrarEgresoModal'
import { RegistrarRetiroModal } from './RegistrarRetiroModal'
import { ConfirmarCierreZModal } from './ConfirmarCierreZModal'
import type { CierreCaja, Egreso, RetiroCaja } from '@virikyna/shared'
import type { CierreCajaConUsuario, EgresoConUsuario, RetiroConNombres } from './types'

export function CierreCajaPage() {
  const [cierres, setCierres] = useState<CierreCajaConUsuario[]>([])
  const [egresos, setEgresos] = useState<EgresoConUsuario[]>([])
  const [retiros, setRetiros] = useState<RetiroConNombres[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const [haciendoX, setHaciendoX] = useState(false)
  const [modalEgreso, setModalEgreso] = useState(false)
  const [modalRetiro, setModalRetiro] = useState(false)
  const [modalZ, setModalZ] = useState(false)
  const [verDetalle, setVerDetalle] = useState<CierreCajaConUsuario | null>(null)

  async function cargar() {
    setLoading(true)
    setError(null)
    const hoy = fechaHoyISO()

    const [cierresRes, egresosRes, retirosRes] = await Promise.all([
      supabase.from('cierres_caja').select('*').eq('turno_fecha', hoy).order('created_at', { ascending: false }),
      supabase
        .from('egresos')
        .select('*')
        .eq('origen', 'turno')
        .gte('created_at', `${hoy}T00:00:00`)
        .lte('created_at', `${hoy}T23:59:59`)
        .order('created_at', { ascending: false }),
      supabase.from('retiros_caja').select('*').eq('fecha', hoy).order('created_at', { ascending: false }),
    ])

    const cierresSinUsuario = (cierresRes.data ?? []) as unknown as CierreCaja[]
    const egresosSinUsuario = (egresosRes.data ?? []) as unknown as Egreso[]
    const retirosSinNombres = (retirosRes.data ?? []) as unknown as RetiroCaja[]

    const nombrePorUsuario = await nombresPorId(supabase, [
      ...cierresSinUsuario.flatMap((c) => [c.usuario_id, c.validado_por]),
      ...egresosSinUsuario.map((e) => e.usuario_id),
      ...retirosSinNombres.flatMap((r) => [r.cajero_id, r.admin_receptor_id]),
    ])

    if (cierresRes.error) {
      setError(friendlyError(cierresRes.error))
    } else {
      setCierres(
        cierresSinUsuario.map((c) => ({
          ...c,
          usuario: nombrePorUsuario.has(c.usuario_id) ? { nombre: nombrePorUsuario.get(c.usuario_id)! } : null,
          validador:
            c.validado_por && nombrePorUsuario.has(c.validado_por)
              ? { nombre: nombrePorUsuario.get(c.validado_por)! }
              : null,
        })),
      )
    }
    if (!egresosRes.error) {
      setEgresos(
        egresosSinUsuario.map((e) => ({
          ...e,
          usuario: nombrePorUsuario.has(e.usuario_id) ? { nombre: nombrePorUsuario.get(e.usuario_id)! } : null,
        })),
      )
    }
    if (!retirosRes.error) {
      setRetiros(
        retirosSinNombres.map((r) => ({
          ...r,
          cajero: nombrePorUsuario.has(r.cajero_id) ? { nombre: nombrePorUsuario.get(r.cajero_id)! } : null,
          admin: nombrePorUsuario.has(r.admin_receptor_id)
            ? { nombre: nombrePorUsuario.get(r.admin_receptor_id)! }
            : null,
        })),
      )
    }
    setLoading(false)
  }

  useEffect(() => {
    cargar()
  }, [])

  const cierresX = cierres.filter((c) => c.tipo === 'x')
  const cierreZ = cierres.find((c) => c.tipo === 'z') ?? null
  const totalEgresosHoy = egresos.reduce((acc, e) => acc + e.monto, 0)
  const totalRetirosHoy = retiros.reduce((acc, r) => acc + r.monto, 0)

  async function realizarCierreX() {
    if (haciendoX) return
    setHaciendoX(true)
    setError(null)
    const { data: cierreId, error: rpcError, status } = await supabase.rpc('cerrar_caja', {
      p_tipo: 'x',
      p_efectivo_contado: null,
    })
    setHaciendoX(false)
    if (rpcError || !cierreId) {
      setError(mensajeErrorGuardado(rpcError, status, 'generar el Cierre X', 'podés reintentar'))
      return
    }
    await cargar()
  }

  async function realizarCierreZ(efectivoContado: number) {
    const { error: rpcError, status } = await supabase.rpc('cerrar_caja', {
      p_tipo: 'z',
      p_efectivo_contado: efectivoContado,
    })
    if (rpcError) {
      throw new Error(mensajeErrorGuardado(rpcError, status, 'cerrar la caja', 'el monto contado sigue cargado'))
    }
    setModalZ(false)
    await cargar()
  }

  return (
    <div className="flex h-full flex-col gap-stack-md">
      <section className="rounded-lg bg-surface p-card shadow-sm">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="font-display text-headline-lg text-accent-darker">Cierre de Caja</h1>
            <p className="mt-1 font-sans text-body-md text-ink-soft">
              Cierre X para una foto del turno, Cierre Z para cerrar el día.
            </p>
          </div>
          <div className="flex gap-3">
            <button
              type="button"
              onClick={() => setModalEgreso(true)}
              className="rounded-lg border border-line px-4 py-3 font-sans text-label-bold text-ink-soft hover:border-accent"
            >
              + Registrar egreso
            </button>
            <button
              type="button"
              onClick={() => setModalRetiro(true)}
              className="rounded-lg border border-line px-4 py-3 font-sans text-label-bold text-ink-soft hover:border-accent"
            >
              + Retiro
            </button>
            <button
              type="button"
              onClick={realizarCierreX}
              disabled={haciendoX}
              className="rounded-lg border border-accent px-4 py-3 font-sans text-label-bold text-accent-dark hover:bg-accent-light disabled:opacity-60"
            >
              {haciendoX ? 'Generando...' : 'Realizar Cierre X'}
            </button>
            {!cierreZ && (
              <button
                type="button"
                onClick={() => setModalZ(true)}
                className="rounded-lg bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark"
              >
                Realizar Cierre Z
              </button>
            )}
          </div>
        </div>

        {error && (
          <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>
        )}
      </section>

      {cierreZ && (
        <section className="rounded-lg bg-surface p-card shadow-sm">
          <div className="flex items-center justify-between">
            <div>
              <p className="font-sans text-label-bold text-ink-soft">Cierre Z de hoy</p>
              <p className="mt-1 font-display text-headline-md text-accent-darker">
                {cierreZ.estado_validacion === 'validado' ? 'Validado' : 'Pendiente de validación'}
              </p>
            </div>
            <div className="text-right">
              <p className="font-sans text-label-md text-ink-soft">Diferencia</p>
              <p className={`font-display text-headline-md ${diferenciaLabel(cierreZ.diferencia).className}`}>
                {diferenciaLabel(cierreZ.diferencia).texto}
              </p>
            </div>
            <button
              type="button"
              onClick={() => setVerDetalle(cierreZ)}
              className="rounded px-4 py-3 font-sans text-label-bold text-accent-dark hover:bg-accent-light"
            >
              Ver detalle
            </button>
          </div>
        </section>
      )}

      <section className="flex-1 overflow-auto rounded-lg bg-surface p-card shadow-sm">
        <p className="font-sans text-label-bold text-ink-soft">Egresos de turno de hoy</p>
        <div className="mt-3 overflow-auto rounded-lg border border-line">
          <table className="w-full text-left font-sans text-body-md leading-5">
            <thead>
              <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
                <th className="px-3 py-2">Hora</th>
                <th className="px-3 py-2">Categoría</th>
                <th className="px-3 py-2">Descripción</th>
                <th className="px-3 py-2">Usuario</th>
                <th className="px-3 py-2 text-right">Monto</th>
              </tr>
            </thead>
            <tbody>
              {!loading && egresos.length === 0 && (
                <tr>
                  <td className="px-4 py-4 text-ink-soft" colSpan={5}>
                    Sin egresos registrados hoy.
                  </td>
                </tr>
              )}
              {egresos.map((egreso) => (
                <tr key={egreso.id} className="border-b border-line last:border-0">
                  <td className="px-3 py-1.5 text-ink-soft">{formatFechaHora(egreso.created_at)}</td>
                  <td className="px-3 py-1.5 text-ink">{CATEGORIA_EGRESO_LABEL[egreso.categoria]}</td>
                  <td className="px-3 py-1.5 text-ink-soft">{egreso.descripcion ?? '—'}</td>
                  <td className="px-3 py-1.5 text-ink-soft">{egreso.usuario?.nombre ?? '—'}</td>
                  <td className="px-3 py-1.5 text-right text-ink">{formatCurrency(egreso.monto)}</td>
                </tr>
              ))}
            </tbody>
            {egresos.length > 0 && (
              <tfoot>
                <tr>
                  <td className="px-3 py-1.5 font-sans text-label-bold text-ink-soft" colSpan={4}>
                    Total egresos
                  </td>
                  <td className="px-3 py-1.5 text-right font-sans text-label-bold text-ink">
                    {formatCurrency(totalEgresosHoy)}
                  </td>
                </tr>
              </tfoot>
            )}
          </table>
        </div>

        <p className="mt-stack-md font-sans text-label-bold text-ink-soft">Retiros de caja de hoy</p>
        <div className="mt-3 overflow-auto rounded-lg border border-line">
          <table className="w-full text-left font-sans text-body-md leading-5">
            <thead>
              <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
                <th className="px-3 py-2">Hora</th>
                <th className="px-3 py-2">Cajero</th>
                <th className="px-3 py-2">Admin que recibe</th>
                <th className="px-3 py-2 text-right">Monto</th>
              </tr>
            </thead>
            <tbody>
              {!loading && retiros.length === 0 && (
                <tr>
                  <td className="px-4 py-4 text-ink-soft" colSpan={4}>
                    Sin retiros registrados hoy.
                  </td>
                </tr>
              )}
              {retiros.map((retiro) => (
                <tr key={retiro.id} className="border-b border-line last:border-0">
                  <td className="px-3 py-1.5 text-ink-soft">{formatFechaHora(retiro.created_at)}</td>
                  <td className="px-3 py-1.5 text-ink-soft">{retiro.cajero?.nombre ?? '—'}</td>
                  <td className="px-3 py-1.5 text-ink-soft">{retiro.admin?.nombre ?? '—'}</td>
                  <td className="px-3 py-1.5 text-right text-ink">{formatCurrency(retiro.monto)}</td>
                </tr>
              ))}
            </tbody>
            {retiros.length > 0 && (
              <tfoot>
                <tr>
                  <td className="px-3 py-1.5 font-sans text-label-bold text-ink-soft" colSpan={3}>
                    Total retiros
                  </td>
                  <td className="px-3 py-1.5 text-right font-sans text-label-bold text-ink">
                    {formatCurrency(totalRetirosHoy)}
                  </td>
                </tr>
              </tfoot>
            )}
          </table>
        </div>

        <p className="mt-stack-md font-sans text-label-bold text-ink-soft">Cierres X de hoy</p>
        <div className="mt-3 overflow-auto rounded-lg border border-line">
          <table className="w-full text-left font-sans text-body-md leading-5">
            <thead>
              <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
                <th className="px-3 py-2">Hora</th>
                <th className="px-3 py-2">Usuario</th>
                <th className="px-3 py-2 text-right">Efectivo esperado</th>
                <th className="px-3 py-2"></th>
              </tr>
            </thead>
            <tbody>
              {loading && (
                <tr>
                  <td className="px-4 py-4 text-ink-soft" colSpan={4}>
                    Cargando...
                  </td>
                </tr>
              )}
              {!loading && cierresX.length === 0 && (
                <tr>
                  <td className="px-4 py-4 text-ink-soft" colSpan={4}>
                    Todavía no se hizo ningún Cierre X hoy.
                  </td>
                </tr>
              )}
              {cierresX.map((cierre) => (
                <tr key={cierre.id} className="border-b border-line last:border-0">
                  <td className="px-3 py-1.5 text-ink-soft">{formatFechaHora(cierre.created_at)}</td>
                  <td className="px-3 py-1.5 text-ink-soft">{cierre.usuario?.nombre ?? '—'}</td>
                  <td className="px-3 py-1.5 text-right text-ink">{formatCurrency(cierre.efectivo_esperado)}</td>
                  <td className="px-3 py-1.5 text-right">
                    <button
                      type="button"
                      onClick={() => setVerDetalle(cierre)}
                      title="Ver detalle"
                      aria-label="Ver detalle"
                      className="rounded px-3 py-1.5 text-accent-dark hover:bg-accent-light"
                    >
                      <Eye size={18} strokeWidth={1.5} />
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      {modalEgreso && (
        <RegistrarEgresoModal
          onClose={() => setModalEgreso(false)}
          onSaved={() => {
            setModalEgreso(false)
            cargar()
          }}
        />
      )}

      {modalRetiro && (
        <RegistrarRetiroModal
          onClose={() => setModalRetiro(false)}
          onSaved={() => {
            setModalRetiro(false)
            cargar()
          }}
        />
      )}

      {modalZ && <ConfirmarCierreZModal onClose={() => setModalZ(false)} onConfirmar={realizarCierreZ} />}

      {verDetalle && <CierreDetalleModal cierre={verDetalle} onClose={() => setVerDetalle(null)} />}
    </div>
  )
}
