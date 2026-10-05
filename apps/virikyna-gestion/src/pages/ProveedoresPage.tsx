import { useMemo, useState } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { Pencil, Trash2 } from 'lucide-react'
import type { ProveedorSaldo } from '@virikyna/shared'
import { supabase } from '../lib/supabaseClient'
import {
  formatCurrency,
  friendlyError,
  proveedorQueryKeys,
  RowActionsMenu,
  useProveedoresSaldo,
  type RowActionsMenuItem,
} from '@virikyna/shared'
import { SearchInput } from '../components/SearchInput'
import { ConfirmDialog } from '../components/ConfirmDialog'
import { ProveedorFormModal } from './Proveedores/ProveedorFormModal'
import { FacturasCompraTab } from './Proveedores/FacturasCompraTab'

const TABS = [
  { id: 'facturas', label: 'Facturas de compra' },
  { id: 'proveedores', label: 'Proveedores' },
] as const

type TabId = (typeof TABS)[number]['id']

// La pestaña vive en la URL (?tab=proveedores): volver desde la cuenta corriente de un proveedor
// (/proveedores/:id) cae en la lista de proveedores y no en Facturas, que es la de por defecto.
export function ProveedoresPage() {
  const [params, setParams] = useSearchParams()
  const tab: TabId = params.get('tab') === 'proveedores' ? 'proveedores' : 'facturas'

  return (
    <section className="flex h-full flex-col rounded-lg bg-surface p-card shadow-sm">
      <div>
        <h1 className="font-display text-headline-lg text-accent-darker">Proveedores</h1>
      </div>

      <div className="mt-stack-md flex gap-1 border-b border-line">
        {TABS.map((t) => (
          <button
            key={t.id}
            type="button"
            aria-pressed={tab === t.id}
            onClick={() => setParams(t.id === 'facturas' ? {} : { tab: t.id }, { replace: true })}
            className={[
              'rounded-t px-4 py-2 font-sans text-label-bold',
              tab === t.id
                ? 'border-b-2 border-accent text-accent-darker'
                : 'text-ink-soft hover:text-accent-darker',
            ].join(' ')}
          >
            {t.label}
          </button>
        ))}
      </div>

      <div className="mt-stack-md flex-1 overflow-hidden">
        {tab === 'proveedores' && <ProveedoresTab />}
        {tab === 'facturas' && <FacturasCompraTab />}
      </div>
    </section>
  )
}

function ProveedoresTab() {
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const { data: proveedores = [], isPending: loading, error: queryError } = useProveedoresSaldo(supabase)
  const [error, setError] = useState<string | null>(null)
  const [modal, setModal] = useState<'nuevo' | ProveedorSaldo | null>(null)
  const [aEliminar, setAEliminar] = useState<ProveedorSaldo | null>(null)
  const [eliminando, setEliminando] = useState(false)
  const [busqueda, setBusqueda] = useState('')

  const proveedoresFiltrados = useMemo(() => {
    const q = busqueda.trim().toLowerCase()
    if (!q) return proveedores
    return proveedores.filter(
      (p) => p.razon_social.toLowerCase().includes(q) || (p.cuit ?? '').toLowerCase().includes(q),
    )
  }, [proveedores, busqueda])

  // Lista + cabecera de cualquier cuenta corriente abierta (prefijo ['proveedor']).
  const recargar = () =>
    Promise.all([
      queryClient.invalidateQueries({ queryKey: proveedorQueryKeys.saldos }),
      queryClient.invalidateQueries({ queryKey: ['proveedor'] }),
    ])

  async function eliminar() {
    if (!aEliminar) return
    setEliminando(true)
    const { error: dbError } = await supabase.rpc('eliminar_proveedor', { p_proveedor_id: aEliminar.id })
    setEliminando(false)
    if (dbError) {
      setError(friendlyError(dbError, 'No se pudo eliminar: es posible que ya tenga productos o facturas asociadas.'))
      setAEliminar(null)
      return
    }
    setAEliminar(null)
    recargar()
  }

  const mensajeError = error ?? (queryError ? friendlyError(queryError as Error) : null)

  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center justify-between">
        <p className="font-sans text-body-md text-ink-soft">Tocá un proveedor para ver su cuenta corriente y registrar pagos.</p>
        <div className="flex items-center gap-3">
          <SearchInput value={busqueda} onChange={setBusqueda} placeholder="Buscar proveedor..." />
          <button
            type="button"
            onClick={() => setModal('nuevo')}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark"
          >
            + Nuevo proveedor
          </button>
        </div>
      </div>

      {mensajeError && (
        <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{mensajeError}</p>
      )}

      <div className="mt-stack-md flex-1 overflow-auto rounded-xl shadow-sm">
        <table className="w-full text-left font-sans text-table-row">
          <thead>
            <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
              <th className="whitespace-nowrap px-3 py-2.5">Razón social</th>
              <th className="whitespace-nowrap px-3 py-2.5">CUIT</th>
              <th className="whitespace-nowrap px-3 py-2.5">Teléfono</th>
              <th className="whitespace-nowrap px-3 py-2.5">Margen 1</th>
              <th className="whitespace-nowrap px-3 py-2.5">Margen 2</th>
              <th className="whitespace-nowrap px-3 py-2.5 text-right">Saldo</th>
              <th className="whitespace-nowrap px-3 py-2.5">
                <span className="sr-only">Acciones</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={7}>
                  Cargando...
                </td>
              </tr>
            )}
            {!loading && proveedores.length > 0 && proveedoresFiltrados.length === 0 && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={7}>
                  Sin resultados para "{busqueda}".
                </td>
              </tr>
            )}
            {!loading && proveedores.length === 0 && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={7}>
                  No hay proveedores cargados todavía.
                </td>
              </tr>
            )}
            {proveedoresFiltrados.map((proveedor) => {
              const items: RowActionsMenuItem[] = [
                { label: 'Editar', icon: Pencil, onClick: () => setModal(proveedor) },
                { label: 'Eliminar', icon: Trash2, onClick: () => setAEliminar(proveedor), destructive: true },
              ]
              return (
                <tr
                  key={proveedor.id}
                  onClick={() => navigate(`/proveedores/${proveedor.id}`)}
                  className="cursor-pointer border-b border-table-divider last:border-0 even:bg-table-row-alt hover:bg-accent-light/40"
                >
                  <td className="px-3 py-3 text-ink">
                    {/* El link es el foco de teclado de la fila (Enter abre); el click en la fila es atajo de mouse. */}
                    <Link
                      to={`/proveedores/${proveedor.id}`}
                      onClick={(e) => e.stopPropagation()}
                      className="rounded hover:underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
                    >
                      {proveedor.razon_social}
                    </Link>
                  </td>
                  <td className="px-3 py-3 text-ink-soft">{proveedor.cuit ?? '—'}</td>
                  <td className="px-3 py-3 text-ink-soft">{proveedor.telefono ?? '—'}</td>
                  <td className="px-3 py-3 text-ink-soft">{proveedor.margen_1_default}%</td>
                  <td className="px-3 py-3 text-ink-soft">{proveedor.margen_2_default}%</td>
                  <td
                    className={`px-3 py-3 text-right font-semibold tabular-nums ${
                      proveedor.saldo_actual > 0 ? 'text-error' : proveedor.saldo_actual < 0 ? 'text-success' : 'text-ink-soft'
                    }`}
                  >
                    {formatCurrency(proveedor.saldo_actual)}
                  </td>
                  <td className="px-3 py-3 text-right" onClick={(e) => e.stopPropagation()}>
                    <RowActionsMenu ariaLabel={`Más acciones para ${proveedor.razon_social}`} items={items} />
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      {modal && (
        <ProveedorFormModal
          proveedor={modal === 'nuevo' ? undefined : modal}
          onClose={() => setModal(null)}
          onSaved={() => {
            setModal(null)
            recargar()
          }}
        />
      )}

      {aEliminar && (
        <ConfirmDialog
          title="Eliminar proveedor"
          mensaje={`¿Eliminar a "${aEliminar.razon_social}"? Esta acción no se puede deshacer.`}
          confirmando={eliminando}
          onCancel={() => setAEliminar(null)}
          onConfirm={eliminar}
        />
      )}
    </div>
  )
}
