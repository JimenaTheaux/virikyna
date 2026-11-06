import { useMemo, useState, type ComponentType } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Eye, Pencil, Trash2 } from 'lucide-react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { ClienteSaldo } from '../../types/database'
import { clienteQueryKeys, nombreCliente, useClientesSaldo } from '../../lib/cuentaCorrienteCliente'
import { formatCurrency } from '../../lib/format'
import { friendlyError } from '../../lib/supabaseErrors'
import { textoParaBuscar } from '../../lib/texto'
import { EstadoBadge } from './EstadoBadge'
import { RowActionsMenu, type RowActionsMenuItem } from './RowActionsMenu'
import { ConfirmDialog } from './ConfirmDialog'
import { ClienteFormModal } from './ClienteFormModal'

type Props = {
  supabase: SupabaseClient
  // Cada app tiene su buscador (mismo aspecto, su propio ícono).
  SearchInput: ComponentType<{ value: string; onChange: (value: string) => void; placeholder: string }>
  onAbrirCuenta: (clienteId: string) => void // /clientes/:id
}

// Listado de clientes con su saldo (docs/04, módulo 8). Igual en Local y Gestión (antes, una copia
// por app). Abrir un cliente lleva a su cuenta corriente (ClienteCuentaCorriente, docs/68).
export function ClientesPage({ supabase, SearchInput, onAbrirCuenta }: Props) {
  const queryClient = useQueryClient()
  const clientesQ = useClientesSaldo(supabase)
  const clientes = useMemo(() => clientesQ.data ?? [], [clientesQ.data])
  const [modal, setModal] = useState<'nuevo' | ClienteSaldo | null>(null)
  const [busqueda, setBusqueda] = useState('')

  const [aEliminar, setAEliminar] = useState<ClienteSaldo | null>(null)
  const [errorEliminar, setErrorEliminar] = useState<string | null>(null)
  const [procesandoEliminar, setProcesandoEliminar] = useState(false)

  const clientesFiltrados = useMemo(() => {
    const q = textoParaBuscar(busqueda)
    if (!q) return clientes
    return clientes.filter((c) =>
      [c.razon_social, c.nombre_fantasia, c.cuit, c.mail].some((campo) => textoParaBuscar(campo).includes(q)),
    )
  }, [clientes, busqueda])

  const recargar = () => queryClient.invalidateQueries({ queryKey: clienteQueryKeys.saldos })

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
      void recargar()
      return
    }

    const { error: dbError } = await supabase.from('clientes').update({ activo: false }).eq('id', aEliminar.id)
    setProcesandoEliminar(false)
    if (dbError) {
      setErrorEliminar(friendlyError(dbError))
      return
    }
    cerrarEliminar()
    void recargar()
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

      {clientesQ.error && (
        <p className="mt-stack-md rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">{friendlyError(clientesQ.error as Error)}</p>
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
              <th className="whitespace-nowrap px-3 py-2.5">
                <span className="sr-only">Acciones</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {clientesQ.isPending && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={6}>
                  Cargando...
                </td>
              </tr>
            )}
            {!clientesQ.isPending && clientes.length > 0 && clientesFiltrados.length === 0 && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={6}>
                  Sin resultados para "{busqueda}".
                </td>
              </tr>
            )}
            {!clientesQ.isPending && clientes.length === 0 && (
              <tr>
                <td className="px-4 py-4 text-ink-soft" colSpan={6}>
                  No hay clientes cargados todavía.
                </td>
              </tr>
            )}
            {clientesFiltrados.map((cliente) => {
              const nombre = nombreCliente(cliente)
              const items: RowActionsMenuItem[] = [
                { label: 'Ver cuenta corriente', icon: Eye, onClick: () => onAbrirCuenta(cliente.id) },
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
                <tr
                  key={cliente.id}
                  onClick={() => onAbrirCuenta(cliente.id)}
                  className="cursor-pointer border-b border-table-divider last:border-0 even:bg-table-row-alt hover:bg-accent-light/40"
                >
                  <td className="px-3 py-3 text-ink">
                    <button
                      type="button"
                      onClick={(e) => {
                        e.stopPropagation()
                        onAbrirCuenta(cliente.id)
                      }}
                      aria-label={`Ver cuenta corriente de ${nombre}`}
                      className="rounded text-left hover:underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
                    >
                      {nombre}
                    </button>
                  </td>
                  <td className="px-3 py-3 text-ink-soft">{cliente.cuit ?? '—'}</td>
                  <td className="px-3 py-3 text-ink-soft">{cliente.celular ?? '—'}</td>
                  <td className={`px-3 py-3 text-right font-semibold tabular-nums ${cliente.saldo_actual > 0 ? 'text-error' : 'text-ink-soft'}`}>
                    {formatCurrency(cliente.saldo_actual)}
                  </td>
                  <td className="px-3 py-3">
                    <EstadoBadge variant={cliente.activo ? 'green' : 'neutral'}>{cliente.activo ? 'Activo' : 'Inactivo'}</EstadoBadge>
                  </td>
                  <td className="px-3 py-3 text-right" onClick={(e) => e.stopPropagation()}>
                    <RowActionsMenu ariaLabel={`Más acciones para ${nombre}`} items={items} />
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      {modal && (
        <ClienteFormModal
          supabase={supabase}
          cliente={modal === 'nuevo' ? undefined : modal}
          onClose={() => setModal(null)}
          onSaved={() => {
            setModal(null)
            void recargar()
          }}
        />
      )}

      {aEliminar && (
        <ConfirmDialog
          title={errorEliminar ? 'No se pudo eliminar' : 'Eliminar cliente'}
          mensaje={
            errorEliminar
              ? `${errorEliminar} ¿Querés inactivar a "${nombreCliente(aEliminar)}" en su lugar?`
              : `¿Eliminar a "${nombreCliente(aEliminar)}"?`
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
