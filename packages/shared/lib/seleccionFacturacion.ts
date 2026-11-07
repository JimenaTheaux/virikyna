// Selección de la tab Facturación (Local y Gestión): separa "lo que sumo" de "lo que facturo".
// Se puede tildar cualquier venta visible —sin facturar, facturada o a revisar— para ver su total;
// el lote de Factura C (irreversible, en producción) sale solo de las que se pueden emitir.
// Sin imports de valores a propósito: lo corre node --test directo (tests/seleccionFacturacion.test.ts).
// Se exporta desde index.ts; las apps lo importan por ruta (@virikyna/shared/lib/seleccionFacturacion).

export type VentaSeleccionable = {
  id: string
  estado: string
  total: number
  estado_interno?: string | null
}

export type EstadoSeleccionarTodo = 'ninguna' | 'algunas' | 'todas'

export type Subtotal = { cantidad: number; total: number }

export type ResumenSeleccion<T> = {
  // Tildadas y visibles: lo que se suma.
  paraSumar: T[]
  total: number
  // Desglose por estado de la venta ("a revisar" sigue siendo sin facturar).
  sinFacturar: Subtotal
  facturadas: Subtotal
  // Lo único que puede ir a "Emitir Factura C".
  paraEmitir: T[]
  // Encabezado tri-estado, sobre las visibles.
  estadoTodo: EstadoSeleccionarTodo
}

// Centavos exactos: sumar floats deja colas como 0.30000000000000004.
function sumar(ventas: VentaSeleccionable[]): number {
  return Math.round(ventas.reduce((acc, v) => acc + Number(v.total), 0) * 100) / 100
}

export function sePuedeEmitir(v: VentaSeleccionable, idsARevisar: ReadonlySet<string>): boolean {
  return v.estado === 'sin_facturar' && !idsARevisar.has(v.id) && !v.estado_interno
}

export function resumenSeleccion<T extends VentaSeleccionable>(
  visibles: T[],
  seleccion: ReadonlySet<string>,
  idsARevisar: ReadonlySet<string>,
): ResumenSeleccion<T> {
  // Solo las visibles: una tildada que quedó oculta por un filtro no suma ni se factura sin verse.
  const paraSumar = visibles.filter((v) => seleccion.has(v.id))
  const facturadas = paraSumar.filter((v) => v.estado === 'facturado')
  const sinFacturar = paraSumar.filter((v) => v.estado !== 'facturado')

  let estadoTodo: EstadoSeleccionarTodo = 'ninguna'
  if (paraSumar.length > 0) estadoTodo = paraSumar.length === visibles.length ? 'todas' : 'algunas'

  return {
    paraSumar,
    total: sumar(paraSumar),
    sinFacturar: { cantidad: sinFacturar.length, total: sumar(sinFacturar) },
    facturadas: { cantidad: facturadas.length, total: sumar(facturadas) },
    paraEmitir: paraSumar.filter((v) => sePuedeEmitir(v, idsARevisar)),
    estadoTodo,
  }
}

// Clic en "Seleccionar todo": con todas tildadas, destilda las visibles; si no, tilda todas las visibles.
export function alternarTodas(
  visibles: VentaSeleccionable[],
  seleccion: ReadonlySet<string>,
  estadoTodo: EstadoSeleccionarTodo,
): Set<string> {
  const next = new Set(seleccion)
  for (const v of visibles) {
    if (estadoTodo === 'todas') next.delete(v.id)
    else next.add(v.id)
  }
  return next
}
