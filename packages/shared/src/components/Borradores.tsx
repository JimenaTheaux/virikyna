// Piezas de UI de borradores (docs/54) — las mismas en el modal de escritorio y en la página de
// Inventario; `size="touch"` agranda los botones para el celular (≥ 44 px).
import { useEffect, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import {
  eliminarBorrador,
  haceCuanto,
  SISTEMA_LABEL,
  type BorradorConNombres,
  type EstadoBorrador,
  type SistemaApp,
  type useBorradores,
} from '../../lib/borradores'
import { formatFechaHora } from '../../lib/format'
import { EstadoBadge } from './EstadoBadge'
import { ConfirmDialog } from './ConfirmDialog'

// "Borrador guardado hace 12 s" — discreto, al pie del formulario. Se refresca solo.
export function IndicadorBorrador({ estado }: { estado: EstadoBorrador }) {
  const [, setTick] = useState(0)
  useEffect(() => {
    const t = setInterval(() => setTick((n) => n + 1), 5000)
    return () => clearInterval(t)
  }, [])
  let texto: string | null = null
  let clase = 'text-ink-soft'
  if (estado.tipo === 'guardando') texto = 'Guardando borrador…'
  else if (estado.tipo === 'guardado') texto = `Borrador guardado ${haceCuanto(estado.en)}`
  else if (estado.tipo === 'sin_conexion') texto = 'Sin conexión: el borrador quedó en este equipo y se sube al volver la red'
  else if (estado.tipo === 'error') {
    texto = estado.mensaje
    clase = 'text-error'
  }
  return (
    <p role="status" aria-live="polite" className={`font-sans text-label-md ${clase}`}>
      {texto}
    </p>
  )
}

type AvisosProps = {
  estado: EstadoBorrador
  // Borrador retomado de otro usuario: "Creado por X · fecha hora".
  autorAjeno?: { nombre: string | null; creado: string } | null
  // Lo que cambió desde que se guardó (producto eliminado, proveedor que no existe…).
  avisosRestauracion?: string[]
  onRecargar?: () => void
  onGuardarComoNuevo?: () => void
  size?: 'compact' | 'touch'
}

export function AvisosBorrador({ estado, autorAjeno, avisosRestauracion = [], onRecargar, onGuardarComoNuevo, size = 'compact' }: AvisosProps) {
  const boton = `rounded border border-accent bg-surface px-3 font-sans text-label-bold text-accent-darker transition hover:bg-accent-light ${
    size === 'touch' ? 'min-h-11' : 'py-1.5'
  }`
  return (
    <>
      {autorAjeno && (
        <p className="rounded bg-badge-neutral-bg px-4 py-2 font-sans text-body-md text-ink">
          Creado por <strong>{autorAjeno.nombre ?? 'otro usuario'}</strong> · {formatFechaHora(autorAjeno.creado)}
        </p>
      )}
      {avisosRestauracion.length > 0 && (
        <div role="alert" className="rounded bg-badge-amber-bg px-4 py-2 font-sans text-body-md text-badge-amber-text">
          <p className="font-semibold">Cambió algo desde que se guardó el borrador:</p>
          <ul className="mt-1 list-disc pl-5">
            {avisosRestauracion.map((a) => (
              <li key={a}>{a}</li>
            ))}
          </ul>
        </div>
      )}
      {estado.tipo === 'conflicto' && (
        <div role="alert" className="flex flex-wrap items-center gap-3 rounded bg-badge-amber-bg px-4 py-2 font-sans text-body-md text-badge-amber-text">
          <p className="flex-1">
            <strong>{estado.editor ?? 'Otro usuario'}</strong> guardó cambios en este borrador a las{' '}
            {formatFechaHora(estado.en).split(' ')[1]}. El autoguardado se frenó para no pisarlos.
          </p>
          {onRecargar && (
            <button type="button" onClick={onRecargar} className={boton}>
              Recargar sus cambios
            </button>
          )}
        </div>
      )}
      {estado.tipo === 'eliminado' && (
        <div role="alert" className="flex flex-wrap items-center gap-3 rounded bg-badge-amber-bg px-4 py-2 font-sans text-body-md text-badge-amber-text">
          <p className="flex-1">Este borrador se eliminó o se confirmó desde otra pantalla. Lo cargado sigue acá.</p>
          {onGuardarComoNuevo && (
            <button type="button" onClick={onGuardarComoNuevo} className={boton}>
              Guardar como borrador nuevo
            </button>
          )}
        </div>
      )}
    </>
  )
}

type ListaProps<T> = {
  supabase: SupabaseClient
  sistema: SistemaApp
  lista: ReturnType<typeof useBorradores<T>>
  onRetomar: (borrador: BorradorConNombres<T>) => void
  // 'filas' (escritorio, arriba del listado de facturas) / 'tarjetas' (celular).
  variante?: 'filas' | 'tarjetas'
}

// Borradores de un formulario, con autor y última edición. Solo el sistema donde se creó puede
// seguir editándolo o eliminarlo (la RLS también lo frena); desde otro se ve, con el motivo.
// Sin borradores no muestra nada en 'filas' (el listado de facturas queda como siempre).
export function ListaBorradores<T>({ supabase, sistema, lista, onRetomar, variante = 'filas' }: ListaProps<T>) {
  const [aEliminar, setAEliminar] = useState<BorradorConNombres<T> | null>(null)
  const [eliminando, setEliminando] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const touch = variante === 'tarjetas'

  if (lista.borradores.length === 0) {
    if (!touch) return null
    return (
      <p className="font-sans text-body-md text-ink-soft">
        {lista.cargando ? 'Cargando borradores…' : 'No hay borradores de facturas.'}
      </p>
    )
  }

  async function eliminar(b: BorradorConNombres<T>) {
    setEliminando(true)
    const { error: dbError } = await eliminarBorrador(supabase, b.id)
    setEliminando(false)
    setAEliminar(null)
    if (dbError) setError('No se pudo eliminar el borrador.')
    lista.recargar()
  }

  const botonBase = `rounded px-3 font-sans text-label-bold transition ${touch ? 'min-h-11 flex-1' : 'py-1.5'}`

  return (
    <section aria-label="Borradores">
      {!touch && (
        <p className="font-sans text-label-bold text-ink">
          Borradores <span className="font-normal text-ink-soft">· no mueven stock, saldos ni caja hasta confirmarlos</span>
        </p>
      )}
      {(error || lista.error) && <p className="mt-1 font-sans text-label-md text-error">{error ?? lista.error}</p>}
      <ul className={`${touch ? 'flex flex-col gap-stack-sm' : 'mt-2 divide-y divide-table-divider rounded-xl border border-line bg-surface'}`}>
        {lista.borradores.map((b) => {
          const propio = b.sistema === sistema
          const motivo = propio ? undefined : `Creado en ${SISTEMA_LABEL[b.sistema]}`
          const editado = b.updated_at !== b.created_at
          return (
            <li
              key={b.id}
              className={
                touch
                  ? 'flex flex-col gap-2 rounded-lg border border-line bg-surface p-4 shadow-sm'
                  : 'flex flex-wrap items-center gap-x-4 gap-y-1 px-3 py-2.5'
              }
            >
              <div className={`flex min-w-0 items-center gap-2 ${touch ? '' : 'flex-1'}`}>
                <EstadoBadge variant="neutral">Borrador</EstadoBadge>
                <span className={`min-w-0 font-sans text-table-row text-ink ${touch ? '' : 'truncate'}`} title={b.resumen ?? undefined}>
                  {b.resumen || 'Sin datos todavía'}
                </span>
              </div>
              <p className="font-sans text-label-md text-ink-soft">
                {b.autor ?? '—'} · {formatFechaHora(b.created_at)}
                {editado && (
                  <>
                    {' '}· editado {formatFechaHora(b.updated_at)}
                    {b.editor && b.actualizado_por !== b.usuario_id ? ` por ${b.editor}` : ''}
                  </>
                )}
                {!propio && <> · {SISTEMA_LABEL[b.sistema]}</>}
              </p>
              <div className={`flex gap-2 ${touch ? '' : 'ml-auto'}`}>
                <button
                  type="button"
                  aria-disabled={!propio}
                  title={motivo}
                  onClick={() => propio && onRetomar(b)}
                  className={`${botonBase} border border-accent text-accent-darker ${
                    propio ? 'hover:bg-accent-light' : 'cursor-not-allowed opacity-50'
                  }`}
                >
                  Seguir editando
                </button>
                <button
                  type="button"
                  aria-disabled={!propio}
                  title={motivo}
                  onClick={() => propio && setAEliminar(b)}
                  className={`${botonBase} text-error ${propio ? 'hover:bg-error/10' : 'cursor-not-allowed opacity-50'}`}
                >
                  Eliminar
                </button>
              </div>
              {motivo && <span className="sr-only">{motivo}: solo se puede ver.</span>}
            </li>
          )
        })}
      </ul>

      {aEliminar && (
        <ConfirmDialog
          title="Eliminar borrador"
          mensaje={`Se elimina el borrador "${aEliminar.resumen ?? ''}". No hay nada que revertir: un borrador no movió stock, saldos ni caja.`}
          confirmLabel="Eliminar borrador"
          confirmando={eliminando}
          onCancel={() => setAEliminar(null)}
          onConfirm={() => void eliminar(aEliminar)}
        />
      )}
    </section>
  )
}
