import { useId } from 'react'

type Opcion<T extends string> = { value: T; label: string }

type Props<T extends string> = {
  legend: string
  opciones: Opcion<T>[]
  value: T
  onChange: (value: T) => void
  // 'touch' (Inventario): ancho completo (columnas iguales, las que haya) y 48px de alto, cómodo con el pulgar.
  size?: 'compact' | 'touch'
  // Deshabilita el grupo entero (fieldset disabled): se ve la opción elegida pero no se cambia.
  disabled?: boolean
  // La opción elegida en teal lleno (accent-dark, texto blanco) en vez de la pestaña blanca: para
  // una elección que cambia el formulario entero (tipo de compra, docs/53) y no se puede pasar por alto.
  resaltado?: boolean
  // En una barra de filtros (Inventario): la leyenda queda solo para el lector de pantalla.
  ocultarLegend?: boolean
}

// Selector excluyente con aspecto de pestañas. Por debajo son radios nativos (visualmente ocultos),
// así el teclado funciona como en cualquier grupo de radios — Tab entra al grupo, ← → cambian la
// opción — y el lector de pantalla anuncia "<legend>, <opción>, 1 de 2" sin ARIA a mano.
export function ControlSegmentado<T extends string>({
  legend,
  opciones,
  value,
  onChange,
  size = 'compact',
  disabled = false,
  resaltado = false,
  ocultarLegend = false,
}: Props<T>) {
  const name = useId()
  const touch = size === 'touch'
  return (
    <fieldset disabled={disabled} className="flex flex-col gap-2">
      <legend className={ocultarLegend ? 'sr-only' : 'mb-2 font-sans text-label-md text-ink'}>{legend}</legend>
      <div
        className={`${touch ? 'grid auto-cols-fr grid-flow-col' : 'inline-flex self-start'} gap-1 rounded border border-line bg-bg p-1 ${
          disabled ? 'opacity-60' : ''
        }`}
      >
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
              className={`flex cursor-pointer items-center justify-center rounded-[8px] px-4 font-sans text-label-bold text-ink-soft transition hover:text-ink peer-checked:shadow-sm ${
                resaltado
                  ? 'peer-checked:bg-accent-dark peer-checked:text-white peer-checked:hover:text-white'
                  : 'peer-checked:bg-surface peer-checked:text-accent-darker'
              } peer-focus-visible:outline peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-accent-dark peer-disabled:cursor-not-allowed peer-disabled:hover:text-ink-soft ${
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
