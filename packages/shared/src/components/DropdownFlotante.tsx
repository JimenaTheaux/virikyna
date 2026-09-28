import { useCallback, useLayoutEffect, useRef, useState, type ReactNode, type RefObject } from 'react'
import { createPortal } from 'react-dom'

type Props = {
  anchorRef: RefObject<HTMLElement>
  children: ReactNode
  // 'fijo' (default): panel de 256px, para celdas angostas de una planilla de escritorio.
  // 'ancla': mismo ancho y posición horizontal que el campo — para formularios de celular, donde
  // el campo ocupa todo el ancho de la pantalla.
  ancho?: 'fijo' | 'ancla'
}

type Posicion = { left: number; width?: number; top?: number; bottom?: number; maxHeight: number }

// Dropdown de sugerencias en un portal con position:fixed calculado desde el input: un dropdown
// "absolute" dentro de un modal/contenedor con overflow queda recortado o tapado por el footer. Se
// reposiciona en scroll/resize y se abre hacia arriba si abajo no hay lugar. El borde inferior
// visible se toma de visualViewport cuando existe, para que en celular no quede tapado por el
// teclado en pantalla.
export function DropdownFlotante({ anchorRef, children, ancho = 'fijo' }: Props) {
  const [pos, setPos] = useState<Posicion | null>(null)
  const panelRef = useRef<HTMLDivElement>(null)

  const calcular = useCallback(() => {
    const el = anchorRef.current
    if (!el) return
    const r = el.getBoundingClientRect()
    const vv = window.visualViewport
    const bordeInferiorVisible = vv ? vv.offsetTop + vv.height : window.innerHeight
    const espacioAbajo = bordeInferiorVisible - r.bottom - 8
    const espacioArriba = r.top - 8
    // Se abre del lado donde entra completo; si no entra en ninguno, del lado con más lugar (y
    // recién ahí scrollea por dentro). Con el contenido todavía sin medir se estima en 220px.
    const contenido = panelRef.current?.scrollHeight || 220
    const abajo = espacioAbajo >= contenido || espacioAbajo >= espacioArriba
    const horizontal: Pick<Posicion, 'left' | 'width'> =
      ancho === 'ancla'
        ? { left: r.left, width: r.width }
        : { left: Math.max(8, Math.min(r.left, window.innerWidth - 264)) }
    const nueva: Posicion = abajo
      ? { ...horizontal, top: r.bottom + 4, maxHeight: Math.max(espacioAbajo, 120) }
      : { ...horizontal, bottom: window.innerHeight - r.top + 4, maxHeight: Math.max(espacioArriba, 120) }
    // Sin cambios no se vuelve a renderizar (esto corre después de cada render del padre).
    setPos((prev) =>
      prev &&
      prev.left === nueva.left &&
      prev.width === nueva.width &&
      prev.top === nueva.top &&
      prev.bottom === nueva.bottom &&
      prev.maxHeight === nueva.maxHeight
        ? prev
        : nueva,
    )
  }, [anchorRef, ancho])

  useLayoutEffect(() => {
    window.addEventListener('scroll', calcular, true)
    window.addEventListener('resize', calcular)
    window.visualViewport?.addEventListener('resize', calcular)
    window.visualViewport?.addEventListener('scroll', calcular)
    return () => {
      window.removeEventListener('scroll', calcular, true)
      window.removeEventListener('resize', calcular)
      window.visualViewport?.removeEventListener('resize', calcular)
      window.visualViewport?.removeEventListener('scroll', calcular)
    }
  }, [calcular])

  // Después de cada render (cambia la cantidad de sugerencias) se vuelve a medir el contenido.
  useLayoutEffect(() => {
    calcular()
  })

  if (!pos) return null
  return createPortal(
    // mousedown sin default: el click en una sugerencia no le quita el foco al input (si no, el
    // blur cerraría el dropdown antes de que el click llegue a dispararse).
    <div
      ref={panelRef}
      className={`fixed z-[60] overflow-y-auto rounded-lg border border-line bg-surface shadow-sm ${ancho === 'fijo' ? 'w-64' : ''}`}
      style={pos}
      onMouseDown={(e) => e.preventDefault()}
    >
      {children}
    </div>,
    document.body,
  )
}
