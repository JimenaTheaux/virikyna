import { useEffect, useMemo, useState } from 'react'
import { Pencil } from 'lucide-react'
import type { ProveedorSaldo } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { formatCurrency, friendlyError } from '@virikyna/shared'
import { SearchInput } from '../../components/SearchInput'
import { ProveedorFormModal } from './ProveedorFormModal'

// Lista de proveedores con saldo visible (docs/04_modulos_y_funciones.md, módulo 6) — el saldo
// sale de la vista `proveedores_saldo` (docs/06_estructura_de_datos.md, sección 9), nunca se
// recalcula acá: saldo inicial + facturado − pagado.
export function ProveedoresTab() {
  const [proveedores, setProveedores] = useState<ProveedorSaldo[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [modal, setModal] = useState<'nuevo' | ProveedorSaldo | null>(null)
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

  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center justify-between">
        <p className="font-sans text-body-md text-ink-soft">Datos de contacto, márgenes por defecto y saldo.</p>
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
              <th className="px-3 py-2">Razón social</th>
              <th className="px-3 py-2">CUIT</th>
              <th className="px-3 py-2">Teléfono</th>
              <th className="px-3 py-2 text-right">Saldo</th>
              <th className="px-3 py-2"></th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={5}>
                  Cargando...
                </td>
              </tr>
            )}
            {!loading && proveedores.length > 0 && proveedoresFiltrados.length === 0 && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={5}>
                  Sin resultados para "{busqueda}".
                </td>
              </tr>
            )}
            {!loading && proveedores.length === 0 && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={5}>
                  No hay proveedores cargados todavía.
                </td>
              </tr>
            )}
            {proveedoresFiltrados.map((proveedor) => (
              <tr key={proveedor.id} className="border-b border-line last:border-0">
                <td className="px-3 py-1.5 text-ink">{proveedor.razon_social}</td>
                <td className="px-3 py-1.5 text-ink-soft">{proveedor.cuit ?? '—'}</td>
                <td className="px-3 py-1.5 text-ink-soft">{proveedor.telefono ?? '—'}</td>
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
    </div>
  )
}
