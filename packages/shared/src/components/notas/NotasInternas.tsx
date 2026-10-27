import { useEffect, useMemo, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { NotaInternaConAutor, OrigenNota } from '../../../types/database'
import { formatFechaHora } from '../../../lib/format'
import { friendlyError } from '../../../lib/supabaseErrors'
import { ErrorText, inputClass } from '../FormField'
import { NuevaNotaModal } from './NuevaNotaModal'

// 6 colores del isologo Virikyna, rotando por card para que dos notas consecutivas nunca
// compartan color (docs/04_modulos_y_funciones.md, módulo 11).
const COLORES_MARCA = ['bg-amarillo', 'bg-rosa', 'bg-violeta', 'bg-celeste', 'bg-verde-agua', 'bg-accent'] as const

// Rotación leve por card para el efecto post-it desprolijo. Largo distinto al de
// COLORES_MARCA a propósito, para que color y ángulo no queden siempre pegados.
const ROTACIONES = [-2, 1.5, -1, 2, -1.5] as const

// Hilo: sangría hasta el 3er nivel de respuesta, más abajo sigue plano en ese nivel.
const NIVELES_CON_SANGRIA = 3
// Con más respuestas que esto, el hilo arranca colapsado ("Ver N respuestas").
const RESPUESTAS_SIN_COLAPSAR = 3

const botonAccion =
  'rounded px-2 py-1 font-sans text-ink/80 transition hover:bg-black/5 disabled:opacity-60 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent'

type Edicion = { tipo: 'responder' | 'editar'; notaId: string; texto: string }

type Props = {
  supabase: SupabaseClient
  // Cada app ve y crea solo las de su origen (docs/06 sección 15); la vista y la RLS lo refuerzan.
  origen: OrigenNota
  // Usuario logueado: crea, responde y edita las propias. Sin perfil todavía, solo lectura.
  usuarioId: string | null
}

// Notas internas tipo post-it con hilos de respuestas (docs/61) — misma pantalla en Local y Gestión.
// Responder: cualquiera. Editar: solo el autor (RPC editar_nota). Archivar / desarchivar: cualquiera,
// sobre la nota principal y con todo su hilo (RPC archivar_nota).
export function NotasInternas({ supabase, origen, usuarioId }: Props) {
  const [notas, setNotas] = useState<NotaInternaConAutor[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [modalNueva, setModalNueva] = useState(false)
  const [verArchivadas, setVerArchivadas] = useState(false)
  const [archivando, setArchivando] = useState<string | null>(null)
  const [edicion, setEdicion] = useState<Edicion | null>(null)
  const [errorEdicion, setErrorEdicion] = useState<string | null>(null)
  const [guardando, setGuardando] = useState(false)
  const [hilosAbiertos, setHilosAbiertos] = useState<Set<string>>(new Set())

  async function cargar() {
    setLoading(true)
    setError(null)
    // Vista con el nombre del autor ya resuelto (docs/16, docs/61): un cajero no tiene acceso
    // directo a la fila de `perfiles` de otro usuario. Filtro explícito por origen además del de
    // la vista: cada app nunca pide ni muestra las notas de la otra, ni siquiera a un admin.
    const { data, error: dbError } = await supabase
      .from('notas_internas_con_autor')
      .select('*')
      .eq('origen', origen)
      .order('created_at', { ascending: true })
    if (dbError) {
      setError(friendlyError(dbError))
    } else {
      setNotas((data ?? []) as NotaInternaConAutor[])
    }
    setLoading(false)
  }

  useEffect(() => {
    cargar()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [origen])

  // Principales: la más nueva primero. Respuestas: en orden de llegada, como una conversación.
  const { principales, respuestasDe } = useMemo(() => {
    const respuestasDe = new Map<string, NotaInternaConAutor[]>()
    const principales: NotaInternaConAutor[] = []
    for (const nota of notas) {
      if (nota.parent_id) respuestasDe.set(nota.parent_id, [...(respuestasDe.get(nota.parent_id) ?? []), nota])
      else principales.push(nota)
    }
    principales.reverse()
    return { principales, respuestasDe }
  }, [notas])

  const activas = principales.filter((n) => !n.archivada)
  const archivadas = principales.filter((n) => n.archivada)

  // Todas las respuestas de un hilo en orden de lectura (primero en profundidad), con su nivel.
  function aplanarHilo(notaId: string, nivel = 1): { nota: NotaInternaConAutor; nivel: number }[] {
    return (respuestasDe.get(notaId) ?? []).flatMap((r) => [{ nota: r, nivel }, ...aplanarHilo(r.id, nivel + 1)])
  }

  function empezar(tipo: Edicion['tipo'], nota: NotaInternaConAutor) {
    setErrorEdicion(null)
    setEdicion({ tipo, notaId: nota.id, texto: tipo === 'editar' ? nota.mensaje : '' })
  }

  async function guardarEdicion() {
    if (!edicion || guardando) return
    const texto = edicion.texto.trim()
    if (!texto) return setErrorEdicion('Escribí un mensaje.')
    setGuardando(true)
    setErrorEdicion(null)
    const { error: dbError } =
      edicion.tipo === 'responder'
        ? await supabase
            .from('notas_internas')
            .insert({ mensaje: texto, autor_id: usuarioId, origen, parent_id: edicion.notaId })
        : await supabase.rpc('editar_nota', { p_nota_id: edicion.notaId, p_mensaje: texto })
    setGuardando(false)
    if (dbError) return setErrorEdicion(friendlyError(dbError))
    // Al responder, el hilo queda abierto para ver la respuesta recién escrita.
    if (edicion.tipo === 'responder') {
      const raiz = principalDe(edicion.notaId)
      if (raiz) setHilosAbiertos((prev) => new Set(prev).add(raiz))
    }
    setEdicion(null)
    cargar()
  }

  function principalDe(notaId: string): string | null {
    let nota = notas.find((n) => n.id === notaId)
    while (nota?.parent_id) nota = notas.find((n) => n.id === nota!.parent_id)
    return nota?.id ?? null
  }

  async function archivar(nota: NotaInternaConAutor, archivar: boolean) {
    setArchivando(nota.id)
    setError(null)
    const { error: dbError } = await supabase.rpc('archivar_nota', { p_nota_id: nota.id, p_archivar: archivar })
    setArchivando(null)
    if (dbError) return setError(friendlyError(dbError))
    cargar()
  }

  function toggleHilo(id: string) {
    setHilosAbiertos((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  function renderEditor(chico: boolean) {
    if (!edicion) return null
    const respondiendo = edicion.tipo === 'responder'
    return (
      <div className="flex flex-col gap-2">
        <textarea
          autoFocus
          rows={chico ? 2 : 3}
          value={edicion.texto}
          aria-label={respondiendo ? 'Respuesta' : 'Editar nota'}
          placeholder={respondiendo ? 'Escribí una respuesta…' : undefined}
          onChange={(e) => setEdicion({ ...edicion, texto: e.target.value })}
          onKeyDown={(e) => {
            if (e.key === 'Escape') setEdicion(null)
            if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) guardarEdicion()
          }}
          className={`${inputClass} resize-none`}
        />
        {errorEdicion && <ErrorText>{errorEdicion}</ErrorText>}
        <div className="flex justify-end gap-2">
          <button type="button" onClick={() => setEdicion(null)} className={`${botonAccion} text-label-bold`}>
            Cancelar
          </button>
          <button
            type="button"
            onClick={guardarEdicion}
            disabled={guardando}
            className="rounded bg-accent px-3 py-1.5 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-60"
          >
            {guardando ? 'Guardando...' : respondiendo ? 'Responder' : 'Guardar'}
          </button>
        </div>
      </div>
    )
  }

  // Responder / Editar de una nota o respuesta. En un hilo archivado no se escribe: solo se lee.
  function renderAcciones(nota: NotaInternaConAutor, chico: boolean) {
    if (!usuarioId || nota.archivada || edicion) return null
    const texto = chico ? 'text-label-md font-semibold' : 'text-label-bold'
    return (
      <>
        <button type="button" onClick={() => empezar('responder', nota)} className={`${botonAccion} ${texto}`}>
          Responder
        </button>
        {nota.autor_id === usuarioId && (
          <button type="button" onClick={() => empezar('editar', nota)} className={`${botonAccion} ${texto}`}>
            Editar
          </button>
        )}
      </>
    )
  }

  function renderHilo(principal: NotaInternaConAutor) {
    const respuestas = aplanarHilo(principal.id)
    const respondiendoPrincipal = edicion?.tipo === 'responder' && edicion.notaId === principal.id
    if (respuestas.length === 0 && !respondiendoPrincipal) return null
    const colapsable = respuestas.length > RESPUESTAS_SIN_COLAPSAR
    const abierto = !colapsable || hilosAbiertos.has(principal.id)
    return (
      <div className="flex flex-col gap-2 border-t border-black/10 pt-2">
        {colapsable && (
          <button
            type="button"
            aria-expanded={abierto}
            onClick={() => toggleHilo(principal.id)}
            className={`${botonAccion} self-start text-label-md font-semibold text-accent-dark`}
          >
            {abierto ? 'Ocultar respuestas' : `Ver ${respuestas.length} respuestas`}
          </button>
        )}
        {abierto &&
          respuestas.map(({ nota, nivel }) => {
            const editando = edicion?.tipo === 'editar' && edicion.notaId === nota.id
            const respondiendo = edicion?.tipo === 'responder' && edicion.notaId === nota.id
            return (
              <div
                key={nota.id}
                style={{ marginLeft: `${(Math.min(nivel, NIVELES_CON_SANGRIA) - 1) * 0.75}rem` }}
                className="flex flex-col gap-1 border-l-2 border-black/10 pl-2.5"
              >
                <p className="font-sans text-label-md text-ink-soft">
                  <span className="font-semibold text-ink/80">{nota.autor_nombre}</span> · {formatFechaHora(nota.created_at)}
                  {nota.editada_at && ' · editada'}
                </p>
                {editando ? (
                  renderEditor(true)
                ) : (
                  <p className="whitespace-pre-wrap font-sans text-label-md text-ink [overflow-wrap:anywhere]">{nota.mensaje}</p>
                )}
                <div className="-ml-2 flex flex-wrap gap-1">{renderAcciones(nota, true)}</div>
                {respondiendo && renderEditor(true)}
              </div>
            )
          })}
        {respondiendoPrincipal && renderEditor(true)}
      </div>
    )
  }

  function renderTarjeta(nota: NotaInternaConAutor, i: number) {
    const archivada = nota.archivada
    const editando = edicion?.tipo === 'editar' && edicion.notaId === nota.id
    // Con un campo de texto adentro la card se endereza: escribir en diagonal incomoda.
    const escribiendoAca = edicion && principalDe(edicion.notaId) === nota.id
    const rotacion = archivada || escribiendoAca ? 0 : ROTACIONES[i % ROTACIONES.length]
    return (
      <article
        key={nota.id}
        style={rotacion ? { transform: `rotate(${rotacion}deg)` } : undefined}
        className={[
          'relative flex min-h-[180px] flex-col gap-stack-sm overflow-hidden rounded-lg p-card-sm',
          archivada ? 'bg-bg text-ink-soft' : 'bg-[#FFFDF6] shadow-md',
        ].join(' ')}
      >
        {!archivada && <span className={`absolute inset-x-0 top-0 h-1.5 ${COLORES_MARCA[i % COLORES_MARCA.length]}`} />}
        <span className="font-sans text-label-md text-ink-soft">
          {formatFechaHora(nota.created_at)}
          {nota.editada_at && ' · editada'}
        </span>
        {editando ? (
          renderEditor(false)
        ) : (
          <p className={`flex-1 whitespace-pre-wrap font-sans text-body-md [overflow-wrap:anywhere] ${archivada ? '' : 'text-ink'}`}>
            {nota.mensaje}
          </p>
        )}
        <div className="flex flex-col gap-1">
          <span className={`font-sans text-label-bold ${archivada ? '' : 'text-ink/80'}`}>{nota.autor_nombre}</span>
          <div className="-ml-2 flex flex-wrap gap-1">
            {renderAcciones(nota, false)}
            {!edicion && (
              <button
                type="button"
                onClick={() => archivar(nota, !archivada)}
                disabled={archivando === nota.id}
                className={`${botonAccion} text-label-bold`}
              >
                {archivada ? 'Desarchivar' : 'Archivar'}
              </button>
            )}
          </div>
        </div>
        {renderHilo(nota)}
      </article>
    )
  }

  const visibles = verArchivadas ? archivadas : activas

  return (
    <section className="flex h-full flex-col rounded-lg bg-surface p-card shadow-sm">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="font-display text-headline-lg text-accent-darker">Notas internas</h1>
        <div className="flex items-center gap-3">
          <button
            type="button"
            aria-pressed={verArchivadas}
            onClick={() => {
              setEdicion(null)
              setVerArchivadas((v) => !v)
            }}
            className={[
              'rounded-full border px-4 py-2 font-sans text-label-bold transition',
              'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-1',
              verArchivadas
                ? 'border-accent bg-accent-light text-accent-darker'
                : 'border-line bg-surface text-ink-soft hover:border-accent hover:text-accent-darker',
            ].join(' ')}
          >
            Ver archivadas ({archivadas.length})
          </button>
          {usuarioId && (
            <button
              type="button"
              onClick={() => setModalNueva(true)}
              className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark"
            >
              + Nueva nota
            </button>
          )}
        </div>
      </div>

      {error && (
        <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>
      )}

      <div className="mt-stack-md flex-1 overflow-auto">
        {loading && <p className="font-sans text-body-md text-ink-soft">Cargando...</p>}

        {!loading && visibles.length === 0 && (
          <p className="font-sans text-body-md text-ink-soft">
            {verArchivadas ? 'No hay notas archivadas.' : 'No hay notas activas todavía.'}
          </p>
        )}

        {!loading && visibles.length > 0 && (
          // items-start: una nota con hilo largo no estira a las de su fila.
          <div className="grid grid-cols-1 items-start gap-gutter-grid sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
            {visibles.map((nota, i) => renderTarjeta(nota, i))}
          </div>
        )}
      </div>

      {modalNueva && usuarioId && (
        <NuevaNotaModal
          supabase={supabase}
          autorId={usuarioId}
          origen={origen}
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
