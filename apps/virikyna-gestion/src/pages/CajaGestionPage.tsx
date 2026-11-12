import { avisarIntentoSalir } from '@virikyna/shared'
import { useParamsPagina } from '@virikyna/shared/lib/estadoPagina'
import { ResumenCuentasTab } from './CajaGestion/ResumenCuentasTab'
import { TableroTab } from './CajaGestion/TableroTab'
import { CargaInicialTab } from './CajaGestion/CargaInicialTab'
import { MovimientosManualesTab } from './CajaGestion/MovimientosManualesTab'

const TABS = [
  { id: 'resumen', label: 'Resumen cuentas' },
  { id: 'tablero', label: 'Tablero de cierres' },
  { id: 'carga-inicial', label: 'Carga inicial' },
  { id: 'movimientos', label: 'Movimientos manuales' },
] as const

type TabId = (typeof TABS)[number]['id']
const TAB_DEFAULT = { tab: 'resumen' }

export function CajaGestionPage() {
  // Pestaña en la URL (?tab=movimientos) y recordada en la sesión (docs/73).
  const { valores, set } = useParamsPagina('caja-gestion:tab', TAB_DEFAULT)
  const tab: TabId = TABS.some((t) => t.id === valores.tab) ? (valores.tab as TabId) : 'resumen'
  // Cambiar de pestaña desmonta la de ahora: con Movimientos manuales a medio cargar, pregunta
  // primero (la pestaña no cambia la ruta, así que GuardiaNavegacion no lo ve).
  const setTab = (id: TabId) => {
    if (!avisarIntentoSalir({ continuar: () => set({ tab: id }), cancelar: () => {} })) set({ tab: id })
  }

  return (
    <section className="flex h-full flex-col rounded-lg bg-surface p-card shadow-sm">
      <div>
        <h1 className="font-display text-headline-lg text-accent-darker">Caja Gestión</h1>
        <p className="mt-1 font-sans text-body-md text-ink-soft">
          Validación de cierres, carga inicial del sistema y movimientos manuales de la caja general.
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
        {tab === 'resumen' && <ResumenCuentasTab />}
        {tab === 'tablero' && <TableroTab />}
        {tab === 'carga-inicial' && <CargaInicialTab />}
        {tab === 'movimientos' && <MovimientosManualesTab />}
      </div>
    </section>
  )
}
