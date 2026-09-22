import { useState } from 'react'
import { RegistrarEgresoTab } from './Egresos/RegistrarEgresoTab'
import { HistorialEgresosTab } from './Egresos/HistorialEgresosTab'

const TABS = [
  { id: 'registrar', label: 'Registrar egreso' },
  { id: 'historial', label: 'Historial' },
] as const

type TabId = (typeof TABS)[number]['id']

// Módulo de primer nivel, separado de Caja Gestión (docs/04_modulos_y_funciones.md, módulo
// Egresos) — comparte el RPC registrar_egreso_general, pero acá siempre va con origen='general'.
export function EgresosPage() {
  const [tab, setTab] = useState<TabId>('registrar')

  return (
    <section className="flex h-full flex-col rounded-lg bg-surface p-card shadow-sm">
      <div>
        <h1 className="font-display text-headline-lg text-accent-darker">Egresos</h1>
        <p className="mt-1 font-sans text-body-md text-ink-soft">
          Egresos generales de la sucursal (sueldos, servicios) e historial completo de egresos.
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

      <div className="mt-stack-md flex-1 overflow-auto">
        {tab === 'registrar' && <RegistrarEgresoTab />}
        {tab === 'historial' && <HistorialEgresosTab />}
      </div>
    </section>
  )
}
