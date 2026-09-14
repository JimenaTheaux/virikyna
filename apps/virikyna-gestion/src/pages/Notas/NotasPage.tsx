import { useEffect, useMemo, useState } from 'react'
import type { NotaInternaConAutor } from '@virikyna/shared'
import { formatFechaHora, friendlyError } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { usePerfil } from '../../auth/AuthContext'
import { NuevaNotaModal } from './NuevaNotaModal'

// 6 colores del isologo Virikyna, rotando por card para que dos notas consecutivas nunca
// compartan color (docs/04_modulos_y_funciones.md, módulo 11).
const COLORES_MARCA = ['bg-amarillo', 'bg-rosa', 'bg-violeta', 'bg-celeste', 'bg-verde-agua', 'bg-accent'] as const

// Rotación leve por card para el efecto post-it desprolijo. Largo distinto al de
// COLORES_MARCA a propósito, para que color y ángulo no queden siempre pegados.
const ROTACIONES = [-2, 1.5, -1, 2, -1.5] as const

export function NotasPage() {
  const { perfil } = usePerfil()
  const [notas, setNotas] = useState<NotaInternaConAutor[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [modalNueva, setModalNueva] = useState(false)
  const [verArchivadas, setVerArchivadas] = useState(false)
  const [archivando, setArchivando] = useState<string | null>(null)

  async function cargar() {
    setLoading(true)
    setError(null)
    // Vista con el nombre del autor ya resuelto (docs/16_notas_internas.sql).
    // Filtro explícito por origen='gestion' (docs/06_estructura_de_datos (1).md sección 15):
    // Gestión ya no comparte notas 1:1 con Local — cada app ve solo las de su propio origen,
    // y esto además evita depender solo de RLS para que un cajero no llegue a ver una de acá.
    const { data, error: dbError } = await supabase
      .from('notas_internas_con_autor')
      .select('*')
      .eq('origen', 'gestion')
      .order('created_at', { ascending: false })
    if (dbError) {
      setError(friendlyError(dbError))
    } else {
      setNotas((data ?? []) as NotaInternaConAutor[])
    }
    setLoading(false)
  }

  useEffect(() => {
    cargar()
  }, [])

  const activas = useMemo(() => notas.filter((n) => !n.archivada), [notas])
  const archivadas = useMemo(() => notas.filter((n) => n.archivada), [notas])

  async function archivar(nota: NotaInternaConAutor) {
    setArchivando(nota.id)
    const { error: dbError } = await supabase
      .from('notas_internas')
      .update({ archivada: true, archivada_at: new Date().toISOString() })
      .eq('id', nota.id)
    setArchivando(null)
    if (dbError) {
      setError(friendlyError(dbError))
      return
    }
    cargar()
  }

  return (
    <section className="flex h-full flex-col rounded-lg bg-surface p-card shadow-sm">
      <div className="flex items-center justify-between">
        <h1 className="font-display text-headline-lg text-accent-darker">Notas internas</h1>
        {perfil && (
          <button
            type="button"
            onClick={() => setModalNueva(true)}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark"
          >
            + Nueva nota
          </button>
        )}
      </div>

      {error && (
        <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>
      )}

      <div className="mt-stack-md flex-1 overflow-auto">
        {loading && <p className="font-sans text-body-md text-ink-soft">Cargando...</p>}

        {!loading && activas.length === 0 && (
          <p className="font-sans text-body-md text-ink-soft">No hay notas activas todavía.</p>
        )}

        {!loading && activas.length > 0 && (
          <div className="grid grid-cols-1 gap-gutter-grid sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
            {activas.map((nota, i) => (
              <div
                key={nota.id}
                style={{ transform: `rotate(${ROTACIONES[i % ROTACIONES.length]}deg)` }}
                className="relative flex min-h-[180px] flex-col justify-between gap-stack-sm overflow-hidden rounded-lg bg-[#FFFDF6] p-card-sm shadow-md"
              >
                <span className={`absolute inset-x-0 top-0 h-1.5 ${COLORES_MARCA[i % COLORES_MARCA.length]}`} />
                <span className="font-sans text-label-md text-ink-soft">{formatFechaHora(nota.created_at)}</span>
                <p className="flex-1 whitespace-pre-wrap font-sans text-body-md text-ink">{nota.mensaje}</p>
                <div className="flex items-center justify-between gap-3">
                  <span className="font-sans text-label-bold text-ink/80">{nota.autor_nombre}</span>
                  <button
                    type="button"
                    onClick={() => archivar(nota)}
                    disabled={archivando === nota.id}
                    className="rounded px-3 py-1.5 font-sans text-label-bold text-ink/80 transition hover:bg-black/5 disabled:opacity-60"
                  >
                    Archivar
                  </button>
                </div>
              </div>
            ))}
          </div>
        )}

        <button
          type="button"
          onClick={() => setVerArchivadas((v) => !v)}
          className="mt-stack-lg font-sans text-label-bold text-accent-dark hover:text-accent-darker"
        >
          {verArchivadas ? 'Ocultar archivadas' : `Ver archivadas (${archivadas.length})`}
        </button>

        {verArchivadas && (
          <div className="mt-stack-md grid grid-cols-1 gap-gutter-grid sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
            {archivadas.length === 0 && (
              <p className="font-sans text-body-md text-ink-soft">No hay notas archivadas.</p>
            )}
            {archivadas.map((nota) => (
              <div
                key={nota.id}
                className="flex min-h-[180px] flex-col justify-between gap-stack-sm rounded-lg bg-bg p-card-sm text-ink-soft"
              >
                <span className="font-sans text-label-md">{formatFechaHora(nota.created_at)}</span>
                <p className="flex-1 whitespace-pre-wrap font-sans text-body-md line-through">{nota.mensaje}</p>
                <span className="font-sans text-label-bold">{nota.autor_nombre}</span>
              </div>
            ))}
          </div>
        )}
      </div>

      {modalNueva && perfil && (
        <NuevaNotaModal
          autorId={perfil.id}
          onClose={() => setModalNueva(false)}
          onSaved={() => {
            setModalNueva(false)
            cargar()
          }}
        />
      )}
    </section>
  )
}
