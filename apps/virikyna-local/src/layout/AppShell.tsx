import { NavLink, Outlet } from 'react-router-dom'
import { usePerfil, useAuth } from '../auth/AuthContext'
import { Footer } from '@virikyna/shared'
import virikynaWordmark from '@virikyna/shared/src/assets/virikyna-wordmark.png'
import {
  IconCambiarUsuario,
  IconCierreCaja,
  IconClientes,
  IconConfiguracion,
  IconDashboard,
  IconFacturacion,
  IconInventario,
  IconNotas,
  IconProveedores,
  IconVentas,
} from '../components/icons'
import type { RolUsuario } from '@virikyna/shared'

type NavItem = { to: string; label: string; Icon: typeof IconVentas; roles: RolUsuario[] }

// Dashboard va suelto arriba de todo, sin sección, antes de los grupos.
// Caja Gestión NO vive acá — es exclusiva de Virikyna Gestión (docs/02_roles_y_permisos.md).
const TOP_ITEMS: NavItem[] = [
  { to: '/dashboard', label: 'Dashboard', Icon: IconDashboard, roles: ['admin', 'cajero'] },
]

// Experimento sidebar-nav: los ítems ahora se agrupan por sección (título chico
// en mayúscula) en vez de una sola fila horizontal.
const NAV_SECTIONS: { title: string; items: NavItem[] }[] = [
  {
    title: 'Operación',
    items: [
      { to: '/ventas', label: 'Ventas', Icon: IconVentas, roles: ['admin', 'cajero'] },
      { to: '/facturacion', label: 'Facturación', Icon: IconFacturacion, roles: ['admin', 'cajero'] },
    ],
  },
  {
    title: 'Gestión',
    items: [
      { to: '/inventario', label: 'Inventario', Icon: IconInventario, roles: ['admin', 'cajero'] },
      { to: '/proveedores', label: 'Proveedores', Icon: IconProveedores, roles: ['admin', 'cajero'] },
      { to: '/clientes', label: 'Cuentas corrientes', Icon: IconClientes, roles: ['admin', 'cajero'] },
      { to: '/cierre-caja', label: 'Cierre de Caja', Icon: IconCierreCaja, roles: ['admin', 'cajero'] },
      { to: '/notas', label: 'Notas', Icon: IconNotas, roles: ['admin', 'cajero'] },
    ],
  },
  {
    title: 'Cuenta',
    items: [{ to: '/configuracion', label: 'Configuración', Icon: IconConfiguracion, roles: ['admin'] }],
  },
]

function NavItemLink({ to, label, Icon }: NavItem) {
  return (
    <NavLink
      to={to}
      className={({ isActive }) =>
        [
          // Excepción a propósito: los ítems del sidebar van en `body-md`
          // (16px, escala normal), no en la escala grande del resto de la
          // app — en un menú angosto, letra grande satura y muestra menos
          // ítems de una. No es un olvido del pedido de "letras grandes".
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

  const topItems = TOP_ITEMS.filter((item) => perfil && item.roles.includes(perfil.rol))
  const sections = NAV_SECTIONS.map((section) => ({
    title: section.title,
    items: section.items.filter((item) => perfil && item.roles.includes(perfil.rol)),
  })).filter((section) => section.items.length > 0)

  return (
    <div className="flex h-screen overflow-hidden bg-bg text-ink">
      <aside className="flex w-[248px] flex-shrink-0 flex-col overflow-y-auto border-r border-line bg-surface">
        <div className="flex items-center gap-3 border-b border-line px-6 py-6">
          <img src={virikynaWordmark} alt="Virikyna" className="h-9 w-auto" />
        </div>
        <nav className="flex-1 px-3 py-4">
          {topItems.length > 0 && (
            <div className="mb-6 flex flex-col gap-1">
              {topItems.map((item) => (
                <NavItemLink key={item.to} {...item} />
              ))}
            </div>
          )}
          {sections.map((section) => (
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
            Terminal #001
          </div>
          {perfil && (
            <div className="flex items-center gap-2 rounded-full bg-bg px-4 py-2 font-sans text-label-bold text-ink-soft">
              {perfil.nombre} · {perfil.rol === 'admin' ? 'Admin' : 'Cajero'}
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
