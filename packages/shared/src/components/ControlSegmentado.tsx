import { useId } from 'react'

type Opcion<T extends string> = { value: T; label: string }

type Props<T extends string> = {
  legend: string
  opciones: Opcion<T>[]
  value: T
  onChange: (value: T) => void
  // 'touch' (Inventario): ancho completo y 48px de alto, cómodo con el pulgar.
  size?: 'compact' | 'touch'
}

// Selector excluyente con aspecto de pestañas. Por debajo son radios nativos (visualmente ocultos),
// así el teclado funciona como en cualquier grupo de radios — Tab entra al grupo, ← → cambian la
// opción — y el lector de pantalla anuncia "<legend>, <opción>, 1 de 2" sin ARIA a mano.
export function ControlSegmentado<T extends string>({ legend, opciones, value, onChange, size = 'compact' }: Props<T>) {
  const name = useId()
  const touch = size === 'touch'
  return (
    <fieldset className="flex flex-col gap-2">
      <legend className="mb-2 font-sans text-label-md text-ink">{legend}</legend>
      <div className={`${touch ? 'grid grid-cols-2' : 'inline-flex self-start'} gap-1 rounded border border-line bg-bg p-1`}>
        {opciones.map((o) => (
          <label key={o.value} className="relative">
            <input
              type="radio"
              name={name}
              value={o.value}
              checked={value === o.value}
              onChange={() => onChange(o.value)}
              className="peer sr-only"
            />
            <span
              className={`flex cursor-pointer items-center justify-center rounded-[8px] px-4 font-sans text-label-bold text-ink-soft transition hover:text-ink peer-checked:bg-surface peer-checked:text-accent-darker peer-checked:shadow-sm peer-focus-visible:outline peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-accent-dark ${
                touch ? 'min-h-12' : 'py-2'
              }`}
            >
              {o.label}
            </span>
          </label>
        ))}
      </div>
    </fieldset>
  )
}
