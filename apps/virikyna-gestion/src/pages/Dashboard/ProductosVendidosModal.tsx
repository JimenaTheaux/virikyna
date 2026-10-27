import { useMemo, useState } from 'react'
import { formatCantidad, formatCurrency, textoParaBuscar } from '@virikyna/shared'
import { Modal } from '../../components/Modal'
import { CeldaStock, separarVendidos, Tendencia, valorDe } from './columnas'
import type { Medida, VentaPorProducto } from './types'

type Orden = Medida | 'nombre'

const ORDENES: [Orden, string, string][] = [
  ['unidades', 'Unid.', 'Unidades'],
  ['importe', '$', 'Importe'],
  ['nombre', 'Nombre', 'Nombre'],
]

function ordenar(filas: VentaPorProducto[], orden: Orden) {
  return [...filas].sort((a, b) =>
    orden === 'nombre' ? a.nombre.localeCompare(b.nombre, 'es') : valorDe(b, orden) - valorDe(a, orden) || a.nombre.localeCompare(b.nombre, 'es'),
  )
}

// "Ver todos" de Productos vendidos (un día) y del Top (rango). Usa las mismas filas que ya trajo
// useVentasPorProducto — no consulta de nuevo. En rango, el # es el puesto real por la medida (no
// cambia al buscar) y la tendencia es contra el período anterior, igual que el Top.
export function ProductosVendidosModal({
  filas,
  titulo,
  enRango,
  medidaInicial,
  comparacion,
  onClose,
}: {
  filas: VentaPorProducto[]
  titulo: string
  enRango: boolean
  medidaInicial: Medida
  comparacion?: string
  onClose: () => void
}) {
  const [busqueda, setBusqueda] = useState('')
  const [orden, setOrden] = useState<Orden>(enRango ? medidaInicial : 'importe')
  // Ordenado por nombre, el puesto y la tendencia siguen la medida con la que se abrió.
  const medida: Medida = orden === 'nombre' ? medidaInicial : orden

  const { vendidos, devueltos } = useMemo(() => separarVendidos(filas), [filas])
  const puesto = useMemo(() => new Map(ordenar(vendidos, medida).map((f, i) => [f.productoId, i + 1])), [vendidos, medida])

  const q = textoParaBuscar(busqueda)
  const coincide = (f: VentaPorProducto) => !q || textoParaBuscar(`${f.nombre} ${f.marca ?? ''}`).includes(q)
  const visibles = ordenar(vendidos.filter(coincide), orden)
  // Devoluciones: lo más devuelto primero (unidades más negativas), o por nombre.
  const devueltosVisibles =
    orden === 'nombre'
      ? ordenar(devueltos.filter(coincide), 'nombre')
      : devueltos.filter(coincide).sort((a, b) => a.unidades - b.unidades || a.nombre.localeCompare(b.nombre, 'es'))

  const unidades = vendidos.reduce((acc, f) => acc + f.unidades, 0)
  const importe = vendidos.reduce((acc, f) => acc + f.importe, 0)

  return (
    <Modal title={titulo} onClose={onClose} widthClassName="max-w-[760px]" dialogo={{ onEscape: onClose }}>
      <div className="flex flex-col gap-3">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <input
            type="search"
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            placeholder="Buscar producto o marca"
            aria-label="Buscar producto o marca"
            className="min-w-[12rem] flex-1 rounded border border-line bg-surface px-3 py-2 font-sans text-body-md text-ink outline-none focus:border-accent"
          />
          <div role="group" aria-label="Ordenar por" className="flex gap-1 rounded-full bg-bg p-0.5">
            {ORDENES.map(([id, label, aria]) => (
              <button
                key={id}
                type="button"
                aria-pressed={orden === id}
                aria-label={aria}
                onClick={() => setOrden(id)}
                className={`rounded-full px-3 py-1 font-sans text-label-bold transition ${
                  orden === id ? 'bg-surface text-accent-darker shadow-sm' : 'text-ink-soft hover:text-accent-darker'
                }`}
              >
                {label}
              </button>
            ))}
          </div>
        </div>

        <p className="font-sans text-label-md text-ink-soft">
          {vendidos.length} producto{vendidos.length === 1 ? '' : 's'} · {formatCantidad(unidades)} unid. · {formatCurrency(importe)}
          {enRango && comparacion && ` · Tendencia vs. ${comparacion}`}
        </p>

        {visibles.length === 0 ? (
          <p className="py-2 font-sans text-body-md text-ink-soft">
            {vendidos.length === 0 ? 'Sin ventas en el período.' : 'Ningún producto coincide con la búsqueda.'}
          </p>
        ) : (
          <div className="max-h-[55vh] overflow-auto rounded">
            <table className="w-full table-fixed text-left font-sans text-table-row">
              <colgroup>
                {enRango && <col className="w-9" />}
                <col />
                <col className="w-16" />
                <col className="w-[7.5rem]" />
                <col className={enRango ? 'w-[4.5rem]' : 'w-20'} />
              </colgroup>
              <thead className="sticky top-0">
                <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
                  {enRango && <th className="px-2 py-2">#</th>}
                  <th className="px-2 py-2">Producto</th>
                  <th className="px-2 py-2 text-right">Unid.</th>
                  <th className="px-2 py-2 text-right">Importe</th>
                  {enRango ? (
                    <th className="px-2 py-2 text-right">
                      <span className="sr-only">Tendencia</span>
                      <span aria-hidden="true">±</span>
                    </th>
                  ) : (
                    <th className="px-2 py-2 text-right">Stock</th>
                  )}
                </tr>
              </thead>
              <tbody>
                {visibles.map((f) => (
                  <tr key={f.productoId} className="border-b border-table-divider last:border-0 even:bg-table-row-alt">
                    {enRango && <td className="px-2 py-1 text-ink-soft">{puesto.get(f.productoId)}</td>}
                    <td className="truncate px-2 py-1 text-ink" title={f.marca ? `${f.nombre} · ${f.marca}` : f.nombre}>
                      {f.nombre}
                      {f.marca && <span className="text-ink-soft"> · {f.marca}</span>}
                    </td>
                    <td className={`px-2 py-1 text-right ${medida === 'unidades' ? 'font-semibold text-ink' : 'text-ink-soft'}`}>
                      {formatCantidad(f.unidades)}
                    </td>
                    <td className={`whitespace-nowrap px-2 py-1 text-right ${medida === 'importe' ? 'font-semibold text-ink' : 'text-ink-soft'}`}>
                      {formatCurrency(f.importe)}
                    </td>
                    {enRango ? (
                      <td className="px-2 py-1 text-right">
                        <Tendencia
                          actual={valorDe(f, medida)}
                          anterior={medida === 'unidades' ? f.unidadesAnterior : f.importeAnterior}
                          medida={medida}
                        />
                      </td>
                    ) : (
                      <CeldaStock fila={f} />
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {devueltosVisibles.length > 0 && (
          <div className="border-t border-table-divider pt-2">
            <p className="font-sans text-label-md font-semibold text-ink-soft">
              {enRango ? 'Devoluciones del período' : 'Devoluciones del día'}
            </p>
            {enRango && (
              <p className="font-sans text-label-md text-ink-soft">Devuelto más de lo que se vendió en el período.</p>
            )}
            <ul className="mt-0.5">
              {devueltosVisibles.map((f) => (
                <li key={f.productoId} className="flex items-baseline justify-between gap-3 font-sans text-label-md text-ink-soft">
                  <span className="min-w-0 truncate" title={f.marca ? `${f.nombre} · ${f.marca}` : f.nombre}>
                    {f.nombre}
                    {f.marca && <span> · {f.marca}</span>}
                  </span>
                  <span className="shrink-0 whitespace-nowrap">
                    {formatCantidad(f.unidades)} unid. · {formatCurrency(f.importe)}
                  </span>
                </li>
              ))}
            </ul>
          </div>
        )}
      </div>
    </Modal>
  )
}
