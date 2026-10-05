// Precio de venta de un producto — espejo exacto de las columnas generadas de `productos`
// (docs/06_estructura_de_datos.md, sección 20; docs/29_redondeo_y_costo_factura.sql):
//
//   precio_calculado = ROUND(costo × (1 + margen_1/100) × (1 + margen_2/100) × (1 + iva/100), 2)
//   precio_venta     = ROUND(misma fórmula cruda, -2)   ← lo que se cobra, a la centena
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

export type DatosPrecio = {
  costo: number | string
  margen1: number | string
  margen2: number | string
  iva: number | string
}

export type PrecioProducto = {
  calculado: number // precio_calculado: exacto, 2 decimales
  venta: number // precio_venta: a la centena
  ajuste: number // venta − calculado (negativo si redondeó para abajo)
}

export function calcularPrecio({ costo, margen1, margen2, iva }: DatosPrecio): PrecioProducto {
  // costo en centavos × las tres razones con 4 decimales → centavos × 10^12
  const crudo =
    aEscalado(costo, 2) *
    (DIEZ_MIL + aEscalado(margen1, 2)) *
    (DIEZ_MIL + aEscalado(margen2, 2)) *
    (DIEZ_MIL + aEscalado(iva, 2))
  const calculado = dividirRedondeando(crudo, UN_BILLON)
  // Desde la fórmula cruda, no desde `calculado` (igual que la columna generada).
  const venta = dividirRedondeando(crudo, UN_BILLON * DIEZ_MIL) * DIEZ_MIL
  return { calculado: aPesos(calculado), venta: aPesos(venta), ajuste: aPesos(venta - calculado) }
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

// Redondeo a 2 decimales con la misma regla que Postgres (para comparar costos).
export function redondearPesos(valor: number | string): number {
  return aPesos(aEscalado(valor, 2))
}

// ─────────────────────────────────────────────────────────────
// Ítem de factura de compra: cómo queda el precio de venta al guardar
// ─────────────────────────────────────────────────────────────

// Lo que el ítem necesita saber del producto vinculado (se completa al elegirlo en la búsqueda).
export type ProductoPrecioActual = {
  costo: number
  margen_1: number
  margen_2: number
  iva_porcentaje: number
  proveedor_id: string | null
  precio_venta: number
}

export type CambioPrecioFactura =
  | { tipo: 'actualiza'; antes: number; despues: number }
  | { tipo: 'sin_cambio_precio'; precio: number }
  | { tipo: 'repetido' }

type ItemParaPrecio = {
  key: string
  productoId: string | null
  precioUnitarioSinIva: string
  productoPrecio: ProductoPrecioActual | null
}

type ProveedorMargenes = { id: string; margen_1_default: number; margen_2_default: number }

// Espejo de cargar_factura_compra (docs/29): por producto, la ÚLTIMA línea pisa el costo con su
// precio unitario sin IVA (salvo nota de crédito/débito o precio 0); si el proveedor de la factura
// es otro, los márgenes pasan a los default de ese proveedor. Devuelve, por key de ítem, qué
// mostrar; sin entrada = no cambia nada.
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
    const costoNuevo = actualizaCosto && precioItem > 0 ? precioItem : redondearPesos(actual.costo)
    const cambiaCosto = costoNuevo !== redondearPesos(actual.costo)
    const cambiaProveedor = !!proveedor && proveedor.id !== actual.proveedor_id

    if (!esUltima) {
      // Una línea anterior del mismo producto no define nada: avisarlo solo si su precio difiere.
      if (actualizaCosto && precioItem > 0 && precioItem !== redondearPesos(actual.costo)) {
        resultado.set(it.key, { tipo: 'repetido' })
      }
      continue
    }
    if (!cambiaCosto && !cambiaProveedor) continue

    const margenes = cambiaProveedor && proveedor ? proveedor : null
    const despues = calcularPrecio({
      costo: costoNuevo,
      margen1: margenes ? margenes.margen_1_default : actual.margen_1,
      margen2: margenes ? margenes.margen_2_default : actual.margen_2,
      iva: actual.iva_porcentaje,
    }).venta
    resultado.set(
      it.key,
      despues === actual.precio_venta
        ? { tipo: 'sin_cambio_precio', precio: despues }
        : { tipo: 'actualiza', antes: actual.precio_venta, despues },
    )
  }
  return resultado
}
