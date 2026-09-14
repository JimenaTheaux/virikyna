import { NavLink, Outlet } from 'react-router-dom'
import { usePerfil, useAuth } from '../auth/AuthContext'
import { Footer } from '@virikyna/shared'
import { IconFacturas, IconInventario, IconSalir } from '../components/icons'

const TAB_CLASS =
  'flex flex-1 flex-col items-center justify-center gap-1 py-2 font-sans text-label-md'

export function AppShell() {
  const { perfil } = usePerfil()
  const { signOut } = useAuth()

  return (
    <div className="flex h-[100dvh] flex-col overflow-hidden bg-bg text-ink">
      <header className="flex flex-shrink-0 items-center justify-between border-b border-line bg-surface px-4 py-3 pt-[calc(env(safe-area-inset-top,0px)+12px)]">
        <span className="font-display text-headline-md text-accent-darker">Virikyna</span>
        {perfil && (
          <span className="rounded-full bg-bg px-3 py-1.5 font-sans text-label-md text-ink-soft">
            {perfil.nombre} · {perfil.rol === 'admin' ? 'Admin' : 'Cajero'}
          </span>
        )}
      </header>

      <main className="flex-1 overflow-y-auto p-stack-md pb-[calc(84px+env(safe-area-inset-bottom,0px))]">
        <Outlet />
        <Footer />
      </main>

      <nav className="fixed inset-x-0 bottom-0 z-40 flex border-t border-line bg-surface pb-[env(safe-area-inset-bottom,0px)] shadow-[0_-2px_8px_rgba(0,0,0,0.06)]">
        <NavLink
          to="/inventario"
          className={({ isActive }) =>
            [TAB_CLASS, isActive ? 'text-accent-dark' : 'text-ink-soft'].join(' ')
          }
        >
          <IconInventario className="h-6 w-6" />
          Inventario
        </NavLink>
        <NavLink
          to="/facturas"
          className={({ isActive }) =>
            [TAB_CLASS, isActive ? 'text-accent-dark' : 'text-ink-soft'].join(' ')
          }
        >
          <IconFacturas className="h-6 w-6" />
          Facturas
        </NavLink>
        <button type="button" onClick={() => signOut()} className={[TAB_CLASS, 'text-ink-soft'].join(' ')}>
          <IconSalir className="h-6 w-6" />
          Salir
        </button>
      </nav>
    </div>
  )
}
