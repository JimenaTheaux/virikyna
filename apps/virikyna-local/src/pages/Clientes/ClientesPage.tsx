import { useEffect, useMemo, useState } from 'react'
import { Eye, Pencil, Trash2 } from 'lucide-react'
import type { ClienteSaldo } from '@virikyna/shared'
import { supabase } from '../../lib/supabaseClient'
import { formatCurrency, friendlyError, EstadoBadge, RowActionsMenu, type RowActionsMenuItem } from '@virikyna/shared'
import { SearchInput } from '../../components/SearchInput'
import { ConfirmDialog } from '../../components/ConfirmDialog'
import { ClienteFormModal } from './ClienteFormModal'
import { ClienteDetalleModal } from './ClienteDetalleModal'

export function ClientesPage() {
  const [clientes, setClientes] = useState<ClienteSaldo[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [modal, setModal] = useState<'nuevo' | ClienteSaldo | null>(null)
  const [verDetalle, setVerDetalle] = useState<ClienteSaldo | null>(null)
  const [busqueda, setBusqueda] = useState('')

  const [aEliminar, setAEliminar] = useState<ClienteSaldo | null>(null)
  const [errorEliminar, setErrorEliminar] = useState<string | null>(null)
  const [procesandoEliminar, setProcesandoEliminar] = useState(false)

  const clientesFiltrados = useMemo(() => {
    const q = busqueda.trim().toLowerCase()
    if (!q) return clientes
    return clientes.filter((c) =>
      [c.razon_social, c.nombre_fantasia, c.cuit, c.mail].some((campo) => (campo ?? '').toLowerCase().includes(q)),
    )
  }, [clientes, busqueda])

  async function cargar() {
    setLoading(true)
    setError(null)
    // `clientes_saldo` (nunca `clientes` a secas): el saldo es saldo_inicial + ventas a cta.
    // cte. − pagos, siempre calculado en la base, nunca a mano en el frontend.
    const { data, error: dbError } = await supabase
      .from('clientes_saldo')
      .select('*')
      .order('razon_social', { ascending: true, nullsFirst: false })
    if (dbError) {
      setError(friendlyError(dbError))
    } else {
      setClientes((data ?? []) as ClienteSaldo[])
    }
    setLoading(false)
  }

  useEffect(() => {
    cargar()
  }, [])

  function cerrarEliminar() {
    setAEliminar(null)
    setErrorEliminar(null)
    setProcesandoEliminar(false)
  }

  // Primer click intenta eliminar. Si el cliente tiene historial, la base lo rechaza con un
  // mensaje claro (docs/04_modulos_y_funciones.md, módulo 8) — se lo mostramos tal cual y
  // ofrecemos inactivar en su lugar como una acción aparte, no como fallback silencioso.
  async function confirmarEliminar() {
    if (!aEliminar) return
    setProcesandoEliminar(true)

    if (!errorEliminar) {
      const { error: dbError } = await supabase.from('clientes').delete().eq('id', aEliminar.id)
      setProcesandoEliminar(false)
      if (dbError) {
        setErrorEliminar(friendlyError(dbError))
        return
      }
      cerrarEliminar()
      cargar()
      return
    }

    const { error: dbError } = await supabase.from('clientes').update({ activo: false }).eq('id', aEliminar.id)
    setProcesandoEliminar(false)
    if (dbError) {
      setErrorEliminar(friendlyError(dbError))
      return
    }
    cerrarEliminar()
    cargar()
  }

  return (
    <section className="flex h-full flex-col rounded-lg bg-surface p-card shadow-sm">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="font-display text-headline-lg text-accent-darker">Cuentas corrientes</h1>
          <p className="mt-1 font-sans text-body-md text-ink-soft">Datos de clientes y cuenta corriente.</p>
        </div>
        <div className="flex items-center gap-3">
          <SearchInput value={busqueda} onChange={setBusqueda} placeholder="Buscar cliente..." />
          <button
            type="button"
            onClick={() => setModal('nuevo')}
            className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark"
          >
            + Nuevo cliente
          </button>
        </div>
      </div>

      {error && (
        <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{error}</p>
      )}

      <div className="mt-stack-md flex-1 overflow-auto rounded-xl shadow-sm">
        <table className="w-full text-left font-sans text-table-row">
          <thead>
            <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
              <th className="whitespace-nowrap px-3 py-2.5">Nombre</th>
              <th className="whitespace-nowrap px-3 py-2.5">CUIT</th>
              <th className="whitespace-nowrap px-3 py-2.5">Celular</th>
              <th className="whitespace-nowrap px-3 py-2.5 text-right">Saldo cta. cte.</th>
              <th className="whitespace-nowrap px-3 py-2.5">Estado</th>
              <th className="whitespace-nowrap px-3 py-2.5"></th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={6}>
                  Cargando...
                </td>
              </tr>
            )}
            {!loading && clientes.length > 0 && clientesFiltrados.length === 0 && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={6}>
                  Sin resultados para "{busqueda}".
                </td>
              </tr>
            )}
            {!loading && clientes.length === 0 && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={6}>
                  No hay clientes cargados todavía.
                </td>
              </tr>
            )}
            {clientesFiltrados.map((cliente) => {
              const items: RowActionsMenuItem[] = [
                { label: 'Ver detalle', icon: Eye, onClick: () => setVerDetalle(cliente) },
                { label: 'Editar', icon: Pencil, onClick: () => setModal(cliente) },
              ]
              if (cliente.activo) {
                items.push({
                  label: 'Eliminar',
                  icon: Trash2,
                  onClick: () => setAEliminar(cliente),
                  destructive: true,
                })
              }
              return (
                <tr key={cliente.id} className="border-b border-table-divider last:border-0 even:bg-table-row-alt">
                  <td className="px-3 py-3 text-ink">{cliente.razon_social ?? cliente.nombre_fantasia}</td>
                  <td className="px-3 py-3 text-ink-soft">{cliente.cuit ?? '—'}</td>
                  <td className="px-3 py-3 text-ink-soft">{cliente.celular ?? '—'}</td>
                  <td className={`px-3 py-3 text-right font-semibold ${cliente.saldo_actual > 0 ? 'text-error' : 'text-ink-soft'}`}>
                    {formatCurrency(cliente.saldo_actual)}
                  </td>
                  <td className="px-3 py-3">
                    <EstadoBadge variant={cliente.activo ? 'green' : 'neutral'}>
                      {cliente.activo ? 'Activo' : 'Inactivo'}
                    </EstadoBadge>
                  </td>
                  <td className="px-3 py-3 text-right">
                    <RowActionsMenu
                      ariaLabel={`Más acciones para ${cliente.razon_social ?? cliente.nombre_fantasia}`}
                      items={items}
                    />
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      {modal && (
        <ClienteFormModal
          cliente={modal === 'nuevo' ? undefined : modal}
          onClose={() => setModal(null)}
          onSaved={() => {
            setModal(null)
            cargar()
          }}
        />
      )}

      {verDetalle && (
        <ClienteDetalleModal
          cliente={verDetalle}
          onClose={() => setVerDetalle(null)}
          onChanged={cargar}
        />
      )}

      {aEliminar && (
        <ConfirmDialog
          title={errorEliminar ? 'No se pudo eliminar' : 'Eliminar cliente'}
          mensaje={
            errorEliminar
              ? `${errorEliminar} ¿Querés inactivar a "${aEliminar.razon_social ?? aEliminar.nombre_fantasia}" en su lugar?`
              : `¿Eliminar a "${aEliminar.razon_social ?? aEliminar.nombre_fantasia}"?`
          }
          confirmLabel={errorEliminar ? 'Inactivar' : 'Eliminar'}
          confirmando={procesandoEliminar}
          onCancel={cerrarEliminar}
          onConfirm={confirmarEliminar}
        />
      )}
    </section>
  )
}
