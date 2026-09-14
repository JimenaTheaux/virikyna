import { NavLink, Outlet } from 'react-router-dom'
import { usePerfil, useAuth } from '../auth/AuthContext'
import { Footer } from '@virikyna/shared'
import virikynaWordmark from '@virikyna/shared/src/assets/virikyna-wordmark.png'
import {
  IconCajaGestion,
  IconCambiarUsuario,
  IconClientes,
  IconConfiguracion,
  IconDashboard,
  IconEgresos,
  IconFacturacion,
  IconHistorial,
  IconInventario,
  IconNotas,
  IconProveedores,
} from '../components/icons'

type NavItem = { to: string; label: string; Icon: typeof IconDashboard }

// Dashboard y Caja Gestión van sueltos arriba de todo, sin sección — Caja Gestión es el otro
// panel de "vista general" de la dueña, no un ítem más de Gestión operativa.
const TOP_ITEMS: NavItem[] = [
  { to: '/dashboard', label: 'Dashboard', Icon: IconDashboard },
  { to: '/caja-gestion', label: 'Caja Gestión', Icon: IconCajaGestion },
]

// Sin sección "Operación" ni ítem de Ventas — Virikyna Gestión es todo el CRUD de Admin
// salvo Ventas/cobro, que depende del motor local de la Caja (docs/05_stack_tecnico.md, sección 3).
const NAV_SECTIONS: { title: string; items: NavItem[] }[] = [
  {
    title: 'Gestión',
    items: [
      { to: '/inventario', label: 'Inventario', Icon: IconInventario },
      { to: '/proveedores', label: 'Proveedores', Icon: IconProveedores },
      { to: '/clientes', label: 'Cuentas corrientes', Icon: IconClientes },
      { to: '/facturacion', label: 'Facturación', Icon: IconFacturacion },
      { to: '/egresos', label: 'Egresos', Icon: IconEgresos },
      { to: '/notas', label: 'Notas', Icon: IconNotas },
    ],
  },
  {
    title: 'Cuenta',
    items: [
      { to: '/historial', label: 'Historial y Auditoría', Icon: IconHistorial },
      { to: '/configuracion', label: 'Configuración', Icon: IconConfiguracion },
    ],
  },
]

function NavItemLink({ to, label, Icon }: NavItem) {
  return (
    <NavLink
      to={to}
      className={({ isActive }) =>
        [
          'flex items-center gap-3 rounded px-3 py-[10px] font-sans text-body-md',
          isActive
            ? 'bg-accent-light text-accent-darker font-medium'
            : 'text-ink-soft hover:bg-accent-light hover:text-accent-darker',
        ].join(' ')
      }
    >
      {({ isActive }) => (
        <>
          <Icon className="h-5 w-5 flex-shrink-0" filled={isActive} />
          {label}
        </>
      )}
    </NavLink>
  )
}

export function AppShell() {
  const { perfil } = usePerfil()
  const { signOut } = useAuth()

  return (
    <div className="flex h-screen overflow-hidden bg-bg text-ink">
      <aside className="flex w-[248px] flex-shrink-0 flex-col overflow-y-auto border-r border-line bg-surface">
        <div className="flex items-center gap-3 border-b border-line px-6 py-6">
          <img src={virikynaWordmark} alt="Virikyna" className="h-9 w-auto" />
        </div>
        <nav className="flex-1 px-3 py-4">
          <div className="mb-6 flex flex-col gap-1">
            {TOP_ITEMS.map((item) => (
              <NavItemLink key={item.to} {...item} />
            ))}
          </div>
          {NAV_SECTIONS.map((section) => (
            <div key={section.title} className="mb-6 last:mb-0">
              <p className="mb-2 px-3 font-sans text-label-md uppercase tracking-wide text-ink-soft">
                {section.title}
              </p>
              <div className="flex flex-col gap-1">
                {section.items.map((item) => (
                  <NavItemLink key={item.to} {...item} />
                ))}
              </div>
            </div>
          ))}
        </nav>
      </aside>
      <div className="flex flex-1 flex-col overflow-hidden">
        <header className="flex h-[64px] flex-shrink-0 items-center justify-end gap-3 border-b border-line bg-surface px-7 shadow-sm">
          <div className="flex items-center gap-2 rounded-full bg-bg px-4 py-2 font-sans text-label-bold text-ink-soft">
            Virikyna Gestión
          </div>
          {perfil && (
            <div className="flex items-center gap-2 rounded-full bg-bg px-4 py-2 font-sans text-label-bold text-ink-soft">
              {perfil.nombre} · Admin
            </div>
          )}
          <button
            type="button"
            onClick={() => signOut()}
            className="flex items-center gap-2 rounded px-3 py-2 font-sans text-label-bold text-ink-soft hover:bg-accent-light hover:text-accent-darker"
            title="Cambiar de usuario"
          >
            <IconCambiarUsuario className="h-5 w-5" />
            Cambiar de usuario
          </button>
        </header>
        <main className="flex-1 overflow-auto p-card md:pb-10">
          <Outlet />
          <Footer />
        </main>
      </div>
    </div>
  )
}
