import { useId } from 'react'
import { nombreConMarca } from '../../lib/productoTexto'
import type { ProductoSeleccionable } from '../../lib/useSeleccionProductos'
import { MostrarMas } from './MostrarMas'

type Props<P extends ProductoSeleccionable> = {
  sel: {
    seleccion: Set<string>
    busqueda: string
    buscar: (texto: string) => void
    soloTildados: boolean
    verSoloTildados: (valor: boolean) => void
    productosVisibles: P[]
    sinResultados: boolean
    restantes: number
    verMas: () => void
  }
  // Cada pantalla envuelve el tilde (ej. para descartar una vista previa vieja y marcar dirty).
  onToggle: (id: string) => void
  // Clase del campo de búsqueda de cada app (el de Inventario es más alto, para el pulgar).
  inputClassName: string
  // 'touch' (Inventario): filas de 48px y checkbox más grande.
  size?: 'compact' | 'touch'
  // Texto del contador (por defecto "N seleccionados"; IVA: "N exentos (sin IVA)").
  contador?: (n: number) => string
  // Con texto, muestra el filtro "ver solo los tildados" (IVA: "Ver solo los exentos").
  filtroTildados?: string
}

// Foco visible con contraste AA (accent-dark, 5,2:1 sobre blanco).
const FOCO = 'focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-dark'

// Buscador + lista tildable de las acciones masivas sobre productos (Actualizar precios, IVA):
// escritorio (Local, Gestión) y celular (Inventario). La lógica está en useSeleccionProductos.
export function ListaSeleccionProductos<P extends ProductoSeleccionable>({
  sel,
  onToggle,
  inputClassName,
  size = 'compact',
  contador: textoContador = (n) => `${n} seleccionado${n === 1 ? '' : 's'}`,
  filtroTildados,
}: Props<P>) {
  const id = useId()
  const touch = size === 'touch'
  const contador = (
    <p aria-live="polite" className={`font-sans text-label-bold text-ink ${touch ? '' : 'pb-2'}`}>
      {textoContador(sel.seleccion.size)}
    </p>
  )
  const filtro = filtroTildados && (
    <label className={`flex cursor-pointer items-center gap-2 font-sans text-label-md text-ink ${touch ? 'min-h-12' : ''}`}>
      <input
        type="checkbox"
        checked={sel.soloTildados}
        onChange={(e) => sel.verSoloTildados(e.target.checked)}
        className={`${touch ? 'h-5 w-5' : 'h-4 w-4'} accent-accent-dark ${FOCO}`}
      />
      {filtroTildados}
    </label>
  )
  const buscador = (
    <input
      id={`${id}-buscar`}
      type="search"
      value={sel.busqueda}
      onChange={(e) => sel.buscar(e.target.value)}
      // Enter (o "Ir" en el teclado del celular) solo busca: no envía el formulario de la acción
      // masiva, que sin nada tildado mostraba "Tildá al menos un producto".
      onKeyDown={(e) => {
        if (e.key === 'Enter') e.preventDefault()
      }}
      placeholder="Nombre, marca, código o proveedor"
      className={touch ? inputClassName : `${inputClassName} w-72 py-2`}
    />
  )

  return (
    <div className="flex flex-col gap-2">
      {touch ? (
        <>
          <label htmlFor={`${id}-buscar`} className="font-sans text-label-md text-ink">
            Buscar producto
          </label>
          {buscador}
          {filtro}
          {contador}
        </>
      ) : (
        <div className="flex items-end justify-between gap-3">
          <div className="flex flex-col gap-2">
            <label htmlFor={`${id}-buscar`} className="font-sans text-label-md text-ink">
              Buscar producto
            </label>
            <div className="flex items-center gap-4">
              {buscador}
              {filtro}
            </div>
          </div>
          {contador}
        </div>
      )}
      <ul
        className={
          touch
            ? 'overflow-hidden rounded-lg border border-line bg-surface'
            : 'overflow-hidden rounded-xl font-sans text-table-row shadow-sm'
        }
        aria-label="Productos"
      >
        {sel.productosVisibles.map((p) => (
          <li
            key={p.id}
            className={`flex items-center gap-3 border-b px-3 last:border-0 ${
              touch ? 'border-line' : 'border-table-divider even:bg-table-row-alt'
            }`}
          >
            <input
              id={`${id}-chk-${p.id}`}
              type="checkbox"
              checked={sel.seleccion.has(p.id)}
              onChange={() => onToggle(p.id)}
              aria-labelledby={`${id}-nom-${p.id}`}
              aria-describedby={`${id}-prv-${p.id}`}
              className={`${touch ? 'h-5 w-5' : 'h-4 w-4'} flex-shrink-0 accent-accent-dark ${FOCO}`}
            />
            {/* Toda la fila es tocable; el nombre accesible es solo el del producto. */}
            {touch ? (
              <label
                htmlFor={`${id}-chk-${p.id}`}
                className="flex min-h-12 flex-1 cursor-pointer flex-col justify-center py-2 active:bg-bg"
              >
                <span id={`${id}-nom-${p.id}`} className="font-sans text-body-md text-ink [overflow-wrap:anywhere]">
                  {nombreConMarca(p)}
                </span>
                <span id={`${id}-prv-${p.id}`} className="font-sans text-label-md text-ink-soft">
                  {p.proveedor?.razon_social ?? 'Sin proveedor'}
                </span>
              </label>
            ) : (
              <label htmlFor={`${id}-chk-${p.id}`} className="flex flex-1 cursor-pointer items-center gap-3 py-3">
                <span id={`${id}-nom-${p.id}`} className="text-ink [overflow-wrap:anywhere]">
                  {nombreConMarca(p)}
                </span>
                <span id={`${id}-prv-${p.id}`} className="ml-auto text-ink-soft">
                  {p.proveedor?.razon_social ?? 'Sin proveedor'}
                </span>
              </label>
            )}
          </li>
        ))}
        {sel.sinResultados && (
          <li className={`px-3 py-4 text-center ${touch ? 'font-sans text-body-md text-ink-soft' : 'text-ink-soft'}`}>
            Sin resultados.
          </li>
        )}
      </ul>
      <MostrarMas restantes={sel.restantes} onClick={sel.verMas} size={touch ? 'touch' : undefined} />
    </div>
  )
}
