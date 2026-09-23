import type { CambioMargenProducto } from '@virikyna/shared'
import { formatCurrency, formatFechaHora } from '@virikyna/shared'

type Props = {
  cambios: CambioMargenProducto[]
  usuarios: Map<string, string>
  loading: boolean
}

// Puramente presentacional — los datos ya vienen filtrados/mapeados desde `auditoria` por
// ProductoFormSheet (fetch único, compartido con la línea de "última modificación" en la ficha).
// Solo se monta para admin: `auditoria` tiene RLS de solo-lectura-admin (docs/06), y el margen ya
// es un campo admin-only acá — ver ProductoFormSheet.
export function HistorialPrecioTab({ cambios, usuarios, loading }: Props) {
  if (loading) {
    return <p className="py-6 font-sans text-body-md text-ink-soft">Cargando...</p>
  }

  if (cambios.length === 0) {
    return (
      <p className="py-6 font-sans text-body-md text-ink-soft">
        Todavía no hay cambios de costo o margen registrados para este producto.
      </p>
    )
  }

  return (
    <div className="overflow-auto rounded-lg border border-line">
      <table className="w-full text-left font-sans text-label-md">
        <thead>
          <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
            <th className="min-w-[110px] whitespace-nowrap px-3 py-2">Fecha</th>
            <th className="whitespace-nowrap px-3 py-2">Usuario</th>
            <th className="whitespace-nowrap px-3 py-2">Costo</th>
            <th className="whitespace-nowrap px-3 py-2">Margen 1</th>
            <th className="whitespace-nowrap px-3 py-2">Margen 2</th>
            <th className="whitespace-nowrap px-3 py-2">Precio de venta</th>
          </tr>
        </thead>
        <tbody>
          {cambios.map((c) => (
            <tr key={c.auditoriaId} className="border-b border-line last:border-0">
              <td className="whitespace-nowrap px-3 py-2 text-ink-soft">{formatFechaHora(c.createdAt)}</td>
              <td className="px-3 py-2 text-ink-soft">{usuarios.get(c.usuarioId) ?? '—'}</td>
              <td className="px-3 py-2 text-ink">
                {formatCurrency(c.costoAnterior)} → {formatCurrency(c.costoNuevo)}
              </td>
              <td className="px-3 py-2 text-ink">
                {c.margen1Anterior}% → {c.margen1Nuevo}%
              </td>
              <td className="px-3 py-2 text-ink">
                {c.margen2Anterior}% → {c.margen2Nuevo}%
              </td>
              <td className="px-3 py-2 font-sans text-label-bold text-accent-darker">
                {formatCurrency(c.precioVentaAnterior)} → {formatCurrency(c.precioVentaNuevo)}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
