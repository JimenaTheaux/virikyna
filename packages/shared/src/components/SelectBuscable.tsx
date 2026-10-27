import { useEffect, useId, useMemo, useRef, useState } from 'react'
import { textoParaBuscar } from '../../lib/texto'

export type OpcionBuscable = { value: string; label: string }

type Props = {
  // Nombre del filtro (aria-label del botón y del buscador): "Marca", "Proveedor".
  label: string
  value: string // '' = todas
  opciones: OpcionBuscable[]
  onChange: (value: string) => void
  todasLabel: string // "Todas las marcas" (primera opción de la lista)
  placeholder?: string // texto del botón sin nada elegido; por defecto todasLabel
  size?: 'compact' | 'touch'
  className?: string
}

// Con cientos de marcas, el desplegable muestra las primeras que coinciden; escribir acota.
const MAX_VISIBLES = 150

// Select compacto con buscador para filtros de listados (marca, proveedor). Botón que abre un
// panel con un campo de búsqueda y la lista; teclado: ↑ ↓ mueven, Enter elige, Esc cierra y
// devuelve el foco al botón. Clic afuera cierra sin cambiar nada.
export function SelectBuscable({
  label,
  value,
  opciones,
  onChange,
  todasLabel,
  placeholder = todasLabel,
  size = 'compact',
  className = '',
}: Props) {
  const [abierto, setAbierto] = useState(false)
  const [texto, setTexto] = useState('')
  const [activo, setActivo] = useState(0)
  const raizRef = useRef<HTMLDivElement>(null)
  const botonRef = useRef<HTMLButtonElement>(null)
  const listaRef = useRef<HTMLUListElement>(null)
  const listaId = useId()

  const elegida = opciones.find((o) => o.value === value)
  const filtradas = useMemo(() => {
    const q = textoParaBuscar(texto)
    const todas: OpcionBuscable[] = [{ value: '', label: todasLabel }, ...opciones]
    return (q ? todas.filter((o) => o.value && textoParaBuscar(o.label).includes(q)) : todas).slice(0, MAX_VISIBLES)
  }, [texto, opciones, todasLabel])

  useEffect(() => {
    if (!abierto) return
    function fuera(e: MouseEvent) {
      if (!raizRef.current?.contains(e.target as Node)) setAbierto(false)
    }
    document.addEventListener('mousedown', fuera)
    return () => document.removeEventListener('mousedown', fuera)
  }, [abierto])

  useEffect(() => {
    listaRef.current?.querySelector(`[data-indice="${activo}"]`)?.scrollIntoView({ block: 'nearest' })
  }, [activo])

  function abrir() {
    setTexto('')
    setActivo(Math.max(0, [{ value: '' }, ...opciones].findIndex((o) => o.value === value)))
    setAbierto(true)
  }

  function elegir(o: OpcionBuscable) {
    onChange(o.value)
    setAbierto(false)
    botonRef.current?.focus()
  }

  const alto = size === 'touch' ? 'min-h-12' : 'h-10'
  return (
    <div ref={raizRef} className={`relative ${className}`}>
      <button
        ref={botonRef}
        type="button"
        aria-haspopup="listbox"
        aria-expanded={abierto}
        aria-label={`${label}: ${elegida?.label ?? todasLabel}`}
        onClick={() => (abierto ? setAbierto(false) : abrir())}
        className={`flex w-full items-center justify-between gap-2 rounded border bg-surface px-3 font-sans text-body-md outline-none transition focus-visible:border-accent ${alto} ${
          value ? 'border-accent text-accent-darker' : 'border-line text-ink-soft hover:border-accent'
        }`}
      >
        <span className="truncate">{elegida?.label ?? placeholder}</span>
        <svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true" className="h-4 w-4 shrink-0">
          <path d="M5.5 7.5 10 12l4.5-4.5" stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round" />
        </svg>
      </button>

      {abierto && (
        <div className="absolute left-0 z-30 mt-1 w-72 max-w-[90vw] rounded-lg border border-line bg-surface p-2 shadow-lg">
          <input
            autoFocus
            type="text"
            role="combobox"
            aria-expanded="true"
            aria-controls={listaId}
            aria-activedescendant={`${listaId}-${activo}`}
            aria-label={`Buscar ${label.toLowerCase()}`}
            placeholder={`Buscar ${label.toLowerCase()}…`}
            value={texto}
            onChange={(e) => {
              setTexto(e.target.value)
              setActivo(0)
            }}
            onKeyDown={(e) => {
              if (e.key === 'ArrowDown') {
                e.preventDefault()
                setActivo((i) => Math.min(i + 1, filtradas.length - 1))
              } else if (e.key === 'ArrowUp') {
                e.preventDefault()
                setActivo((i) => Math.max(i - 1, 0))
              } else if (e.key === 'Enter') {
                e.preventDefault()
                if (filtradas[activo]) elegir(filtradas[activo])
              } else if (e.key === 'Escape') {
                e.preventDefault()
                e.stopPropagation()
                setAbierto(false)
                botonRef.current?.focus()
              }
            }}
            className={`w-full rounded border border-line bg-surface px-3 font-sans text-body-md text-ink outline-none focus:border-accent ${alto}`}
          />
          <ul ref={listaRef} id={listaId} role="listbox" aria-label={label} className="mt-1 max-h-64 overflow-auto">
            {filtradas.length === 0 && <li className="px-3 py-2 font-sans text-body-md text-ink-soft">Sin coincidencias</li>}
            {filtradas.map((o, i) => (
              <li
                key={o.value || '__todas'}
                id={`${listaId}-${i}`}
                data-indice={i}
                role="option"
                aria-selected={o.value === value}
                onMouseDown={(e) => e.preventDefault()}
                onClick={() => elegir(o)}
                onMouseEnter={() => setActivo(i)}
                className={`cursor-pointer truncate rounded px-3 font-sans text-body-md ${size === 'touch' ? 'py-3' : 'py-1.5'} ${
                  i === activo ? 'bg-accent-light text-accent-darker' : 'text-ink'
                } ${o.value === value ? 'font-semibold' : ''} ${o.value ? '' : 'text-ink-soft'}`}
              >
                {o.label}
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}
