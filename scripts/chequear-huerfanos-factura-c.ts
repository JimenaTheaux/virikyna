// Busca Factura C huérfanas: comprobantes que ARCA producción autorizó pero que no están en facturas_c
// (por ejemplo, la doble emisión de una misma venta desde dos pantallas). Solo lee: no emite ni escribe.
//
//   node scripts/chequear-huerfanos-factura-c.ts
//
// Se loguea con VIRIKYNA_ADMIN_EMAIL y VIRIKYNA_ADMIN_PASSWORD (cualquier usuario activo alcanza para
// ultimo_autorizado y consultar). URL y anon key salen de apps/virikyna-gestion/.env.local.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { createClient } from '@supabase/supabase-js'

// PV 0002 N° 1 es la prueba del 14/09, borrada de la base en la limpieza del 13/10 (docs/59).
const CONOCIDOS_FUERA_DE_LA_BASE: Record<number, string> = { 1: 'prueba del 14/09 (conocida)' }

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

async function arca(body: object) {
  const { data, error } = await supabase.functions.invoke('arca-emitir-factura', {
    body: { ...body, ambiente: 'produccion' },
  })
  const r = error ? await error.context?.json?.().catch(() => null) : data
  return r ?? { ok: false, error: error?.message }
}

const ultimo = await arca({ accion: 'ultimo_autorizado' })
if (!ultimo.ok) throw new Error(`ultimo_autorizado: ${ultimo.error}`)
const puntoVenta = Number(ultimo.puntoVenta)

const { data, error } = await supabase
  .from('facturas_c')
  .select('numero_factura, punto_venta, venta:ventas(numero)')
  .eq('ambiente', 'produccion')
if (error) throw new Error(`Lectura: ${error.message}`)
const filas = (data as unknown as { numero_factura: string; punto_venta: string }[]).filter(
  (f) => Number(f.punto_venta) === puntoVenta,
)
const enBase = new Set(filas.map((f) => Number(f.numero_factura)))
const maxBase = Math.max(0, ...enBase)

console.log(`ARCA producción PV ${puntoVenta}, Factura C — último autorizado: ${ultimo.ultimoNumero}`)
console.log(`Base (facturas_c producción, PV ${puntoVenta}): ${enBase.size} comprobantes, máximo ${maxBase}`)
if (enBase.size !== filas.length) console.log('⚠ Hay números repetidos en la base')
const fueraDeArca = [...enBase].filter((n) => n > ultimo.ultimoNumero)
if (fueraDeArca.length) console.log(`⚠ En la base pero por encima del último de ARCA: ${fueraDeArca.join(', ')}`)

const faltantes: number[] = []
for (let n = 1; n <= ultimo.ultimoNumero; n++) if (!enBase.has(n)) faltantes.push(n)
console.log(`\nAutorizados en ARCA que no están en la base: ${faltantes.length ? faltantes.join(', ') : 'ninguno'}\n`)

for (const n of faltantes) {
  const r = await arca({ accion: 'consultar', numero: n })
  if (!r.ok) {
    console.log(`N° ${n}: no se pudo consultar — ${r.error}`)
    continue
  }
  const c = r.resultado
  console.log(
    `N° ${n}: fecha ${c.CbteFch}  importe ${c.ImpTotal}  DocTipo ${c.DocTipo}  DocNro ${c.DocNro}  ` +
      `CAE ${c.CodAutorizacion}  resultado ${c.Resultado}  procesado ${c.FchProceso}` +
      (CONOCIDOS_FUERA_DE_LA_BASE[n] ? `  — ${CONOCIDOS_FUERA_DE_LA_BASE[n]}` : ''),
  )
}
