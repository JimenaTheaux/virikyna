import { useMemo, useRef, useState, type KeyboardEvent, type ReactNode, type RefObject } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { AlertTriangle, Check, Loader2, Lock, Pencil, RotateCcw, Trash2 } from 'lucide-react'
import type { AccionCargaInicial, CargaInicialBusqueda, CargaInicialFinalizarResultado } from '../../../types/database'
import {
  buscarCodigoCarga,
  esCargaCerrada,
  formatCantidad,
  useEliminarBorrador,
  useFilasPendientes,
  useFinalizarCarga,
  useGuardarBorrador,
  useMisBorradores,
  validarFila,
  type ErroresFila,
  type FilaPendiente,
} from '../../../lib/cargaInicial'
import { normalizarCodigoBarras } from '../../../lib/productoBusqueda'
import { formatCurrency } from '../../../lib/format'
import { ScanButton } from '../ScanButton'
import { RowActionsMenu, type RowActionsMenuItem } from '../RowActionsMenu'
import { BotonesDialogo, Dialogo, ResultadoFinalizar, textoAccion } from './comunes'

type Campos = { codigo: string; nombre: string; marca: string; descripcion: string; precio: string; cantidad: string }
const VACIO: Campos = { codigo: '', nombre: '', marca: '', descripcion: '', precio: '', cantidad: '' }

// 'datos': "usar sus datos" — solo se carga la cantidad. 'precio': producto con costo, el precio
// sale de la fórmula y no se puede cambiar desde acá.
type Bloqueo = 'ninguno' | 'datos' | 'precio'

// Una fila de la lista: un borrador del servidor, o una fila que todavía no llegó (pendiente).
type FilaVista = {
  key: string
  id: string | null
  idLocal: string | null
  codigo: string
  nombre: string
  marca: string
  descripcion: string
  precio: string
  cantidad: string
  accion: AccionCargaInicial
  conProducto: boolean
  estado: 'guardada' | 'guardando' | 'error'
  error: string | null
}

type Props = {
  supabase: SupabaseClient
  usuarioId: string
  datosResetAt: string | null | undefined
  celular: boolean
  onCerrada: () => void
}

export function MiCarga({ supabase, usuarioId, datosResetAt, celular, onCerrada }: Props) {
  const misBorradores = useMisBorradores(supabase, usuarioId)
  const pendientes = useFilasPendientes(usuarioId, datosResetAt)
  const guardar = useGuardarBorrador(supabase, usuarioId)
  const eliminar = useEliminarBorrador(supabase, usuarioId)
  const finalizar = useFinalizarCarga(supabase, usuarioId)

  const [errorGeneral, setErrorGeneral] = useState<string | null>(null)
  const [confirmarFinalizar, setConfirmarFinalizar] = useState(false)
  const [resultado, setResultado] = useState<CargaInicialFinalizarResultado | null>(null)
  const [aEliminar, setAEliminar] = useState<FilaVista | null>(null)
  const [editandoSheet, setEditandoSheet] = useState<FilaVista | null>(null)

  // Pendientes arriba (las más nuevas primero), después los borradores guardados. Una edición
  // pendiente de un borrador reemplaza a su versión guardada.
  const filas = useMemo<FilaVista[]>(() => {
    const editados = new Set(pendientes.filas.filter((p) => p.id).map((p) => p.id))
    const deServidor = misBorradores.data ?? []
    const conProducto = new Map(deServidor.map((b) => [b.id, b.producto_id !== null]))
    const vistaPendientes: FilaVista[] = [...pendientes.filas]
      .sort((a, b) => b.creadaAt - a.creadaAt)
      .map((p) => ({
        key: p.idLocal,
        id: p.id,
        idLocal: p.idLocal,
        codigo: p.codigo,
        nombre: p.nombre,
        marca: p.marca,
        descripcion: p.descripcion,
        precio: p.precio,
        cantidad: p.cantidad,
        accion: p.accion,
        conProducto: p.id ? (conProducto.get(p.id) ?? false) : p.accion === 'sumar',
        estado: p.estado,
        error: p.error,
      }))
    const vistaServidor: FilaVista[] = deServidor
      .filter((b) => !editados.has(b.id))
      .map((b) => ({
        key: b.id,
        id: b.id,
        idLocal: null,
        codigo: b.codigo_barras ?? '',
        nombre: b.nombre,
        marca: b.marca ?? '',
        descripcion: b.descripcion ?? '',
        precio: String(b.precio),
        cantidad: String(b.cantidad),
        accion: b.accion,
        conProducto: b.producto_id !== null,
        estado: 'guardada',
        error: null,
      }))
    return [...vistaPendientes, ...vistaServidor]
  }, [pendientes.filas, misBorradores.data])

  const unidades = filas.reduce((acc, f) => acc + (Number(f.cantidad) || 0), 0)
  const hayPendientes = pendientes.filas.length > 0

  function manejarError(e: unknown) {
    if (esCargaCerrada(e)) onCerrada()
  }

  // Manda una fila al servidor. Mientras viaja queda "guardando" (y en el navegador); si falla
  // queda "No guardada" con su error, sin perder lo tipeado. Reintentar vuelve a mandar la misma
  // fila con el mismo clientId: si el envío anterior había llegado, la base no lo aplica dos veces.
  async function enviar(fila: FilaPendiente) {
    pendientes.actualizar((prev) => [...prev.filter((p) => p.idLocal !== fila.idLocal), { ...fila, estado: 'guardando', error: null }])
    try {
      await guardar.mutateAsync({ ...fila, precio: Number(fila.precio), cantidad: Number(fila.cantidad) })
      pendientes.actualizar((prev) => prev.filter((p) => p.idLocal !== fila.idLocal))
    } catch (e) {
      manejarError(e)
      const mensaje = e instanceof Error ? e.message : 'No se pudo guardar.'
      pendientes.actualizar((prev) =>
        prev.map((p) => (p.idLocal === fila.idLocal ? { ...p, estado: 'error', error: mensaje } : p)),
      )
    }
  }

  function guardarNueva(c: Campos, accion: AccionCargaInicial) {
    void enviar({
      idLocal: crypto.randomUUID(),
      clientId: crypto.randomUUID(),
      id: null,
      codigo: normalizarCodigoBarras(c.codigo),
      nombre: c.nombre.trim(),
      marca: c.marca.trim(),
      descripcion: c.descripcion.trim(),
      precio: c.precio,
      cantidad: c.cantidad,
      accion,
      estado: 'guardando',
      error: null,
      creadaAt: Date.now(),
    })
  }

  function guardarEdicion(fila: FilaVista, c: Omit<Campos, 'codigo'>) {
    const previa = fila.idLocal ? pendientes.filas.find((p) => p.idLocal === fila.idLocal) : undefined
    void enviar({
      idLocal: fila.idLocal ?? crypto.randomUUID(),
      // Una edición de un borrador guardado es otra operación: clientId nuevo. Excepción: corregir
      // un ALTA que todavía no se confirmó mantiene su clientId — ese alta pudo haber llegado, y
      // con otro id volvería a sumar. Si había llegado, la base devuelve la fila como quedó y la
      // corrección se hace sobre ella (aparece como guardada, editable).
      clientId: fila.id === null && previa ? previa.clientId : crypto.randomUUID(),
      id: fila.id,
      codigo: fila.codigo,
      nombre: c.nombre.trim(),
      marca: c.marca.trim(),
      descripcion: c.descripcion.trim(),
      precio: c.precio,
      cantidad: c.cantidad,
      accion: fila.accion,
      estado: 'guardando',
      error: null,
      creadaAt: previa?.creadaAt ?? Date.now(),
    })
  }

  function reintentar(fila: FilaVista) {
    const p = pendientes.filas.find((x) => x.idLocal === fila.idLocal)
    if (p) void enviar(p)
  }

  async function confirmarEliminar() {
    const fila = aEliminar
    if (!fila) return
    setErrorGeneral(null)
    try {
      if (fila.id) await eliminar.mutateAsync(fila.id)
      if (fila.idLocal) pendientes.actualizar((prev) => prev.filter((p) => p.idLocal !== fila.idLocal))
      setAEliminar(null)
    } catch (e) {
      manejarError(e)
      setErrorGeneral(e instanceof Error ? e.message : 'No se pudo eliminar la fila.')
      setAEliminar(null)
    }
  }

  async function confirmarFinalizacion() {
    setErrorGeneral(null)
    try {
      const r = await finalizar.mutateAsync()
      setConfirmarFinalizar(false)
      setResultado(r)
    } catch (e) {
      manejarError(e)
      setConfirmarFinalizar(false)
      setErrorGeneral(e instanceof Error ? e.message : 'No se pudo finalizar la carga.')
    }
  }

  const contador = (
    <p aria-live="polite" className="font-sans text-label-bold text-ink-soft">
      {filas.length} fila{filas.length === 1 ? '' : 's'} · {formatCantidad(unidades)} unidad{unidades === 1 ? '' : 'es'}
    </p>
  )

  const botonFinalizar = (
    <button
      type="button"
      onClick={() => setConfirmarFinalizar(true)}
      disabled={filas.length === 0 || hayPendientes}
      title={hayPendientes ? 'Hay filas sin guardar: reintentalas o eliminalas antes de finalizar.' : undefined}
      className={`rounded bg-accent px-5 font-sans text-label-bold text-white transition hover:bg-accent-dark disabled:opacity-50 ${
        celular ? 'min-h-12 w-full' : 'py-3'
      }`}
    >
      Finalizar mi carga
    </button>
  )

  return (
    <div className="flex flex-col gap-stack-md">
      <Entrada supabase={supabase} celular={celular} onGuardar={guardarNueva} onCerrada={onCerrada} />

      {errorGeneral && (
        <p role="alert" className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">
          {errorGeneral}
        </p>
      )}
      {misBorradores.isError && (
        <p className="rounded bg-error/10 px-4 py-3 font-sans text-body-md text-error">
          No se pudieron leer tus filas guardadas. Revisá la conexión.
        </p>
      )}

      {celular ? (
        <>
          {contador}
          <ul className="flex flex-col gap-3">
            {filas.map((f) => (
              <TarjetaBorrador
                key={f.key}
                fila={f}
                onEditar={() => setEditandoSheet(f)}
                onEliminar={() => setAEliminar(f)}
                onReintentar={() => reintentar(f)}
              />
            ))}
          </ul>
          {filas.length === 0 && !misBorradores.isLoading && <ListaVacia />}
          <div className="sticky bottom-0 -mx-stack-md bg-bg px-stack-md py-2">{botonFinalizar}</div>
        </>
      ) : (
        <>
          <div className="overflow-auto rounded-xl shadow-sm">
            <table className="w-full table-fixed text-left font-sans text-table-row max-xl:[&_td]:px-2 max-xl:[&_th]:px-2">
              <ColumnasMiCarga />
              <thead>
                <tr className="bg-accent-light text-table-head uppercase text-accent-dark">
                  <th className="px-3 py-2.5">Código</th>
                  <th className="px-3 py-2.5">Nombre</th>
                  <th className="px-3 py-2.5">Marca</th>
                  <th className="px-3 py-2.5">Descripción</th>
                  <th className="px-3 py-2.5 text-right">Precio</th>
                  <th className="px-3 py-2.5 text-right">Cant.</th>
                  <th className="px-3 py-2.5">
                    <span className="sr-only">Acciones</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                {filas.map((f) => (
                  <FilaBorrador
                    key={f.key}
                    fila={f}
                    onGuardar={(c) => guardarEdicion(f, c)}
                    onEliminar={() => setAEliminar(f)}
                    onReintentar={() => reintentar(f)}
                  />
                ))}
                {filas.length === 0 && !misBorradores.isLoading && (
                  <tr>
                    <td colSpan={7} className="px-3 py-4">
                      <ListaVacia />
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
          <div className="flex items-center justify-between gap-3">
            {contador}
            {botonFinalizar}
          </div>
        </>
      )}

      {hayPendientes && (
        <p className="font-sans text-label-md text-ink-soft">
          Hay filas sin guardar: reintentalas o eliminalas antes de finalizar.
        </p>
      )}

      {editandoSheet && (
        <EditorBorradorSheet
          fila={editandoSheet}
          onCancelar={() => setEditandoSheet(null)}
          onGuardar={(c) => {
            guardarEdicion(editandoSheet, c)
            setEditandoSheet(null)
          }}
        />
      )}

      {aEliminar && (
        <Dialogo celular={celular} title="Eliminar fila" onClose={() => setAEliminar(null)}>
          <div className="flex flex-col gap-stack-md">
            <p className="font-sans text-body-md text-ink">
              ¿Eliminar <strong>{aEliminar.nombre || 'esta fila'}</strong> de tu carga? No se aplica nada al inventario.
            </p>
            <BotonesDialogo
              celular={celular}
              onCancelar={() => setAEliminar(null)}
              onConfirmar={confirmarEliminar}
              confirmarLabel="Eliminar"
              confirmando={eliminar.isPending}
              destructivo
            />
          </div>
        </Dialogo>
      )}

      {confirmarFinalizar && (
        <Dialogo celular={celular} title="Finalizar mi carga" onClose={() => setConfirmarFinalizar(false)}>
          <div className="flex flex-col gap-stack-md font-sans text-body-md text-ink">
            <p>
              Vas a aplicar <strong>{filas.length}</strong> fila{filas.length === 1 ? '' : 's'} ·{' '}
              <strong>{formatCantidad(unidades)}</strong> unidades al inventario.
            </p>
            <ul className="list-disc pl-5 text-ink-soft">
              <li>Los productos nuevos se crean con el precio que cargaste.</li>
              <li>El stock se suma en Local.</li>
              <li>Tu lista queda vacía para seguir cargando.</li>
            </ul>
            <BotonesDialogo
              celular={celular}
              onCancelar={() => setConfirmarFinalizar(false)}
              onConfirmar={confirmarFinalizacion}
              confirmarLabel="Finalizar"
              confirmando={finalizar.isPending}
            />
          </div>
        </Dialogo>
      )}

      {resultado && (
        <Dialogo celular={celular} title="Carga aplicada" onClose={() => setResultado(null)}>
          <div className="flex flex-col gap-stack-md">
            <ResultadoFinalizar resultado={resultado} />
            <BotonesDialogo celular={celular} onCancelar={() => setResultado(null)} cancelarLabel="Listo" />
          </div>
        </Dialogo>
      )}
    </div>
  )
}

function ListaVacia() {
  return (
    <p className="py-2 text-center font-sans text-body-md text-ink-soft">
      Todavía no cargaste nada. Escaneá o tipeá un código arriba.
    </p>
  )
}

// Anchos de columna compartidos por la fila de entrada y la tabla (sección 5.2: table-fixed + colgroup).
function ColumnasMiCarga() {
  return (
    <colgroup>
      <col className="w-[11rem]" />
      <col />
      <col className="w-[14%]" />
      <col className="w-[18%]" />
      <col className="w-[7.5rem]" />
      <col className="w-[6rem]" />
      <col className="w-[7rem]" />
    </colgroup>
  )
}

// ─────────────────────────────────────────────────────────────
// Fila de entrada
// ─────────────────────────────────────────────────────────────

const inputEscritorio =
  'h-9 w-full min-w-0 rounded border border-line bg-surface px-2 font-sans text-body-md text-ink outline-none focus:border-accent read-only:bg-bg read-only:text-ink-soft aria-[invalid=true]:border-error'
const inputCelular =
  'h-12 w-full min-w-0 rounded border border-line bg-surface px-3 font-sans text-body-md text-ink outline-none focus:border-accent read-only:bg-bg read-only:text-ink-soft aria-[invalid=true]:border-error'

function Entrada({
  supabase,
  celular,
  onGuardar,
  onCerrada,
}: {
  supabase: SupabaseClient
  celular: boolean
  onGuardar: (c: Campos, accion: AccionCargaInicial) => void
  onCerrada: () => void
}) {
  const [campos, setCampos] = useState<Campos>(VACIO)
  const [accion, setAccion] = useState<AccionCargaInicial>('nuevo')
  const [bloqueo, setBloqueo] = useState<Bloqueo>('ninguno')
  const [panel, setPanel] = useState<CargaInicialBusqueda | null>(null)
  const [aviso, setAviso] = useState<string | null>(null)
  const [errores, setErrores] = useState<ErroresFila & { general?: string }>({})
  const [buscando, setBuscando] = useState(false)
  // Código ya consultado (normalizado): no se vuelve a buscar al salir del campo sin cambiarlo.
  const buscado = useRef<string>('')
  const codigoRef = useRef<HTMLInputElement>(null)
  const nombreRef = useRef<HTMLInputElement>(null)
  const precioRef = useRef<HTMLInputElement>(null)
  const cantidadRef = useRef<HTMLInputElement>(null)

  function set<K extends keyof Campos>(campo: K, valor: string) {
    setCampos((prev) => ({ ...prev, [campo]: valor }))
    if (campo in errores) setErrores((prev) => ({ ...prev, [campo]: undefined }))
  }

  function limpiar() {
    setCampos(VACIO)
    setAccion('nuevo')
    setBloqueo('ninguno')
    setPanel(null)
    setAviso(null)
    setErrores({})
    buscado.current = ''
    codigoRef.current?.focus()
  }

  function cambiarCodigo(valor: string) {
    set('codigo', valor)
    // Otro código: lo decidido para el anterior ya no vale.
    if (normalizarCodigoBarras(valor) !== buscado.current) {
      if (bloqueo !== 'ninguno' || accion !== 'nuevo' || panel || aviso) {
        setAccion('nuevo')
        setBloqueo('ninguno')
        setPanel(null)
        setAviso(null)
      }
    }
  }

  async function buscar(valor: string) {
    const codigo = normalizarCodigoBarras(valor)
    if (!codigo || codigo === buscado.current) return
    buscado.current = codigo
    setBuscando(true)
    setErrores((prev) => ({ ...prev, general: undefined }))
    try {
      const r = await buscarCodigoCarga(supabase, codigo)
      if (buscado.current !== codigo) return // se cambió el código mientras tanto
      aplicarBusqueda(r)
    } catch (e) {
      if (esCargaCerrada(e)) onCerrada()
      setAviso(
        'No se pudo verificar el código (sin conexión). Se guarda como producto nuevo; si ya existía, la base lo avisa al reintentar.',
      )
    } finally {
      setBuscando(false)
    }
  }

  function aplicarBusqueda(r: CargaInicialBusqueda) {
    setPanel(null)
    setAviso(null)
    setBloqueo('ninguno')
    if (r.mi_borrador) {
      const b = r.mi_borrador
      setAccion(b.accion)
      setCampos((prev) => ({
        ...prev,
        nombre: prev.nombre || b.nombre,
        marca: prev.marca || (b.marca ?? ''),
        descripcion: prev.descripcion || (b.descripcion ?? ''),
        precio: prev.precio || String(b.precio),
      }))
      if (b.accion === 'sumar') setBloqueo('datos')
      setAviso(`Ya está en tu lista (${formatCantidad(b.cantidad)} u.): al guardar se suma la cantidad.`)
      return
    }
    if (r.producto || r.borradores_otros.length > 0) {
      setPanel(r)
      return
    }
    setAccion('nuevo')
  }

  function usarSusDatos() {
    if (!panel) return
    const p = panel.producto
    const otro = panel.borradores_otros[panel.borradores_otros.length - 1]
    setCampos((prev) => ({
      ...prev,
      nombre: p ? p.nombre : otro.nombre,
      marca: (p ? p.marca : otro.marca) ?? '',
      descripcion: p ? (p.descripcion ?? '') : prev.descripcion,
      precio: String(p ? p.precio_venta : otro.precio),
    }))
    setAccion(p ? 'sumar' : 'nuevo')
    setBloqueo('datos')
    setPanel(null)
    setErrores({})
    setTimeout(() => cantidadRef.current?.focus())
  }

  function usarMisDatos() {
    if (!panel) return
    const p = panel.producto
    setAccion('reemplazar')
    if (p?.tiene_costo) {
      setCampos((prev) => ({ ...prev, precio: String(p.precio_venta) }))
      setBloqueo('precio')
    } else {
      setBloqueo('ninguno')
    }
    setPanel(null)
    setTimeout(() => nombreRef.current?.focus())
  }

  async function guardar() {
    if (buscando) {
      setErrores({ general: 'Verificando el código, un momento…' })
      return
    }
    const codigo = normalizarCodigoBarras(campos.codigo)
    // Código sin consultar (ej. ✓ directo desde el campo): primero se consulta, después se guarda.
    if (codigo && codigo !== buscado.current) {
      await buscar(codigo)
      return
    }
    if (panel) {
      setErrores({ general: 'Elegí qué hacer con este código antes de guardar.' })
      return
    }
    const e = validarFila(campos)
    if (Object.keys(e).length > 0) {
      setErrores(e)
      ;(e.nombre ? nombreRef : e.precio ? precioRef : cantidadRef).current?.focus()
      return
    }
    onGuardar(campos, accion)
    limpiar()
  }

  function onKeyDownCodigo(e: KeyboardEvent<HTMLInputElement>) {
    // El lector físico manda Enter al terminar: consulta el código y pasa al siguiente campo.
    if (e.key === 'Enter') {
      e.preventDefault()
      void buscar(campos.codigo)
      ;(bloqueo === 'datos' ? cantidadRef : nombreRef).current?.focus()
    }
    if (e.key === 'Escape') limpiar()
  }

  function onKeyDownCampo(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'Enter') {
      e.preventDefault()
      void guardar()
    }
    if (e.key === 'Escape') limpiar()
  }

  const bloqueaDatos = bloqueo === 'datos'
  const bloqueaPrecio = bloqueo !== 'ninguno'
  const inputClass = celular ? inputCelular : inputEscritorio
  const props = (campo: keyof ErroresFila | 'marca' | 'descripcion', ref?: RefObject<HTMLInputElement>) => ({
    ref,
    value: campos[campo],
    onChange: (ev: { target: { value: string } }) => set(campo, ev.target.value),
    onKeyDown: onKeyDownCampo,
    'aria-invalid': campo in errores && !!errores[campo as keyof ErroresFila],
    'aria-describedby': errores[campo as keyof ErroresFila] ? `err-carga-${campo}` : undefined,
    className: inputClass,
  })

  const inputCodigo = (
    <div className="flex items-center gap-1.5">
      <input
        ref={codigoRef}
        id="carga-codigo"
        autoFocus
        value={campos.codigo}
        onChange={(e) => cambiarCodigo(e.target.value)}
        onBlur={(e) => void buscar(e.target.value)}
        onKeyDown={onKeyDownCodigo}
        placeholder={celular ? 'Escaneá o tipeá' : 'Lector o tipeo'}
        autoComplete="off"
        className={inputClass}
      />
      <ScanButton
        size={celular ? 'touch' : 'compact'}
        className={
          celular
            ? 'flex h-12 w-14 flex-shrink-0 items-center justify-center rounded border border-accent bg-accent text-white active:bg-accent-dark'
            : undefined
        }
        onDetect={(codigo) => {
          cambiarCodigo(codigo)
          void buscar(codigo)
          setTimeout(() => nombreRef.current?.focus())
        }}
        onFocusCampo={() => codigoRef.current?.focus()}
      />
    </div>
  )

  const botonGuardar = (
    <button
      type="button"
      onClick={() => void guardar()}
      aria-label="Guardar fila"
      title="Guardar fila (Enter)"
      className={`flex flex-shrink-0 items-center justify-center rounded bg-accent text-white transition hover:bg-accent-dark ${
        celular ? 'h-12 min-w-12 px-3' : 'h-9 w-9'
      }`}
    >
      {buscando ? <Loader2 className="h-5 w-5 animate-spin" aria-hidden /> : <Check className="h-5 w-5" aria-hidden />}
    </button>
  )

  const mensajes = (
    <>
      {buscando && (
        <p className="font-sans text-label-md text-ink-soft" aria-live="polite">
          Verificando código…
        </p>
      )}
      {aviso && <p className="rounded bg-accent-light px-3 py-2 font-sans text-label-md text-accent-darker">{aviso}</p>}
      {accion !== 'nuevo' && !aviso && !panel && (
        <p className="font-sans text-label-md text-accent-darker">
          {accion === 'sumar'
            ? 'Se suma la cantidad al producto existente.'
            : 'Se guardan tus datos y se suma la cantidad.'}
          {bloqueo === 'precio' && ' El precio sale del costo del producto y no se cambia.'}
        </p>
      )}
      {panel && <PanelCodigo r={panel} celular={celular} onSus={usarSusDatos} onMios={usarMisDatos} onCancelar={limpiar} />}
      {(errores.nombre || errores.precio || errores.cantidad || errores.general) && (
        <ul role="alert" className="flex flex-col gap-0.5 font-sans text-label-md text-error">
          {errores.general && <li>{errores.general}</li>}
          {errores.nombre && <li id="err-carga-nombre">{errores.nombre}</li>}
          {errores.precio && <li id="err-carga-precio">{errores.precio}</li>}
          {errores.cantidad && <li id="err-carga-cantidad">{errores.cantidad}</li>}
        </ul>
      )}
    </>
  )

  const candado = bloqueaPrecio ? (
    <Lock className="h-4 w-4 flex-shrink-0 text-ink-soft" aria-label="Precio fijo" />
  ) : null

  if (celular) {
    return (
      <section aria-label="Cargar producto" className="flex flex-col gap-2 rounded-lg border border-line bg-surface p-3 shadow-sm">
        <Etiqueta htmlFor="carga-codigo" texto="Código">
          {inputCodigo}
        </Etiqueta>
        <Etiqueta htmlFor="carga-nombre" texto="Nombre">
          <input id="carga-nombre" readOnly={bloqueaDatos} {...props('nombre', nombreRef)} />
        </Etiqueta>
        <div className="grid grid-cols-2 gap-2">
          <Etiqueta htmlFor="carga-marca" texto="Marca">
            <input id="carga-marca" readOnly={bloqueaDatos} {...props('marca')} />
          </Etiqueta>
          <Etiqueta htmlFor="carga-descripcion" texto="Descripción">
            <input id="carga-descripcion" readOnly={bloqueaDatos} {...props('descripcion')} />
          </Etiqueta>
        </div>
        <div className="grid grid-cols-[1fr_1fr_auto] items-end gap-2">
          <Etiqueta htmlFor="carga-precio" texto="Precio">
            <div className="flex items-center gap-1">
              <input id="carga-precio" type="number" inputMode="decimal" min="0" step="0.01" readOnly={bloqueaPrecio} {...props('precio', precioRef)} />
              {candado}
            </div>
          </Etiqueta>
          <Etiqueta htmlFor="carga-cantidad" texto="Cantidad">
            <input id="carga-cantidad" type="number" inputMode="decimal" min="0" step="1" {...props('cantidad', cantidadRef)} />
          </Etiqueta>
          {botonGuardar}
        </div>
        {mensajes}
      </section>
    )
  }

  return (
    // Fija arriba mientras la lista scrollea: el foco vuelve siempre acá después de guardar.
    <section aria-label="Cargar producto" className="sticky top-0 z-10 flex flex-col gap-2 rounded-xl border-2 border-accent/40 bg-surface p-2 shadow-sm">
      <table className="w-full table-fixed font-sans text-table-row max-xl:[&_td]:px-1">
        <ColumnasMiCarga />
        <thead>
          <tr className="text-left text-table-head uppercase text-accent-dark">
            <th className="px-1.5 pb-1">
              <label htmlFor="carga-codigo">Código</label>
            </th>
            <th className="px-1.5 pb-1">
              <label htmlFor="carga-nombre">Nombre</label>
            </th>
            <th className="px-1.5 pb-1">
              <label htmlFor="carga-marca">Marca</label>
            </th>
            <th className="px-1.5 pb-1">
              <label htmlFor="carga-descripcion">Descripción</label>
            </th>
            <th className="px-1.5 pb-1 text-right">
              <label htmlFor="carga-precio">Precio</label>
            </th>
            <th className="px-1.5 pb-1 text-right">
              <label htmlFor="carga-cantidad">Cantidad</label>
            </th>
            <th className="px-1.5 pb-1">
              <span className="sr-only">Guardar</span>
            </th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td className="px-1.5">{inputCodigo}</td>
            <td className="px-1.5">
              <input id="carga-nombre" readOnly={bloqueaDatos} {...props('nombre', nombreRef)} />
            </td>
            <td className="px-1.5">
              <input id="carga-marca" readOnly={bloqueaDatos} {...props('marca')} />
            </td>
            <td className="px-1.5">
              <input id="carga-descripcion" readOnly={bloqueaDatos} {...props('descripcion')} />
            </td>
            <td className="px-1.5">
              <div className="flex items-center gap-1">
                <input id="carga-precio" type="number" min="0" step="0.01" readOnly={bloqueaPrecio} {...props('precio', precioRef)} />
                {candado}
              </div>
            </td>
            <td className="px-1.5">
              <input id="carga-cantidad" type="number" min="0" step="1" {...props('cantidad', cantidadRef)} />
            </td>
            <td className="px-1.5">
              <div className="flex justify-end">{botonGuardar}</div>
            </td>
          </tr>
        </tbody>
      </table>
      <div className="flex flex-col gap-1 px-1.5">{mensajes}</div>
      <p className="px-1.5 font-sans text-label-md text-ink-soft">
        Enter guarda la fila · Esc la limpia · Código vacío = se genera uno al finalizar
      </p>
    </section>
  )
}

function Etiqueta({ htmlFor, texto, children }: { htmlFor: string; texto: string; children: ReactNode }) {
  return (
    <div className="flex min-w-0 flex-col gap-1">
      <label htmlFor={htmlFor} className="font-sans text-label-md text-ink">
        {texto}
      </label>
      {children}
    </div>
  )
}

// "Ya cargado por Juan…" — el código existe como producto y/o en borradores de otros.
function PanelCodigo({
  r,
  celular,
  onSus,
  onMios,
  onCancelar,
}: {
  r: CargaInicialBusqueda
  celular: boolean
  onSus: () => void
  onMios: () => void
  onCancelar: () => void
}) {
  const boton = `rounded px-4 font-sans text-label-bold ${celular ? 'min-h-11 w-full' : 'py-2'}`
  return (
    <div role="region" aria-live="polite" aria-label="El código ya está cargado" className="rounded-lg border border-badge-amber-text/40 bg-badge-amber-bg px-3 py-2">
      <ul className="flex flex-col gap-0.5 font-sans text-body-md text-ink">
        {r.producto && (
          <li>
            <strong>Ya existe:</strong> {r.producto.nombre}
            {r.producto.marca ? ` · ${r.producto.marca}` : ''} · {formatCurrency(r.producto.precio_venta)} · stock local{' '}
            {formatCantidad(r.producto.stock_local)}
            {r.producto.tiene_costo && ' · precio por costo'}
            {r.producto.estado === 'inactivo' && ' · inactivo'}
          </li>
        )}
        {r.borradores_otros.map((b) => (
          <li key={b.id}>
            <strong>Ya cargado por {b.usuario_nombre}:</strong> {b.nombre} · {formatCurrency(b.precio)} ·{' '}
            {formatCantidad(b.cantidad)} u.
          </li>
        ))}
      </ul>
      <div className={`mt-2 flex gap-2 ${celular ? 'flex-col' : 'flex-wrap'}`}>
        <button type="button" onClick={onSus} className={`${boton} bg-accent text-white hover:bg-accent-dark`}>
          Usar sus datos y sumar
        </button>
        <button type="button" onClick={onMios} className={`${boton} border border-accent bg-surface text-accent-darker hover:bg-accent-light`}>
          Usar mis datos
        </button>
        <button type="button" onClick={onCancelar} className={`${boton} text-ink-soft hover:bg-bg`}>
          Cancelar
        </button>
      </div>
    </div>
  )
}

// ─────────────────────────────────────────────────────────────
// Filas guardadas (escritorio)
// ─────────────────────────────────────────────────────────────

function EstadoFila({ fila, onReintentar }: { fila: FilaVista; onReintentar: () => void }) {
  if (fila.estado === 'guardando')
    return <Loader2 className="h-4 w-4 animate-spin text-ink-soft" aria-label="Guardando" />
  if (fila.estado === 'error')
    return (
      <span className="flex items-center gap-1 text-error">
        <AlertTriangle className="h-4 w-4 flex-shrink-0" aria-hidden />
        <span className="sr-only">No guardada.</span>
        <button type="button" onClick={onReintentar} className="rounded px-1 font-semibold underline hover:bg-error/10" title={fila.error ?? undefined}>
          Reintentar
        </button>
      </span>
    )
  return <Check className="h-4 w-4 text-success" aria-label="Guardada" />
}

function FilaBorrador({
  fila,
  onGuardar,
  onEliminar,
  onReintentar,
}: {
  fila: FilaVista
  onGuardar: (c: Omit<Campos, 'codigo'>) => void
  onEliminar: () => void
  onReintentar: () => void
}) {
  const [edicion, setEdicion] = useState<Omit<Campos, 'codigo'> | null>(null)
  const [errores, setErrores] = useState<ErroresFila>({})
  const soloCantidad = fila.accion === 'sumar'

  function empezar() {
    setEdicion({ nombre: fila.nombre, marca: fila.marca, descripcion: fila.descripcion, precio: fila.precio, cantidad: fila.cantidad })
    setErrores({})
  }

  function confirmar() {
    if (!edicion) return
    const e = validarFila(edicion)
    if (Object.keys(e).length > 0) {
      setErrores(e)
      return
    }
    onGuardar(edicion)
    setEdicion(null)
  }

  function onKeyDown(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'Enter') {
      e.preventDefault()
      confirmar()
    }
    if (e.key === 'Escape') {
      e.preventDefault()
      setEdicion(null)
    }
  }

  const items: RowActionsMenuItem[] = [
    { label: 'Editar', icon: Pencil, onClick: empezar, disabled: fila.estado === 'guardando' },
    { label: 'Eliminar', icon: Trash2, onClick: onEliminar, destructive: true, disabled: fila.estado === 'guardando' },
  ]
  if (fila.estado === 'error') items.unshift({ label: 'Reintentar', icon: RotateCcw, onClick: onReintentar })

  const etiqueta = textoAccion(fila.accion, fila.conProducto)
  const celda = 'px-3 py-3 align-top'

  if (edicion) {
    const input = (campo: keyof typeof edicion, extra: Record<string, unknown> = {}) => (
      <input
        aria-label={campo === 'cantidad' ? 'Cantidad' : campo[0].toUpperCase() + campo.slice(1)}
        value={edicion[campo]}
        onChange={(e) => setEdicion({ ...edicion, [campo]: e.target.value })}
        onKeyDown={onKeyDown}
        aria-invalid={!!errores[campo as keyof ErroresFila]}
        className={inputEscritorio}
        {...extra}
      />
    )
    return (
      <tr className="border-b border-table-divider bg-accent-light/40">
        <td className={`${celda} [overflow-wrap:anywhere]`}>{fila.codigo || '—'}</td>
        <td className={celda}>{soloCantidad ? fila.nombre : input('nombre', { autoFocus: true })}</td>
        <td className={celda}>{soloCantidad ? fila.marca : input('marca')}</td>
        <td className={celda}>{soloCantidad ? fila.descripcion : input('descripcion')}</td>
        <td className={`${celda} text-right`}>
          {soloCantidad ? formatCurrency(Number(fila.precio)) : input('precio', { type: 'number', min: '0', step: '0.01' })}
        </td>
        <td className={celda}>{input('cantidad', { type: 'number', min: '0', step: '1', autoFocus: soloCantidad })}</td>
        <td className={celda}>
          <div className="flex justify-end gap-1">
            <button type="button" onClick={confirmar} aria-label="Guardar cambios" className="rounded bg-accent p-1.5 text-white hover:bg-accent-dark">
              <Check className="h-4 w-4" aria-hidden />
            </button>
            <button type="button" onClick={() => setEdicion(null)} aria-label="Cancelar edición" className="rounded px-1.5 text-ink-soft hover:bg-bg">
              Esc
            </button>
          </div>
          {Object.values(errores).filter(Boolean).length > 0 && (
            <p role="alert" className="mt-1 text-error">
              {Object.values(errores).filter(Boolean).join(' ')}
            </p>
          )}
        </td>
      </tr>
    )
  }

  return (
    <tr
      className={`border-b border-table-divider last:border-0 even:bg-table-row-alt ${fila.estado === 'error' ? '!bg-error/5' : ''}`}
      onDoubleClick={fila.estado === 'guardando' ? undefined : empezar}
    >
      <td className={`${celda} [overflow-wrap:anywhere]`}>{fila.codigo || <span className="text-ink-soft">Se genera</span>}</td>
      <td className={`${celda} [overflow-wrap:anywhere]`}>
        <span className="text-ink">{fila.nombre}</span>
        {etiqueta && <span className="ml-2 rounded-[6px] bg-badge-neutral-bg px-1.5 py-0.5 text-ink-soft">{etiqueta}</span>}
        {fila.estado === 'error' && (
          <span className="mt-0.5 block text-error">No guardada{fila.error ? `: ${fila.error}` : ''}</span>
        )}
      </td>
      <td className={`${celda} [overflow-wrap:anywhere] text-ink-soft`}>{fila.marca}</td>
      <td className={`${celda} [overflow-wrap:anywhere] text-ink-soft`}>{fila.descripcion}</td>
      <td className={`${celda} text-right font-semibold text-accent-darker`}>{formatCurrency(Number(fila.precio))}</td>
      <td className={`${celda} text-right`}>{formatCantidad(Number(fila.cantidad))}</td>
      <td className={celda}>
        <div className="flex items-center justify-end gap-2">
          <EstadoFila fila={fila} onReintentar={onReintentar} />
          <RowActionsMenu items={items} ariaLabel={`Acciones de ${fila.nombre}`} />
        </div>
      </td>
    </tr>
  )
}

// ─────────────────────────────────────────────────────────────
// Filas guardadas (celular)
// ─────────────────────────────────────────────────────────────

function TarjetaBorrador({
  fila,
  onEditar,
  onEliminar,
  onReintentar,
}: {
  fila: FilaVista
  onEditar: () => void
  onEliminar: () => void
  onReintentar: () => void
}) {
  const etiqueta = textoAccion(fila.accion, fila.conProducto)
  const items: RowActionsMenuItem[] = [
    { label: 'Editar', icon: Pencil, onClick: onEditar, disabled: fila.estado === 'guardando' },
    { label: 'Eliminar', icon: Trash2, onClick: onEliminar, destructive: true, disabled: fila.estado === 'guardando' },
  ]
  if (fila.estado === 'error') items.unshift({ label: 'Reintentar', icon: RotateCcw, onClick: onReintentar })
  return (
    <li className={`rounded-lg border bg-surface p-4 shadow-sm ${fila.estado === 'error' ? 'border-error/50' : 'border-line'}`}>
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="font-sans text-label-bold text-ink [overflow-wrap:anywhere]">{fila.nombre}</p>
          <p className="font-sans text-label-md text-ink-soft [overflow-wrap:anywhere]">
            {[fila.marca, fila.codigo || 'Código: se genera'].filter(Boolean).join(' · ')}
          </p>
          {etiqueta && <p className="font-sans text-label-md text-accent-darker">{etiqueta}</p>}
        </div>
        <RowActionsMenu items={items} size="touch" ariaLabel={`Acciones de ${fila.nombre}`} />
      </div>
      <div className="mt-2 flex items-end justify-between">
        <span className="font-sans text-body-md text-ink">{formatCantidad(Number(fila.cantidad))} u.</span>
        <span className="font-display text-headline-md text-accent-darker">{formatCurrency(Number(fila.precio))}</span>
      </div>
      <div className="mt-2 flex items-center gap-2 font-sans text-label-md">
        {fila.estado === 'guardada' && (
          <span className="flex items-center gap-1 text-success">
            <Check className="h-4 w-4" aria-hidden /> Guardada
          </span>
        )}
        {fila.estado === 'guardando' && (
          <span className="flex items-center gap-1 text-ink-soft">
            <Loader2 className="h-4 w-4 animate-spin" aria-hidden /> Guardando…
          </span>
        )}
        {fila.estado === 'error' && (
          <div className="flex w-full flex-col gap-2 text-error">
            <span>No guardada{fila.error ? `: ${fila.error}` : ''}</span>
            <button type="button" onClick={onReintentar} className="min-h-11 rounded border border-error px-4 font-sans text-label-bold">
              Reintentar
            </button>
          </div>
        )}
      </div>
    </li>
  )
}

function EditorBorradorSheet({
  fila,
  onCancelar,
  onGuardar,
}: {
  fila: FilaVista
  onCancelar: () => void
  onGuardar: (c: Omit<Campos, 'codigo'>) => void
}) {
  const [c, setC] = useState<Omit<Campos, 'codigo'>>({
    nombre: fila.nombre,
    marca: fila.marca,
    descripcion: fila.descripcion,
    precio: fila.precio,
    cantidad: fila.cantidad,
  })
  const [errores, setErrores] = useState<ErroresFila>({})
  const soloCantidad = fila.accion === 'sumar'

  function confirmar() {
    const e = validarFila(c)
    if (Object.keys(e).length > 0) {
      setErrores(e)
      return
    }
    onGuardar(c)
  }

  const campo = (k: keyof typeof c, label: string, extra: Record<string, unknown> = {}) => (
    <Etiqueta htmlFor={`editar-${k}`} texto={label}>
      <input
        id={`editar-${k}`}
        value={c[k]}
        onChange={(e) => setC({ ...c, [k]: e.target.value })}
        readOnly={soloCantidad && k !== 'cantidad'}
        aria-invalid={!!errores[k as keyof ErroresFila]}
        className={inputCelular}
        {...extra}
      />
      {errores[k as keyof ErroresFila] && <span className="font-sans text-label-md text-error">{errores[k as keyof ErroresFila]}</span>}
    </Etiqueta>
  )

  return (
    <Dialogo
      celular
      title="Editar fila"
      onClose={onCancelar}
      footer={<BotonesDialogo celular onCancelar={onCancelar} onConfirmar={confirmar} confirmarLabel="Guardar" />}
    >
      <div className="flex flex-col gap-3">
        <p className="font-sans text-label-md text-ink-soft">Código: {fila.codigo || 'se genera al finalizar'}</p>
        {soloCantidad && (
          <p className="font-sans text-label-md text-accent-darker">Suma stock a un producto existente: solo se cambia la cantidad.</p>
        )}
        {campo('nombre', 'Nombre')}
        {campo('marca', 'Marca')}
        {campo('descripcion', 'Descripción')}
        <div className="grid grid-cols-2 gap-2">
          {campo('precio', 'Precio', { type: 'number', inputMode: 'decimal', min: '0', step: '0.01' })}
          {campo('cantidad', 'Cantidad', { type: 'number', inputMode: 'decimal', min: '0', step: '1', autoFocus: soloCantidad })}
        </div>
      </div>
    </Dialogo>
  )
}
