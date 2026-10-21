import { useEffect, useState } from 'react'
import { Eye } from 'lucide-react'
import { supabase } from '../../lib/supabaseClient'
import { descripcionSinCategoria, friendlyError, mensajeErrorGuardado, nombresPorId, proveedoresPorPago } from '@virikyna/shared'
import { formatCurrency, formatHora, fechaHoyISO, rangoTimestampsAR } from '@virikyna/shared'
import { CATEGORIA_EGRESO_LABEL, FORMA_PAGO_EGRESO_LABEL, diferenciaLabel } from '../../lib/caja'
import { Fila, FilaMensaje, FilaTotal, TablaHead, TablaListado, Td, Th } from '../../components/TablaListado'
import { CierreDetalleModal } from './CierreDetalleModal'
import { RegistrarEgresoModal } from './RegistrarEgresoModal'
import { RegistrarRetiroModal } from './RegistrarRetiroModal'
import { ConfirmarCierreZModal } from './ConfirmarCierreZModal'
import type { AperturaCaja, CierreCaja, Egreso, RetiroCaja } from '@virikyna/shared'
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
    const rangoHoy = rangoTimestampsAR(hoy, hoy)

    const [cierresRes, egresosRes, retirosRes] = await Promise.all([
      supabase.from('cierres_caja').select('*').eq('turno_fecha', hoy).order('created_at', { ascending: false }),
      supabase
        .from('egresos')
        .select('*')
        .eq('origen', 'turno')
        .gte('created_at', rangoHoy.desde)
        .lte('created_at', rangoHoy.hasta)
        .order('created_at', { ascending: false }),
      supabase.from('retiros_caja').select('*').eq('fecha', hoy).order('created_at', { ascending: false }),
    ])

    const cierresSinUsuario = (cierresRes.data ?? []) as unknown as CierreCaja[]
    const egresosSinUsuario = (egresosRes.data ?? []) as unknown as Egreso[]
    const retirosSinNombres = (retirosRes.data ?? []) as unknown as RetiroCaja[]

    const aperturaIds = Array.from(
      new Set(cierresSinUsuario.map((c) => c.apertura_id).filter((id): id is string => Boolean(id))),
    )
    const aperturasRes =
      aperturaIds.length > 0
        ? await supabase.from('aperturas_caja').select('*').in('id', aperturaIds)
        : { data: [] as AperturaCaja[], error: null }
    const aperturaPorId = new Map(
      ((aperturasRes.data ?? []) as unknown as AperturaCaja[]).map((a) => [a.id, a]),
    )

    const proveedorPorPago = await proveedoresPorPago(
      supabase,
      egresosSinUsuario.map((e) => e.pago_proveedor_id),
    )

    const nombrePorUsuario = await nombresPorId(supabase, [
      ...cierresSinUsuario.flatMap((c) => [c.usuario_id, c.validado_por]),
      ...egresosSinUsuario.map((e) => e.usuario_id),
      ...retirosSinNombres.flatMap((r) => [r.cajero_id, r.admin_receptor_id]),
      ...Array.from(aperturaPorId.values()).map((a) => a.usuario_id),
    ])

    if (cierresRes.error) {
      setError(friendlyError(cierresRes.error))
    } else {
      setCierres(
        cierresSinUsuario.map((c) => {
          const apertura = c.apertura_id ? aperturaPorId.get(c.apertura_id) ?? null : null
          return {
            ...c,
            usuario: nombrePorUsuario.has(c.usuario_id) ? { nombre: nombrePorUsuario.get(c.usuario_id)! } : null,
            validador:
              c.validado_por && nombrePorUsuario.has(c.validado_por)
                ? { nombre: nombrePorUsuario.get(c.validado_por)! }
                : null,
            apertura: apertura
              ? { ...apertura, usuarioNombre: nombrePorUsuario.get(apertura.usuario_id) ?? null }
              : null,
          }
        }),
      )
    }
    if (!egresosRes.error) {
      setEgresos(
        egresosSinUsuario.map((e) => ({
          ...e,
          usuario: nombrePorUsuario.has(e.usuario_id) ? { nombre: nombrePorUsuario.get(e.usuario_id)! } : null,
          proveedorNombre: e.pago_proveedor_id ? proveedorPorPago.get(e.pago_proveedor_id) ?? null : null,
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
    <div className="flex flex-col gap-3">
      <section className="rounded-lg bg-surface p-card-sm shadow-sm">
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
          <p className="mt-3 rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>
        )}
      </section>

      {cierreZ && (
        <section className="flex items-center gap-6 rounded-lg bg-surface px-card-sm py-3 shadow-sm">
          <div className="flex items-baseline gap-3">
            <p className="font-sans text-label-bold text-ink-soft">Cierre Z de hoy</p>
            <p className="font-sans text-body-lg font-bold text-accent-darker">
              {cierreZ.estado_validacion === 'validado' ? 'Validado' : 'Pendiente de validación'}
            </p>
          </div>
          <div className="flex items-baseline gap-3">
            <p className="font-sans text-label-md text-ink-soft">Diferencia</p>
            <p className={`font-sans text-body-lg font-bold ${diferenciaLabel(cierreZ.diferencia).className}`}>
              {diferenciaLabel(cierreZ.diferencia).texto}
            </p>
          </div>
          <button
            type="button"
            onClick={() => setVerDetalle(cierreZ)}
            className="ml-auto rounded px-4 py-2 font-sans text-label-bold text-accent-dark hover:bg-accent-light"
          >
            Ver detalle
          </button>
        </section>
      )}

      <section className="rounded-lg bg-surface p-card-sm shadow-sm">
        <h2 className="mb-2 font-sans text-label-bold text-ink-soft">Egresos de turno de hoy</h2>
        <TablaListado>
          <TablaHead>
            <Th>Hora</Th>
            <Th>Categoría</Th>
            <Th align="right">Monto</Th>
            <Th>Forma de pago</Th>
            <Th>Proveedor</Th>
            <Th>Usuario</Th>
            <Th>Descripción</Th>
          </TablaHead>
          <tbody>
            {loading && <FilaMensaje colSpan={7}>Cargando...</FilaMensaje>}
            {!loading && egresos.length === 0 && <FilaMensaje colSpan={7}>Sin egresos registrados hoy.</FilaMensaje>}
            {egresos.map((egreso) => (
              <Fila key={egreso.id}>
                <Td className="whitespace-nowrap text-ink-soft">{formatHora(egreso.created_at)}</Td>
                <Td className="whitespace-nowrap text-ink">{CATEGORIA_EGRESO_LABEL[egreso.categoria]}</Td>
                <Td align="right" className="font-semibold text-error">
                  {formatCurrency(-egreso.monto)}
                </Td>
                <Td>{FORMA_PAGO_EGRESO_LABEL[egreso.forma_pago]}</Td>
                <Td className="uppercase text-ink-soft">{egreso.proveedorNombre ?? '—'}</Td>
                <Td>{egreso.usuario?.nombre ?? '—'}</Td>
                <Td>{descripcionSinCategoria(egreso.descripcion, CATEGORIA_EGRESO_LABEL[egreso.categoria]) ?? '—'}</Td>
              </Fila>
            ))}
          </tbody>
          {egresos.length > 0 && (
            <FilaTotal label="Total egresos" labelColSpan={2} restoColSpan={4} montoClassName="text-error">
              {formatCurrency(-totalEgresosHoy)}
            </FilaTotal>
          )}
        </TablaListado>
      </section>

      <section className="rounded-lg bg-surface p-card-sm shadow-sm">
        <h2 className="mb-2 font-sans text-label-bold text-ink-soft">Retiros de caja de hoy</h2>
        <TablaListado>
          <TablaHead>
            <Th>Hora</Th>
            <Th>Cajero</Th>
            <Th>Admin que recibe</Th>
            <Th align="right">Monto</Th>
          </TablaHead>
          <tbody>
            {loading && <FilaMensaje colSpan={4}>Cargando...</FilaMensaje>}
            {!loading && retiros.length === 0 && <FilaMensaje colSpan={4}>Sin retiros registrados hoy.</FilaMensaje>}
            {retiros.map((retiro) => (
              <Fila key={retiro.id}>
                <Td className="whitespace-nowrap text-ink-soft">{formatHora(retiro.created_at)}</Td>
                <Td>{retiro.cajero?.nombre ?? '—'}</Td>
                <Td>{retiro.admin?.nombre ?? '—'}</Td>
                <Td align="right" className="font-semibold text-error">
                  {formatCurrency(-retiro.monto)}
                </Td>
              </Fila>
            ))}
          </tbody>
          {retiros.length > 0 && (
            <FilaTotal label="Total retiros" labelColSpan={3} montoClassName="text-error">
              {formatCurrency(-totalRetirosHoy)}
            </FilaTotal>
          )}
        </TablaListado>
      </section>

      <section className="rounded-lg bg-surface p-card-sm shadow-sm">
        <h2 className="mb-2 font-sans text-label-bold text-ink-soft">Cierres X de hoy</h2>
        <TablaListado>
          <TablaHead>
            <Th>Hora</Th>
            <Th>Usuario</Th>
            <Th align="right">Efectivo esperado</Th>
            <Th />
          </TablaHead>
          <tbody>
            {loading && <FilaMensaje colSpan={4}>Cargando...</FilaMensaje>}
            {!loading && cierresX.length === 0 && (
              <FilaMensaje colSpan={4}>Todavía no se hizo ningún Cierre X hoy.</FilaMensaje>
            )}
            {cierresX.map((cierre) => (
              <Fila key={cierre.id}>
                <Td className="whitespace-nowrap text-ink-soft">{formatHora(cierre.created_at)}</Td>
                <Td>{cierre.usuario?.nombre ?? '—'}</Td>
                <Td align="right" className="font-semibold text-ink">
                  {formatCurrency(cierre.efectivo_esperado)}
                </Td>
                <Td align="right">
                  <button
                    type="button"
                    onClick={() => setVerDetalle(cierre)}
                    title="Ver detalle"
                    aria-label="Ver detalle"
                    className="-my-1 rounded p-1 align-middle text-accent-dark hover:bg-accent-light"
                  >
                    <Eye size={18} strokeWidth={1.5} />
                  </button>
                </Td>
              </Fila>
            ))}
          </tbody>
        </TablaListado>
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
