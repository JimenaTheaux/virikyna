// Re-emisión en ARCA producción de las Factura C que quedaron en homologación (docs/59).
//
//   node scripts/reemitir-facturas-c.ts                       → solo muestra el plan, no emite
//   node scripts/reemitir-facturas-c.ts --emitir --limite 1   → emite la primera (prueba piloto)
//   node scripts/reemitir-facturas-c.ts --emitir              → emite todas las pendientes
//
// Requiere docs/59 aplicada y la Edge Function arca-emitir-factura desplegada con la acción
// `reemitir`. Se loguea como un admin: VIRIKYNA_ADMIN_EMAIL y VIRIKYNA_ADMIN_PASSWORD en el entorno.
// URL y anon key salen de apps/virikyna-gestion/.env.local.
//
// Fecha del comprobante: la de emisión original (hora argentina), salvo que tenga más de 5 días —
// ARCA no acepta más atrás para productos — en cuyo caso va la más vieja permitida. Se emiten en
// orden de fecha, porque ARCA rechaza una fecha anterior al último comprobante del punto de venta.
//
// Cada comprobante es fiscal, real e irreversible. El script frena en el primer error, y anota
// cada CAE en ~/Backups/virikyna/ ANTES de guardarlo en la base, para no perderlo si el guardado falla.
import { readFileSync, appendFileSync, mkdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { createClient } from '@supabase/supabase-js'

const DIAS_ATRAS_MAXIMO = 5

const args = process.argv.slice(2)
const emitir = args.includes('--emitir')
const limiteIdx = args.indexOf('--limite')
const limite = limiteIdx >= 0 ? Number(args[limiteIdx + 1]) : Infinity
if (!(limite > 0)) throw new Error('--limite tiene que ser un número mayor a 0')

function fechaArgentina(fecha = new Date()): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Argentina/Buenos_Aires' }).format(fecha)
}

const env = Object.fromEntries(
  readFileSync(join(import.meta.dirname, '..', 'apps', 'virikyna-gestion', '.env.local'), 'utf8')
    .split(/\r?\n/)
    .filter((l) => l.includes('='))
    .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
)
const email = process.env.VIRIKYNA_ADMIN_EMAIL
const password = process.env.VIRIKYNA_ADMIN_PASSWORD
if (!email || !password) throw new Error('Faltan VIRIKYNA_ADMIN_EMAIL / VIRIKYNA_ADMIN_PASSWORD')

const supabase = createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_ANON_KEY, {
  auth: { persistSession: false },
})
const { error: loginError } = await supabase.auth.signInWithPassword({ email, password })
if (loginError) throw new Error(`Login: ${loginError.message}`)

type Fila = {
  venta_id: string
  cae: string
  punto_venta: string
  numero_factura: string
  fecha_emision: string
  venta: { numero: number; total: number; cliente: { razon_social: string | null; cuit: string | null } | null }
}

const { data, error } = await supabase
  .from('facturas_c')
  .select('venta_id, cae, punto_venta, numero_factura, fecha_emision, venta:ventas(numero, total, cliente:clientes(razon_social, cuit))')
  .eq('ambiente', 'homologacion')
  .order('fecha_emision')
if (error) throw new Error(`Lectura: ${error.message}`)
const filas = data as unknown as Fila[]

const hoy = fechaArgentina()
const minima = fechaArgentina(new Date(Date.now() - DIAS_ATRAS_MAXIMO * 24 * 60 * 60 * 1000))
const plan = filas.map((f) => {
  const original = fechaArgentina(new Date(f.fecha_emision))
  return { ...f, original, fecha: original < minima ? minima : original }
})

console.log(`Hoy ${hoy} — ARCA acepta fechas desde ${minima}. Pendientes de re-emitir: ${plan.length}\n`)
console.log('venta  total         cliente                    homologación          fecha original → fecha nueva')
for (const p of plan) {
  const cliente = p.venta.cliente?.cuit ? `${p.venta.cliente.razon_social ?? ''} (${p.venta.cliente.cuit})` : 'Consumidor final'
  console.log(
    `${String(p.venta.numero).padStart(5)}  ${('$ ' + p.venta.total).padEnd(12)}  ${cliente.slice(0, 25).padEnd(25)}  ` +
      `${p.punto_venta}-${p.numero_factura}  ${p.original}${p.fecha !== p.original ? ` → ${p.fecha}  (cambia)` : ''}`,
  )
}
const cambian = plan.filter((p) => p.fecha !== p.original).length
console.log(`\n${cambian} de ${plan.length} salen con una fecha distinta a la original.`)

if (!emitir) {
  console.log('\nModo vista previa: no se emitió nada. Agregar --emitir para emitir.')
  process.exit(0)
}

const dirLog = join(homedir(), 'Backups', 'virikyna')
mkdirSync(dirLog, { recursive: true })
const archivoLog = join(dirLog, `reemision-facturas-c-${hoy}.jsonl`)
const log = (registro: object) => appendFileSync(archivoLog, JSON.stringify({ en: new Date().toISOString(), ...registro }) + '\n')
console.log(`\nEmitiendo en PRODUCCIÓN. Registro: ${archivoLog}\n`)

let emitidas = 0
for (const p of plan.slice(0, limite)) {
  const { data: resp, error: fnError } = await supabase.functions.invoke('arca-emitir-factura', {
    body: { accion: 'reemitir', venta_id: p.venta_id, fecha: p.fecha, ambiente: 'produccion' },
  })
  let r = resp
  if (fnError) {
    r = await fnError.context?.json?.().catch(() => null)
  }
  if (!r?.ok) {
    log({ venta: p.venta.numero, error: r?.error ?? fnError?.message })
    console.error(`✗ Venta N° ${p.venta.numero}: ARCA no emitió — ${r?.error ?? fnError?.message}. Frenado.`)
    process.exit(1)
  }
  if (r.ambiente !== 'produccion') {
    log({ venta: p.venta.numero, error: 'la función no usó producción', r })
    console.error(`✗ Venta N° ${p.venta.numero}: la función respondió ambiente ${r.ambiente}. Frenado.`)
    process.exit(1)
  }
  log({ venta: p.venta.numero, venta_id: p.venta_id, cae_homologacion: p.cae, cae: r.cae, cae_vto: r.caeFchVto,
        punto_venta: r.puntoVenta, numero: r.numeroFactura, fecha: r.fecha, guardado: false })

  const { error: rpcError } = await supabase.rpc('reemitir_factura_c_produccion', {
    p_venta_id: p.venta_id,
    p_cae: r.cae,
    p_numero_factura: r.numeroFactura,
    p_punto_venta: r.puntoVenta,
  })
  if (rpcError) {
    log({ venta: p.venta.numero, cae: r.cae, error_guardado: rpcError.message })
    console.error(
      `✗ Venta N° ${p.venta.numero}: ARCA EMITIÓ ${r.puntoVenta}-${r.numeroFactura} CAE ${r.cae} pero no se guardó ` +
        `(${rpcError.message}). Está en ${archivoLog}. Frenado.`,
    )
    process.exit(1)
  }
  log({ venta: p.venta.numero, cae: r.cae, guardado: true })
  emitidas++
  console.log(`✓ Venta N° ${p.venta.numero}: ${r.puntoVenta}-${r.numeroFactura} del ${r.fecha}, CAE ${r.cae}`)
}
console.log(`\nListo: ${emitidas} re-emitidas, ${plan.length - emitidas} pendientes.`)
