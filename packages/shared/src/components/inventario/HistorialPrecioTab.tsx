import { useEffect, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Auditoria } from '../../../types/database'
import { historialDeMargen, type CambioMargenProducto } from '../../../lib/historialPrecio'
import { nombresPorId } from '../../../lib/perfiles'
import { formatCurrency, formatCurrencyOpcional, formatFechaHora } from '../../../lib/format'

// Historial de precio (prompt 5): se deriva de `auditoria`, no de una tabla propia — un solo fetch al
// abrir la ficha alimenta la pestaña "Historial de precio" y la línea "Última modificación de margen"
// del formulario. Solo admin (`habilitado`): `auditoria` es de lectura solo para administradores.
export function useHistorialMargen(supabase: SupabaseClient, productoId: string | undefined, habilitado = true) {
  const [cambios, setCambios] = useState<CambioMargenProducto[]>([])
  const [usuarios, setUsuarios] = useState<Map<string, string>>(new Map())
  const [cargando, setCargando] = useState(false)

  useEffect(() => {
    if (!productoId || !habilitado) return
    let cancelado = false
    setCargando(true)
    supabase
      .from('auditoria')
      .select('*')
      .eq('tabla_afectada', 'productos')
      .eq('registro_id', productoId)
      .eq('accion', 'edicion')
      .order('created_at', { ascending: false })
      .then(async ({ data }) => {
        const lista = historialDeMargen((data ?? []) as unknown as Auditoria[])
        const nombres = await nombresPorId(
          supabase,
          lista.map((c) => c.usuarioId),
        )
        if (cancelado) return
        setCambios(lista)
        setUsuarios(nombres)
        setCargando(false)
      })
    return () => {
      cancelado = true
    }
  }, [supabase, productoId, habilitado])

  return { cambios, usuarios, cargando }
}

type Props = {
  cambios: CambioMargenProducto[]
  usuarios: Map<string, string>
  loading: boolean
}

// Puramente presentacional. Tabla de listado §5.2 (docs/08), mismas columnas y textos de siempre.
export function HistorialPrecioTab({ cambios, usuarios, loading }: Props) {
  if (loading) {
    return (
      <p role="status" className="py-6 font-sans text-body-md text-ink-soft">
        Cargando...
      </p>
    )
  }

  if (cambios.length === 0) {
    return (
      <p className="py-6 font-sans text-body-md text-ink-soft">
        Todavía no hay cambios de costo, margen o precio manual registrados para este producto.
      </p>
    )
  }

  return (
    <div className="overflow-hidden rounded-xl shadow-sm">
      <table className="w-full table-fixed text-left font-sans text-table-row max-xl:[&_td]:px-2 max-xl:[&_th]:px-2">
        <caption className="sr-only">Cambios de costo, margen y precio de venta, del más reciente al más viejo</caption>
        <colgroup>
          <col className="w-[8.75rem]" />
          <col className="w-[7.5rem]" />
          <col />
          <col className="w-[7.5rem]" />
          <col className="w-[7.5rem]" />
          <col />
        </colgroup>
        <thead>
          <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
            <th scope="col" className="px-3 py-2.5">Fecha</th>
            <th scope="col" className="px-3 py-2.5">Usuario</th>
            <th scope="col" className="px-3 py-2.5">Costo</th>
            <th scope="col" className="px-3 py-2.5">Margen 1</th>
            <th scope="col" className="px-3 py-2.5">Margen 2</th>
            <th scope="col" className="px-3 py-2.5">Precio de venta</th>
          </tr>
        </thead>
        <tbody>
          {cambios.map((c) => (
            <tr key={c.auditoriaId} className="border-b border-table-divider last:border-0 even:bg-table-row-alt">
              <td className="whitespace-nowrap px-3 py-3 text-ink-soft">{formatFechaHora(c.createdAt)}</td>
              <td className="px-3 py-3 text-ink-soft [overflow-wrap:anywhere]">{usuarios.get(c.usuarioId) ?? '—'}</td>
              <td className="px-3 py-3 tabular-nums text-ink [overflow-wrap:anywhere]">
                {formatCurrencyOpcional(c.costoAnterior)} → {formatCurrencyOpcional(c.costoNuevo)}
              </td>
              <td className="px-3 py-3 tabular-nums text-ink">
                {c.margen1Anterior}% → {c.margen1Nuevo}%
              </td>
              <td className="px-3 py-3 tabular-nums text-ink">
                {c.margen2Anterior}% → {c.margen2Nuevo}%
              </td>
              <td className="px-3 py-3 font-semibold tabular-nums text-accent-darker [overflow-wrap:anywhere]">
                {formatCurrency(c.precioVentaAnterior)}
                {c.precioManualAnterior !== null && ' (manual)'} → {formatCurrency(c.precioVentaNuevo)}
                {c.precioManualNuevo !== null && ' (manual)'}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
