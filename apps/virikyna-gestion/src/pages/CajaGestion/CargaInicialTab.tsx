import { useEffect, useId, useMemo, useState } from 'react'
import {
  AYUDA_SALDO_INICIAL,
  ControlSegmentado,
  EstadoBadge,
  estadoSaldoInicial,
  formatCurrency,
  formatFechaHora,
  friendlyError,
  tieneSaldoInicial,
} from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { usePerfil } from '../../auth/AuthContext'
import { Modal } from '../../components/Modal'
import { inputClass } from '../../components/FormField'
import { CorregirSaldoInicialModal, type CuentaACorregir } from './CorregirSaldoInicialModal'

// Carga inicial de saldos (docs/69). El saldo inicial es ÚNICO por cuenta: cada fila tiene su propio
// estado. Las que ya lo tienen se ven en solo lectura (monto, fecha y quién) y se corrigen con
// motivo; solo las que no lo tienen llevan un campo. No hay bloqueo global de la pantalla.

type TipoFila = 'cuenta' | 'proveedor' | 'cliente'

type Fila = {
  clave: string // `${tipo}:${id}`
  tipo: TipoFila
  id: string
  nombre: string
  inactivo: boolean
  cargado: boolean
  saldoInicial: number
  pendiente: number | null // proveedor/cliente: lo que falta cancelar del saldo inicial
  fecha: string | null
  usuario: string | null
}

type Filtro = 'todos' | 'sin' | 'con'

const FILTROS: { value: Filtro; label: string }[] = [
  { value: 'todos', label: 'Todos' },
  { value: 'sin', label: 'Sin saldo inicial' },
  { value: 'con', label: 'Con saldo inicial' },
]

const SECCIONES: { tipo: TipoFila; titulo: string; columna: string }[] = [
  { tipo: 'cuenta', titulo: 'Cuentas de dinero', columna: 'Cuenta' },
  { tipo: 'proveedor', titulo: 'Proveedores (deuda inicial)', columna: 'Proveedor' },
  { tipo: 'cliente', titulo: 'Clientes (saldo inicial de cuenta corriente)', columna: 'Cliente' },
]

type FilaVista = { id: string; saldo_inicial: number; saldo_inicial_fecha: string | null; saldo_inicial_usuario_nombre: string | null; saldo_inicial_pendiente: number }
type ProveedorVista = FilaVista & { razon_social: string }
type ClienteVista = FilaVista & { razon_social: string | null; nombre_fantasia: string | null; activo: boolean }
type MovimientoInicial = { cuenta_id: string; monto: number; created_at: string; usuario_id: string }

async function leerFilas(): Promise<Fila[]> {
  const [cuentasRes, movRes, perfilesRes, provRes, cliRes] = await Promise.all([
    supabase.from('cuentas').select('id, nombre').order('nombre'),
    supabase.from('movimientos_cuenta').select('cuenta_id, monto, created_at, usuario_id').eq('tipo', 'saldo_inicial'),
    // perfiles tiene RLS "solo el propio": los nombres salen de perfiles_publico.
    supabase.from('perfiles_publico').select('id, nombre'),
    supabase
      .from('proveedores_saldo')
      .select('id, razon_social, saldo_inicial, saldo_inicial_fecha, saldo_inicial_usuario_nombre, saldo_inicial_pendiente')
      .order('razon_social'),
    supabase
      .from('clientes_saldo')
      .select('id, razon_social, nombre_fantasia, activo, saldo_inicial, saldo_inicial_fecha, saldo_inicial_usuario_nombre, saldo_inicial_pendiente')
      .order('razon_social', { ascending: true, nullsFirst: false }),
  ])
  const error = cuentasRes.error || movRes.error || perfilesRes.error || provRes.error || cliRes.error
  if (error) throw error

  const nombres = new Map(((perfilesRes.data ?? []) as { id: string; nombre: string }[]).map((p) => [p.id, p.nombre]))
  const movPorCuenta = new Map(((movRes.data ?? []) as MovimientoInicial[]).map((m) => [m.cuenta_id, m]))

  const cuentas: Fila[] = ((cuentasRes.data ?? []) as { id: string; nombre: string }[]).map((c) => {
    const m = movPorCuenta.get(c.id)
    return {
      clave: `cuenta:${c.id}`,
      tipo: 'cuenta',
      id: c.id,
      nombre: c.nombre,
      inactivo: false,
      cargado: Boolean(m),
      saldoInicial: m ? Number(m.monto) : 0,
      pendiente: null,
      fecha: m?.created_at ?? null,
      usuario: m ? (nombres.get(m.usuario_id) ?? null) : null,
    }
  })
  const desdeVista = (tipo: 'proveedor' | 'cliente', v: FilaVista, nombre: string, inactivo: boolean): Fila => ({
    clave: `${tipo}:${v.id}`,
    tipo,
    id: v.id,
    nombre,
    inactivo,
    cargado: tieneSaldoInicial(v),
    saldoInicial: Number(v.saldo_inicial),
    pendiente: Number(v.saldo_inicial_pendiente),
    fecha: v.saldo_inicial_fecha,
    usuario: v.saldo_inicial_usuario_nombre,
  })
  const proveedores = ((provRes.data ?? []) as ProveedorVista[]).map((p) => desdeVista('proveedor', p, p.razon_social, false))
  const clientes = ((cliRes.data ?? []) as ClienteVista[]).map((c) =>
    desdeVista('cliente', c, c.razon_social ?? c.nombre_fantasia ?? '—', !c.activo),
  )
  return [...cuentas, ...proveedores, ...clientes]
}

export function CargaInicialTab() {
  const { rol } = usePerfil()
  const esAdmin = rol === 'admin'
  const [filas, setFilas] = useState<Fila[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [aviso, setAviso] = useState('')
  const [saving, setSaving] = useState(false)
  const [montos, setMontos] = useState<Record<string, string>>({})
  const [filtro, setFiltro] = useState<Filtro>('todos')
  const [buscar, setBuscar] = useState('')
  const [confirmar, setConfirmar] = useState<Fila[] | null>(null)
  const [aCorregir, setACorregir] = useState<CuentaACorregir | null>(null)
  const ayudaId = useId()

  async function cargar() {
    setError(null)
    try {
      setFilas(await leerFilas())
    } catch (e) {
      setError(friendlyError(e as Error))
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    cargar()
  }, [])

  // Filas sin saldo inicial con un monto escrito (las que se van a enviar).
  const aEnviar = useMemo(
    () => filas.filter((f) => !f.cargado && (montos[f.clave] ?? '').trim() !== ''),
    [filas, montos],
  )

  const texto = buscar.trim().toLowerCase()
  const visiblesDe = (tipo: TipoFila) =>
    filas.filter(
      (f) =>
        f.tipo === tipo &&
        (filtro === 'todos' || (filtro === 'con' ? f.cargado : !f.cargado)) &&
        (!texto || f.nombre.toLowerCase().includes(texto)),
    )

  // Validación previa: montos válidos y, contra la base recién leída, que ninguna fila haya
  // recibido un saldo inicial mientras la pantalla estaba abierta (otra persona, otra pestaña).
  async function revisarYConfirmar() {
    setError(null)
    setAviso('')
    const invalidas = aEnviar.filter((f) => {
      const n = Number(montos[f.clave])
      return !Number.isFinite(n) || n === 0
    })
    if (invalidas.length > 0) {
      setError(`Revisá el monto de: ${invalidas.map((f) => f.nombre).join(', ')}. Tiene que ser un número distinto de cero.`)
      return
    }
    let frescas: Fila[]
    try {
      frescas = await leerFilas()
    } catch (e) {
      setError(friendlyError(e as Error))
      return
    }
    const ahoraCargadas = new Set(frescas.filter((f) => f.cargado).map((f) => f.clave))
    const yaTienen = aEnviar.filter((f) => ahoraCargadas.has(f.clave))
    setFilas(frescas)
    if (yaTienen.length > 0) {
      setError(
        `Ya tienen saldo inicial cargado y no se suma: ${yaTienen.map((f) => f.nombre).join(', ')}. No se envió nada. ` +
          'Si falta deuda, cargala como comprobante; si el monto está mal, usá Corregir.',
      )
      return
    }
    setConfirmar(aEnviar)
  }

  async function guardar(lista: Fila[]) {
    const items = (tipo: TipoFila, campo: string) =>
      lista.filter((f) => f.tipo === tipo).map((f) => ({ [campo]: f.id, monto: Number(montos[f.clave]) }))
    setSaving(true)
    const { error: rpcError } = await supabase.rpc('cargar_saldos_iniciales', {
      p_saldos_cuentas: items('cuenta', 'cuenta_id'),
      p_saldos_proveedores: items('proveedor', 'proveedor_id'),
      p_saldos_clientes: items('cliente', 'cliente_id'),
    })
    setSaving(false)
    setConfirmar(null)
    if (rpcError) {
      setError(friendlyError(rpcError))
      await cargar()
      return
    }
    setMontos({})
    setAviso(lista.length === 1 ? 'Se cargó 1 saldo inicial.' : `Se cargaron ${lista.length} saldos iniciales.`)
    await cargar()
  }

  if (loading) return <p className="font-sans text-body-md text-ink-soft">Cargando...</p>

  return (
    <div className="flex flex-col gap-stack-md">
      <p id={ayudaId} className="rounded bg-accent-light px-4 py-3 font-sans text-body-md text-accent-darker">
        {AYUDA_SALDO_INICIAL} Si un monto está mal, se corrige con <strong>Corregir</strong> y un motivo.
      </p>

      <div className="flex flex-wrap items-end gap-stack-md">
        <ControlSegmentado legend="Mostrar" opciones={FILTROS} value={filtro} onChange={setFiltro} />
        <label className="flex w-64 flex-col gap-2">
          <span className="font-sans text-label-md text-ink">Buscar</span>
          <input
            type="search"
            value={buscar}
            onChange={(e) => setBuscar(e.target.value)}
            placeholder="Nombre"
            className={inputClass}
          />
        </label>
      </div>

      {error && (
        <p role="alert" className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">
          {error}
        </p>
      )}
      <p aria-live="polite" className={aviso ? 'rounded bg-badge-green-bg px-4 py-3 font-sans text-body-md text-badge-green-text' : 'sr-only'}>
        {aviso}
      </p>

      {SECCIONES.map((s) => (
        <SeccionSaldos
          key={s.tipo}
          titulo={s.titulo}
          columna={s.columna}
          todas={filas.filter((f) => f.tipo === s.tipo)}
          visibles={visiblesDe(s.tipo)}
          montos={montos}
          ayudaId={ayudaId}
          puedeCorregir={esAdmin && s.tipo !== 'cuenta'}
          onMonto={(clave, valor) => setMontos((prev) => ({ ...prev, [clave]: valor }))}
          onCorregir={(f) =>
            setACorregir({
              tipo: f.tipo as CuentaACorregir['tipo'],
              id: f.id,
              nombre: f.nombre,
              saldoInicial: f.saldoInicial,
              fecha: f.fecha,
              usuario: f.usuario,
            })
          }
        />
      ))}

      <div className="sticky bottom-0 flex flex-wrap items-center justify-end gap-3 border-t border-line bg-surface py-4">
        <p className="mr-auto font-sans text-body-md text-ink-soft" aria-live="polite">
          {aEnviar.length === 0
            ? 'Escribí el monto en las filas sin saldo inicial.'
            : `${aEnviar.length} ${aEnviar.length === 1 ? 'saldo inicial' : 'saldos iniciales'} para cargar`}
        </p>
        <button
          type="button"
          onClick={revisarYConfirmar}
          disabled={saving || aEnviar.length === 0}
          className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
        >
          Revisar y cargar
        </button>
      </div>

      {confirmar && (
        <ConfirmarCarga
          lista={confirmar}
          montos={montos}
          guardando={saving}
          onVolver={() => setConfirmar(null)}
          onConfirmar={() => guardar(confirmar)}
        />
      )}

      {aCorregir && (
        <CorregirSaldoInicialModal
          cuenta={aCorregir}
          onClose={() => setACorregir(null)}
          onCorregido={(r) => {
            setAviso(`Saldo inicial de ${aCorregir.nombre} corregido: ${formatCurrency(r.anterior)} → ${formatCurrency(r.nuevo)}.`)
            setACorregir(null)
            cargar()
          }}
        />
      )}
    </div>
  )
}

function SeccionSaldos({
  titulo,
  columna,
  todas,
  visibles,
  montos,
  ayudaId,
  puedeCorregir,
  onMonto,
  onCorregir,
}: {
  titulo: string
  columna: string
  todas: Fila[]
  visibles: Fila[]
  montos: Record<string, string>
  ayudaId: string
  puedeCorregir: boolean
  onMonto: (clave: string, valor: string) => void
  onCorregir: (f: Fila) => void
}) {
  const tituloId = useId()
  const conSaldo = todas.filter((f) => f.cargado).length
  return (
    <section aria-labelledby={tituloId}>
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 id={tituloId} className="font-sans text-label-bold text-ink">
          {titulo}
        </h2>
        <p className="font-sans text-label-md text-ink-soft">
          {conSaldo} con saldo inicial · {todas.length - conSaldo} sin
        </p>
      </div>
      <div className="mt-2 overflow-x-auto rounded-xl shadow-sm">
        <table className="w-full table-fixed text-left font-sans text-table-row">
          <colgroup>
            <col />
            <col className="w-[13rem]" />
            <col className="w-[15rem]" />
            <col className="w-[8rem]" />
          </colgroup>
          <thead>
            <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
              <th scope="col" className="px-3 py-2.5">{columna}</th>
              <th scope="col" className="px-3 py-2.5 text-right">Saldo inicial</th>
              <th scope="col" className="px-3 py-2.5">Cargado</th>
              <th scope="col" className="px-3 py-2.5">
                <span className="sr-only">Acciones</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {visibles.length === 0 && (
              <tr>
                <td colSpan={4} className="px-4 py-4 text-ink-soft">
                  {todas.length === 0 ? 'No hay ninguna cargada todavía.' : 'Ninguna coincide con el filtro.'}
                </td>
              </tr>
            )}
            {visibles.map((f) => {
              const estado = f.pendiente !== null ? estadoSaldoInicial(f.saldoInicial, f.pendiente) : null
              return (
                <tr key={f.clave} className="border-b border-table-divider last:border-0 even:bg-table-row-alt">
                  <th scope="row" className="px-3 py-3 font-normal text-ink [overflow-wrap:anywhere]">
                    {f.nombre}
                    {f.inactivo && <span className="ml-2 text-ink-soft">(inactivo)</span>}
                  </th>
                  <td className="px-3 py-2 text-right">
                    {f.cargado ? (
                      <>
                        <span className="font-semibold tabular-nums text-ink">{formatCurrency(f.saldoInicial)}</span>
                        {estado && (
                          <span className="mt-1 flex justify-end">
                            <EstadoBadge variant={estado.variant}>{estado.label}</EstadoBadge>
                          </span>
                        )}
                      </>
                    ) : (
                      <input
                        type="number"
                        step="0.01"
                        value={montos[f.clave] ?? ''}
                        onChange={(e) => onMonto(f.clave, e.target.value)}
                        aria-label={`Saldo inicial de ${f.nombre}`}
                        aria-describedby={ayudaId}
                        placeholder="$ 0,00"
                        className={`${inputClass} w-full text-right tabular-nums`}
                      />
                    )}
                  </td>
                  <td className="px-3 py-3 text-ink-soft">
                    {f.cargado ? (
                      <>
                        <span className="tabular-nums">{f.fecha ? formatFechaHora(f.fecha) : '—'}</span>
                        <span className="block text-ink">{f.usuario ?? 'Usuario inactivo'}</span>
                      </>
                    ) : (montos[f.clave] ?? '').trim() !== '' && Number.isFinite(Number(montos[f.clave])) ? (
                      // Formato argentino de lo que se va a guardar ("4.500" acá es 4,50).
                      <span className="text-ink">
                        Se carga <span className="font-semibold tabular-nums">{formatCurrency(Number(montos[f.clave]))}</span>
                      </span>
                    ) : (
                      'Sin saldo inicial'
                    )}
                  </td>
                  <td className="px-3 py-2 text-right">
                    {f.cargado && puedeCorregir && (
                      <button
                        type="button"
                        onClick={() => onCorregir(f)}
                        aria-label={`Corregir el saldo inicial de ${f.nombre}`}
                        className="rounded border border-line bg-surface px-3 py-2 font-sans text-label-bold text-accent-dark transition hover:border-accent hover:bg-accent-light"
                      >
                        Corregir
                      </button>
                    )}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
    </section>
  )
}

// Confirmación antes de cargar: lista con los montos en formato argentino. El foco arranca en
// "Volver" (un Enter apurado no confirma) y Esc vuelve.
function ConfirmarCarga({
  lista,
  montos,
  guardando,
  onVolver,
  onConfirmar,
}: {
  lista: Fila[]
  montos: Record<string, string>
  guardando: boolean
  onVolver: () => void
  onConfirmar: () => void
}) {
  const etiqueta: Record<TipoFila, string> = { cuenta: 'Cuenta', proveedor: 'Proveedor', cliente: 'Cliente' }
  return (
    <Modal title="Confirmar carga de saldos iniciales" onClose={onVolver} widthClassName="max-w-[560px]" dialogo={{ onEscape: onVolver }}>
      <div className="flex flex-col gap-stack-md">
        <p className="font-sans text-body-md text-ink">
          Cada saldo inicial se carga <strong>una sola vez</strong>. Después solo se puede corregir con motivo.
        </p>
        <ul className="max-h-[18rem] overflow-y-auto rounded-lg border border-line">
          {lista.map((f) => (
            <li key={f.clave} className="flex items-baseline justify-between gap-3 border-b border-line px-4 py-2 last:border-0">
              <span className="min-w-0 font-sans text-body-md text-ink [overflow-wrap:anywhere]">
                <span className="text-ink-soft">{etiqueta[f.tipo]} · </span>
                {f.nombre}
              </span>
              <span className="shrink-0 font-sans text-body-md font-semibold tabular-nums text-ink">
                {formatCurrency(Number(montos[f.clave]))}
              </span>
            </li>
          ))}
        </ul>
        <div className="flex justify-end gap-3">
          <button
            type="button"
            data-autofocus
            onClick={onVolver}
            className="rounded px-4 py-3 font-sans text-label-bold text-ink-soft hover:bg-bg"
          >
            Volver
          </button>
          <button
            type="button"
            onClick={onConfirmar}
            disabled={guardando}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
          >
            {guardando ? 'Guardando...' : `Cargar ${lista.length === 1 ? '1 saldo' : `${lista.length} saldos`}`}
          </button>
        </div>
      </div>
    </Modal>
  )
}
