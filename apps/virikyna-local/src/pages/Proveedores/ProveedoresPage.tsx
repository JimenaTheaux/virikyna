import { useState } from 'react'
import { ProveedoresTab } from './ProveedoresTab'
import { FacturasCompraTab } from './FacturasCompraTab'

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
              'rounded-t px-4 py-3 font-sans text-label-bold',
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
