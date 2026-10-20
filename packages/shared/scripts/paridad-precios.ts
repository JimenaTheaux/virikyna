// Paridad de precios cliente ↔ base: `npm run paridad-precios` desde la raíz.
// Requiere la CLI de Supabase linkeada al proyecto (supabase/.temp) — consulta la base real.
//
// 1. Trae todos los productos y compara calcularPrecio() contra precio_calculado y precio_venta
//    (incluidos los de precio manual y costo null — docs/34).
// 2. Corre actualizar_precios_masivo con varios porcentajes sobre TODOS los productos dentro de un
//    bloque que termina en error a propósito (rollback: no queda nada escrito) y compara el costo y
//    el precio resultantes con lo que muestra la vista previa (costoConPorcentaje + calcularPrecio, o
//    precioManualConPorcentaje para los de precio manual).
// 3. Compara costoConDescuento con el ROUND de Postgres que usa cargar_factura_compra (docs/45).
//
// Sale con código 1 si hay alguna diferencia.
import { execSync } from 'node:child_process'
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { calcularPrecio, costoConDescuento, costoConPorcentaje, precioManualConPorcentaje } from '../lib/precios.ts'

type FilaProducto = {
  id: string
  nombre: string
  costo: number | null
  margen_1: number
  margen_2: number
  iva_porcentaje: number
  precio_manual: number | null
  precio_calculado: number | null
  precio_venta: number
}

const PORCENTAJES = ['7.5', '-12.34', '33.333', '0.01', '150']

function correrSql(sql: string): string {
  const dir = mkdtempSync(join(tmpdir(), 'paridad-'))
  const archivo = join(dir, 'q.sql')
  writeFileSync(archivo, sql)
  try {
    return execSync(`supabase db query --linked -f "${archivo}"`, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
  } catch (e) {
    const err = e as { stdout?: string; stderr?: string }
    return `${err.stdout ?? ''}\n${err.stderr ?? ''}`
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

// La CLI imprime líneas sueltas ("Initialising login role...") antes del JSON.
function jsonDeSalida(salida: string): unknown {
  const inicio = salida.indexOf('{')
  const fin = salida.lastIndexOf('}')
  if (inicio < 0) throw new Error(`Salida inesperada de la CLI:\n${salida}`)
  return JSON.parse(salida.slice(inicio, fin + 1))
}

const n = (v: unknown) => Number(v)
const nn = (v: unknown) => (v === null || v === undefined ? null : Number(v))

// ── 1. Columnas generadas ──────────────────────────────────────
const { rows } = jsonDeSalida(
  correrSql(
    'select id, nombre, costo, margen_1, margen_2, iva_porcentaje, precio_manual, precio_calculado, precio_venta from productos order by nombre;',
  ),
) as { rows: Record<string, unknown>[] }
const productos: FilaProducto[] = rows.map((r) => ({
  id: String(r.id),
  nombre: String(r.nombre),
  costo: nn(r.costo),
  margen_1: n(r.margen_1),
  margen_2: n(r.margen_2),
  iva_porcentaje: n(r.iva_porcentaje),
  precio_manual: nn(r.precio_manual),
  precio_calculado: nn(r.precio_calculado),
  precio_venta: n(r.precio_venta),
}))

const difColumnas: string[] = []
for (const p of productos) {
  const c = calcularPrecio({
    costo: p.costo,
    margen1: p.margen_1,
    margen2: p.margen_2,
    iva: p.iva_porcentaje,
    precioManual: p.precio_manual,
  })
  if (c.calculado !== p.precio_calculado || c.venta !== p.precio_venta) {
    difColumnas.push(
      `  ${p.nombre}: base calc=${p.precio_calculado} venta=${p.precio_venta} · cliente calc=${c.calculado} venta=${c.venta}`,
    )
  }
}
const manuales = productos.filter((p) => p.precio_manual !== null).length
console.log(
  `1. Columnas generadas: ${productos.length} productos (${manuales} con precio manual), ${difColumnas.length} diferencias`,
)
difColumnas.forEach((d) => console.log(d))

// ── 2. Actualización masiva (rollback) ─────────────────────────
const bloque = `
DO $$
DECLARE
  v_ids UUID[];
  v_p NUMERIC;
  v_res JSONB := '{}'::jsonb;
  v_uno JSONB;
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', (SELECT id FROM perfiles WHERE activo LIMIT 1), 'role', 'authenticated')::text, true);
  SELECT array_agg(id) INTO v_ids FROM productos;
  FOREACH v_p IN ARRAY ARRAY[${PORCENTAJES.join(',')}]::NUMERIC[] LOOP
    BEGIN
      PERFORM actualizar_precios_masivo(v_p, NULL, v_ids);
      SELECT jsonb_object_agg(id, jsonb_build_array(costo, precio_venta, precio_manual)) INTO v_uno FROM productos;
      v_res := v_res || jsonb_build_object(v_p::text, v_uno);
      RAISE EXCEPTION 'deshacer' USING ERRCODE = 'P0002';
    EXCEPTION WHEN SQLSTATE 'P0002' THEN NULL;
    END;
  END LOOP;
  RAISE EXCEPTION 'PARIDAD<<%>>PARIDAD', v_res;
END;
$$;`
const salida = correrSql(bloque)
const mensaje = (() => {
  try {
    return String((jsonDeSalida(salida) as { error?: { message?: string } }).error?.message ?? salida)
  } catch {
    return salida
  }
})()
const m = /PARIDAD<<([\s\S]*)>>PARIDAD/.exec(mensaje)
if (!m) {
  console.error('2. No se pudo leer el resultado del bloque de prueba:\n', mensaje)
  process.exit(1)
}
// Según cómo la CLI arme el error, el JSON llega con las comillas escapadas.
const crudo = m[1].includes('\\"') ? m[1].replace(/\\"/g, '"') : m[1]
const resultado = JSON.parse(crudo) as Record<string, Record<string, [number | null, number, number | null]>>

const difMasiva: string[] = []
for (const pct of PORCENTAJES) {
  const real = resultado[String(Number(pct))] ?? resultado[pct]
  if (!real) {
    difMasiva.push(`  ${pct}%: sin resultado de la base`)
    continue
  }
  for (const p of productos) {
    // Precio manual: el % va sobre el precio y el costo no cambia. Si no, sobre el costo (como antes).
    const manualPrev = p.precio_manual === null ? null : precioManualConPorcentaje(p.precio_manual, pct)
    const costoPrev = p.precio_manual !== null || p.costo === null ? p.costo : costoConPorcentaje(p.costo, pct)
    const ventaPrev = calcularPrecio({
      costo: costoPrev,
      margen1: p.margen_1,
      margen2: p.margen_2,
      iva: p.iva_porcentaje,
      precioManual: manualPrev,
    }).venta
    const [costoReal, ventaReal, manualReal] = (real[p.id] ?? []).map(nn) as [number | null, number, number | null]
    if (costoPrev !== costoReal || ventaPrev !== ventaReal || manualPrev !== manualReal) {
      difMasiva.push(
        `  ${pct}% ${p.nombre}: base costo=${costoReal} venta=${ventaReal} manual=${manualReal} · vista previa costo=${costoPrev} venta=${ventaPrev} manual=${manualPrev}`,
      )
    }
  }
}
console.log(
  `2. Actualización masiva (${PORCENTAJES.map((p) => `${p}%`).join(', ')}): ${
    productos.length * PORCENTAJES.length
  } comparaciones, ${difMasiva.length} diferencias (rollback, la base no cambió)`,
)
difMasiva.forEach((d) => console.log(d))

// ── 3. Costo con descuento de línea (docs/45) ──────────────────
// La misma expresión que cargar_factura_compra, con valores sueltos: solo lectura.
const PRECIOS_LINEA = ['1000', '8182', '333.33', '0.05', '1234.567', '99999.99']
const DESCUENTOS_LINEA = ['0', '10', '12.5', '33.333', '50', '99.99', '100']
const pares = PRECIOS_LINEA.flatMap((p) => DESCUENTOS_LINEA.map((d) => [p, d] as const))
const { rows: filasDescuento } = jsonDeSalida(
  correrSql(
    `select p::text as p, d::text as d, ROUND(p * (1 - d / 100.0), 2) as costo from (values ${pares
      .map(([p, d]) => `(${p}::numeric, ${d}::numeric)`)
      .join(', ')}) v(p, d);`,
  ),
) as { rows: Record<string, unknown>[] }
const difDescuento = pares.flatMap(([p, d], i) => {
  const real = n(filasDescuento[i]?.costo)
  const previa = costoConDescuento(p, d)
  return real === previa ? [] : [`  ${p} − ${d} %: base ${real} · vista previa ${previa}`]
})
console.log(`3. Costo con descuento de línea: ${pares.length} combinaciones, ${difDescuento.length} diferencias`)
difDescuento.forEach((d) => console.log(d))

// ── 4. Productos sin IVA (docs/47), rollback ──────────────────
// Hoy casi todos tienen precio manual e IVA 21: para ejercitar la fórmula sin IVA, dentro de un
// bloque que termina en error (no queda nada) se les pone un costo derivado del precio, sin precio
// manual e IVA 0, y se compara la columna generada con calcularPrecio(iva 0).
const bloqueSinIva = `
DO $$
DECLARE v_res JSONB;
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', (SELECT id FROM perfiles WHERE activo AND rol = 'admin' LIMIT 1), 'role', 'authenticated')::text, true);
  PERFORM set_config('virikyna.suppress_audit', 'true', true);
  UPDATE productos SET costo = COALESCE(costo, ROUND(precio_manual / 2.9, 2)), precio_manual = NULL, iva_porcentaje = 0
  WHERE id IS NOT NULL;
  SELECT jsonb_agg(jsonb_build_array(id, costo, margen_1, margen_2, precio_calculado, precio_venta)) INTO v_res FROM productos;
  RAISE EXCEPTION 'PARIDAD<<%>>PARIDAD', v_res;
END;
$$;`
const salidaSinIva = correrSql(bloqueSinIva)
const mensajeSinIva = (() => {
  try {
    return String((jsonDeSalida(salidaSinIva) as { error?: { message?: string } }).error?.message ?? salidaSinIva)
  } catch {
    return salidaSinIva
  }
})()
const mSinIva = /PARIDAD<<([\s\S]*)>>PARIDAD/.exec(mensajeSinIva)
const difSinIva: string[] = []
let filasSinIva: [string, number, number, number, number, number][] = []
if (!mSinIva) {
  difSinIva.push(`  No se pudo leer el resultado: ${mensajeSinIva.slice(0, 300)}`)
} else {
  const crudoSinIva = mSinIva[1].includes('\\"') ? mSinIva[1].replace(/\\"/g, '"') : mSinIva[1]
  filasSinIva = JSON.parse(crudoSinIva)
  const nombrePorId = new Map(productos.map((p) => [p.id, p.nombre]))
  for (const [pid, costo, m1, m2, calc, venta] of filasSinIva) {
    const c = calcularPrecio({ costo: n(costo), margen1: n(m1), margen2: n(m2), iva: 0 })
    if (c.calculado !== nn(calc) || c.venta !== n(venta)) {
      difSinIva.push(`  ${nombrePorId.get(pid) ?? pid}: base calc=${calc} venta=${venta} · cliente calc=${c.calculado} venta=${c.venta}`)
    }
  }
}
console.log(`4. Sin IVA: ${filasSinIva.length} productos, ${difSinIva.length} diferencias (rollback, la base no cambió)`)
difSinIva.forEach((d) => console.log(d))

process.exit(difColumnas.length + difMasiva.length + difDescuento.length + difSinIva.length > 0 ? 1 : 0)
