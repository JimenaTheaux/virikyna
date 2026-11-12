import { useParamsPagina } from '@virikyna/shared/lib/estadoPagina'
import { ProveedoresTab } from './ProveedoresTab'
import { FacturasCompraTab } from './FacturasCompraTab'

const TABS = [
  { id: 'facturas', label: 'Facturas de compra' },
  { id: 'proveedores', label: 'Proveedores' },
] as const

type TabId = (typeof TABS)[number]['id']
const TAB_DEFAULT = { tab: 'facturas' }

// La pestaña vive en la URL (?tab=proveedores): volver desde la cuenta corriente de un proveedor
// (/proveedores/:id) cae en la lista de proveedores y no en Facturas, que es la de por defecto.
// También se recuerda en la sesión (docs/73): volver desde el menú cae en la misma pestaña.
export function ProveedoresPage() {
  const { valores, set } = useParamsPagina('proveedores:tab', TAB_DEFAULT)
  const tab: TabId = valores.tab === 'proveedores' ? 'proveedores' : 'facturas'

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
            onClick={() => set({ tab: t.id })}
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
