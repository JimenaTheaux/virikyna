import { useState, type KeyboardEvent } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { Check, Loader2, Lock, Pencil, Search } from 'lucide-react'
import {
  esCargaCerrada,
  formatCantidad,
  useEditarProductoCarga,
  useInventarioTotal,
  validarFila,
  type ErroresFila,
  type ProductoInventarioTotal,
} from '../../../lib/cargaInicial'
import { useDebouncedValue } from '../../../lib/useDebouncedValue'
import { formatCurrency } from '../../../lib/format'
import { MostrarMas } from '../MostrarMas'
import { BotonesDialogo, Dialogo } from './comunes'

// clientId (docs/34c): uno por versión de la edición. Cambiar un campo genera otro; guardar de
// nuevo sin cambios (reintento tras un error de red) reusa el mismo y la base no lo aplica dos veces.
type Edicion = { nombre: string; marca: string; descripcion: string; precio: string; cantidad: string; clientId: string }

const TOOLTIP_COSTO = 'Precio calculado por costo: este producto tiene costo cargado y su precio sale de la fórmula.'

const inputEscritorio =
  'h-9 w-full min-w-0 rounded border border-line bg-surface px-2 font-sans text-body-md text-ink outline-none focus:border-accent disabled:bg-bg disabled:text-ink-soft aria-[invalid=true]:border-error'
const inputCelular =
  'h-12 w-full min-w-0 rounded border border-line bg-surface px-3 font-sans text-body-md text-ink outline-none focus:border-accent disabled:bg-bg disabled:text-ink-soft aria-[invalid=true]:border-error'

// Como validarFila, pero la cantidad es el stock real: puede ser 0 (se agotó o se corrige), no negativa.
function erroresEdicion(e: Edicion): ErroresFila {
  const { cantidad: _, ...errores } = validarFila({ ...e, cantidad: '1' })
  if (e.cantidad.trim() === '' || !(Number(e.cantidad) >= 0)) {
    return { ...errores, cantidad: 'La cantidad no puede quedar vacía ni ser negativa.' }
  }
  return errores
}

function edicionDe(p: ProductoInventarioTotal): Edicion {
  return {
    nombre: p.nombre,
    marca: p.marca ?? '',
    descripcion: p.descripcion ?? '',
    precio: String(p.precio_venta),
    cantidad: String(p.stock_local),
    clientId: crypto.randomUUID(),
  }
}

type Props = {
  supabase: SupabaseClient
  celular: boolean
  activo: boolean // pestaña visible: solo así se consulta y se refresca
  onCerrada: () => void
}

// Productos activos con stock en Local, editables por cualquier usuario mientras la carga está
// abierta (carga_inicial_editar_producto). La edición en curso vive en el estado de la fila, así
// el refresco cada 15 s no pisa lo que se está tipeando.
export function InventarioTotal({ supabase, celular, activo, onCerrada }: Props) {
  const [busqueda, setBusqueda] = useState('')
  const busquedaDebounced = useDebouncedValue(busqueda, 300)
  const consulta = useInventarioTotal(supabase, busquedaDebounced, activo)
  const editar = useEditarProductoCarga(supabase)
  const [editandoSheet, setEditandoSheet] = useState<ProductoInventarioTotal | null>(null)

  const productos = consulta.data?.pages.flatMap((p) => p.productos) ?? []
  const total = consulta.data?.pages[0]?.total ?? 0

  async function guardar(p: ProductoInventarioTotal, e: Edicion): Promise<string | null> {
    try {
      await editar.mutateAsync({
        clientId: e.clientId,
        productoId: p.id,
        nombre: e.nombre.trim(),
        marca: e.marca.trim(),
        descripcion: e.descripcion.trim(),
        precio: p.costo !== null ? null : Number(e.precio),
        cantidadLocal: Number(e.cantidad),
      })
      return null
    } catch (err) {
      if (esCargaCerrada(err)) onCerrada()
      return err instanceof Error ? err.message : 'No se pudo guardar.'
    }
  }

  const buscador = (
    <div className="relative">
      <Search className="pointer-events-none absolute left-3 top-1/2 h-5 w-5 -translate-y-1/2 text-ink-soft" aria-hidden />
      <label htmlFor="carga-total-buscar" className="sr-only">
        Buscar por código, nombre o marca
      </label>
      <input
        id="carga-total-buscar"
        type="search"
        value={busqueda}
        onChange={(e) => setBusqueda(e.target.value)}
        placeholder="Buscar por código, nombre o marca…"
        className={`w-full rounded border border-line bg-surface pl-11 pr-4 font-sans text-body-md text-ink outline-none focus:border-accent ${
          celular ? 'h-12' : 'h-10'
        }`}
      />
    </div>
  )

  const estado = (
    <p aria-live="polite" className="font-sans text-label-md text-ink-soft">
      {consulta.isLoading
        ? 'Cargando…'
        : consulta.isError
          ? 'No se pudo cargar el inventario. Revisá la conexión.'
          : `${total} producto${total === 1 ? '' : 's'}${busquedaDebounced.trim() ? ` para "${busquedaDebounced.trim()}"` : ''}`}
      {consulta.isFetching && !consulta.isLoading && ' · actualizando…'}
    </p>
  )

  const masPaginas = consulta.hasNextPage ? (
    <MostrarMas
      restantes={total - productos.length}
      onClick={() => void consulta.fetchNextPage()}
      size={celular ? 'touch' : 'compact'}
    />
  ) : null

  if (celular) {
    return (
      <div className="flex flex-col gap-stack-md">
        {buscador}
        {estado}
        <ul className="flex flex-col gap-3">
          {productos.map((p) => (
            <li key={p.id}>
              <button
                type="button"
                onClick={() => setEditandoSheet(p)}
                className="w-full rounded-lg border border-line bg-surface p-4 text-left shadow-sm active:bg-bg"
              >
                <p className="font-sans text-label-bold text-ink [overflow-wrap:anywhere]">{p.nombre}</p>
                <p className="font-sans text-label-md text-ink-soft [overflow-wrap:anywhere]">
                  {[p.marca, p.codigo_barras ?? p.codigo_interno].filter(Boolean).join(' · ')}
                </p>
                <div className="mt-2 flex items-end justify-between">
                  <span className="font-sans text-body-md text-ink">Local: {formatCantidad(p.stock_local)}</span>
                  <span className="flex items-center gap-1 font-display text-headline-md text-accent-darker">
                    {p.costo !== null && <Lock className="h-4 w-4 text-ink-soft" aria-label="Precio por costo" />}
                    {formatCurrency(p.precio_venta)}
                  </span>
                </div>
              </button>
            </li>
          ))}
        </ul>
        {masPaginas}
        {editandoSheet && (
          <EditorProductoSheet
            producto={editandoSheet}
            guardando={editar.isPending}
            onCancelar={() => setEditandoSheet(null)}
            onGuardar={async (e) => {
              const error = await guardar(editandoSheet, e)
              if (!error) setEditandoSheet(null)
              return error
            }}
          />
        )}
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-stack-md">
      <div className="flex items-center justify-between gap-3">
        <div className="w-full max-w-[28rem]">{buscador}</div>
        {estado}
      </div>
      <div className="overflow-auto rounded-xl shadow-sm">
        <table className="w-full table-fixed text-left font-sans text-table-row max-xl:[&_td]:px-2 max-xl:[&_th]:px-2">
          <colgroup>
            <col className="w-[11rem]" />
            <col />
            <col className="w-[14%]" />
            <col className="w-[18%]" />
            <col className="w-[8rem]" />
            <col className="w-[6.5rem]" />
            <col className="w-[5.5rem]" />
          </colgroup>
          <thead>
            <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
              <th className="px-3 py-2.5">Código</th>
              <th className="px-3 py-2.5">Nombre</th>
              <th className="px-3 py-2.5">Marca</th>
              <th className="px-3 py-2.5">Descripción</th>
              <th className="px-3 py-2.5 text-right">Precio</th>
              <th className="px-3 py-2.5 text-right">Stock local</th>
              <th className="px-3 py-2.5">
                <span className="sr-only">Editar</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {productos.map((p) => (
              <FilaProducto key={p.id} producto={p} onGuardar={(e) => guardar(p, e)} />
            ))}
            {!consulta.isLoading && productos.length === 0 && (
              <tr>
                <td colSpan={7} className="px-3 py-4 text-center text-ink-soft">
                  {busquedaDebounced.trim() ? 'Sin resultados.' : 'Todavía no hay productos activos.'}
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
      {masPaginas}
      <p className="font-sans text-label-md text-ink-soft">
        Doble clic o ✎ para editar · Enter guarda · Esc cancela · <Lock className="inline h-3.5 w-3.5" aria-hidden /> precio
        calculado por costo (no se edita acá)
      </p>
    </div>
  )
}

function FilaProducto({
  producto,
  onGuardar,
}: {
  producto: ProductoInventarioTotal
  onGuardar: (e: Edicion) => Promise<string | null>
}) {
  const [edicion, setEdicion] = useState<Edicion | null>(null)
  const [errores, setErrores] = useState<ErroresFila>({})
  const [error, setError] = useState<string | null>(null)
  const [guardando, setGuardando] = useState(false)
  const conCosto = producto.costo !== null

  function empezar() {
    setEdicion(edicionDe(producto))
    setErrores({})
    setError(null)
  }

  async function confirmar() {
    if (!edicion || guardando) return
    const e = erroresEdicion(edicion)
    if (Object.keys(e).length > 0) {
      setErrores(e)
      return
    }
    setGuardando(true)
    const err = await onGuardar(edicion)
    setGuardando(false)
    if (err) setError(err)
    else setEdicion(null)
  }

  function onKeyDown(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'Enter') {
      e.preventDefault()
      void confirmar()
    }
    if (e.key === 'Escape') {
      e.preventDefault()
      setEdicion(null)
    }
  }

  const celda = 'px-3 py-3 align-top'
  const codigo = producto.codigo_barras ?? producto.codigo_interno ?? '—'

  if (edicion) {
    const input = (campo: keyof Edicion, label: string, extra: Record<string, unknown> = {}) => (
      <input
        aria-label={label}
        value={edicion[campo]}
        onChange={(e) => setEdicion({ ...edicion, [campo]: e.target.value, clientId: crypto.randomUUID() })}
        onKeyDown={onKeyDown}
        aria-invalid={!!errores[campo as keyof ErroresFila]}
        className={inputEscritorio}
        {...extra}
      />
    )
    return (
      <tr className="border-b border-table-divider bg-accent-light/40">
        <td className={`${celda} [overflow-wrap:anywhere]`}>{codigo}</td>
        <td className={celda}>{input('nombre', 'Nombre', { autoFocus: true })}</td>
        <td className={celda}>{input('marca', 'Marca')}</td>
        <td className={celda}>{input('descripcion', 'Descripción')}</td>
        <td className={celda}>
          <div className="flex items-center gap-1" title={conCosto ? TOOLTIP_COSTO : undefined}>
            {input('precio', 'Precio', { type: 'number', min: '0', step: '0.01', disabled: conCosto })}
            {conCosto && <Lock className="h-4 w-4 flex-shrink-0 text-ink-soft" aria-hidden />}
          </div>
          {conCosto && <span className="mt-0.5 block text-ink-soft">Precio por costo</span>}
        </td>
        <td className={celda}>{input('cantidad', 'Stock local', { type: 'number', min: '0', step: '1' })}</td>
        <td className={celda}>
          <div className="flex justify-end gap-1">
            <button
              type="button"
              onClick={() => void confirmar()}
              aria-label="Guardar cambios"
              disabled={guardando}
              className="rounded bg-accent p-1.5 text-white hover:bg-accent-dark disabled:opacity-60"
            >
              {guardando ? <Loader2 className="h-4 w-4 animate-spin" aria-hidden /> : <Check className="h-4 w-4" aria-hidden />}
            </button>
            <button type="button" onClick={() => setEdicion(null)} aria-label="Cancelar edición" className="rounded px-1.5 text-ink-soft hover:bg-bg">
              Esc
            </button>
          </div>
          {(error || Object.values(errores).some(Boolean)) && (
            <p role="alert" className="mt-1 text-error">
              {error ?? Object.values(errores).filter(Boolean).join(' ')}
            </p>
          )}
        </td>
      </tr>
    )
  }

  return (
    <tr className="border-b border-table-divider last:border-0 even:bg-table-row-alt" onDoubleClick={empezar}>
      <td className={`${celda} [overflow-wrap:anywhere]`}>{codigo}</td>
      <td className={`${celda} [overflow-wrap:anywhere] text-ink`}>{producto.nombre}</td>
      <td className={`${celda} [overflow-wrap:anywhere] text-ink-soft`}>{producto.marca}</td>
      <td className={`${celda} [overflow-wrap:anywhere] text-ink-soft`}>{producto.descripcion}</td>
      <td className={`${celda} text-right font-semibold text-accent-darker`} title={conCosto ? TOOLTIP_COSTO : undefined}>
        <span className="inline-flex items-center gap-1">
          {conCosto && <Lock className="h-3.5 w-3.5 text-ink-soft" aria-label="Precio por costo" />}
          {formatCurrency(producto.precio_venta)}
        </span>
      </td>
      <td className={`${celda} text-right`}>{formatCantidad(producto.stock_local)}</td>
      <td className={`${celda} text-right`}>
        <button
          type="button"
          onClick={empezar}
          aria-label={`Editar ${producto.nombre}`}
          title="Editar"
          className="rounded p-1.5 text-accent-dark hover:bg-accent-light"
        >
          <Pencil className="h-4 w-4" aria-hidden />
        </button>
      </td>
    </tr>
  )
}

function EditorProductoSheet({
  producto,
  guardando,
  onCancelar,
  onGuardar,
}: {
  producto: ProductoInventarioTotal
  guardando: boolean
  onCancelar: () => void
  onGuardar: (e: Edicion) => Promise<string | null>
}) {
  const [e, setE] = useState<Edicion>(() => edicionDe(producto))
  const [errores, setErrores] = useState<ErroresFila>({})
  const [error, setError] = useState<string | null>(null)
  const conCosto = producto.costo !== null

  async function confirmar() {
    const v = erroresEdicion(e)
    if (Object.keys(v).length > 0) {
      setErrores(v)
      return
    }
    setError(await onGuardar(e))
  }

  const campo = (k: keyof Edicion, label: string, extra: Record<string, unknown> = {}) => (
    <div className="flex flex-col gap-1">
      <label htmlFor={`total-${k}`} className="font-sans text-label-md text-ink">
        {label}
      </label>
      <input
        id={`total-${k}`}
        value={e[k]}
        onChange={(ev) => setE({ ...e, [k]: ev.target.value, clientId: crypto.randomUUID() })}
        aria-invalid={!!errores[k as keyof ErroresFila]}
        className={inputCelular}
        {...extra}
      />
      {errores[k as keyof ErroresFila] && <span className="font-sans text-label-md text-error">{errores[k as keyof ErroresFila]}</span>}
    </div>
  )

  return (
    <Dialogo
      celular
      title="Editar producto"
      onClose={onCancelar}
      footer={
        <BotonesDialogo celular onCancelar={onCancelar} onConfirmar={() => void confirmar()} confirmarLabel="Guardar" confirmando={guardando} />
      }
    >
      <div className="flex flex-col gap-3">
        <p className="font-sans text-label-md text-ink-soft">Código: {producto.codigo_barras ?? producto.codigo_interno ?? '—'}</p>
        {campo('nombre', 'Nombre')}
        {campo('marca', 'Marca')}
        {campo('descripcion', 'Descripción')}
        <div className="grid grid-cols-2 gap-2">
          {campo('precio', 'Precio', { type: 'number', inputMode: 'decimal', min: '0', step: '0.01', disabled: conCosto })}
          {campo('cantidad', 'Stock local', { type: 'number', inputMode: 'decimal', min: '0', step: '1' })}
        </div>
        {conCosto && (
          <p className="flex items-center gap-1 font-sans text-label-md text-ink-soft">
            <Lock className="h-4 w-4" aria-hidden /> {TOOLTIP_COSTO}
          </p>
        )}
        {error && (
          <p role="alert" className="rounded bg-error/10 px-3 py-2 font-sans text-body-md text-error">
            {error}
          </p>
        )}
      </div>
    </Dialogo>
  )
}
