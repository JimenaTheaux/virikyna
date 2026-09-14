import { useEffect, useRef, useState, type FormEvent } from 'react'
import { createPortal } from 'react-dom'
import { IconCamara, IconCerrar } from './icons'

type Props = {
  onDetect: (codigo: string) => void
  onClose: () => void
}

type Estado = 'iniciando' | 'listo' | 'error'

// Solo los formatos de código de barras de producto reales (+ QR por si acaso) — reduce el
// trabajo por frame del decoder frente al set completo por defecto (que incluye Aztec, PDF417,
// Datamatrix), lo que en celulares gama media se nota como escaneo lento/"que no anda".
// Nombres tal cual los define la Barcode Detection API (mismos strings usa el fallback ZXing).
const FORMATOS = ['ean_13', 'ean_8', 'upc_a', 'upc_e', 'code_128', 'code_39', 'itf', 'qr_code']

interface CapacidadesTorch extends MediaTrackCapabilities {
  torch?: boolean
}
interface ConstraintsTorch extends MediaTrackConstraintSet {
  torch?: boolean
}

interface DetectorResultado {
  rawValue: string
}
interface DetectorBarcode {
  detect(video: HTMLVideoElement): Promise<DetectorResultado[]>
}
interface DetectorBarcodeCtor {
  new (opciones?: { formats?: string[] }): DetectorBarcode
}

declare global {
  interface Window {
    BarcodeDetector?: DetectorBarcodeCtor
  }
}

let detectorCtorPromise: Promise<DetectorBarcodeCtor> | null = null

// Patrón híbrido (estándar 2026): si el navegador trae la Barcode Detection API nativa
// (Chrome/Android, que usa ML Kit por debajo — más precisa y rápida que un decoder en JS) la
// usamos tal cual. Si no está disponible (Safari/iOS, que a la fecha no la soporta) recién ahí
// cargamos el polyfill basado en ZXing — así no le bajamos ~430kb de más a la mayoría de los
// usuarios, que sí tienen soporte nativo.
function getBarcodeDetectorCtor(): Promise<DetectorBarcodeCtor> {
  if (!detectorCtorPromise) {
    detectorCtorPromise = (async () => {
      if (window.BarcodeDetector) {
        console.info('[BarcodeScanner] usando BarcodeDetector nativo del navegador (ML Kit en Android)')
        return window.BarcodeDetector
      }
      const { BarcodeDetector } = await import('barcode-detector-api-polyfill')
      console.info('[BarcodeScanner] BarcodeDetector nativo no disponible — fallback a ZXing (polyfill)')
      const ctor = BarcodeDetector as unknown as DetectorBarcodeCtor
      window.BarcodeDetector = ctor
      return ctor
    })()
  }
  return detectorCtorPromise
}

// Lectura de código de barras con la cámara del celular (docs/04_modulos_y_funciones.md, 5.1).
// Pedimos la cámara nosotros mismos con facingMode ideal 'environment' (no decodeFromVideoDevice
// de ZXing, que además ya no usamos para decodificar) para elegir siempre la trasera por defecto,
// y sin deviceId permite ofrecer un botón "Cambiar cámara" para cuando el celular elige la cámara
// equivocada (frecuente en Android) — eso, más el fallback de código manual, es lo que evita que
// un problema de cámara puntual deje a alguien sin poder cargar un producto.
export default function BarcodeScanner({ onDetect, onClose }: Props) {
  const videoRef = useRef<HTMLVideoElement>(null)
  const onDetectRef = useRef(onDetect)
  const streamRef = useRef<MediaStream | null>(null)
  const [estado, setEstado] = useState<Estado>('iniciando')
  const [error, setError] = useState<string | null>(null)
  const [dispositivos, setDispositivos] = useState<MediaDeviceInfo[]>([])
  const [deviceIndex, setDeviceIndex] = useState<number | null>(null)
  const [torchDisponible, setTorchDisponible] = useState(false)
  const [torchOn, setTorchOn] = useState(false)
  const [manual, setManual] = useState(false)
  const [codigoManual, setCodigoManual] = useState('')

  useEffect(() => {
    onDetectRef.current = onDetect
  }, [onDetect])

  useEffect(() => {
    // Si el usuario canceló el escaneo para tipear a mano, no tocamos la cámara: se libera del
    // todo en el cleanup de abajo y no vuelve a pedirse mientras escribe, sin ningún límite de
    // tiempo — puede tipear con la calma que necesite.
    if (manual) return

    let cancelled = false
    let rafId: number | null = null
    let detectando = false

    setEstado('iniciando')
    setError(null)
    setTorchOn(false)

    async function iniciar() {
      try {
        const deviceId = deviceIndex !== null ? dispositivos[deviceIndex]?.deviceId : undefined
        const video: MediaTrackConstraints = deviceId
          ? { deviceId: { exact: deviceId } }
          : { facingMode: { ideal: 'environment' } }
        const stream = await navigator.mediaDevices.getUserMedia({ video })
        if (cancelled) {
          stream.getTracks().forEach((track) => track.stop())
          return
        }
        streamRef.current = stream

        const videoEl = videoRef.current
        if (!videoEl) return
        videoEl.srcObject = stream
        await videoEl.play().catch(() => {})

        const track = stream.getVideoTracks()[0]
        const capacidades = track?.getCapabilities?.() as CapacidadesTorch | undefined
        setTorchDisponible(Boolean(capacidades?.torch))

        if (dispositivos.length === 0) {
          const lista = await navigator.mediaDevices.enumerateDevices()
          if (!cancelled) setDispositivos(lista.filter((d) => d.kind === 'videoinput'))
        }

        const DetectorCtor = await getBarcodeDetectorCtor()
        if (cancelled) return
        const detector = new DetectorCtor({ formats: FORMATOS })
        setEstado('listo')

        const detectar = async () => {
          if (cancelled) return
          if (detectando) {
            rafId = requestAnimationFrame(detectar)
            return
          }
          detectando = true
          try {
            const resultados = await detector.detect(videoEl)
            if (!cancelled && resultados.length > 0) {
              onDetectRef.current(resultados[0].rawValue)
              return
            }
          } catch {
            // Sin resultado en este frame (o el video todavía no tiene data) — reintenta.
          }
          detectando = false
          if (!cancelled) rafId = requestAnimationFrame(detectar)
        }
        rafId = requestAnimationFrame(detectar)
      } catch {
        if (!cancelled) {
          setEstado('error')
          setError('No se pudo acceder a la cámara. Revisá los permisos del navegador para este sitio.')
        }
      }
    }

    iniciar()

    return () => {
      cancelled = true
      if (rafId !== null) cancelAnimationFrame(rafId)
      streamRef.current?.getTracks().forEach((track) => track.stop())
      streamRef.current = null
      if (videoRef.current) videoRef.current.srcObject = null
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [deviceIndex, manual])

  function cambiarCamara() {
    if (dispositivos.length < 2) return
    const actual = deviceIndex ?? 0
    setDeviceIndex((actual + 1) % dispositivos.length)
  }

  async function alternarLinterna() {
    const track = streamRef.current?.getVideoTracks()[0]
    if (!track) return
    try {
      await track.applyConstraints({ advanced: [{ torch: !torchOn } as ConstraintsTorch] })
      setTorchOn((prev) => !prev)
    } catch {
      // Algunos navegadores reportan la capability pero no soportan aplicarla en runtime.
    }
  }

  function cancelarYTipear() {
    setManual(true)
  }

  function handleManualSubmit(e: FormEvent) {
    e.preventDefault()
    const codigo = codigoManual.trim()
    if (!codigo) return
    onDetectRef.current(codigo)
  }

  // Portal + stopPropagation por el mismo motivo que Modal/BottomSheet (ver esos componentes):
  // este scanner tiene su propio <form> (el de "ingresar a mano") y se abre desde adentro de OTRO
  // formulario (ItemFacturaRow, CargarFacturaPage, ProductoFormSheet) — sin esto, el submit del
  // código a mano termina disparando el formulario de afuera en vez del propio.
  return createPortal(
    <div className="fixed inset-0 z-[60] flex flex-col bg-black" onSubmit={(e) => e.stopPropagation()}>
      <div className="flex items-center justify-between px-4 py-3 pt-[calc(env(safe-area-inset-top,0px)+12px)]">
        <span className="font-sans text-label-bold text-white">Apuntá al código de barras</span>
        <button
          type="button"
          onClick={onClose}
          aria-label="Cerrar escáner"
          className="rounded-full bg-white/10 p-2 text-white"
        >
          <IconCerrar className="h-6 w-6" />
        </button>
      </div>

      <div className="relative flex-1 overflow-hidden">
        {!manual && (
          <>
            {/* eslint-disable-next-line jsx-a11y/media-has-caption */}
            <video ref={videoRef} className="h-full w-full object-cover" muted playsInline autoPlay />

            {estado === 'iniciando' && (
              <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 bg-black">
                <div className="h-10 w-10 animate-spin rounded-full border-4 border-white/20 border-t-white" />
                <p className="font-sans text-body-md text-white/80">Iniciando cámara...</p>
              </div>
            )}

            {estado === 'listo' && (
              <div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center gap-3">
                <div className="h-1/4 w-4/5 rounded-lg border-4 border-accent-light/80" />
                <p className="rounded-full bg-black/50 px-4 py-2 font-sans text-label-md text-white">
                  Acercá el código bien iluminado, dentro del recuadro
                </p>
              </div>
            )}

            {estado === 'listo' && (
              <div className="absolute bottom-4 right-4 flex flex-col gap-2">
                {torchDisponible && (
                  <button
                    type="button"
                    onClick={alternarLinterna}
                    className={`rounded-full p-3 shadow ${torchOn ? 'bg-accent text-white' : 'bg-white/90 text-ink'}`}
                    aria-label="Linterna"
                  >
                    💡
                  </button>
                )}
                {dispositivos.length > 1 && (
                  <button
                    type="button"
                    onClick={cambiarCamara}
                    className="flex items-center justify-center rounded-full bg-white/90 p-3 text-ink shadow"
                    aria-label="Cambiar cámara"
                  >
                    <IconCamara className="h-5 w-5" />
                  </button>
                )}
              </div>
            )}
          </>
        )}

        {manual && (
          <div className="flex h-full flex-col items-center justify-center gap-3 px-6 text-center">
            <p className="font-sans text-body-md text-white/70">
              Escaneo cancelado. Escribí el código de barras abajo, sin apuro.
            </p>
            <button
              type="button"
              onClick={() => setManual(false)}
              className="font-sans text-label-bold text-white/70 underline"
            >
              Volver a escanear
            </button>
          </div>
        )}
      </div>

      <div className="flex-shrink-0 bg-black px-4 pb-[calc(16px+env(safe-area-inset-bottom,0px))] pt-3">
        {error && <p className="mb-2 rounded bg-error px-4 py-3 text-center font-sans text-body-md text-white">{error}</p>}

        {!manual && (
          <button
            type="button"
            onClick={cancelarYTipear}
            className="w-full rounded px-4 py-3 text-center font-sans text-label-bold text-white/70 underline"
          >
            ¿No podés escanear? Ingresá el código a mano
          </button>
        )}

        {manual && (
          <form onSubmit={handleManualSubmit} className="flex gap-2">
            <input
              autoFocus
              inputMode="numeric"
              value={codigoManual}
              onChange={(e) => setCodigoManual(e.target.value)}
              placeholder="Código de barras"
              className="flex-1 rounded border border-white/20 bg-white/10 px-4 py-3 font-sans text-body-lg text-white outline-none placeholder:text-white/50 focus:border-white"
            />
            <button
              type="submit"
              className="rounded bg-accent px-5 py-3 font-sans text-label-bold text-white hover:bg-accent-dark"
            >
              Usar
            </button>
          </form>
        )}
      </div>
    </div>,
    document.body,
  )
}
