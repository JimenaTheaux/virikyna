import type { ReactNode } from 'react'

// Tabla de listado estilo "G" (docs/08, sección 5.2) — la misma que usa Historial de Egresos en
// Virikyna Gestión: header teal claro en mayúsculas, filas cebra, texto table-row y montos a la
// derecha. Piezas chicas en vez de una tabla con config para que cada pantalla arme sus celdas.

type Align = 'left' | 'right'

export function TablaListado({ children }: { children: ReactNode }) {
  return (
    <div className="overflow-auto rounded-xl border border-table-divider">
      <table className="w-full text-left font-sans text-table-row">{children}</table>
    </div>
  )
}

export function TablaHead({ children }: { children: ReactNode }) {
  return (
    <thead>
      <tr className="bg-accent-light text-table-head uppercase text-accent-dark">{children}</tr>
    </thead>
  )
}

export function Th({ children, align = 'left' }: { children?: ReactNode; align?: Align }) {
  return <th className={`whitespace-nowrap px-3 py-2.5 ${align === 'right' ? 'text-right' : ''}`}>{children}</th>
}

export function Fila({ children }: { children: ReactNode }) {
  return <tr className="border-b border-table-divider last:border-0 even:bg-table-row-alt">{children}</tr>
}

export function Td({
  children,
  align = 'left',
  className = 'text-ink-soft',
}: {
  children?: ReactNode
  align?: Align
  className?: string
}) {
  return <td className={`px-3 py-2 ${align === 'right' ? 'whitespace-nowrap text-right' : ''} ${className}`}>{children}</td>
}

// Estado vacío / cargando: una sola celda gris, más chica que las filas con datos.
export function FilaMensaje({ colSpan, children }: { colSpan: number; children: ReactNode }) {
  return (
    <tr>
      <td className="px-3 py-3 font-sans text-[12px] leading-4 text-ink-soft" colSpan={colSpan}>
        {children}
      </td>
    </tr>
  )
}

// Fila de total al pie: separador superior y negrita. `labelColSpan` columnas para el texto, el
// monto en la siguiente y `restoColSpan` celdas vacías después (cuando el monto no es la última).
export function FilaTotal({
  label,
  labelColSpan,
  restoColSpan = 0,
  montoClassName = 'text-ink',
  children,
}: {
  label: string
  labelColSpan: number
  restoColSpan?: number
  montoClassName?: string
  children: ReactNode
}) {
  return (
    <tfoot>
      <tr className="border-t-2 border-line font-bold">
        <td className="px-3 py-2.5 text-ink" colSpan={labelColSpan}>
          {label}
        </td>
        <td className={`whitespace-nowrap px-3 py-2.5 text-right ${montoClassName}`}>{children}</td>
        {restoColSpan > 0 && <td colSpan={restoColSpan} />}
      </tr>
    </tfoot>
  )
}
