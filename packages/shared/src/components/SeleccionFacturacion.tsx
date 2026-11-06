// Piezas de la selección de la tab Facturación (Local y Gestión), para que las dos apps muestren
// exactamente lo mismo. La lógica está en lib/seleccionFacturacion. Se importa por ruta
// (@virikyna/shared/src/components/SeleccionFacturacion), no desde index.ts.
import { useEffect, useRef } from 'react'
import { formatCurrency } from '../../lib/format'
import type { EstadoSeleccionarTodo, ResumenSeleccion } from '../../lib/seleccionFacturacion'

// Encabezado de la columna de checkboxes: tri-estado (ninguna / algunas / todas) sobre las visibles.
export function CheckboxSeleccionarTodo({
  estado,
  onToggle,
  disabled,
}: {
  estado: EstadoSeleccionarTodo
  onToggle: () => void
  disabled?: boolean
}) {
  const ref = useRef<HTMLInputElement>(null)
  // `indeterminate` no tiene atributo HTML: solo se fija por JS. El lector de pantalla lo anuncia "mixto".
  useEffect(() => {
    if (ref.current) ref.current.indeterminate = estado === 'algunas'
  }, [estado])

  return (
    <input
      ref={ref}
      type="checkbox"
      checked={estado === 'todas'}
      onChange={onToggle}
      disabled={disabled}
      aria-label="Seleccionar todo"
      title={estado === 'todas' ? 'Deseleccionar todo' : 'Seleccionar todo'}
      className="mt-0.5 h-4 w-4 cursor-pointer align-middle accent-accent disabled:cursor-default disabled:opacity-50"
    />
  )
}

function plural(n: number, singular: string, pluralTexto: string): string {
  return n === 1 ? singular : pluralTexto
}

// "N seleccionada(s) · $ X", el desglose si se mezclan estados y, si el lote de Factura C no es toda
// la selección, el aviso "Se emiten solo las N sin facturar." — va justo debajo del botón Emitir (en
// la fila de filtros no entra sin empujar los filtros a otra línea). Siempre montado (vacío sin
// selección) para que aria-live anuncie los cambios.
export function ResumenSeleccionFacturacion({
  resumen,
  className = '',
}: {
  resumen: ResumenSeleccion<unknown>
  className?: string
}) {
  const n = resumen.paraSumar.length
  const mezcla = resumen.sinFacturar.cantidad > 0 && resumen.facturadas.cantidad > 0
  const aviso = textoLoteFacturaC(resumen)
  return (
    <div aria-live="polite" className={className}>
      {n > 0 && (
        <div className="text-right font-sans text-ink-soft">
          <p className="text-body-md">
            {n} {plural(n, 'seleccionada', 'seleccionadas')} ·{' '}
            <span className="whitespace-nowrap font-semibold text-ink">{formatCurrency(resumen.total)}</span>
          </p>
          {mezcla && (
            <p className="text-label-md">
              <span className="whitespace-nowrap">
                Sin facturar: {resumen.sinFacturar.cantidad} · {formatCurrency(resumen.sinFacturar.total)}
              </span>
              {' — '}
              <span className="whitespace-nowrap">
                Facturadas: {resumen.facturadas.cantidad} · {formatCurrency(resumen.facturadas.total)}
              </span>
            </p>
          )}
          {aviso && <p className="text-label-md text-ink">{aviso}</p>}
        </div>
      )}
    </div>
  )
}

// Aviso chico bajo "Emitir Factura C" cuando la selección trae ventas que no se emiten
// (facturadas o a revisar). Null si todo lo tildado se puede emitir.
export function textoLoteFacturaC(resumen: ResumenSeleccion<unknown>): string | null {
  const total = resumen.paraSumar.length
  const n = resumen.paraEmitir.length
  if (total === 0 || n === total) return null
  // "Ninguna se puede facturar" y no "no hay sin facturar": una a revisar también es sin facturar.
  if (n === 0) return 'Ninguna de las seleccionadas se puede facturar.'
  return n === 1 ? 'Se emite solo la 1 sin facturar.' : `Se emiten solo las ${n} sin facturar.`
}

// La API corta en 1000 filas (max_rows de Supabase); las consultas de la tab piden ese tope explícito.
export const LIMITE_FILAS_FACTURACION = 1000

export function AvisoTopeFilasFacturacion({ cantidad }: { cantidad: number }) {
  if (cantidad < LIMITE_FILAS_FACTURACION) return null
  return (
    <p role="status" className="mt-2 rounded bg-amarillo/20 px-4 py-2 font-sans text-body-md text-ink">
      Se muestran las primeras {LIMITE_FILAS_FACTURACION} ventas. Acotá las fechas para ver todas.
    </p>
  )
}
