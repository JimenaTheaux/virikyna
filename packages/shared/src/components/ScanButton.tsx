import { lazy, Suspense, useEffect, useState } from 'react'

const BarcodeScanner = lazy(() => import('./BarcodeScanner'))

const svgProps = {
  viewBox: '0 0 24 24',
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 1.75,
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
}

// Ícono "código de barras" (líneas) — el que se usa en desktop, donde el escaneo habitual es con
// lector físico. En celular/tablet se usa el ícono de cámara.
export function IconCodigoBarras({ className }: { className?: string }) {
  return (
    <svg {...svgProps} className={className} aria-hidden="true">
      <path d="M4 5v14M7 5v14M11 5v14M14 5v14M17 5v14M20 5v14" strokeWidth={1.5} />
      <path d="M9 5v14M19 5v14" strokeWidth={2.75} />
    </svg>
  )
}

export function IconCamaraScan({ className }: { className?: string }) {
  return (
    <svg {...svgProps} className={className} aria-hidden="true">
      <path d="M4 8h3l1.5-2h7L17 8h3v11H4z" />
      <circle cx="12" cy="13" r="3.5" />
    </svg>
  )
}

// Celular/tablet = puntero táctil principal ("coarse"). Si el navegador no soporta matchMedia
// asumimos desktop.
export function useDispositivoTactil(): boolean {
  const [tactil, setTactil] = useState(
    () => typeof window !== 'undefined' && !!window.matchMedia?.('(pointer: coarse)').matches,
  )
  useEffect(() => {
    const mq = window.matchMedia?.('(pointer: coarse)')
    if (!mq) return
    const onChange = () => setTactil(mq.matches)
    mq.addEventListener('change', onChange)
    return () => mq.removeEventListener('change', onChange)
  }, [])
  return tactil
}

// ¿Hay al menos una cámara? Solo enumera dispositivos, sin pedir permiso. Si el navegador no
// expone mediaDevices (contexto no seguro, webview viejo) se considera que no hay cámara.
export function useCamaraDisponible(): boolean {
  const [disponible, setDisponible] = useState(false)
  useEffect(() => {
    let cancelado = false
    const md = typeof navigator !== 'undefined' ? navigator.mediaDevices : undefined
    if (!md?.enumerateDevices || !md.getUserMedia) return
    md.enumerateDevices()
      .then((lista) => {
        if (!cancelado) setDisponible(lista.some((d) => d.kind === 'videoinput'))
      })
      .catch(() => {})
    return () => {
      cancelado = true
    }
  }, [])
  return disponible
}

type Props = {
  onDetect: (codigo: string) => void
  // Sin cámara disponible el botón solo lleva el foco al campo para escanear con lector físico.
  onFocusCampo?: () => void
  className?: string
}

// Botón de escaneo: ícono de cámara en celular/tablet, ícono de código de barras (líneas) en
// desktop. Si hay cámara la abre; si no, deja el foco en el campo para que escriba el lector físico.
export function ScanButton({ onDetect, onFocusCampo, className }: Props) {
  const tactil = useDispositivoTactil()
  const hayCamara = useCamaraDisponible()
  const [escaneando, setEscaneando] = useState(false)

  function handleClick() {
    if (hayCamara) setEscaneando(true)
    else onFocusCampo?.()
  }

  return (
    <>
      <button
        type="button"
        onClick={handleClick}
        title={hayCamara ? 'Escanear con la cámara' : 'Escanear con el lector de códigos de barras'}
        aria-label="Escanear código de barras"
        className={
          className ??
          'flex h-9 w-9 flex-shrink-0 items-center justify-center rounded border border-accent/40 bg-accent-light text-accent-darker transition hover:bg-accent hover:text-white'
        }
      >
        {tactil ? <IconCamaraScan className="h-5 w-5" /> : <IconCodigoBarras className="h-5 w-5" />}
      </button>
      {escaneando && (
        <Suspense fallback={null}>
          <BarcodeScanner
            onDetect={(codigo) => {
              setEscaneando(false)
              onDetect(codigo)
            }}
            onClose={() => setEscaneando(false)}
          />
        </Suspense>
      )}
    </>
  )
}
