import { useEffect, useId, useMemo, useRef, useState, type KeyboardEvent, type ReactNode } from 'react'
import { useSearchParams } from 'react-router-dom'

// Esqueleto de una cuenta corriente (proveedores docs/31, clientes docs/68): cabecera con volver,
// título, datos y acción principal; KPIs; pestañas accesibles (flechas, Home/End); filtros;
// panel; barra de selección sticky. Lo propio de cada cuenta (columnas, filtros, KPIs, acciones,
// modales) entra por props. El markup es el que tenía ProveedorCuentaCorriente.

export type TabCuenta<T extends string = string> = { id: T; label: string }

// ── Pestaña y filtros en la URL (search params): se pueden compartir y sobreviven al volver ──
export function useParamsCuentaCorriente<T extends string>(tabs: readonly TabCuenta<T>[], filtros: readonly string[]) {
  const [params, setParams] = useSearchParams()
  const tab = (tabs.some((t) => t.id === params.get('tab')) ? params.get('tab') : tabs[0].id) as T
  const valores = Object.fromEntries(filtros.map((k) => [k, params.get(k) ?? ''])) as Record<string, string>
  const hayFiltros = filtros.some((k) => Boolean(valores[k]))

  function setParam(clave: string, valor: string) {
    setParams(
      (prev) => {
        const next = new URLSearchParams(prev)
        if (valor) next.set(clave, valor)
        else next.delete(clave)
        return next
      },
      { replace: true },
    )
  }
  function limpiarFiltros() {
    setParams(
      (prev) => {
        const next = new URLSearchParams(prev)
        for (const k of filtros) next.delete(k)
        return next
      },
      { replace: true },
    )
  }
  // La primera pestaña es la de entrada: no se escribe en la URL.
  const irATab = (id: T) => setParam('tab', id === tabs[0].id ? '' : id)

  return { tab, irATab, valores, hayFiltros, setParam, limpiarFiltros }
}

// ── Selección múltiple: lo que deja de ser seleccionable (tras un pago, edición…) se cae solo ──
export function useSeleccion<F>(filas: F[], getId: (f: F) => string, esSeleccionable: (f: F) => boolean) {
  const [seleccion, setSeleccion] = useState<Set<string>>(new Set())
  const porId = useMemo(() => new Map(filas.map((f) => [getId(f), f])), [filas, getId])
  useEffect(() => {
    setSeleccion((prev) => {
      const next = new Set([...prev].filter((id) => {
        const f = porId.get(id)
        return f ? esSeleccionable(f) : false
      }))
      return next.size === prev.size ? prev : next
    })
  }, [porId, esSeleccionable])

  function toggle(id: string) {
    setSeleccion((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }
  return { seleccion, setSeleccion, toggle, limpiar: () => setSeleccion(new Set()) }
}

export function KpiCuenta({ label, children }: { label: string; children: ReactNode }) {
  return (
    <li className="rounded-lg border border-line p-4">
      <p className="font-sans text-label-bold uppercase text-ink-soft">{label}</p>
      <p className="mt-1 font-display text-headline-md text-accent-darker tabular-nums">{children}</p>
    </li>
  )
}

type Props<T extends string> = {
  volverLabel: string // "← Proveedores"
  onVolver: () => void
  titulo: string
  datos: { label: string; valor: ReactNode }[] // CUIT, contacto…
  // motivoDeshabilitada: la acción no se puede usar (se muestra deshabilitada con ese motivo).
  accionPrincipal: { label: string; onClick: () => void; motivoDeshabilitada?: string }
  // Una sola acción teal sólida por pantalla (docs/08 §5): con selección, la protagonista es la de la barra.
  conSeleccion: boolean
  debajoCabecera?: ReactNode
  kpis: ReactNode // <KpiCuenta> items
  kpisClassName?: string // columnas en pantallas grandes
  tabs: readonly TabCuenta<T>[]
  tab: T
  onTab: (id: T) => void
  filtros: ReactNode // campos del formulario de filtros
  hayFiltros: boolean
  onLimpiarFiltros: () => void
  error?: string | null
  avisos?: ReactNode // entre filtros y panel (ej. "Hay $ X a cuenta")
  aviso: string // confirmación verde (aria-live)
  panel: ReactNode
  barraSeleccion: { resumen: string; accionLabel: string; onAccion: () => void; onQuitar: () => void } | null
  children?: ReactNode // modales
}

export function CuentaCorrienteLayout<T extends string>({
  volverLabel,
  onVolver,
  titulo,
  datos,
  accionPrincipal,
  conSeleccion,
  debajoCabecera,
  kpis,
  kpisClassName = 'lg:grid-cols-5',
  tabs,
  tab,
  onTab,
  filtros,
  hayFiltros,
  onLimpiarFiltros,
  error,
  avisos,
  aviso,
  panel,
  barraSeleccion,
  children,
}: Props<T>) {
  const idBase = useId()
  const tabRefs = useRef<(HTMLButtonElement | null)[]>([])

  function onTabKeyDown(e: KeyboardEvent<HTMLDivElement>) {
    const i = tabs.findIndex((t) => t.id === tab)
    const destino =
      e.key === 'ArrowRight' ? (i + 1) % tabs.length
      : e.key === 'ArrowLeft' ? (i - 1 + tabs.length) % tabs.length
      : e.key === 'Home' ? 0
      : e.key === 'End' ? tabs.length - 1
      : -1
    if (destino < 0) return
    e.preventDefault()
    onTab(tabs[destino].id)
    tabRefs.current[destino]?.focus()
  }

  return (
    <section aria-labelledby={`${idBase}-titulo`} className="flex min-h-full flex-col rounded-lg bg-surface p-card shadow-sm">
      {/* ── Cabecera ── */}
      <div className="flex flex-wrap items-start justify-between gap-stack-md">
        <div className="min-w-0">
          <button
            type="button"
            onClick={onVolver}
            className="rounded font-sans text-label-bold text-accent-dark hover:underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
          >
            {volverLabel}
          </button>
          <h1 id={`${idBase}-titulo`} className="mt-1 font-display text-headline-lg text-accent-darker [overflow-wrap:anywhere]">
            {titulo}
          </h1>
          <dl className="mt-1 flex flex-wrap gap-x-stack-md gap-y-1 font-sans text-label-md text-ink-soft">
            {datos.map((d) => (
              <div key={d.label} className="flex gap-1">
                <dt>{d.label}:</dt>
                <dd className="text-ink">{d.valor}</dd>
              </div>
            ))}
          </dl>
        </div>
        <button
          type="button"
          onClick={accionPrincipal.onClick}
          disabled={Boolean(accionPrincipal.motivoDeshabilitada)}
          title={accionPrincipal.motivoDeshabilitada}
          aria-describedby={accionPrincipal.motivoDeshabilitada ? `${idBase}-motivo` : undefined}
          className={
            conSeleccion
              ? 'rounded border border-accent px-4 py-3 font-sans text-label-bold text-accent-darker transition hover:bg-accent-light'
              : accionPrincipal.motivoDeshabilitada
                ? 'cursor-not-allowed rounded bg-accent px-4 py-3 font-sans text-label-bold text-white opacity-60'
                : 'rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark'
          }
        >
          {accionPrincipal.label}
        </button>
        {accionPrincipal.motivoDeshabilitada && (
          <span id={`${idBase}-motivo`} className="sr-only">
            {accionPrincipal.motivoDeshabilitada}
          </span>
        )}
      </div>

      {debajoCabecera}

      {/* ── KPIs ── */}
      <ul aria-label="Resumen de la cuenta" className={`mt-stack-md grid grid-cols-2 gap-stack-sm ${kpisClassName}`}>
        {kpis}
      </ul>

      {/* ── Pestañas ── */}
      <div role="tablist" aria-label="Vista de la cuenta" onKeyDown={onTabKeyDown} className="mt-stack-md flex gap-1 border-b border-line">
        {tabs.map((t, i) => (
          <button
            key={t.id}
            ref={(el) => (tabRefs.current[i] = el)}
            id={`${idBase}-tab-${t.id}`}
            type="button"
            role="tab"
            aria-selected={tab === t.id}
            aria-controls={`${idBase}-panel`}
            tabIndex={tab === t.id ? 0 : -1}
            onClick={() => onTab(t.id)}
            className={[
              'rounded-t px-4 py-2 font-sans text-label-bold focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent',
              tab === t.id ? 'border-b-2 border-accent text-accent-darker' : 'text-ink-soft hover:text-accent-darker',
            ].join(' ')}
          >
            {t.label}
          </button>
        ))}
      </div>

      {/* ── Filtros (en la URL) ── */}
      <form
        role="search"
        aria-label="Filtrar"
        onSubmit={(e) => e.preventDefault()}
        className="mt-stack-md flex flex-wrap items-end gap-stack-sm"
      >
        {filtros}
        {hayFiltros && (
          <button
            type="button"
            onClick={onLimpiarFiltros}
            className="rounded px-3 py-2.5 font-sans text-label-bold text-ink-soft hover:bg-bg focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
          >
            Limpiar filtros
          </button>
        )}
      </form>

      {error && (
        <p role="alert" className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">
          {error}
        </p>
      )}
      {avisos}
      <p aria-live="polite" className={aviso ?'mt-stack-md rounded bg-badge-green-bg px-4 py-3 font-sans text-body-md text-badge-green-text' : 'sr-only'}>
        {aviso}
      </p>

      {/* ── Panel ── */}
      <div
        id={`${idBase}-panel`}
        role="tabpanel"
        aria-labelledby={`${idBase}-tab-${tab}`}
        className="mt-stack-md flex-1 overflow-hidden rounded-xl shadow-sm"
      >
        {panel}
      </div>

      {/* ── Barra de selección ── */}
      <p aria-live="polite" className="sr-only">
        {barraSeleccion?.resumen ?? ''}
      </p>
      {barraSeleccion && (
        <div
          role="region"
          aria-label="Comprobantes seleccionados"
          className="sticky bottom-0 z-10 mt-stack-md flex flex-wrap items-center justify-between gap-stack-sm rounded-lg border border-accent bg-accent-light px-4 py-3"
        >
          <p className="font-sans text-body-md font-semibold text-accent-darker tabular-nums">{barraSeleccion.resumen}</p>
          <div className="flex gap-3">
            <button
              type="button"
              onClick={barraSeleccion.onQuitar}
              className="rounded px-4 py-2.5 font-sans text-label-bold text-ink-soft hover:bg-surface focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
            >
              Quitar selección
            </button>
            <button
              type="button"
              onClick={barraSeleccion.onAccion}
              className="rounded bg-accent px-4 py-2.5 font-sans text-label-bold text-white transition hover:bg-accent-dark"
            >
              {barraSeleccion.accionLabel}
            </button>
          </div>
        </div>
      )}

      {children}
    </section>
  )
}

// ── Tabla de comprobantes con selección ──────────────────────────────────────────────────────
export type ColumnaComprobantes<F> = {
  id: string
  header: ReactNode
  colClassName?: string // ancho (<col>)
  thClassName?: string // además de "px-3 py-2.5"
  td: (fila: F) => { className: string; contenido: ReactNode; detenerClick?: boolean }
}

// Línea fija al principio de la tabla que no es un comprobante (docs/69: el saldo inicial). Sin
// checkbox ni click; cada celda va por id de columna (la que falte queda vacía).
export type FilaInicialComprobantes = {
  etiqueta: string // nombre de la línea para el lector de pantalla
  celdas: Partial<Record<string, ReactNode>>
}

type TablaProps<F> = {
  filaInicial?: FilaInicialComprobantes | null
  filas: F[]
  columnas: ColumnaComprobantes<F>[]
  getId: (f: F) => string
  esSeleccionable: (f: F) => boolean
  etiquetaFila: (f: F) => string // aria-label del checkbox
  seleccion: Set<string>
  onToggle: (id: string) => void
  onToggleVisibles: (ids: string[], marcar: boolean) => void
  onAbrir: (f: F) => void
  claseFila?: (f: F) => string // ej. atenuar cerrados
  cargando: boolean
  vacio: string
}

export function TablaComprobantes<F>({
  filaInicial,
  filas,
  columnas,
  getId,
  esSeleccionable,
  etiquetaFila,
  seleccion,
  onToggle,
  onToggleVisibles,
  onAbrir,
  claseFila,
  cargando,
  vacio,
}: TablaProps<F>) {
  const seleccionablesVisibles = filas.filter(esSeleccionable)
  const todosMarcados = seleccionablesVisibles.length > 0 && seleccionablesVisibles.every((f) => seleccion.has(getId(f)))
  const algunoMarcado = seleccionablesVisibles.some((f) => seleccion.has(getId(f)))
  const checkTodosRef = useRef<HTMLInputElement>(null)
  useEffect(() => {
    if (checkTodosRef.current) checkTodosRef.current.indeterminate = algunoMarcado && !todosMarcados
  }, [algunoMarcado, todosMarcados])
  const colSpan = columnas.length + 1

  return (
    <table className="w-full table-fixed text-left font-sans text-table-row max-xl:[&_td]:px-2 max-xl:[&_th]:px-2">
      <colgroup>
        <col className="w-[2.75rem]" />
        {columnas.map((c) => (
          <col key={c.id} className={c.colClassName} />
        ))}
      </colgroup>
      <thead>
        <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
          <th scope="col" className="px-3 py-2.5">
            <input
              ref={checkTodosRef}
              type="checkbox"
              checked={todosMarcados}
              disabled={seleccionablesVisibles.length === 0}
              onChange={() => onToggleVisibles(seleccionablesVisibles.map(getId), !todosMarcados)}
              aria-label="Seleccionar todos los comprobantes visibles"
              className="h-4 w-4 accent-accent"
            />
          </th>
          {columnas.map((c) => (
            <th key={c.id} scope="col" className={c.thClassName ? `px-3 py-2.5 ${c.thClassName}` : 'px-3 py-2.5'}>
              {c.header}
            </th>
          ))}
        </tr>
      </thead>
      <tbody>
        {cargando && (
          <tr>
            <td colSpan={colSpan} className="px-4 py-4 text-ink-soft">Cargando...</td>
          </tr>
        )}
        {!cargando && filaInicial && (
          <tr className="border-b border-table-divider bg-bg">
            <th scope="row" className="px-3 py-3 font-normal">
              <span className="sr-only">{filaInicial.etiqueta}</span>
            </th>
            {columnas.map((c) => (
              <td key={c.id} className={`px-3 py-3 ${c.thClassName ?? ''}`}>
                {filaInicial.celdas[c.id] ?? null}
              </td>
            ))}
          </tr>
        )}
        {!cargando && filas.length === 0 && !filaInicial && (
          <tr>
            <td colSpan={colSpan} className="px-4 py-4 text-ink-soft">
              {vacio}
            </td>
          </tr>
        )}
        {filas.map((f) => {
          const id = getId(f)
          const seleccionable = esSeleccionable(f)
          return (
            <tr
              key={id}
              onClick={() => onAbrir(f)}
              className={`cursor-pointer border-b border-table-divider last:border-0 even:bg-table-row-alt hover:bg-accent-light/40 ${
                claseFila?.(f) ?? ''
              } ${seleccion.has(id) ? '!bg-accent-light' : ''}`}
            >
              <td className="px-3 py-3" onClick={(e) => e.stopPropagation()}>
                {seleccionable && (
                  <input
                    type="checkbox"
                    checked={seleccion.has(id)}
                    onChange={() => onToggle(id)}
                    aria-label={`Seleccionar ${etiquetaFila(f)}`}
                    className="h-4 w-4 accent-accent"
                  />
                )}
              </td>
              {columnas.map((c) => {
                const celda = c.td(f)
                return (
                  <td
                    key={c.id}
                    className={celda.className}
                    onClick={celda.detenerClick ? (e) => e.stopPropagation() : undefined}
                  >
                    {celda.contenido}
                  </td>
                )
              })}
            </tr>
          )
        })}
      </tbody>
    </table>
  )
}
