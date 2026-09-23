import { useEffect, useRef, useState } from 'react'
import { ScanButton } from './ScanButton'

export type ProductoDuplicado = { id: string; nombre: string }

type Props = {
  value: string
  onChange: (value: string) => void
  // Busca un producto existente con ese código exacto (cada app usa su cliente de Supabase).
  buscarPorCodigo: (codigo: string) => Promise<ProductoDuplicado | null>
  // Al editar, el propio producto no cuenta como duplicado.
  excluirId?: string
  onEditarExistente?: (id: string) => void
  autoFocus?: boolean
}

// Campo destacado "Código de barras" del formulario de producto: autofoco para el lector físico,
// botón de escaneo (cámara/lector) y aviso en vivo si el código ya existe en el catálogo.
export function CodigoBarrasBox({
  value,
  onChange,
  buscarPorCodigo,
  excluirId,
  onEditarExistente,
  autoFocus = true,
}: Props) {
  const inputRef = useRef<HTMLInputElement>(null)
  const [duplicado, setDuplicado] = useState<ProductoDuplicado | null>(null)

  useEffect(() => {
    if (autoFocus) inputRef.current?.focus()
  }, [autoFocus])

  // Verificación en tiempo real con un pequeño debounce para no consultar por cada tecla; el
  // lector físico escribe todo de golpe, así que se resuelve con una sola consulta.
  useEffect(() => {
    const codigo = value.trim()
    if (!codigo) {
      setDuplicado(null)
      return
    }
    let cancelado = false
    const t = setTimeout(async () => {
      const existente = await buscarPorCodigo(codigo).catch(() => null)
      if (cancelado) return
      setDuplicado(existente && existente.id !== excluirId ? existente : null)
    }, 300)
    return () => {
      cancelado = true
      clearTimeout(t)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value, excluirId])

  return (
    <div
      className={`rounded-lg border-2 bg-accent-light/40 px-3 py-1.5 ${duplicado ? 'border-error' : 'border-accent'}`}
    >
      <label className="flex flex-col gap-1">
        <span className="font-sans text-label-bold text-ink">Código de barras</span>
        <div className="flex items-center gap-2">
          <input
            ref={inputRef}
            value={value}
            onChange={(e) => onChange(e.target.value)}
            onKeyDown={(e) => {
              // El lector manda Enter al terminar: no debe enviar el formulario.
              if (e.key === 'Enter') e.preventDefault()
            }}
            placeholder="Escaneá con el lector o tipeá el código…"
            className="h-9 min-w-0 flex-1 rounded border border-line bg-surface px-3 font-sans text-body-md text-ink outline-none focus:border-accent"
          />
          <ScanButton onDetect={onChange} onFocusCampo={() => inputRef.current?.focus()} />
        </div>
      </label>
      {duplicado ? (
        <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 font-sans text-label-md text-error">
          <span>
            Ya existe un producto con este código: <strong>{duplicado.nombre}</strong>. ¿Querés editarlo en vez de
            crear uno nuevo?
          </span>
          {onEditarExistente && (
            <button
              type="button"
              onClick={() => onEditarExistente(duplicado.id)}
              className="rounded bg-error px-2.5 py-1 font-sans text-label-bold text-white hover:opacity-90"
            >
              Editar existente
            </button>
          )}
        </div>
      ) : (
        <p className="mt-1 font-sans text-label-md text-accent-darker">
          Si ya existe en el catálogo se avisa antes de continuar. Vacío = código interno automático.
        </p>
      )}
    </div>
  )
}
