import { useParamsPagina } from '@virikyna/shared/lib/estadoPagina'
import { VentasDelDiaTab } from './VentasDelDiaTab'
import { FacturacionTab } from './FacturacionTab'
import { DevolucionesTab } from './DevolucionesTab'

const TABS = [
  { id: 'ventas_dia', label: 'Ventas del día' },
  { id: 'facturacion', label: 'Facturación' },
  { id: 'devoluciones', label: 'Devoluciones' },
] as const

type TabId = (typeof TABS)[number]['id']
const TAB_DEFAULT = { tab: 'ventas_dia' }

export function FacturacionPage() {
  // Pestaña en la URL (?tab=facturacion) y recordada en la sesión (docs/73): recargar o volver desde
  // el menú cae en la misma pestaña, con sus filtros.
  const { valores, set } = useParamsPagina('facturacion:tab', TAB_DEFAULT)
  const tab: TabId = TABS.some((t) => t.id === valores.tab) ? (valores.tab as TabId) : 'ventas_dia'
  const setTab = (id: TabId) => set({ tab: id })

  return (
    <section className="flex h-full flex-col rounded-lg bg-surface p-card shadow-sm">
      <div>
        <h1 className="font-display text-headline-lg text-accent-darker">Facturación</h1>
        <p className="mt-1 font-sans text-body-md text-ink-soft">
          Elegí qué comprobantes se facturan formalmente y cuándo — cobrar y facturar son acciones separadas.
        </p>
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
        {tab === 'ventas_dia' && <VentasDelDiaTab />}
        {tab === 'facturacion' && <FacturacionTab />}
        {tab === 'devoluciones' && <DevolucionesTab />}
      </div>
    </section>
  )
}
