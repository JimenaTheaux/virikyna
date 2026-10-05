import { useEffect, useRef, useState, type ComponentType, type KeyboardEvent } from 'react'
import { createPortal } from 'react-dom'
import { MoreVertical } from 'lucide-react'

export type RowActionsMenuItem = {
  label: string
  // Acepta tanto íconos lucide-react como los íconos SVG propios de cada app — ambos exponen
  // `className` para el tamaño, así que alcanza con ese prop en común.
  icon: ComponentType<{ className?: string }>
  onClick: () => void
  destructive?: boolean
  disabled?: boolean
  // Motivo del disabled, mostrado como tooltip nativo (title) sobre el ítem.
  disabledReason?: string
}

type Props = {
  items: RowActionsMenuItem[]
  // 'sm' (default): botón ~26×26px, para tablas de escritorio (Local/Gestión).
  // 'touch': botón e ítems con mínimo 44×44px, para pantallas de celular (Inventario).
  size?: 'sm' | 'touch'
  ariaLabel?: string
}

type MenuPos = { left?: number; right?: number; top?: number; bottom?: number }

const ANCHO_MENU = 208

// Botón "⋮" que abre un menú de acciones anclado (portal a document.body, posicionado con
// getBoundingClientRect del botón). Generaliza el patrón de TicketMenu en
// apps/virikyna-local/src/pages/Ventas/TicketsBar.tsx, sumando el flip hacia arriba que ya usa
// DropdownFlotante.tsx cuando no hay espacio abajo — ver docs/08_estilos_y_diseno.md, sección 5.2.
// Regla de uso: solo para filas con 2+ acciones — con una sola acción, el call site debe
// renderizar esa acción como ícono suelto en vez de este componente.
export function RowActionsMenu({ items, size = 'sm', ariaLabel = 'Más acciones' }: Props) {
  const [abierto, setAbierto] = useState(false)
  const [pos, setPos] = useState<MenuPos | null>(null)
  const botonRef = useRef<HTMLButtonElement>(null)
  const menuRef = useRef<HTMLDivElement>(null)

  function toggle() {
    if (abierto) {
      setAbierto(false)
      return
    }
    const r = botonRef.current?.getBoundingClientRect()
    if (!r) return
    const espacioAbajo = window.innerHeight - r.bottom - 8
    const contenido = menuRef.current?.scrollHeight || items.length * 44 + 16
    const abajo = espacioAbajo >= contenido
    setPos({
      right: Math.max(8, window.innerWidth - r.right),
      ...(abajo ? { top: r.bottom + 4 } : { bottom: window.innerHeight - r.top + 4 }),
    })
    setAbierto(true)
  }

  // Teclado (patrón "menu button"): al abrir, el foco entra al primer ítem habilitado — el menú
  // vive en un portal al final del body, así que con Tab nunca se llegaba a él.
  useEffect(() => {
    if (abierto && pos) itemsHabilitados()[0]?.focus()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [abierto, pos])

  function itemsHabilitados(): HTMLButtonElement[] {
    return Array.from(menuRef.current?.querySelectorAll<HTMLButtonElement>('[role="menuitem"]:not([disabled])') ?? [])
  }

  function cerrarYVolver() {
    setAbierto(false)
    botonRef.current?.focus()
  }

  // Flechas / Home / End recorren los ítems; Esc y Tab cierran y devuelven el foco al botón ⋮
  // (desde ahí Tab sigue con la fila de siempre).
  function onMenuKeyDown(e: KeyboardEvent<HTMLDivElement>) {
    const lista = itemsHabilitados()
    const i = lista.indexOf(document.activeElement as HTMLButtonElement)
    const ir = (n: number) => {
      e.preventDefault()
      lista[(n + lista.length) % lista.length]?.focus()
    }
    if (e.key === 'ArrowDown') ir(i + 1)
    else if (e.key === 'ArrowUp') ir(i - 1)
    else if (e.key === 'Home') ir(0)
    else if (e.key === 'End') ir(lista.length - 1)
    else if (e.key === 'Escape' || e.key === 'Tab') {
      e.preventDefault()
      // Que el Esc no llegue a un diálogo de abajo (useFocoAtrapado escucha en el DOM).
      e.nativeEvent.stopImmediatePropagation()
      cerrarYVolver()
    }
  }

  useEffect(() => {
    if (!abierto) return
    function onClickFuera(e: MouseEvent) {
      const target = e.target as Node
      if (botonRef.current?.contains(target) || menuRef.current?.contains(target)) return
      setAbierto(false)
    }
    function onCerrar() {
      setAbierto(false)
    }
    document.addEventListener('mousedown', onClickFuera)
    window.addEventListener('resize', onCerrar)
    window.addEventListener('scroll', onCerrar, true)
    return () => {
      document.removeEventListener('mousedown', onClickFuera)
      window.removeEventListener('resize', onCerrar)
      window.removeEventListener('scroll', onCerrar, true)
    }
  }, [abierto])

  const botonClase =
    size === 'touch'
      ? 'flex h-11 w-11 items-center justify-center rounded bg-table-divider text-ink-soft hover:bg-line'
      : 'flex h-[26px] w-[26px] items-center justify-center rounded bg-table-divider text-ink-soft hover:bg-line'

  return (
    <>
      <button
        type="button"
        ref={botonRef}
        aria-label={ariaLabel}
        aria-haspopup="menu"
        aria-expanded={abierto}
        onClick={toggle}
        className={`${botonClase} focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent`}
      >
        <MoreVertical className={size === 'touch' ? 'h-5 w-5' : 'h-4 w-4'} />
      </button>
      {abierto &&
        pos &&
        createPortal(
          <div
            ref={menuRef}
            role="menu"
            aria-label={ariaLabel}
            onMouseDown={(e) => e.stopPropagation()}
            onKeyDown={onMenuKeyDown}
            style={{ position: 'fixed', width: ANCHO_MENU, ...pos }}
            className="z-50 overflow-hidden rounded-lg border border-line bg-surface shadow-lg"
          >
            {items.map((item, i) => (
              <button
                key={item.label}
                type="button"
                role="menuitem"
                tabIndex={-1}
                disabled={item.disabled}
                title={item.disabled ? item.disabledReason : undefined}
                onClick={() => {
                  // El foco vuelve al ⋮ ANTES de la acción: si abre un modal, ese modal lo
                  // devuelve acá al cerrarse (y no a un ítem que ya no existe).
                  cerrarYVolver()
                  item.onClick()
                }}
                className={`flex w-full items-center gap-2.5 px-3 text-left font-sans text-label-md outline-none focus-visible:bg-accent-light ${
                  size === 'touch' ? 'min-h-11 py-2.5' : 'py-2'
                } ${i > 0 ? 'border-t border-line' : ''} ${
                  item.disabled
                    ? 'cursor-not-allowed text-ink-soft/50'
                    : item.destructive
                      ? 'text-error hover:bg-error/10'
                      : 'text-ink hover:bg-bg'
                }`}
              >
                <item.icon className={size === 'touch' ? 'h-[18px] w-[18px]' : 'h-4 w-4'} />
                {item.label}
              </button>
            ))}
          </div>,
          document.body,
        )}
    </>
  )
}
