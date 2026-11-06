import { useRef, type KeyboardEvent, type ReactNode } from 'react'

export type Pestana<T extends string> = { id: T; label: string }

type Props<T extends string> = {
  // Nombre del grupo para el lector de pantalla (ej. "Secciones del producto").
  label: string
  // Prefijo de ids (useId del que las usa): une cada pestaña con su panel (aria-controls / aria-labelledby).
  idBase: string
  pestanas: Pestana<T>[]
  activa: T
  onChange: (id: T) => void
}

export const idPestana = (idBase: string, id: string) => `${idBase}-pestana-${id}`
export const idPanelPestana = (idBase: string, id: string) => `${idBase}-panel-${id}`

// Pestañas de un modal (Datos / Historial…), patrón WAI-ARIA "tabs" con activación automática:
// Tab entra a la pestaña activa y sale al panel; ← → (y Inicio / Fin) cambian de pestaña y la
// activan. Mismo aspecto que las que tenían escritas a mano ProductoFormModal y ProductoFormSheet.
export function Pestanas<T extends string>({ label, idBase, pestanas, activa, onChange }: Props<T>) {
  const refs = useRef<(HTMLButtonElement | null)[]>([])

  function onKeyDown(e: KeyboardEvent<HTMLButtonElement>, i: number) {
    const n = pestanas.length
    const destino =
      e.key === 'ArrowRight' ? (i + 1) % n
      : e.key === 'ArrowLeft' ? (i - 1 + n) % n
      : e.key === 'Home' ? 0
      : e.key === 'End' ? n - 1
      : null
    if (destino === null) return
    e.preventDefault()
    onChange(pestanas[destino].id)
    refs.current[destino]?.focus()
  }

  return (
    <div role="tablist" aria-label={label} className="mb-stack-md flex gap-1 border-b border-line">
      {pestanas.map((p, i) => {
        const seleccionada = p.id === activa
        return (
          <button
            key={p.id}
            ref={(el) => {
              refs.current[i] = el
            }}
            type="button"
            role="tab"
            id={idPestana(idBase, p.id)}
            aria-selected={seleccionada}
            aria-controls={idPanelPestana(idBase, p.id)}
            tabIndex={seleccionada ? 0 : -1}
            onClick={() => onChange(p.id)}
            onKeyDown={(e) => onKeyDown(e, i)}
            className={`rounded-t px-4 py-2 font-sans text-label-bold focus-visible:outline focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent-dark ${
              seleccionada ? 'border-b-2 border-accent text-accent-darker' : 'text-ink-soft hover:text-accent-darker'
            }`}
          >
            {p.label}
          </button>
        )
      })}
    </div>
  )
}

// Panel de la pestaña `id` (solo se renderiza el activo). idBase null = la pantalla no muestra
// pestañas (ej. el alta de un producto): solo el contenido, sin role="tabpanel".
export function PanelPestana({ idBase, id, children }: { idBase: string | null; id: string; children: ReactNode }) {
  if (idBase === null) return <>{children}</>
  return (
    <div role="tabpanel" id={idPanelPestana(idBase, id)} aria-labelledby={idPestana(idBase, id)}>
      {children}
    </div>
  )
}
