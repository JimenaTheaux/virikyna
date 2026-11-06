import { useEffect, useId, useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { VentaCuentaCorrienteSaldo } from '../../types/database'
import {
  esConflictoDeVersion,
  useEditarVentaInterna,
  useFinalizarVentaInterna,
  useItemsVenta,
  useReabrirVentaInterna,
  useVentaCuentaCorriente,
  type ItemVentaInternaRow,
} from '../../lib/cuentaCorrienteCliente'
import { calcularFila, descuentoInicial, totalesInternos, type ItemInterno } from '../../lib/ventaInterna'
import { ErrorRegistrarPago } from '../../lib/facturasCompra'
import { nombresPorId } from '../../lib/perfiles'
import { nombreItemVendido } from '../../lib/productoTexto'
import { formatCurrency, formatFechaHora } from '../../lib/format'
import { friendlyError, mensajeErrorGuardado } from '../../lib/supabaseErrors'
import { Modal } from './Modal'
import { ConfirmDialog } from './ConfirmDialog'
import { ErrorText, Field, inputClass } from './FormField'
import { EstadoBadge } from './EstadoBadge'

type Props = {
  supabase: SupabaseClient
  clienteId: string
  clienteNombre: string
  venta: VentaCuentaCorrienteSaldo
  onVerComprobante: () => void
  onClose: () => void
  onAviso: (mensaje: string) => void
}

const aItem = (it: ItemVentaInternaRow): ItemInterno => ({
  id: it.id,
  cantidad: Number(it.cantidad),
  precio_unitario: Number(it.precio_unitario),
  descuento_porcentaje: Number(it.descuento_porcentaje),
  costo_unitario: it.costo_unitario === null ? null : Number(it.costo_unitario),
  producto_con_iva: it.producto_con_iva,
  producto_costo_actual: it.producto?.costo === null || it.producto?.costo === undefined ? null : Number(it.producto.costo),
  producto_iva_actual: it.producto ? Number(it.producto.iva_porcentaje) : null,
})

const pct = (n: number) => `${n.toLocaleString('es-AR', { maximumFractionDigits: 2 })} %`
const textoDescuento = (n: number) => String(Math.round(n * 100) / 100)

// Revisión de un comprobante interno (dueña o empleado, docs/68 fase 3). Por producto: costo
// comparable (D10), precio registrado, % de descuento, precio final, margen y descuento máximo sin
// pérdida. Guardar deja el comprobante "A revisar"; Finalizar lo cierra sin cobro (se descuenta
// del sueldo fuera del sistema). Finalizado: solo lectura, con Reabrir (pide motivo).
// Sin <form>: Enter en un % no dispara nada (docs: Enter y formato de importes).
export function EditarVentaInternaModal({ supabase, clienteId, clienteNombre, venta: ventaInicial, onVerComprobante, onClose, onAviso }: Props) {
  const idBase = useId()
  const ventaQ = useVentaCuentaCorriente(supabase, ventaInicial.id)
  const venta = ventaQ.data ?? ventaInicial
  const itemsQ = useItemsVenta(supabase, venta.id)
  const filas = useMemo(() => itemsQ.data ?? [], [itemsQ.data])
  const items = useMemo(() => filas.map(aItem), [filas])

  const editar = useEditarVentaInterna(supabase)
  const finalizar = useFinalizarVentaInterna(supabase)
  const reabrir = useReabrirVentaInterna(supabase)
  const guardando = editar.isPending || finalizar.isPending || reabrir.isPending

  const editable = venta.estado_interno === 'pendiente' && venta.estado === 'sin_facturar'
  const globalVigente = Number(venta.descuento_porcentaje)

  // Descuentos como texto (lo que está escrito). Se reinician al cargar o cuando cambia la versión.
  const iniciales = useMemo(
    () => new Map(items.map((it) => [it.id, textoDescuento(descuentoInicial(it, globalVigente))])),
    [items, globalVigente],
  )
  const [descuentos, setDescuentos] = useState<Map<string, string>>(new Map())
  const [recarga, setRecarga] = useState(0) // tras un conflicto, vuelve a lo guardado aunque no haya cambiado nada
  useEffect(() => setDescuentos(new Map(iniciales)), [iniciales, venta.version, recarga])

  const valores = useMemo(() => new Map(items.map((it) => [it.id, Number(descuentos.get(it.id) ?? '0')])), [items, descuentos])
  const invalidos = items.filter((it) => {
    const t = (descuentos.get(it.id) ?? '').trim()
    const v = Number(t)
    return t === '' || !Number.isFinite(v) || v < 0 || v > 100
  })
  const dirty = editable && items.some((it) => (descuentos.get(it.id) ?? '') !== iniciales.get(it.id))
  // Con descuento global vigente hay que guardar igual: pasa a los ítems y el global queda en 0 (D6).
  const necesitaGuardar = dirty || globalVigente > 0
  const totales = totalesInternos(items, valores, Number(venta.recargo_porcentaje))
  const original = Number(venta.total_original ?? venta.total)
  const filasBajoCosto = items.filter((it) => calcularFila(it, valores.get(it.id) ?? 0).bajoCosto).length

  // Quién cargó la venta y quién la tocó después (perfiles_publico).
  const nombresQ = useQuery({
    queryKey: ['nombres', venta.usuario_id, venta.editada_por, venta.finalizada_por, venta.reabierta_por],
    queryFn: () => nombresPorId(supabase, [venta.usuario_id, venta.editada_por, venta.finalizada_por, venta.reabierta_por]),
  })
  const nombre = (id: string | null) => (id ? nombresQ.data?.get(id) ?? '—' : '—')

  const [error, setError] = useState<string | null>(null)
  const [conflicto, setConflicto] = useState(false)
  const [confirmFinalizar, setConfirmFinalizar] = useState(false)
  const [confirmCerrar, setConfirmCerrar] = useState(false)
  const [motivo, setMotivo] = useState<string | null>(null) // != null = pidiendo motivo para reabrir

  function manejarError(err: unknown, accion: string) {
    if (esConflictoDeVersion(err)) {
      setConflicto(true)
      setError(null)
      void Promise.all([ventaQ.refetch(), itemsQ.refetch()]).then(() => setRecarga((n) => n + 1))
      return
    }
    setError(
      err instanceof ErrorRegistrarPago ? mensajeErrorGuardado(err.causa, err.status, accion, 'no se guardó nada') : friendlyError(err as Error),
    )
  }

  async function guardar(): Promise<number | null> {
    const r = await editar.mutateAsync({
      clienteId,
      ventaId: venta.id,
      version: venta.version,
      descuentos: items.map((it) => ({ itemId: it.id, descuento: valores.get(it.id) ?? 0 })),
    })
    return r.version
  }

  async function onGuardar() {
    setError(null)
    setConflicto(false)
    try {
      await guardar()
      onAviso(`Comprobante N° ${venta.numero} guardado: ${formatCurrency(totales.total)}. Sigue a revisar.`)
      onClose()
    } catch (err) {
      manejarError(err, 'guardar el comprobante')
    }
  }

  async function onFinalizar() {
    setConfirmFinalizar(false)
    setError(null)
    setConflicto(false)
    try {
      const version = necesitaGuardar ? await guardar() : venta.version
      await finalizar.mutateAsync({ clienteId, ventaId: venta.id, version: version ?? venta.version })
      onAviso(`Comprobante N° ${venta.numero} finalizado: ${formatCurrency(totales.total)} (se descuenta del sueldo).`)
      onClose()
    } catch (err) {
      manejarError(err, 'finalizar el comprobante')
    }
  }

  async function onReabrir() {
    if (!motivo?.trim()) {
      setError('Escribí el motivo para reabrir.')
      return
    }
    setError(null)
    try {
      await reabrir.mutateAsync({ clienteId, ventaId: venta.id, motivo })
      setMotivo(null)
      onAviso(`Comprobante N° ${venta.numero} reabierto: vuelve a revisión.`)
    } catch (err) {
      manejarError(err, 'reabrir el comprobante')
    }
  }

  const pedirCierre = () => (dirty && !guardando ? setConfirmCerrar(true) : onClose())
  const badge =
    venta.estado_interno === 'finalizado'
      ? { label: 'Finalizado — se descuenta del sueldo', variant: 'neutral' as const }
      : { label: 'A revisar', variant: 'violet' as const }

  return (
    <Modal
      title={`Comprobante interno N° ${venta.numero}`}
      onClose={pedirCierre}
      cambiosSinGuardar={dirty}
      widthClassName="max-w-[1120px]"
      footer={
        <div className="flex flex-wrap items-center justify-end gap-3">
          <button
            type="button"
            onClick={onVerComprobante}
            className="mr-auto rounded px-4 py-3 font-sans text-label-bold text-accent-dark hover:bg-accent-light"
          >
            Ver comprobante X
          </button>
          <button type="button" onClick={pedirCierre} className="rounded px-4 py-3 font-sans text-label-bold text-ink-soft hover:bg-bg">
            {editable ? 'Cancelar' : 'Cerrar'}
          </button>
          {editable && (
            <>
              <button
                type="button"
                onClick={onGuardar}
                disabled={guardando || invalidos.length > 0 || itemsQ.isPending}
                className="rounded border border-accent px-4 py-3 font-sans text-label-bold text-accent-darker transition hover:bg-accent-light disabled:opacity-60"
              >
                {editar.isPending && !finalizar.isPending ? 'Guardando...' : 'Guardar'}
              </button>
              <button
                type="button"
                onClick={() => setConfirmFinalizar(true)}
                disabled={guardando || invalidos.length > 0 || itemsQ.isPending}
                className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
              >
                {finalizar.isPending ? 'Finalizando...' : 'Finalizar'}
              </button>
            </>
          )}
          {venta.estado_interno === 'finalizado' && venta.estado === 'sin_facturar' && motivo === null && (
            <button
              type="button"
              onClick={() => setMotivo('')}
              className="rounded border border-accent px-4 py-3 font-sans text-label-bold text-accent-darker transition hover:bg-accent-light"
            >
              Reabrir
            </button>
          )}
        </div>
      }
    >
      <div className="flex flex-col gap-stack-md">
        <div className="flex flex-wrap items-center justify-between gap-stack-sm">
          <dl className="flex flex-wrap gap-x-stack-md gap-y-1 font-sans text-body-md text-ink-soft">
            <div className="flex gap-1">
              <dt>Compró:</dt>
              <dd className="text-ink">{clienteNombre}</dd>
            </div>
            <div className="flex gap-1">
              <dt>Cargó:</dt>
              <dd className="text-ink">{nombre(venta.usuario_id)}</dd>
            </div>
            <div className="flex gap-1">
              <dt>Fecha:</dt>
              <dd className="text-ink">{formatFechaHora(venta.created_at)}</dd>
            </div>
          </dl>
          <EstadoBadge variant={badge.variant}>{badge.label}</EstadoBadge>
        </div>

        {conflicto && (
          <p role="alert" className="rounded bg-badge-amber-bg px-4 py-3 font-sans text-body-md text-badge-amber-text">
            Alguien cambió este comprobante mientras lo revisabas. Te mostramos la versión actual: revisá los descuentos y volvé a
            guardar.
          </p>
        )}

        {editable && globalVigente > 0 && (
          <p role="note" className="rounded border border-accent bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">
            La venta se registró con <span className="font-semibold">{pct(globalVigente)} de descuento global</span>. Lo precargamos en
            cada producto: modificalo como quieras. Al guardar, el descuento global queda en 0 y rige el % de cada producto.
          </p>
        )}

        {filasBajoCosto > 0 && (
          <p role="status" className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">
            {filasBajoCosto === 1 ? 'Un producto queda' : `${filasBajoCosto} productos quedan`} por debajo del costo.
          </p>
        )}

        <div className="overflow-x-auto rounded-xl shadow-sm">
          <table className="w-full table-fixed text-left font-sans text-body-md leading-5">
            <caption className="sr-only">Productos del comprobante, con costo, descuento y margen</caption>
            <colgroup>
              <col />
              <col className="w-[4rem]" />
              <col className="w-[8.5rem]" />
              <col className="w-[8.5rem]" />
              <col className="w-[7rem]" />
              <col className="w-[8.5rem]" />
              <col className="w-[9.5rem]" />
              <col className="w-[7rem]" />
            </colgroup>
            <thead>
              <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
                <th scope="col" className="px-3 py-2">Producto</th>
                <th scope="col" className="px-3 py-2 text-right">Cant.</th>
                <th scope="col" className="px-3 py-2 text-right">Costo</th>
                <th scope="col" className="px-3 py-2 text-right">Precio registrado</th>
                <th scope="col" className="px-3 py-2 text-right">% desc.</th>
                <th scope="col" className="px-3 py-2 text-right">Precio final</th>
                <th scope="col" className="px-3 py-2 text-right">Margen</th>
                <th scope="col" className="px-3 py-2 text-right">Desc. máx.</th>
              </tr>
            </thead>
            <tbody>
              {itemsQ.isPending && (
                <tr>
                  <td colSpan={8} className="px-3 py-3 text-ink-soft">Cargando...</td>
                </tr>
              )}
              {filas.map((row, i) => {
                const it = items[i]
                const f = calcularFila(it, valores.get(it.id) ?? 0)
                const nombreProducto = nombreItemVendido(row, row.producto)
                const texto = descuentos.get(it.id) ?? ''
                const invalido = invalidos.includes(it)
                return (
                  <tr
                    key={it.id}
                    className={`border-b border-table-divider align-top last:border-0 ${f.bajoCosto ? 'bg-error/10' : 'even:bg-table-row-alt'}`}
                  >
                    <td className="px-3 py-1.5 text-ink [overflow-wrap:anywhere]">{nombreProducto}</td>
                    <td className="px-3 py-1.5 text-right tabular-nums text-ink">{Number(it.cantidad)}</td>
                    <td className="px-3 py-1.5 text-right tabular-nums">
                      {f.costo ? (
                        <>
                          <span className="text-ink">{formatCurrency(f.costo.valor)}</span>
                          <span className="block text-label-md text-ink-soft">
                            {f.costo.fuente === 'actual' ? 'costo actual' : 'al vender'}
                            {(f.costo.fuente === 'actual' ? Number(it.producto_iva_actual) > 0 : it.producto_con_iva) ? ' · c/IVA' : ''}
                          </span>
                        </>
                      ) : (
                        <span className="text-label-md text-ink-soft">Sin costo cargado</span>
                      )}
                    </td>
                    <td className="px-3 py-1.5 text-right tabular-nums text-ink">{formatCurrency(it.precio_unitario)}</td>
                    <td className="px-3 py-1.5 text-right">
                      {editable ? (
                        <input
                          type="number"
                          inputMode="decimal"
                          step="0.01"
                          min={0}
                          max={100}
                          value={texto}
                          onChange={(e) => setDescuentos((prev) => new Map(prev).set(it.id, e.target.value))}
                          onKeyDown={(e) => e.key === 'Enter' && e.preventDefault()}
                          aria-label={`Descuento % de ${nombreProducto}`}
                          aria-invalid={invalido || undefined}
                          aria-describedby={invalido ? `${idBase}-rango` : undefined}
                          className={`${inputClass} w-full px-2 py-1.5 text-right tabular-nums ${invalido ? '!border-error' : ''}`}
                        />
                      ) : (
                        <span className="tabular-nums text-ink">{pct(Number(it.descuento_porcentaje))}</span>
                      )}
                    </td>
                    <td className="px-3 py-1.5 text-right tabular-nums">
                      <span className={`font-semibold ${f.bajoCosto ? 'text-error' : 'text-ink'}`}>{formatCurrency(f.precioFinalUnitario)}</span>
                      {Number(it.cantidad) !== 1 && <span className="block text-label-md text-ink-soft">{formatCurrency(f.importe)} en total</span>}
                    </td>
                    <td className="px-3 py-1.5 text-right tabular-nums">
                      {f.margen === null ? (
                        <span className="text-label-md text-ink-soft">—</span>
                      ) : (
                        <>
                          <span className={f.margen < 0 ? 'font-semibold text-error' : 'text-ink'}>{formatCurrency(f.margen)}</span>
                          <span className={`block text-label-md ${f.margen < 0 ? 'text-error' : 'text-ink-soft'}`}>
                            {f.margenPorcentaje === null ? '—' : pct(f.margenPorcentaje)}
                          </span>
                        </>
                      )}
                    </td>
                    <td className="px-3 py-1.5 text-right tabular-nums text-ink-soft">
                      {f.descuentoMaximo === null ? '—' : pct(f.descuentoMaximo)}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
        {invalidos.length > 0 && (
          <p id={`${idBase}-rango`} className="font-sans text-label-md text-error">
            El descuento va de 0 a 100 %: solo se puede bajar el precio registrado.
          </p>
        )}

        <div className="grid grid-cols-2 gap-stack-sm sm:grid-cols-4">
          <Total label="Precio de lista" valor={totales.lista} />
          <Total label="Original" detalle="lo que registró el cajero" valor={original} />
          <Total label="Total final" valor={totales.total} destacado />
          <Total label="Ahorro" detalle="sobre el precio de lista" valor={totales.lista - totales.total} />
        </div>
        {editable && totales.total > original && (
          <p role="status" className="rounded bg-badge-amber-bg px-4 py-3 font-sans text-body-md text-badge-amber-text">
            El total final queda {formatCurrency(totales.total - original)} por encima de lo que registró el cajero.
          </p>
        )}

        <details className="rounded-lg border border-line px-4 py-3">
          <summary className="cursor-pointer font-sans text-label-bold text-ink">Historial del comprobante</summary>
          <ul className="mt-2 flex flex-col gap-1 font-sans text-body-md text-ink-soft">
            <li>
              Registrado el {formatFechaHora(venta.created_at)} por {nombre(venta.usuario_id)}: total original{' '}
              <span className="tabular-nums text-ink">{formatCurrency(original)}</span>
              {Number(venta.descuento_global_original ?? 0) > 0 && <> con {pct(Number(venta.descuento_global_original))} de descuento global</>}.
            </li>
            {filas.some((r) => r.descuento_porcentaje_original !== null) && (
              <li>
                Descuento original por producto:{' '}
                {filas.map((r) => `${nombreItemVendido(r, r.producto)} ${pct(Number(r.descuento_porcentaje_original ?? r.descuento_porcentaje))}`).join(' · ')}
              </li>
            )}
            {venta.editada_at && (
              <li>
                Última edición: {formatFechaHora(venta.editada_at)} por {nombre(venta.editada_por)}.
              </li>
            )}
            {venta.reabierta_at && (
              <li>
                Reabierto el {formatFechaHora(venta.reabierta_at)} por {nombre(venta.reabierta_por)}: “{venta.reabierta_motivo}”.
              </li>
            )}
            {venta.finalizada_at && (
              <li>
                Finalizado el {formatFechaHora(venta.finalizada_at)} por {nombre(venta.finalizada_por)}.
              </li>
            )}
          </ul>
        </details>

        {motivo !== null && (
          <div className="flex flex-col gap-stack-sm rounded-lg border border-accent bg-accent-light/40 p-4">
            <Field label="Motivo para reabrir" hint="Queda en el historial del comprobante y en la auditoría.">
              <input value={motivo} onChange={(e) => setMotivo(e.target.value)} maxLength={200} autoFocus className={inputClass} />
            </Field>
            <div className="flex justify-end gap-3">
              <button type="button" onClick={() => setMotivo(null)} className="rounded px-4 py-3 font-sans text-label-bold text-ink-soft hover:bg-bg">
                Cancelar
              </button>
              <button
                type="button"
                onClick={onReabrir}
                disabled={guardando}
                className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
              >
                {reabrir.isPending ? 'Reabriendo...' : 'Reabrir comprobante'}
              </button>
            </div>
          </div>
        )}

        {error && <ErrorText>{error}</ErrorText>}
      </div>

      {confirmFinalizar && (
        <ConfirmDialog
          title="Finalizar comprobante"
          mensaje={`Comprobante N° ${venta.numero} de ${clienteNombre}: total final ${formatCurrency(totales.total)}. Queda cerrado sin cobro (se descuenta del sueldo fuera del sistema) y sale del saldo de la cuenta. Se puede reabrir después.`}
          confirmLabel="Finalizar"
          onCancel={() => setConfirmFinalizar(false)}
          onConfirm={onFinalizar}
        />
      )}
      {confirmCerrar && (
        <ConfirmDialog
          title="Cerrar sin guardar"
          mensaje="Hay cambios sin guardar en los descuentos. ¿Querés cerrar de todos modos?"
          confirmLabel="Cerrar sin guardar"
          onCancel={() => setConfirmCerrar(false)}
          onConfirm={onClose}
        />
      )}
    </Modal>
  )
}

function Total({ label, detalle, valor, destacado = false }: { label: string; detalle?: string; valor: number; destacado?: boolean }) {
  return (
    <div className={`rounded-lg border p-3 ${destacado ? 'border-accent bg-accent-light' : 'border-line'}`}>
      <p className="font-sans text-label-bold uppercase text-ink-soft">{label}</p>
      <p className={`mt-1 font-display tabular-nums ${destacado ? 'text-headline-md text-accent-darker' : 'text-body-lg font-semibold text-ink'}`}>
        {formatCurrency(valor)}
      </p>
      {detalle && <p className="font-sans text-label-md text-ink-soft">{detalle}</p>}
    </div>
  )
}
