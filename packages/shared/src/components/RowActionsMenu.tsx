import { useEffect, useRef, useState, type ComponentType } from 'react'
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
      <button type="button" ref={botonRef} aria-label={ariaLabel} onClick={toggle} className={botonClase}>
        <MoreVertical className={size === 'touch' ? 'h-5 w-5' : 'h-4 w-4'} />
      </button>
      {abierto &&
        pos &&
        createPortal(
          <div
            ref={menuRef}
            onMouseDown={(e) => e.stopPropagation()}
            style={{ position: 'fixed', width: ANCHO_MENU, ...pos }}
            className="z-50 overflow-hidden rounded-lg border border-line bg-surface shadow-lg"
          >
            {items.map((item, i) => (
              <button
                key={item.label}
                type="button"
                disabled={item.disabled}
                title={item.disabled ? item.disabledReason : undefined}
                onClick={() => {
                  setAbierto(false)
                  item.onClick()
                }}
                className={`flex w-full items-center gap-2.5 px-3 text-left font-sans text-label-md ${
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
