// Bandeja de documentos minimizados (docs/73) — Virikyna Local y Virikyna Gestión.
//
// Como las subventanas de los sistemas viejos: un detalle o un formulario se minimiza a un chip del
// encabezado, se navega a otra pantalla y al volver se restaura tal cual quedó. Funciona porque los
// documentos se dibujan acá, en AppShell, FUERA del <Outlet/>: cambiar de ruta no los desmonta.
// Minimizado = montado pero invisible (Modal lee DocumentoContext): conserva estado, foco y scroll.
//
// Reglas: máximo 5; una clave por documento (abrir uno que ya está lo trae al frente); uno solo
// visible a la vez; vive en memoria (no se reabre al día siguiente) y se vacía al cerrar sesión.

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react'
import { ChevronDown, FilePlus, Package, Receipt, ShoppingBag, X, type LucideIcon } from 'lucide-react'
import type { RolUsuario } from '../../../types/database'
import { Modal } from '../Modal'
import { DocumentoContext, marcarEstadoBandeja, type DocumentoCtx, type InfoDocumento } from './contexto'

export const MAX_DOCUMENTOS = 5

export type TipoDocumento = 'factura_compra' | 'detalle_factura_compra' | 'detalle_venta' | 'producto'

export type ControlDocumento = {
  clave: string
  // Lo llama el documento al terminar (onClose / onSaved): sale de la bandeja.
  cerrar: () => void
}

export type DocumentoNuevo = {
  // Única por documento: 'factura_compra:detalle:<id>', 'producto:<id>', 'venta:<id>'…
  clave: string
  tipo: TipoDocumento
  etiqueta: string // texto inicial del chip; el Modal raíz lo actualiza después
  // Roles que pueden verlo (los de la pantalla de origen). Sin esta prop, todos.
  roles?: RolUsuario[]
  // Lo que se dibuja: un Modal con `minimizable`. Solo usar cosas estables (supabase, ids, el
  // control y avisarCambioDatos): la página que lo abrió puede desmontarse mientras tanto.
  render: (control: ControlDocumento) => ReactNode
}

export type ChipDocumento = {
  clave: string
  tipo: TipoDocumento
  etiqueta: string
  cambios: boolean
  visible: boolean
}

type Documento = DocumentoNuevo & { etiquetaActual: string; cambios: boolean; restauraciones: number }

type Api = {
  documentos: ChipDocumento[]
  // false si no se abrió (límite de 5 o sin permiso).
  abrir: (doc: DocumentoNuevo) => boolean
  restaurar: (clave: string) => void
  minimizar: (clave: string) => void
  // ✕ del chip: el mismo camino que la ✕ del documento (con cambios, primero lo muestra).
  pedirCerrar: (clave: string) => void
  // Cerrar sesión / cambiar de usuario: guarda los borradores con cambios y vacía la bandeja.
  vaciar: () => Promise<void>
  registrarChip: (clave: string, el: HTMLElement | null) => void
}

const DocumentosContext = createContext<Api | null>(null)

// null fuera de la bandeja (ej. Virikyna Inventario): quien abre un documento cae al modal de siempre.
export function useDocumentosAbiertos(): Api | null {
  return useContext(DocumentosContext)
}

export type BandejaApi = Api

// Para pantallas que siempre están dentro de AppShell (Local, Gestión).
export function useBandeja(): Api {
  const api = useContext(DocumentosContext)
  if (!api) throw new Error('useBandeja: falta DocumentosAbiertosProvider (AppShell)')
  return api
}

const CHIP_MAS = '__mas__'

type Callbacks = Omit<DocumentoCtx, 'clave' | 'minimizado' | 'cambios' | 'restauraciones'> & { cerrar: () => void }

export function DocumentosAbiertosProvider({ rol, children }: { rol: RolUsuario | null; children: ReactNode }) {
  const [docs, setDocs] = useState<Documento[]>([])
  const [visible, setVisible] = useState<string | null>(null)
  const [avisoLimite, setAvisoLimite] = useState(false)
  // Copias síncronas: dos aperturas en el mismo tick ven la primera.
  const docsRef = useRef(docs)
  docsRef.current = docs
  const visibleRef = useRef(visible)
  visibleRef.current = visible
  const cierres = useRef(new Map<string, () => void>())
  const guardados = useRef(new Map<string, () => Promise<unknown> | void>())
  const alias = useRef(new Map<string, string>())
  const chips = useRef(new Map<string, HTMLElement>())
  const callbacks = useRef(new Map<string, Callbacks>())

  const permitido = useCallback((d: Pick<DocumentoNuevo, 'roles'>) => !d.roles || (rol !== null && d.roles.includes(rol)), [rol])

  const buscar = useCallback((clave: string) => {
    const real = alias.current.get(clave) ?? clave
    return docsRef.current.find((d) => d.clave === real) ?? null
  }, [])

  const restaurar = useCallback((clave: string) => {
    if (visibleRef.current === clave) return
    setDocs((ds) => ds.map((d) => (d.clave === clave ? { ...d, restauraciones: d.restauraciones + 1 } : d)))
    // El que estaba visible queda minimizado: uno solo a la vez.
    visibleRef.current = clave
    setVisible(clave)
  }, [])

  const minimizar = useCallback((clave: string) => {
    if (visibleRef.current !== clave) return
    visibleRef.current = null
    setVisible(null)
  }, [])

  const cerrar = useCallback((clave: string) => {
    docsRef.current = docsRef.current.filter((d) => d.clave !== clave)
    setDocs((ds) => ds.filter((d) => d.clave !== clave))
    if (visibleRef.current === clave) {
      visibleRef.current = null
      setVisible(null)
    }
    cierres.current.delete(clave)
    guardados.current.delete(clave)
    callbacks.current.delete(clave)
    chips.current.delete(clave)
    for (const [a, c] of alias.current) if (c === clave) alias.current.delete(a)
  }, [])

  const abrir = useCallback(
    (nuevo: DocumentoNuevo) => {
      if (!permitido(nuevo)) return false
      const existente = buscar(nuevo.clave)
      if (existente) {
        restaurar(existente.clave)
        return true
      }
      if (docsRef.current.length >= MAX_DOCUMENTOS) {
        setAvisoLimite(true)
        return false
      }
      const doc: Documento = { ...nuevo, etiquetaActual: nuevo.etiqueta, cambios: false, restauraciones: 0 }
      docsRef.current = [...docsRef.current, doc]
      setDocs((ds) => [...ds, doc])
      visibleRef.current = nuevo.clave
      setVisible(nuevo.clave)
      return true
    },
    [permitido, buscar, restaurar],
  )

  const pedirCerrar = useCallback(
    (clave: string) => {
      const d = buscar(clave)
      if (!d) return
      const pedir = cierres.current.get(d.clave)
      if (!pedir) {
        cerrar(d.clave)
        return
      }
      // Con cambios el formulario pregunta ("Guardar borrador / Descartar / Seguir editando", o su
      // "¿Cerrar sin guardar?"): tiene que estar a la vista. Sin cambios cierra directo.
      if (d.cambios) restaurar(d.clave)
      pedir()
    },
    [buscar, cerrar, restaurar],
  )

  const vaciar = useCallback(async () => {
    for (const guardar of Array.from(guardados.current.values())) {
      try {
        await guardar()
      } catch {
        // Igual queda la copia del equipo (localStorage), que se sube al volver a abrir el listado.
      }
    }
    docsRef.current = []
    visibleRef.current = null
    setDocs([])
    setVisible(null)
    cierres.current.clear()
    guardados.current.clear()
    alias.current.clear()
    callbacks.current.clear()
    chips.current.clear()
  }, [])

  const registrarChip = useCallback((clave: string, el: HTMLElement | null) => {
    if (el) chips.current.set(clave, el)
    else chips.current.delete(clave)
  }, [])

  // Callbacks estables por documento (los hooks de Modal dependen de su identidad).
  function callbacksDe(clave: string): Callbacks {
    let cb = callbacks.current.get(clave)
    if (!cb) {
      cb = {
        minimizar: () => minimizar(clave),
        cerrar: () => cerrar(clave),
        reportar: (info: InfoDocumento) =>
          setDocs((ds) => {
            const d = ds.find((x) => x.clave === clave)
            if (!d) return ds
            const etiqueta = info.etiqueta ?? d.etiquetaActual
            const cambios = info.cambios ?? d.cambios
            if (etiqueta === d.etiquetaActual && cambios === d.cambios) return ds
            return ds.map((x) => (x.clave === clave ? { ...x, etiquetaActual: etiqueta, cambios } : x))
          }),
        registrarCierre: (fn) => {
          if (fn) cierres.current.set(clave, fn)
          else cierres.current.delete(clave)
        },
        registrarGuardado: (fn) => {
          if (fn) guardados.current.set(clave, fn)
          else guardados.current.delete(clave)
        },
        registrarAlias: (a: string) => {
          alias.current.set(a, clave)
          return () => {
            if (alias.current.get(a) === clave) alias.current.delete(a)
          }
        },
        enfocarChip: () => {
          const chip = chips.current.get(clave) ?? chips.current.get(CHIP_MAS)
          if (chip) chip.focus({ preventScroll: true })
          else (document.activeElement as HTMLElement | null)?.blur?.()
        },
      }
      callbacks.current.set(clave, cb)
    }
    return cb
  }

  // Permisos (docs/73): un documento que el rol actual no puede ver no se muestra ni se restaura.
  useEffect(() => {
    setDocs((ds) => {
      const filtrados = ds.filter(permitido)
      return filtrados.length === ds.length ? ds : filtrados
    })
  }, [permitido])

  const visiblesDocs = docs.filter(permitido)
  const visibleEfectivo = visiblesDocs.some((d) => d.clave === visible) ? visible : null

  useEffect(() => {
    marcarEstadoBandeja({ visible: visibleEfectivo !== null, conCambios: visiblesDocs.some((d) => d.cambios) })
  })
  useEffect(() => () => marcarEstadoBandeja({ visible: false, conCambios: false }), [])

  const api = useMemo<Api>(
    () => ({
      documentos: visiblesDocs.map((d) => ({
        clave: d.clave,
        tipo: d.tipo,
        etiqueta: d.etiquetaActual,
        cambios: d.cambios,
        visible: d.clave === visibleEfectivo,
      })),
      abrir,
      restaurar,
      minimizar,
      pedirCerrar,
      vaciar,
      registrarChip,
    }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [docs, visibleEfectivo, permitido, abrir, restaurar, minimizar, pedirCerrar, vaciar, registrarChip],
  )

  return (
    <DocumentosContext.Provider value={api}>
      {children}
      {visiblesDocs.map((d) => {
        const cb = callbacksDe(d.clave)
        const ctx: DocumentoCtx = {
          clave: d.clave,
          minimizado: d.clave !== visibleEfectivo,
          cambios: d.cambios,
          restauraciones: d.restauraciones,
          minimizar: cb.minimizar,
          reportar: cb.reportar,
          registrarCierre: cb.registrarCierre,
          registrarGuardado: cb.registrarGuardado,
          registrarAlias: cb.registrarAlias,
          enfocarChip: cb.enfocarChip,
        }
        return (
          <DocumentoContext.Provider key={d.clave} value={ctx}>
            {d.render({ clave: d.clave, cerrar: cb.cerrar })}
          </DocumentoContext.Provider>
        )
      })}
      {avisoLimite && (
        <Modal
          title={`Ya hay ${MAX_DOCUMENTOS} documentos abiertos`}
          onClose={() => setAvisoLimite(false)}
          widthClassName="max-w-[440px]"
          dialogo={{ onEscape: () => setAvisoLimite(false) }}
        >
          <div className="flex flex-col gap-stack-md">
            <p className="font-sans text-body-md text-ink">
              Cerrá alguno desde la barra de arriba (la ✕ de cada uno) para abrir otro. No se cerró ninguno.
            </p>
            <div className="flex justify-end">
              <button
                type="button"
                data-autofocus
                onClick={() => setAvisoLimite(false)}
                className="rounded bg-accent px-4 py-3 font-sans text-label-bold text-white transition hover:bg-accent-dark"
              >
                Entendido
              </button>
            </div>
          </div>
        </Modal>
      )}
    </DocumentosContext.Provider>
  )
}

// ─── Chips del encabezado ─────────────────────────────────────────────────────────────────────

const ICONO: Record<TipoDocumento, LucideIcon> = {
  factura_compra: FilePlus,
  detalle_factura_compra: Receipt,
  detalle_venta: ShoppingBag,
  producto: Package,
}

// Cada chip mide entre 160 y 240 px (se achica para que entren más) + separación (gap-2). El "+N"
// (~64 px) se reserva solo si no entran todos; sin ningún chip pasa a decir "N abiertos".
const ANCHO_CHIP_MIN = 160 + 8
const ANCHO_MAS = 72

function etiquetaAccesible(d: ChipDocumento) {
  return `${d.visible ? 'Minimizar' : 'Restaurar'} ${d.etiqueta}${d.cambios ? ' (con cambios sin guardar)' : ''}`
}

function PuntoCambios({ cambios }: { cambios: boolean }) {
  if (!cambios) return null
  return <span aria-hidden="true" className="h-2 w-2 shrink-0 rounded-full bg-accent" title="Con cambios sin guardar" />
}

const focoVisible = 'focus-visible:outline focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent-dark'

// Va en el header de 64 px de cada AppShell, entre el botón del menú y las píldoras de usuario: usa
// el espacio libre que ya había, no le quita alto al área de trabajo.
export function BandejaDocumentos() {
  const api = useDocumentosAbiertos()
  const contenedorRef = useRef<HTMLDivElement>(null)
  const [ancho, setAncho] = useState(0)
  const [menuAbierto, setMenuAbierto] = useState(false)
  const menuRef = useRef<HTMLDivElement>(null)

  useLayoutEffect(() => {
    const el = contenedorRef.current
    if (!el) return
    setAncho(el.clientWidth)
    const obs = new ResizeObserver((entradas) => setAncho(entradas[0].contentRect.width))
    obs.observe(el)
    return () => obs.disconnect()
  }, [])

  useEffect(() => {
    if (!menuAbierto) return
    function afuera(e: MouseEvent) {
      if (!menuRef.current?.contains(e.target as Node)) setMenuAbierto(false)
    }
    function esc(e: KeyboardEvent) {
      if (e.key === 'Escape') {
        setMenuAbierto(false)
        menuRef.current?.querySelector<HTMLButtonElement>('button')?.focus()
      }
    }
    document.addEventListener('mousedown', afuera)
    document.addEventListener('keydown', esc)
    return () => {
      document.removeEventListener('mousedown', afuera)
      document.removeEventListener('keydown', esc)
    }
  }, [menuAbierto])

  const documentos = api?.documentos ?? []
  const cabenTodos = documentos.length * ANCHO_CHIP_MIN - 8 <= ancho
  const cuantos = cabenTodos ? documentos.length : Math.max(0, Math.floor((ancho - ANCHO_MAS) / ANCHO_CHIP_MIN))
  const enChips = documentos.slice(0, cuantos)
  const enMenu = documentos.slice(cuantos)

  useEffect(() => {
    if (enMenu.length === 0) setMenuAbierto(false)
  }, [enMenu.length])

  return (
    <div ref={contenedorRef} className="flex min-w-0 flex-1 items-center gap-2" role="group" aria-label="Documentos abiertos">
      {api &&
        enChips.map((d) => {
          const Icono = ICONO[d.tipo]
          return (
            <div
              key={d.clave}
              className={`flex h-11 min-w-[10rem] flex-[0_1_15rem] items-stretch overflow-hidden rounded border border-accent ${
                d.visible ? 'bg-accent-light' : 'bg-surface'
              }`}
            >
              <button
                ref={(el) => api.registrarChip(d.clave, el)}
                type="button"
                onClick={() => (d.visible ? api.minimizar(d.clave) : api.restaurar(d.clave))}
                aria-label={etiquetaAccesible(d)}
                aria-pressed={d.visible}
                title={d.etiqueta}
                className={`flex min-w-0 flex-1 items-center gap-2 pl-3 pr-1 font-sans text-label-bold text-accent-darker hover:bg-accent-light ${focoVisible}`}
              >
                <Icono size={18} strokeWidth={1.75} aria-hidden className="shrink-0 text-accent-dark" />
                <span className="truncate">{d.etiqueta}</span>
                <PuntoCambios cambios={d.cambios} />
              </button>
              <button
                type="button"
                onClick={() => api.pedirCerrar(d.clave)}
                aria-label={`Cerrar ${d.etiqueta}`}
                title="Cerrar"
                className={`flex w-10 shrink-0 items-center justify-center border-l border-accent/40 text-ink-soft hover:bg-accent-light hover:text-accent-darker ${focoVisible}`}
              >
                <X size={16} strokeWidth={2} aria-hidden />
              </button>
            </div>
          )
        })}

      {api && enMenu.length > 0 && (
        <div ref={menuRef} className="relative shrink-0">
          <button
            ref={(el) => api.registrarChip(CHIP_MAS, el)}
            type="button"
            onClick={() => setMenuAbierto((v) => !v)}
            aria-haspopup="true"
            aria-expanded={menuAbierto}
            aria-label={`${enMenu.length} documento${enMenu.length === 1 ? '' : 's'} abierto${enMenu.length === 1 ? '' : 's'} más`}
            className={`flex h-11 items-center gap-1 whitespace-nowrap rounded border border-accent bg-surface px-3 font-sans text-label-bold text-accent-darker hover:bg-accent-light ${focoVisible}`}
          >
            {enChips.length === 0 ? `${enMenu.length} abierto${enMenu.length === 1 ? '' : 's'}` : `+${enMenu.length}`}
            {enMenu.some((d) => d.cambios) && <PuntoCambios cambios />}
            <ChevronDown size={16} strokeWidth={2} aria-hidden />
          </button>
          {menuAbierto && (
            <ul className="absolute left-0 top-full z-40 mt-1 flex w-72 flex-col gap-1 rounded-lg border border-line bg-surface p-1 shadow-lg">
              {enMenu.map((d) => {
                const Icono = ICONO[d.tipo]
                return (
                  <li key={d.clave} className={`flex min-h-11 items-stretch overflow-hidden rounded ${d.visible ? 'bg-accent-light' : ''}`}>
                    <button
                      type="button"
                      onClick={() => {
                        setMenuAbierto(false)
                        if (d.visible) api.minimizar(d.clave)
                        else api.restaurar(d.clave)
                      }}
                      aria-label={etiquetaAccesible(d)}
                      title={d.etiqueta}
                      className={`flex min-w-0 flex-1 items-center gap-2 px-3 text-left font-sans text-label-bold text-accent-darker hover:bg-accent-light ${focoVisible}`}
                    >
                      <Icono size={18} strokeWidth={1.75} aria-hidden className="shrink-0 text-accent-dark" />
                      <span className="truncate">{d.etiqueta}</span>
                      <PuntoCambios cambios={d.cambios} />
                    </button>
                    <button
                      type="button"
                      onClick={() => {
                        setMenuAbierto(false)
                        api.pedirCerrar(d.clave)
                      }}
                      aria-label={`Cerrar ${d.etiqueta}`}
                      title="Cerrar"
                      className={`flex w-10 shrink-0 items-center justify-center text-ink-soft hover:bg-accent-light hover:text-accent-darker ${focoVisible}`}
                    >
                      <X size={16} strokeWidth={2} aria-hidden />
                    </button>
                  </li>
                )
              })}
            </ul>
          )}
        </div>
      )}
    </div>
  )
}
