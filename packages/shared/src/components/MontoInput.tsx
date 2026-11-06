import { forwardRef, useEffect, useId, useLayoutEffect, useRef, useState, type InputHTMLAttributes } from 'react'
import { montoEditable, parseMonto } from '../../lib/parseMonto'
import { formatCurrency } from '../../lib/format'
import { inputClass } from './FormField'

// Campo de importe con formato argentino (docs/DIAGNOSTICO_ENTER_Y_FORMATO_IMPORTES.md, sección B).
// Contrato igual al de los <input type="number"> que reemplaza: `value` y `onChange` con el string
// normalizado ("4500.40", '' vacío). El estado de los formularios y sus cálculos no cambian.
//   Con foco: editable sin $ ni miles ("4500,40").   Sin foco: "$ 4.500,40".
// Lee "4.500" como 4500 y "4500.40" como 4500,40 (criterio de la dueña, lib/parseMonto.ts).
// Si lo escrito no es un monto: borde de error, mensaje debajo y onChange(MONTO_INVALIDO), que da
// NaN con Number(): las validaciones de cada formulario lo frenan como antes frenaban un campo vacío.

export const MONTO_INVALIDO = 'monto-invalido'

type Props = Omit<InputHTMLAttributes<HTMLInputElement>, 'value' | 'onChange' | 'type' | 'min' | 'max' | 'step'> & {
  value: string
  onChange: (valor: string) => void
  min?: number // por defecto no se aceptan negativos; min agrega un piso (ej. 1)
  negativo?: boolean // acepta montos negativos (ej. saldo inicial a favor)
  className?: string // por defecto inputClass; las tablas pasan su clase de celda
  sinMensaje?: boolean // el error se marca solo con el borde (celdas angostas con su propio aviso)
}

function motivoInvalido(texto: string, negativo: boolean, min: number | undefined, valor: string | null): string {
  if (valor !== null && min !== undefined && Number(valor) < min) return `El mínimo es ${formatCurrency(min)}.`
  if (!negativo && /^\s*[-−]/.test(texto)) return 'No puede ser negativo.'
  if (/[.,]\d{3,}$/.test(texto.trim()) && /,/.test(texto)) return 'Hasta 2 decimales.'
  return 'No es un monto válido. Escribí, por ejemplo, 4.500,40 o 4500.40.'
}

export const MontoInput = forwardRef<HTMLInputElement, Props>(function MontoInput(
  { value, onChange, min, negativo = false, className, sinMensaje = false, onFocus, onBlur, ...resto },
  ref,
) {
  const idError = useId()
  const inputRef = useRef<HTMLInputElement | null>(null)
  // Al tomar el foco el texto cambia ("$ 4.500,40" → "4500,40") y el navegador pierde la selección.
  // Si entró con el teclado (Tab, Enter = Tab) o por código (autofoco), se selecciona todo: tipear
  // reemplaza el monto, como en Excel. Si entró con un clic, el cursor queda donde se hizo clic.
  const seleccionarAlEditar = useRef<boolean | null>(null)
  const conClic = useRef(false)
  const [editando, setEditando] = useState(false)
  const [texto, setTexto] = useState('') // lo que la persona escribe mientras tiene el foco
  const [error, setError] = useState<string | null>(null)

  // El formulario cambió el valor desde afuera (reset tras guardar, monto que sigue a otro): el
  // error de lo que se había tipeado ya no aplica.
  useEffect(() => {
    if (!editando && value !== MONTO_INVALIDO) setError(null)
  }, [value, editando])

  useLayoutEffect(() => {
    const el = inputRef.current
    if (!editando || !el || seleccionarAlEditar.current === null || document.activeElement !== el) return
    if (seleccionarAlEditar.current) el.select()
    seleccionarAlEditar.current = null
  }, [editando])

  const numero = value === '' || value === MONTO_INVALIDO ? NaN : Number(value)
  const invalido = value === MONTO_INVALIDO || error !== null
  const mostrado = editando
    ? texto
    : value === MONTO_INVALIDO
      ? error !== null
        ? texto // lo que la persona tipeó acá, para que lo corrija
        : '' // copia de otro campo inválido (ej. el medio que sigue al total)
      : Number.isFinite(numero)
        ? formatCurrency(numero)
        : value // vacío, o un valor viejo sin normalizar: se muestra tal cual

  function cambiar(t: string) {
    setTexto(t)
    const valor = parseMonto(t, { negativo })
    if (valor === null || (valor !== '' && min !== undefined && Number(valor) < min)) {
      setError(motivoInvalido(t, negativo, min, valor))
      onChange(MONTO_INVALIDO)
      return
    }
    setError(null)
    onChange(valor)
  }

  const ariaInvalid = invalido || resto['aria-invalid'] === true || resto['aria-invalid'] === 'true'
  // El mensaje va solo en el campo donde se tipeó; uno que copia el valor de otro muestra el borde.
  const conMensaje = error !== null && !sinMensaje
  const describedBy = [resto['aria-describedby'], conMensaje ? idError : null].filter(Boolean).join(' ') || undefined

  return (
    <>
      <input
        {...resto}
        ref={(el) => {
          inputRef.current = el
          if (typeof ref === 'function') ref(el)
          else if (ref) ref.current = el
        }}
        type="text"
        inputMode="decimal"
        autoComplete="off"
        value={mostrado}
        onChange={(e) => cambiar(e.target.value)}
        onMouseDown={(e) => {
          if (document.activeElement !== e.currentTarget) conClic.current = true
          resto.onMouseDown?.(e)
        }}
        onFocus={(e) => {
          seleccionarAlEditar.current = !conClic.current
          conClic.current = false
          // El valor del formulario ya viene normalizado ("4500.40"): no se vuelve a interpretar.
          if (value !== MONTO_INVALIDO) setTexto(Number.isFinite(numero) ? montoEditable(value) : value)
          else if (error === null) setTexto('')
          setEditando(true)
          onFocus?.(e)
        }}
        onBlur={(e) => {
          setEditando(false)
          onBlur?.(e)
        }}
        aria-invalid={ariaInvalid || undefined}
        aria-describedby={describedBy}
        className={`${className ?? inputClass}${invalido ? ' !border-error focus:!border-error' : ''}`}
      />
      {conMensaje && (
        <span id={idError} role="alert" className="font-sans text-label-md text-error">
          {error}
        </span>
      )}
    </>
  )
})
