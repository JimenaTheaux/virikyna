// Precio de venta de un producto — espejo exacto de las columnas generadas de `productos`
// (docs/06_estructura_de_datos.md, secciones 20 y 21; docs/29 y docs/30_redondeo_escalonado.sql):
//
//   precio_calculado = ROUND(costo × (1 + margen_1/100) × (1 + margen_2/100) × (1 + iva/100), 2)
//                      (null si costo es null — docs/34)
//   precio_venta     = COALESCE(precio_manual, redondear_precio_venta(precio_calculado))
//                      ← lo que se cobra: el precio manual exacto, o la fórmula con la regla escalonada
//
// El valor real siempre lo calcula la base; esto es para las vistas previas (formularios de
// producto, ítem de factura de compra, actualización masiva). Se calcula con enteros (BigInt) y
// no con number: Postgres usa NUMERIC exacto y redondea la mitad hacia afuera, y con punto
// flotante un precio que cae justo en ,5 podía redondear distinto que la base.
//
// Sin imports a propósito: lo corre también `node --test` (packages/shared/tests).

const DIEZ_MIL = 10000n
const UN_BILLON = 10n ** 12n // 10000³: las tres razones (1 + x/100) llevan 4 decimales cada una

// Pasa un número o texto decimal a entero escalado (valor × 10^escala), redondeando la mitad
// hacia afuera como el cast de Postgres a NUMERIC(p, escala). Lo que no es un número vale 0 (igual
// que `Number(x) || 0` en los formularios).
function aEscalado(valor: number | string, escala: number): bigint {
  let texto: string
  if (typeof valor === 'number') {
    if (!Number.isFinite(valor)) return 0n
    texto = String(valor)
    if (/e/i.test(texto)) texto = valor.toFixed(20)
  } else {
    texto = valor.trim()
  }
  const m = /^([+-]?)(\d*)(?:\.(\d*))?$/.exec(texto)
  if (!m || (m[2] === '' && (m[3] ?? '') === '')) return 0n
  const negativo = m[1] === '-'
  const decimales = m[3] ?? ''
  const entero = BigInt((m[2] || '0') + decimales.padEnd(escala, '0').slice(0, escala))
  const siguiente = decimales.length > escala ? Number(decimales[escala]) : 0
  const absoluto = siguiente >= 5 ? entero + 1n : entero
  return negativo ? -absoluto : absoluto
}

// a / b redondeado a entero, la mitad hacia afuera (como ROUND de Postgres sobre NUMERIC).
function dividirRedondeando(a: bigint, b: bigint): bigint {
  const negativo = a < 0n !== b < 0n
  const absA = a < 0n ? -a : a
  const absB = b < 0n ? -b : b
  let q = absA / absB
  if ((absA % absB) * 2n >= absB) q += 1n
  return negativo ? -q : q
}

const aPesos = (centavos: bigint) => Number(centavos) / 100

// Regla escalonada del precio de venta — espejo de redondear_precio_venta (docs/30). Todo en
// centavos enteros; primero ROUND(x, 2) (= precio_calculado) y después:
//   base < 500           → centena más cercana, la mitad sube        (149 → 100, 150 → 200)
//   500 <= base < 10000  → múltiplo de 500: resto <= 200 baja, > 200 sube (6200 → 6000, 6200,01 → 6500)
//   base >= 10000        → múltiplo de 1000 más cercano, 500 sube   (11499,99 → 11000, 11500 → 12000)
export function redondearPrecioVenta(precio: number | string): number {
  const base = aEscalado(precio, 2)
  let venta: bigint
  if (base < 50_000n) {
    venta = dividirRedondeando(base, 10_000n) * 10_000n
  } else if (base < 1_000_000n) {
    const resto = base % 50_000n
    venta = resto <= 20_000n ? base - resto : base - resto + 50_000n
  } else {
    venta = dividirRedondeando(base, 100_000n) * 100_000n
  }
  return aPesos(venta)
}

export type DatosPrecio = {
  // null = sin costo (producto de la carga inicial): no hay fórmula. Un texto vacío de formulario
  // sigue valiendo 0, como siempre.
  costo: number | string | null
  margen1: number | string
  margen2: number | string
  iva: number | string
  // productos.precio_manual: si viene (no null ni vacío) es el precio de venta, exacto.
  precioManual?: number | string | null
}

export type PrecioProducto = {
  calculado: number | null // precio_calculado: exacto, 2 decimales; null sin costo
  venta: number // precio_venta: el manual, o la fórmula con redondeo escalonado (0 si no hay ninguno)
  ajuste: number // venta − calculado (negativo si redondeó para abajo); 0 con precio manual
  manual: boolean // el precio de venta es el precio manual
}

function hayValor(v: number | string | null | undefined): v is number | string {
  return v !== null && v !== undefined && !(typeof v === 'string' && v.trim() === '')
}

export function calcularPrecio({ costo, margen1, margen2, iva, precioManual }: DatosPrecio): PrecioProducto {
  let calculado: bigint | null = null
  if (costo !== null) {
    // costo en centavos × las tres razones con 4 decimales → centavos × 10^12
    const crudo =
      aEscalado(costo, 2) *
      (DIEZ_MIL + aEscalado(margen1, 2)) *
      (DIEZ_MIL + aEscalado(margen2, 2)) *
      (DIEZ_MIL + aEscalado(iva, 2))
    calculado = dividirRedondeando(crudo, UN_BILLON)
  }
  const calculadoPesos = calculado === null ? null : aPesos(calculado)
  if (hayValor(precioManual)) {
    // NUMERIC(12,2): el manual se guarda redondeado a centavos, sin regla escalonada.
    return { calculado: calculadoPesos, venta: redondearPesos(precioManual), ajuste: 0, manual: true }
  }
  if (calculado === null) return { calculado: null, venta: 0, ajuste: 0, manual: false }
  // La base del redondeo es precio_calculado (la función SQL hace ROUND(…, 2) primero).
  const venta = redondearPrecioVenta(aPesos(calculado))
  return { calculado: calculadoPesos, venta, ajuste: aPesos(aEscalado(venta, 2) - calculado), manual: false }
}

// Costo tras la actualización masiva: ROUND(costo × (1 + porcentaje/100), 2), igual que el RPC
// actualizar_precios_masivo. El porcentaje entra tal cual se tipeó (el RPC no lo redondea).
export function costoConPorcentaje(costo: number | string, porcentaje: number | string): number {
  const texto = typeof porcentaje === 'number' ? String(porcentaje) : porcentaje.trim()
  const decimales = /\.(\d+)/.exec(texto)?.[1].length ?? 0
  const escala = 10n ** BigInt(decimales)
  const p = aEscalado(texto, decimales)
  return aPesos(dividirRedondeando(aEscalado(costo, 2) * (100n * escala + p), 100n * escala))
}

// Precio manual tras la actualización masiva (docs/34): redondear_precio_venta(precio × (1 + p/100)),
// igual que el RPC. Si el redondeo da 0 (precio nuevo menor a $50), queda el valor exacto a centavos.
export function precioManualConPorcentaje(precio: number | string, porcentaje: number | string): number {
  const exacto = costoConPorcentaje(precio, porcentaje) // = ROUND(precio × (1 + p/100), 2)
  const redondeado = redondearPrecioVenta(exacto)
  return redondeado > 0 ? redondeado : exacto
}

// Redondeo a 2 decimales con la misma regla que Postgres (para comparar costos).
export function redondearPesos(valor: number | string): number {
  return aPesos(aEscalado(valor, 2))
}

// ─────────────────────────────────────────────────────────────
// Ítem de factura de compra: cómo queda el precio de venta al guardar
// ─────────────────────────────────────────────────────────────

// Lo que el ítem necesita saber del producto vinculado (se completa al elegirlo en la búsqueda).
export type ProductoPrecioActual = {
  costo: number | null // null = sin costo (carga inicial, docs/34)
  margen_1: number
  margen_2: number
  iva_porcentaje: number
  proveedor_id: string | null
  precio_venta: number
  precio_manual: number | null
}

export type CambioPrecioFactura =
  | { tipo: 'actualiza'; antes: number; despues: number }
  | { tipo: 'sin_cambio_precio'; precio: number }
  // docs/34: la factura le pone costo a un producto con precio manual → el manual se borra y el
  // precio pasa a la fórmula (puede dar el mismo número).
  | { tipo: 'reemplaza_manual'; manual: number; despues: number }
  | { tipo: 'repetido' }

// Igualdad de costos tolerando null (sin costo ≠ cualquier costo).
function mismoCosto(a: number | null, b: number | null): boolean {
  if (a === null || b === null) return a === b
  return redondearPesos(a) === redondearPesos(b)
}

type ItemParaPrecio = {
  key: string
  productoId: string | null
  precioUnitarioSinIva: string
  productoPrecio: ProductoPrecioActual | null
}

type ProveedorMargenes = { id: string; margen_1_default: number; margen_2_default: number }

// Espejo de cargar_factura_compra (docs/29, docs/34): por producto, la ÚLTIMA línea pisa el costo
// con su precio unitario sin IVA (salvo nota de crédito/débito o precio 0) y, si le pone costo,
// borra el precio manual; si el proveedor de la factura es otro (o no tenía), los márgenes pasan a
// los default de ese proveedor. Devuelve, por key de ítem, qué mostrar; sin entrada = no cambia nada.
export function cambiosPrecioFactura(
  items: ItemParaPrecio[],
  tipoComprobante: string,
  proveedorId: string,
  proveedores: ProveedorMargenes[],
): Map<string, CambioPrecioFactura> {
  const resultado = new Map<string, CambioPrecioFactura>()
  const actualizaCosto = tipoComprobante !== 'nota_credito' && tipoComprobante !== 'nota_debito'
  const proveedor = proveedores.find((p) => p.id === proveedorId)

  const ultimaPorProducto = new Map<string, string>()
  for (const it of items) if (it.productoId) ultimaPorProducto.set(it.productoId, it.key)

  for (const it of items) {
    const actual = it.productoPrecio
    if (!it.productoId || !actual) continue
    const esUltima = ultimaPorProducto.get(it.productoId) === it.key

    const precioItem = redondearPesos(it.precioUnitarioSinIva)
    const poneCosto = actualizaCosto && precioItem > 0
    const costoNuevo = poneCosto ? precioItem : actual.costo
    const cambiaCosto = !mismoCosto(costoNuevo, actual.costo)
    const cambiaProveedor = !!proveedor && proveedor.id !== actual.proveedor_id
    const manualActual = actual.precio_manual ?? null
    const borraManual = poneCosto && manualActual !== null

    if (!esUltima) {
      // Una línea anterior del mismo producto no define nada: avisarlo solo si su precio difiere.
      if (poneCosto && !mismoCosto(precioItem, actual.costo)) {
        resultado.set(it.key, { tipo: 'repetido' })
      }
      continue
    }
    if (!cambiaCosto && !cambiaProveedor && !borraManual) continue

    const margenes = cambiaProveedor && proveedor ? proveedor : null
    const despues = calcularPrecio({
      costo: costoNuevo,
      margen1: margenes ? margenes.margen_1_default : actual.margen_1,
      margen2: margenes ? margenes.margen_2_default : actual.margen_2,
      iva: actual.iva_porcentaje,
      precioManual: borraManual ? null : manualActual,
    }).venta
    resultado.set(
      it.key,
      borraManual
        ? { tipo: 'reemplaza_manual', manual: manualActual as number, despues }
        : despues === actual.precio_venta
          ? { tipo: 'sin_cambio_precio', precio: despues }
          : { tipo: 'actualiza', antes: actual.precio_venta, despues },
    )
  }
  return resultado
}
