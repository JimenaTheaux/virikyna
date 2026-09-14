import { useState } from 'react'
import { VentasDelDiaTab } from './VentasDelDiaTab'
import { FacturacionTab } from './FacturacionTab'

const TABS = [
  { id: 'ventas_dia', label: 'Ventas del día' },
  { id: 'facturacion', label: 'Facturación' },
] as const

type TabId = (typeof TABS)[number]['id']

export function FacturacionPage() {
  const [tab, setTab] = useState<TabId>('ventas_dia')

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
        {tab === 'ventas_dia' && <VentasDelDiaTab />}
        {tab === 'facturacion' && <FacturacionTab />}
      </div>
    </section>
  )
}
