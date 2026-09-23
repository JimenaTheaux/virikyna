import { useEffect, useRef } from 'react'
import { ScanButton } from './ScanButton'

type Props = {
  value: string
  onChange: (value: string) => void
  placeholder?: string
  autoFocus?: boolean
}

// Buscador único de productos: acepta lector físico (el campo toma foco al montar y el escaneo
// entra como tipeo), nombre, marca y código, más el botón de escaneo por cámara/lector. El
// filtrado en sí lo hace el padre con `coincideBusquedaProducto` / `filtrarProductosPorBusqueda`.
export function ProductoBuscador({
  value,
  onChange,
  placeholder = 'Buscar por nombre, marca o código de barras…',
  autoFocus = true,
}: Props) {
  const inputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (autoFocus) inputRef.current?.focus()
  }, [autoFocus])

  return (
    <div className="flex min-w-0 flex-1 items-center gap-2">
      <div className="relative min-w-0 flex-1">
        <svg
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.75"
          strokeLinecap="round"
          className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-ink-soft"
          aria-hidden="true"
        >
          <circle cx="10.5" cy="10.5" r="6.5" />
          <path d="m20 20-4.35-4.35" />
        </svg>
        <input
          ref={inputRef}
          type="text"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          onKeyDown={(e) => {
            // El lector manda Enter al terminar el código; no hace falta más que el filtro en vivo.
            if (e.key === 'Enter') e.preventDefault()
          }}
          placeholder={placeholder}
          className="h-10 w-full rounded border border-line bg-surface pl-9 pr-3 font-sans text-body-md text-ink outline-none focus:border-accent"
        />
      </div>
      <ScanButton onDetect={onChange} onFocusCampo={() => inputRef.current?.focus()} />
    </div>
  )
}
