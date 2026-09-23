import { useEffect, useMemo, useState } from 'react'
import { Pencil, Trash2 } from 'lucide-react'
import type { ProveedorSaldo } from '@virikyna/shared'
import { supabase } from '../lib/supabaseClient'
import { formatCurrency, friendlyError } from '@virikyna/shared'
import { SearchInput } from '../components/SearchInput'
import { ConfirmDialog } from '../components/ConfirmDialog'
import { ProveedorFormModal } from './Proveedores/ProveedorFormModal'
import { FacturasCompraTab } from './Proveedores/FacturasCompraTab'

const TABS = [
  { id: 'facturas', label: 'Facturas de compra' },
  { id: 'proveedores', label: 'Proveedores' },
] as const

type TabId = (typeof TABS)[number]['id']

export function ProveedoresPage() {
  const [tab, setTab] = useState<TabId>('facturas')

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
            onClick={() => setTab(t.id)}
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
  const [proveedores, setProveedores] = useState<ProveedorSaldo[]>([])
  const [loading, setLoading] = useState(true)
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

  async function cargar() {
    setLoading(true)
    setError(null)
    const { data, error: dbError } = await supabase.from('proveedores_saldo').select('*').order('razon_social')
    if (dbError) {
      setError(friendlyError(dbError))
    } else {
      setProveedores((data ?? []) as ProveedorSaldo[])
    }
    setLoading(false)
  }

  useEffect(() => {
    cargar()
  }, [])

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
    cargar()
  }

  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center justify-between">
        <p className="font-sans text-body-md text-ink-soft">Datos de contacto y márgenes por defecto.</p>
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

      {error && (
        <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>
      )}

      <div className="mt-stack-md flex-1 overflow-auto rounded-lg border border-line">
        <table className="w-full text-left font-sans text-body-md leading-5">
          <thead>
            <tr className="border-b border-line bg-bg text-label-bold text-ink-soft">
              <th className="whitespace-nowrap px-3 py-2">Razón social</th>
              <th className="whitespace-nowrap px-3 py-2">CUIT</th>
              <th className="whitespace-nowrap px-3 py-2">Teléfono</th>
              <th className="whitespace-nowrap px-3 py-2">Margen 1</th>
              <th className="whitespace-nowrap px-3 py-2">Margen 2</th>
              <th className="whitespace-nowrap px-3 py-2 text-right">Saldo</th>
              <th className="whitespace-nowrap px-3 py-2"></th>
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
            {proveedoresFiltrados.map((proveedor) => (
              <tr key={proveedor.id} className="border-b border-line last:border-0">
                <td className="px-3 py-1.5 text-ink">{proveedor.razon_social}</td>
                <td className="px-3 py-1.5 text-ink-soft">{proveedor.cuit ?? '—'}</td>
                <td className="px-3 py-1.5 text-ink-soft">{proveedor.telefono ?? '—'}</td>
                <td className="px-3 py-1.5 text-ink-soft">{proveedor.margen_1_default}%</td>
                <td className="px-3 py-1.5 text-ink-soft">{proveedor.margen_2_default}%</td>
                <td
                  className={`px-3 py-1.5 text-right ${proveedor.saldo_actual > 0 ? 'text-error' : 'text-ink-soft'}`}
                >
                  {formatCurrency(proveedor.saldo_actual)}
                </td>
                <td className="px-3 py-1.5 text-right">
                  <button
                    type="button"
                    onClick={() => setModal(proveedor)}
                    title="Editar"
                    aria-label="Editar"
                    className="rounded px-3 py-1.5 text-accent-dark hover:bg-accent-light"
                  >
                    <Pencil size={18} strokeWidth={1.5} />
                  </button>
                  <button
                    type="button"
                    onClick={() => setAEliminar(proveedor)}
                    title="Eliminar"
                    aria-label="Eliminar"
                    className="rounded px-3 py-1.5 text-error hover:bg-error/10"
                  >
                    <Trash2 size={18} strokeWidth={1.5} />
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {modal && (
        <ProveedorFormModal
          proveedor={modal === 'nuevo' ? undefined : modal}
          onClose={() => setModal(null)}
          onSaved={() => {
            setModal(null)
            cargar()
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
