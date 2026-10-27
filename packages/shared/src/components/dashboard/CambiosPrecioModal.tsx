import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type { SupabaseClient } from '@supabase/supabase-js'
import { formatCurrency, formatFechaHora, formatFechaCortaLocal } from '../../../lib/format'
import { textoParaBuscar } from '../../../lib/texto'
import { friendlyError } from '../../../lib/supabaseErrors'
import { Modal } from '../Modal'
import { ConfirmDialog } from '../ConfirmDialog'
import {
  ORIGEN_PRECIO_LABEL,
  useCambiosPrecio,
  useMarcarEtiquetas,
  type CambioPrecio,
  type VistaCambiosPrecio,
} from './preciosCambiados'

const VISTAS: [VistaCambiosPrecio, string][] = [
  ['pendientes', 'Pendientes'],
  ['ultimos30', 'Últimos 30 días'],
]

// Etiqueta → actual. Un alta sin etiquetar no tiene "antes".
function Precios({ fila: f }: { fila: CambioPrecio }) {
  return (
    <span className="whitespace-nowrap">
      <span className="text-ink-soft">{f.precioAnterior === null ? 'Sin etiqueta' : formatCurrency(f.precioAnterior)}</span>
      <span aria-hidden="true" className="text-ink-soft">
        {' '}
        →{' '}
      </span>
      <span className="sr-only"> pasa a </span>
      <span className="font-semibold text-ink">{formatCurrency(f.precioActual)}</span>
    </span>
  )
}

// Flecha + número (no solo color). Nunca etiquetado (alta, aunque después lo haya tocado una
// factura): "Nuevo".
function Variacion({ valor, sinEtiqueta }: { valor: number | null; sinEtiqueta: boolean }) {
  if (valor === null) return <span className="text-ink-soft">{sinEtiqueta ? 'Nuevo' : '—'}</span>
  if (valor === 0) return <span className="text-ink-soft">= 0%</span>
  const sube = valor > 0
  return (
    <span className={`whitespace-nowrap font-semibold ${sube ? 'text-badge-amber-text' : 'text-accent-dark'}`}>
      <span aria-hidden="true">{sube ? '↑' : '↓'}</span> {Math.abs(valor).toLocaleString('es-AR')}%
      <span className="sr-only">{sube ? ' de aumento' : ' de baja'}</span>
    </span>
  )
}

// Listado para recorrer el local con la hoja en la mano: casilla vacía para tildar en papel,
// producto, código y precio nuevo grande. Se imprime solo esto (el resto de la página se oculta
// con @media print mientras está montado).
function ListadoImpresion({ filas, titulo, onListo }: { filas: CambioPrecio[]; titulo: string; onListo: () => void }) {
  const onListoRef = useRef(onListo)
  onListoRef.current = onListo
  useEffect(() => {
    const listo = () => onListoRef.current()
    window.addEventListener('afterprint', listo)
    // Un frame para que el portal esté pintado antes de abrir el diálogo de impresión.
    const id = requestAnimationFrame(() => window.print())
    return () => {
      cancelAnimationFrame(id)
      window.removeEventListener('afterprint', listo)
    }
  }, [])

  return createPortal(
    <div id="impresion-cambios-precio" className="hidden bg-white p-6 text-black print:block">
      <style>
        {'@media print { body { background: #fff !important; } body > *:not(#impresion-cambios-precio) { display: none !important; } @page { margin: 12mm; } }'}
      </style>
      <h1 className="text-[16pt] font-bold">{titulo}</h1>
      <p className="mb-3 text-[10pt]">
        {formatFechaHora(new Date().toISOString())} · {filas.length} producto{filas.length === 1 ? '' : 's'}
      </p>
      <table className="w-full border-collapse text-left text-[11pt]">
        <thead>
          <tr className="border-b-2 border-black">
            <th className="w-8 py-1">✓</th>
            <th className="py-1">Producto</th>
            <th className="py-1">Marca</th>
            <th className="py-1">Código</th>
            <th className="py-1 text-right">Etiqueta</th>
            <th className="py-1 text-right">Precio nuevo</th>
          </tr>
        </thead>
        <tbody>
          {filas.map((f) => (
            <tr key={f.productoId} className="break-inside-avoid border-b border-black/40">
              <td className="py-1.5">
                <span className="inline-block h-4 w-4 border border-black" />
              </td>
              <td className="py-1.5 pr-2">{f.nombre}</td>
              <td className="py-1.5 pr-2">{f.marca ?? ''}</td>
              <td className="py-1.5 pr-2 font-mono text-[9pt]">{f.codigoBarras ?? f.codigoInterno ?? ''}</td>
              <td className="whitespace-nowrap py-1.5 pr-3 text-right">{f.precioAnterior === null ? 'Nuevo' : formatCurrency(f.precioAnterior)}</td>
              <td className="whitespace-nowrap py-1.5 text-right text-[13pt] font-bold">{formatCurrency(f.precioActual)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>,
    document.body,
  )
}

// Modal de la alerta de precios (Dashboards de Local y Gestión). Pendientes: lo que hay que
// re-etiquetar, una fila por producto (anterior = precio de la etiqueta). Últimos 30 días: todo lo
// que cambió, con quién lo marcó. Se tildan filas y se confirman con "Etiqueta actualizada"; marcar
// no se deshace, por eso no es un clic por fila.
export function CambiosPrecioModal({ supabase, onClose }: { supabase: SupabaseClient; onClose: () => void }) {
  const [vista, setVista] = useState<VistaCambiosPrecio>('pendientes')
  const [busqueda, setBusqueda] = useState('')
  const [seleccion, setSeleccion] = useState<Set<string>>(new Set())
  const [confirmarTodas, setConfirmarTodas] = useState(false)
  const [aviso, setAviso] = useState<string | null>(null)
  const [imprimiendo, setImprimiendo] = useState(false)
  const buscadorRef = useRef<HTMLInputElement>(null)

  const pendientesQuery = useCambiosPrecio(supabase, 'pendientes')
  const query = useCambiosPrecio(supabase, vista)
  const marcar = useMarcarEtiquetas(supabase)

  const filas = query.data ?? []
  const q = textoParaBuscar(busqueda)
  const visibles = q
    ? filas.filter((f) => textoParaBuscar(`${f.nombre} ${f.marca ?? ''} ${f.codigoBarras ?? ''} ${f.codigoInterno ?? ''}`).includes(q))
    : filas
  const marcables = visibles.filter((f) => f.pendiente)
  const elegidas = marcables.filter((f) => seleccion.has(f.productoId))
  const todasElegidas = marcables.length > 0 && elegidas.length === marcables.length
  const nPendientes = pendientesQuery.data?.length

  function cambiarVista(v: VistaCambiosPrecio) {
    setVista(v)
    setSeleccion(new Set())
    setAviso(null)
  }

  function alternar(id: string) {
    setSeleccion((prev) => {
      const sig = new Set(prev)
      if (sig.has(id)) sig.delete(id)
      else sig.add(id)
      return sig
    })
  }

  async function marcarFilas(lista: CambioPrecio[]) {
    setAviso(null)
    try {
      const marcadas = await marcar.mutateAsync(lista)
      setSeleccion(new Set())
      setAviso(
        marcadas === lista.length
          ? `${marcadas} etiqueta${marcadas === 1 ? '' : 's'} marcada${marcadas === 1 ? '' : 's'} como actualizada${marcadas === 1 ? '' : 's'}.`
          : `Se marcaron ${marcadas} de ${lista.length}: el resto cambió de precio o ya estaba marcado. La lista se actualizó.`,
      )
    } catch (e) {
      setAviso(friendlyError(e as never))
    }
    // El botón se deshabilita mientras marca y la fila tildada desaparece: sin esto el foco queda
    // en <body>, fuera del modal, y Esc deja de cerrarlo.
    buscadorRef.current?.focus()
  }

  const titulo = 'Cambios de precio'

  return (
    <Modal title={titulo} onClose={onClose} widthClassName="max-w-[980px]" dialogo={{ onEscape: onClose }}>
      <div className="flex flex-col gap-3">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div role="tablist" aria-label="Vista" className="flex gap-1 rounded-full bg-bg p-0.5">
            {VISTAS.map(([id, label]) => (
              <button
                key={id}
                type="button"
                role="tab"
                aria-selected={vista === id}
                onClick={() => cambiarVista(id)}
                className={`rounded-full px-3 py-1 font-sans text-label-bold transition ${
                  vista === id ? 'bg-surface text-accent-darker shadow-sm' : 'text-ink-soft hover:text-accent-darker'
                }`}
              >
                {label}
                {id === 'pendientes' && nPendientes !== undefined && ` (${nPendientes})`}
              </button>
            ))}
          </div>
          <input
            ref={buscadorRef}
            type="search"
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar producto, marca o código"
            aria-label="Buscar producto, marca o código"
            className="min-w-[12rem] flex-1 rounded border border-line bg-surface px-3 py-2 font-sans text-body-md text-ink outline-none focus:border-accent"
          />
          <button
            type="button"
            onClick={() => setImprimiendo(true)}
            disabled={visibles.length === 0}
            className="rounded border border-line px-3 py-2 font-sans text-label-bold text-accent-dark transition hover:bg-accent-light disabled:opacity-50"
          >
            Imprimir listado
          </button>
        </div>

        <p className="font-sans text-label-md text-ink-soft">
          {vista === 'pendientes'
            ? 'Productos cuyo precio no coincide con la etiqueta del local. "Etiqueta" es el precio que tiene hoy la etiqueta.'
            : 'Todo lo que cambió de precio en los últimos 30 días. "Etiqueta" es el precio antes del primer cambio del período.'}
        </p>

        {aviso && (
          <p role="status" className="rounded bg-accent-light px-3 py-2 font-sans text-label-md text-accent-darker">
            {aviso}
          </p>
        )}

        {query.isPending ? (
          <p className="py-2 font-sans text-body-md text-ink-soft">Cargando…</p>
        ) : query.isError ? (
          <p className="rounded bg-error/10 px-3 py-2 font-sans text-body-md text-error">{friendlyError(query.error as never)}</p>
        ) : visibles.length === 0 ? (
          <p className="py-2 font-sans text-body-md text-ink-soft">
            {filas.length === 0
              ? vista === 'pendientes'
                ? 'No hay etiquetas pendientes: todos los precios coinciden con el local.'
                : 'Sin cambios de precio en los últimos 30 días.'
              : 'Ningún producto coincide con la búsqueda.'}
          </p>
        ) : (
          <div className="max-h-[50vh] overflow-auto rounded">
            <table className="w-full table-fixed text-left font-sans text-table-row">
              <colgroup>
                <col className="w-10" />
                <col className="w-[8.5rem]" />
                <col />
                <col className="w-32" />
                <col className="w-[13.5rem]" />
                <col className="w-20" />
                <col className="w-24" />
              </colgroup>
              <thead className="sticky top-0 z-10">
                <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
                  <th className="px-2 py-2">
                    <input
                      type="checkbox"
                      checked={todasElegidas}
                      disabled={marcables.length === 0}
                      onChange={() => setSeleccion(todasElegidas ? new Set() : new Set(marcables.map((f) => f.productoId)))}
                      aria-label="Tildar todas las visibles"
                      className="h-4 w-4 accent-accent"
                    />
                  </th>
                  <th className="px-2 py-2">Fecha</th>
                  <th className="px-2 py-2">Producto</th>
                  <th className="px-2 py-2">Marca</th>
                  <th className="px-2 py-2">Etiqueta → Actual</th>
                  <th className="px-2 py-2 text-right">Var.</th>
                  <th className="px-2 py-2">Origen</th>
                </tr>
              </thead>
              <tbody>
                {visibles.map((f) => (
                  <tr key={f.productoId} className="border-b border-table-divider last:border-0 even:bg-table-row-alt">
                    <td className="px-2 py-1">
                      {f.pendiente ? (
                        <input
                          type="checkbox"
                          checked={seleccion.has(f.productoId)}
                          onChange={() => alternar(f.productoId)}
                          aria-label={`Etiqueta actualizada: ${f.nombre}`}
                          className="h-4 w-4 accent-accent"
                        />
                      ) : (
                        <span
                          className="font-semibold text-success"
                          title={
                            f.marcadoAt
                              ? `Etiquetada${f.marcadoPor ? ` por ${f.marcadoPor}` : ''} el ${formatFechaHora(f.marcadoAt)}`
                              : 'Etiqueta al día'
                          }
                        >
                          ✓<span className="sr-only"> etiqueta al día</span>
                        </span>
                      )}
                    </td>
                    <td className="whitespace-nowrap px-2 py-1 text-ink-soft" title={formatFechaHora(f.fechaCambio)}>
                      {formatFechaCortaLocal(f.fechaCambio)}
                    </td>
                    <td className="truncate px-2 py-1 text-ink" title={f.nombre}>
                      {f.nombre}
                    </td>
                    <td className="truncate px-2 py-1 text-ink-soft" title={f.marca ?? undefined}>
                      {f.marca ?? '—'}
                    </td>
                    <td className="px-2 py-1">
                      <Precios fila={f} />
                    </td>
                    <td className="px-2 py-1 text-right">
                      <Variacion valor={f.variacion} sinEtiqueta={f.precioAnterior === null} />
                    </td>
                    <td className="truncate px-2 py-1 text-ink-soft">{ORIGEN_PRECIO_LABEL[f.origen] ?? f.origen}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {marcables.length > 0 && (
          <div className="flex flex-wrap items-center justify-end gap-2 border-t border-table-divider pt-3">
            <button
              type="button"
              onClick={() => setConfirmarTodas(true)}
              disabled={marcar.isPending}
              className="rounded border border-line px-3 py-2 font-sans text-label-bold text-accent-dark transition hover:bg-accent-light disabled:opacity-50"
            >
              Marcar todas ({marcables.length})
            </button>
            <button
              type="button"
              onClick={() => marcarFilas(elegidas)}
              disabled={elegidas.length === 0 || marcar.isPending}
              className="rounded bg-accent px-4 py-2 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-50"
            >
              {marcar.isPending ? 'Marcando…' : `Etiqueta actualizada${elegidas.length > 0 ? ` (${elegidas.length})` : ''}`}
            </button>
          </div>
        )}
      </div>

      {confirmarTodas && (
        <ConfirmDialog
          title="Marcar todas"
          mensaje={`¿Marcar ${marcables.length} etiqueta${marcables.length === 1 ? '' : 's'} como actualizada${
            marcables.length === 1 ? '' : 's'
          }? ${busqueda ? 'Son las que coinciden con la búsqueda. ' : ''}No se puede deshacer.`}
          confirmLabel="Marcar todas"
          confirmando={marcar.isPending}
          onCancel={() => setConfirmarTodas(false)}
          onConfirm={async () => {
            await marcarFilas(marcables)
            setConfirmarTodas(false)
          }}
        />
      )}

      {imprimiendo && (
        <ListadoImpresion
          filas={visibles}
          titulo={vista === 'pendientes' ? 'Etiquetas a cambiar' : 'Cambios de precio (últimos 30 días)'}
          onListo={() => setImprimiendo(false)}
        />
      )}
    </Modal>
  )
}
