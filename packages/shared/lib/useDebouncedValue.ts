import { useEffect, useState } from 'react'

// Debounce genérico para inputs de búsqueda que disparan una consulta de red — evita golpear la
// base de datos en cada tecla tipeada.
export function useDebouncedValue<T>(value: T, delayMs = 250): T {
  const [debounced, setDebounced] = useState(value)

  useEffect(() => {
    const timer = setTimeout(() => setDebounced(value), delayMs)
    return () => clearTimeout(timer)
  }, [value, delayMs])

  return debounced
}
