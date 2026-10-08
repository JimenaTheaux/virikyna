import { useEffect, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { Lock } from 'lucide-react'
import type { RolUsuario } from '../../../types/database'
import {
  KEY_CONFIGURACION,
  formatCantidad,
  formatDiaMes,
  useAbrirCarga,
  useCerrarCarga,
  useConfiguracion,
  useResumenCarga,
} from '../../../lib/cargaInicial'
import { formatCurrency } from '../../../lib/format'
import { ControlSegmentado } from '../ControlSegmentado'
import { BotonesDialogo, Dialogo, type Variante } from './comunes'
import { MiCarga } from './MiCarga'
import { InventarioTotal } from './InventarioTotal'

type Tab = 'mia' | 'total'

type Props = {
  supabase: SupabaseClient
  perfil: { id: string; nombre: string; rol: RolUsuario }
  variante: Variante
  // Local e Inventario: con la carga cerrada la pantalla se bloquea para todos (también admin).
  // Gestión: false — el admin la sigue usando después del cierre.
  bloquearSiCerrada: boolean
  // Gestión: botones Abrir / Cerrar en el encabezado (solo admin).
  controlesAdmin?: boolean
}

// Pantalla de carga inicial de inventario (docs/04 módulo 5.2), compartida por las tres apps. Cada
// app la monta en /carga-inicial con su cliente de Supabase y su perfil.
export function CargaInicial({ supabase, perfil, variante, bloquearSiCerrada, controlesAdmin = false }: Props) {
  const celular = variante === 'celular'
  const esAdmin = perfil.rol === 'admin'
  const queryClient = useQueryClient()
  const configuracion = useConfiguracion(supabase)
  const [tab, setTab] = useState<Tab>('mia')

  const config = configuracion.data
  const abierta = config?.carga_inicial_abierta ?? false
  const bloqueada = !!config && !abierta && (bloquearSiCerrada || !esAdmin)
  const resumen = useResumenCarga(supabase, !!config && !bloqueada)

  // Una RPC contestó "la carga está cerrada": se relee la configuración y la pantalla se bloquea.
  function onCerrada() {
    void queryClient.invalidateQueries({ queryKey: KEY_CONFIGURACION })
  }

  const r = resumen.data

  return (
    <section
      className={celular ? 'flex flex-col gap-stack-md' : 'flex flex-col gap-stack-md rounded-lg bg-surface p-card shadow-sm'}
    >
      <header className={`flex gap-3 ${celular ? 'flex-col' : 'items-start justify-between'}`}>
        <div>
          <h1 className="font-display text-headline-lg text-accent-darker">Carga inicial</h1>
          {r && (
            <p className="mt-1 font-sans text-body-md text-ink-soft">
              Cargado: <strong className="text-ink">{r.productos}</strong> producto{r.productos === 1 ? '' : 's'} ·{' '}
              <strong className="text-ink">{formatCantidad(r.unidades)}</strong> u.
              {esAdmin && (
                <>
                  {' '}
                  · <strong className="text-ink">{formatCurrency(r.valor)}</strong> a precio de venta
                </>
              )}
            </p>
          )}
          {/* Gestión: borradores sin finalizar a la vista, sin abrir el desglose (antes de cerrar). */}
          {controlesAdmin && esAdmin && r && r.borradores > 0 && (
            <p className="mt-1 font-sans text-body-md text-badge-amber-text">
              Sin finalizar:{' '}
              {r.por_usuario
                .filter((u) => u.borradores > 0)
                .map((u) => `${u.nombre} ${u.borradores} fila${u.borradores === 1 ? '' : 's'} (${formatCantidad(u.unidades_borradores)} u.)`)
                .join(' · ')}
            </p>
          )}
        </div>
        {controlesAdmin && esAdmin && config && (
          <ControlesAdmin
            supabase={supabase}
            celular={celular}
            abierta={abierta}
            estado={
              abierta && config.abierta_at
                ? `Carga inicial abierta desde ${formatDiaMes(config.abierta_at)}${r?.abierta_por_nombre ? ` por ${r.abierta_por_nombre}` : ''}`
                : 'Cerrada'
            }
          />
        )}
      </header>

      {configuracion.isError && (
        <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">
          No se pudo leer el estado de la carga inicial. Revisá la conexión.
        </p>
      )}

      {esAdmin && r && r.por_usuario.length > 0 && !bloqueada && (
        <details className="rounded-lg border border-line bg-surface px-4 py-2 font-sans text-body-md">
          <summary className="cursor-pointer py-1 font-sans text-label-bold text-accent-dark">
            Avance por usuario
            {r.borradores > 0 && (
              <span className="ml-2 font-normal text-ink-soft">
                · {r.borradores} borrador{r.borradores === 1 ? '' : 'es'} sin finalizar
              </span>
            )}
          </summary>
          <TablaPorUsuario r={r} />
        </details>
      )}

      {bloqueada ? (
        <div role="alert" className="flex flex-col items-center gap-2 rounded-lg border border-line bg-surface px-6 py-10 text-center">
          <Lock className="h-8 w-8 text-ink-soft" aria-hidden />
          <p className="font-display text-headline-md text-accent-darker">La carga inicial está cerrada</p>
          <p className="max-w-md font-sans text-body-md text-ink-soft">
            {bloquearSiCerrada
              ? 'Un administrador la cerró. Las filas que no llegaste a guardar quedan en este dispositivo y aparecen si se vuelve a abrir.'
              : 'Pedile a un administrador que la abra.'}
          </p>
        </div>
      ) : (
        config && (
          <>
            {!abierta && (
              <p className="rounded bg-badge-amber-bg px-4 py-2 font-sans text-body-md text-badge-amber-text">
                La carga inicial está cerrada para los cajeros. Como administrador podés seguir cargando y corrigiendo.
              </p>
            )}
            <ControlSegmentado
              legend="Vista"
              opciones={[
                { value: 'mia', label: 'Mi carga' },
                { value: 'total', label: 'Inventario total' },
              ]}
              value={tab}
              onChange={setTab}
              size={celular ? 'touch' : 'compact'}
            />
            {/* Las dos pestañas quedan montadas: cambiar de pestaña no pierde lo tipeado en la fila de
                entrada ni una edición a medias. */}
            <div hidden={tab !== 'mia'}>
              <MiCarga
                supabase={supabase}
                usuarioId={perfil.id}
                datosResetAt={configuracion.isSuccess ? (config.datos_reset_at ?? null) : undefined}
                celular={celular}
                onCerrada={onCerrada}
              />
            </div>
            <div hidden={tab !== 'total'}>
              <InventarioTotal supabase={supabase} celular={celular} activo={tab === 'total'} onCerrada={onCerrada} />
            </div>
          </>
        )
      )}
    </section>
  )
}

function TablaPorUsuario({ r }: { r: NonNullable<ReturnType<typeof useResumenCarga>['data']> }) {
  return (
    <div className="overflow-auto">
      <table className="mt-2 w-full table-fixed text-left font-sans text-table-row">
        <thead>
          <tr className="text-table-head uppercase text-accent-dark">
            <th className="px-2 py-1.5">Usuario</th>
            <th className="w-[6rem] px-2 py-1.5 text-right">Productos</th>
            <th className="w-[6rem] px-2 py-1.5 text-right">Unidades</th>
            <th className="w-[8.5rem] px-2 py-1.5 text-right">Valor</th>
            <th className="w-[9rem] px-2 py-1.5 text-right">Sin finalizar</th>
          </tr>
        </thead>
        <tbody>
          {r.por_usuario.map((u) => (
            <tr key={u.usuario_id} className="border-t border-table-divider">
              <td className="px-2 py-1.5 [overflow-wrap:anywhere]">{u.nombre}</td>
              <td className="px-2 py-1.5 text-right">{u.productos}</td>
              <td className="px-2 py-1.5 text-right">{formatCantidad(u.unidades)}</td>
              <td className="px-2 py-1.5 text-right">{formatCurrency(u.valor)}</td>
              <td className={`px-2 py-1.5 text-right ${u.borradores > 0 ? 'font-semibold text-badge-amber-text' : 'text-ink-soft'}`}>
                {u.borradores > 0 ? `${u.borradores} (${formatCantidad(u.unidades_borradores)} u.)` : '—'}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function ControlesAdmin({
  supabase,
  celular,
  abierta,
  estado,
}: {
  supabase: SupabaseClient
  celular: boolean
  abierta: boolean
  estado: string
}) {
  const [dialogo, setDialogo] = useState<'abrir' | 'cerrar' | null>(null)
  return (
    <div className={`flex items-center gap-3 ${celular ? 'flex-wrap' : ''}`}>
      <span
        className={`rounded-full px-3 py-1.5 font-sans text-label-bold ${
          abierta ? 'bg-badge-green-bg text-badge-green-text' : 'bg-badge-neutral-bg text-ink-soft'
        }`}
      >
        {estado}
      </span>
      <button
        type="button"
        onClick={() => setDialogo(abierta ? 'cerrar' : 'abrir')}
        className={`rounded px-4 font-sans text-label-bold ${celular ? 'min-h-12' : 'py-2'} ${
          abierta ? 'border border-error text-error hover:bg-error hover:text-white' : 'border border-accent text-accent-darker hover:bg-accent-light'
        }`}
      >
        {abierta ? 'Cerrar carga inicial' : 'Abrir carga inicial'}
      </button>
      {dialogo === 'abrir' && <AbrirDialog supabase={supabase} celular={celular} onClose={() => setDialogo(null)} />}
      {dialogo === 'cerrar' && <CerrarDialog supabase={supabase} celular={celular} onClose={() => setDialogo(null)} />}
    </div>
  )
}

function AbrirDialog({ supabase, celular, onClose }: { supabase: SupabaseClient; celular: boolean; onClose: () => void }) {
  const abrir = useAbrirCarga(supabase)
  const [error, setError] = useState<string | null>(null)
  async function confirmar() {
    try {
      await abrir.mutateAsync()
      onClose()
    } catch (e) {
      setError(e instanceof Error ? e.message : 'No se pudo abrir la carga.')
    }
  }
  return (
    <Dialogo celular={celular} title="Abrir carga inicial" onClose={onClose}>
      <div className="flex flex-col gap-stack-md font-sans text-body-md text-ink">
        <p>
          Con la carga abierta, todos los usuarios ven "Carga inicial" en Local e Inventario y pueden cargar productos y stock.
        </p>
        {error && (
          <p role="alert" className="rounded bg-error/10 px-3 py-2 text-error">
            {error}
          </p>
        )}
        <BotonesDialogo celular={celular} onCancelar={onClose} onConfirmar={confirmar} confirmarLabel="Abrir" confirmando={abrir.isPending} />
      </div>
    </Dialogo>
  )
}

const PALABRA_CIERRE = 'CERRAR'

function CerrarDialog({ supabase, celular, onClose }: { supabase: SupabaseClient; celular: boolean; onClose: () => void }) {
  const cerrar = useCerrarCarga(supabase)
  // Recién leído al abrir el diálogo: los borradores pendientes de ahora, no los de hace 15 s.
  const resumen = useResumenCarga(supabase)
  useEffect(() => {
    void resumen.refetch()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])
  const [palabra, setPalabra] = useState('')
  const [error, setError] = useState<string | null>(null)
  const pendientes = (resumen.data?.por_usuario ?? []).filter((u) => u.borradores > 0)
  const listo = palabra.trim().toUpperCase() === PALABRA_CIERRE && !resumen.isFetching

  async function confirmar() {
    try {
      await cerrar.mutateAsync()
      onClose()
    } catch (e) {
      setError(e instanceof Error ? e.message : 'No se pudo cerrar la carga.')
    }
  }

  return (
    <Dialogo celular={celular} title="Cerrar carga inicial" onClose={onClose}>
      <div className="flex flex-col gap-stack-md font-sans text-body-md text-ink">
        <p>
          Al cerrar, "Carga inicial" desaparece de Local e Inventario. Solo un administrador puede seguir usándola desde
          Gestión.
        </p>
        {resumen.isFetching && <p className="text-ink-soft">Revisando borradores pendientes…</p>}
        {!resumen.isFetching && pendientes.length > 0 && (
          <div className="rounded-lg border border-badge-amber-text/40 bg-badge-amber-bg px-3 py-2 text-badge-amber-text">
            <p className="font-semibold">Hay borradores sin finalizar. Si cerrás igual, quedan sin aplicar al inventario:</p>
            <ul className="mt-1 list-disc pl-5">
              {pendientes.map((u) => (
                <li key={u.usuario_id}>
                  {u.nombre}: {u.borradores} fila{u.borradores === 1 ? '' : 's'} · {formatCantidad(u.unidades_borradores)} u.
                </li>
              ))}
            </ul>
          </div>
        )}
        <div className="flex flex-col gap-1">
          <label htmlFor="cerrar-carga-palabra" className="font-sans text-label-md text-ink">
            Para confirmar, escribí <strong>{PALABRA_CIERRE}</strong>
          </label>
          <input
            id="cerrar-carga-palabra"
            value={palabra}
            onChange={(e) => setPalabra(e.target.value)}
            autoComplete="off"
            className={`rounded border border-line bg-surface px-3 font-sans text-body-md text-ink outline-none focus:border-accent ${celular ? 'h-12' : 'h-10'}`}
          />
        </div>
        {error && (
          <p role="alert" className="rounded bg-error/10 px-3 py-2 text-error">
            {error}
          </p>
        )}
        <BotonesDialogo
          celular={celular}
          onCancelar={onClose}
          onConfirmar={confirmar}
          confirmarLabel={pendientes.length > 0 ? 'Cerrar igual' : 'Cerrar carga inicial'}
          confirmando={cerrar.isPending}
          deshabilitado={!listo}
          destructivo
        />
      </div>
    </Dialogo>
  )
}
