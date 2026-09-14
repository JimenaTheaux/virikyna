// Edge Function: arca-emitir-factura
//
// Integración real (no mock) con ARCA (WSFEv1) para Factura C. Homologación por default
// siempre — producción es un opt-in explícito: el caller tiene que mandar
// `ambiente: "produccion"` a propósito en el body, si no está ese campo se usa
// homologación siempre, pase lo que pase. Así el uso normal del día a día (Facturación,
// Ventas del día) nunca puede terminar tocando ARCA real por accidente — hoy en día el
// frontend nunca manda ese campo, homologación es la única vía real conectada a las
// pantallas. Esta función solo habla con ARCA; no toca facturas_c ni el estado de la
// venta — eso lo hace el RPC `emitir_factura_c` (ver docs/06_estructura_de_datos.md), que
// asume que el CAE ya se consiguió antes de llamarlo.
//
// SDK elegido: @aledj02/afip.js, fork de @afipsdk/afip.js que acepta cert/key como texto
// (no como paths de archivo) y no cachea el TA (ticket de acceso de WSAA) en disco. Eso
// importa acá porque el runtime de Edge Functions no tiene filesystem persistente entre
// invocaciones. La versión actual de @afipsdk/afip.js en npm (1.x) ya NO habla directo
// con ARCA: proxea todo a través del servicio cloud de afipsdk.com (les mandarías el
// cert/key y dependerías de su cuenta) — no es lo que pide una integración real y directa.
//
// Bug conocido de @aledj02/afip.js@0.8.2: su clase ElectronicBilling nunca invoca
// Authorization.getTokenAuth() para conseguir el TA antes de armar un request — su propio
// getWSInitialRequest(operation, tokenAuth) recibe tokenAuth === undefined para cualquier
// operación que no sea FEDummy, y explota al desestructurarlo. Se parchea en crearAfip()
// de abajo (una sola vez por instancia), reusando el resto de su lógica de armado/parseo
// SOAP tal cual.
//
// El TA se persiste en la tabla arca_wsaa_tokens (ver migración), no en memoria ni en
// disco: WSAA rechaza ("ns1:coe.alreadyAuthenticated") pedir un TA nuevo mientras exista
// uno vigente para el mismo servicio+CUIT (dura ~12hs), y una Edge Function no garantiza
// memoria compartida entre invocaciones — sin esta caché, cada invocación fría intentaría
// loguearse de nuevo y chocaría con el TA de la invocación anterior.

import { createClient } from 'jsr:@supabase/supabase-js@2'
// @ts-types="npm:@aledj02/afip.js@0.8.2"
import Afip from 'npm:@aledj02/afip.js@0.8.2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

const ARCA_CUIT = Deno.env.get('ARCA_CUIT')!
const ARCA_PUNTO_VENTA = Deno.env.get('ARCA_PUNTO_VENTA')!
const ARCA_HOMO_CERT = Deno.env.get('ARCA_HOMO_CERT')!
const ARCA_HOMO_KEY = Deno.env.get('ARCA_HOMO_KEY')!
// Opcionales a propósito: solo hacen falta si alguien manda ambiente:"produccion". Si no
// están cargados y se intenta usar producción, tiene que fallar con un mensaje claro — no
// hay ningún reemplazo/fallback silencioso.
const ARCA_PROD_CERT = Deno.env.get('ARCA_PROD_CERT')
const ARCA_PROD_KEY = Deno.env.get('ARCA_PROD_KEY')
// Producción puede necesitar un número de punto de venta distinto al de homologación —
// en ARCA cada punto de venta está atado a UN sistema (Web Services vs. Factura en Línea,
// por ejemplo), así que el que ya se usa en homologación puede no estar habilitado para
// WSFEv1 en la cuenta real.
const ARCA_PROD_PUNTO_VENTA = Deno.env.get('ARCA_PROD_PUNTO_VENTA')

const WSAA_SERVICIO = 'wsfe'
// Dejamos de reusar el TA cacheado 5 minutos antes de que venza, no justo al límite.
const MARGEN_EXPIRACION_MS = 5 * 60 * 1000

const CBTE_TIPO_FACTURA_C = 11
// DocTipo 99 = Consumidor Final sin identificar, 80 = CUIT (ver FEParamGetTiposDoc)
const DOC_TIPO_CONSUMIDOR_FINAL = 99
const DOC_TIPO_CUIT = 80
// CondicionIVAReceptorId, obligatorio desde RG 5616 (ver FEParamGetCondicionIvaReceptor).
// Mapea 1 a 1 con clientes.condicion_iva (ver migración condicion_iva_cliente). Ventas sin
// cliente_id (consumidor final anónimo, sin cuenta corriente) van siempre como Consumidor Final.
const CONDICION_IVA_ARCA: Record<string, number> = {
  responsable_inscripto: 1,
  exento: 4,
  consumidor_final: 5,
  monotributista: 6,
  no_categorizado: 7,
}
const CONDICION_IVA_CONSUMIDOR_FINAL = CONDICION_IVA_ARCA.consumidor_final

// Presente en TODAS las acciones, pero opcional — ausente u "homologacion" = homologación
// (default seguro). Solo "produccion" activa el ambiente real, y requiere ARCA_PROD_CERT
// y ARCA_PROD_KEY cargados como secretos.
type Ambiente = 'homologacion' | 'produccion'

type Body =
  | { accion: 'dummy'; ambiente?: Ambiente }
  | { accion: 'ultimo_autorizado'; ambiente?: Ambiente }
  | { accion: 'emitir'; venta_id: string; ambiente?: Ambiente }
  | { accion: 'consultar'; numero: number; ambiente?: Ambiente }

// Sin esto, el navegador/webview bloquea el preflight OPTIONS antes de que el POST
// llegue a esta función — supabase-js lo reporta como "Failed to send a request to
// the Edge Function" (no como un error HTTP), que es justo lo que pasaba sin este header.
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
  })
}

function mensajeError(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}

function obtenerPuntoVenta(ambiente: Ambiente): string {
  if (ambiente === 'produccion') {
    if (!ARCA_PROD_PUNTO_VENTA) {
      throw new Error('Ambiente de producción pedido pero ARCA_PROD_PUNTO_VENTA no está cargado como secreto.')
    }
    return ARCA_PROD_PUNTO_VENTA
  }
  return ARCA_PUNTO_VENTA
}

// service_role: única forma de leer/escribir arca_wsaa_tokens (RLS la bloquea para
// anon/authenticated). Se inyecta sola en el runtime de Edge Functions, no hace falta
// configurarla a mano (mismo comentario que en admin-usuarios/index.ts).
const serviceClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY)

async function obtenerTokenAuth(
  // deno-lint-ignore no-explicit-any
  afip: any,
  ambiente: Ambiente,
): Promise<{ token: string; sign: string }> {
  const { data: cacheado } = await serviceClient
    .from('arca_wsaa_tokens')
    .select('token, sign, expiration_time')
    .eq('servicio', WSAA_SERVICIO)
    .eq('cuit', ARCA_CUIT)
    .eq('ambiente', ambiente)
    .maybeSingle()

  if (cacheado && new Date(cacheado.expiration_time).getTime() - MARGEN_EXPIRACION_MS > Date.now()) {
    return { token: cacheado.token, sign: cacheado.sign }
  }

  const raw = await afip.Authorization.getTokenAuth(WSAA_SERVICIO)
  const parsed = JSON.parse(raw)
  const { token, sign } = parsed.credentials
  // @aledj02/afip.js usa `attrkey: 'header'` en su parser xml2js (para atributos XML), que
  // choca de nombre con el elemento <header> real de la respuesta de WSAA — según cómo
  // resuelva xml2js ese choque, parsed.header.expirationtime puede no venir. WSAA emite TAs
  // válidos por 12hs siempre, así que si el parseo falla usamos ese valor conservador en vez
  // de fallar el guardado (expiration_time es NOT NULL).
  const expirationParseada = parsed.header?.expirationtime
  const expirationTime =
    expirationParseada && !isNaN(new Date(expirationParseada).getTime())
      ? expirationParseada
      : new Date(Date.now() + 12 * 60 * 60 * 1000).toISOString()

  const { error: upsertError } = await serviceClient.from('arca_wsaa_tokens').upsert(
    {
      servicio: WSAA_SERVICIO,
      cuit: ARCA_CUIT,
      ambiente,
      token,
      sign,
      expiration_time: expirationTime,
      updated_at: new Date().toISOString(),
    },
    { onConflict: 'servicio,cuit,ambiente' },
  )
  // Si falla el guardado igual devolvemos el token recién conseguido — pero significa que
  // la próxima invocación va a chocar con "alreadyAuthenticated".
  if (upsertError) console.error('No se pudo cachear el TA de WSAA:', upsertError.message)

  return { token, sign }
}

// deno-lint-ignore no-explicit-any
function crearAfip(ambiente: Ambiente): any {
  const produccion = ambiente === 'produccion'

  if (produccion && (!ARCA_PROD_CERT || !ARCA_PROD_KEY)) {
    throw new Error(
      'Ambiente de producción pedido pero ARCA_PROD_CERT / ARCA_PROD_KEY no están cargados como secretos.',
    )
  }

  const afip = new Afip({
    CUIT: ARCA_CUIT,
    production: produccion,
    cert: produccion ? ARCA_PROD_CERT : ARCA_HOMO_CERT,
    key: produccion ? ARCA_PROD_KEY : ARCA_HOMO_KEY,
  })

  // Parche del bug de wiring descripto en el comentario de cabecera.
  let tokenAuthCache: { token: string; sign: string } | null = null
  const original = afip.ElectronicBilling.getWSInitialRequest.bind(afip.ElectronicBilling)
  afip.ElectronicBilling.getWSInitialRequest = async (operation: string) => {
    if (operation === 'FEDummy') return {}
    if (!tokenAuthCache) {
      tokenAuthCache = await obtenerTokenAuth(afip, ambiente)
    }
    return original(operation, tokenAuthCache)
  }

  return afip
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders })
  }

  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return jsonResponse({ error: 'Falta autenticación' }, 401)

  // Cliente "como el usuario que llama" — mismo patrón que admin-usuarios: valida quién
  // es antes de gastar un número de comprobante o tocar ARCA.
  const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  })
  const {
    data: { user },
  } = await callerClient.auth.getUser()
  if (!user) return jsonResponse({ error: 'Sesión inválida' }, 401)

  const { data: perfil, error: perfilError } = await callerClient
    .from('perfiles')
    .select('activo, rol')
    .eq('id', user.id)
    .single()
  if (perfilError || !perfil || !perfil.activo) {
    return jsonResponse({ error: 'Usuario no autorizado' }, 403)
  }

  let body: Body
  try {
    body = await req.json()
  } catch {
    return jsonResponse({ error: 'Body inválido' }, 400)
  }

  const ambiente: Ambiente = body.ambiente === 'produccion' ? 'produccion' : 'homologacion'

  // Producción, además de activo, requiere admin — un cajero nunca debería poder
  // gatillar un comprobante fiscal real.
  if (ambiente === 'produccion' && perfil.rol !== 'admin') {
    return jsonResponse({ error: 'Solo un administrador puede usar el ambiente de producción' }, 403)
  }

  // deno-lint-ignore no-explicit-any
  let afip: any
  let puntoVenta: string
  try {
    afip = crearAfip(ambiente)
    puntoVenta = obtenerPuntoVenta(ambiente)
  } catch (err) {
    return jsonResponse({ ok: false, error: mensajeError(err) }, 400)
  }

  if (body.accion === 'dummy') {
    try {
      const resultado = await afip.ElectronicBilling.getServerStatus()
      return jsonResponse({ ok: true, resultado })
    } catch (err) {
      return jsonResponse({ ok: false, error: mensajeError(err) }, 502)
    }
  }

  if (body.accion === 'ultimo_autorizado') {
    try {
      const ultimoNumero = await afip.ElectronicBilling.getLastVoucher(Number(puntoVenta), CBTE_TIPO_FACTURA_C)
      return jsonResponse({ ok: true, ultimoNumero, ambiente, puntoVenta })
    } catch (err) {
      return jsonResponse({ ok: false, error: mensajeError(err) }, 502)
    }
  }

  // Verificación independiente: le pregunta a ARCA por lo que tiene guardado para ese
  // comprobante (FECompConsultar), en vez de confiar en lo que devolvió FECAESolicitar en
  // su momento. En homologación no hay portal web para chequear esto a ojo — esta es la
  // única forma real de corroborarlo.
  if (body.accion === 'consultar') {
    if (!body.numero) return jsonResponse({ error: 'numero es obligatorio' }, 400)
    try {
      const resultado = await afip.ElectronicBilling.getVoucherInfo(
        body.numero,
        Number(puntoVenta),
        CBTE_TIPO_FACTURA_C,
      )
      if (!resultado) return jsonResponse({ ok: false, error: 'ARCA no tiene registrado ese comprobante' }, 404)
      return jsonResponse({ ok: true, resultado, ambiente })
    } catch (err) {
      return jsonResponse({ ok: false, error: mensajeError(err) }, 502)
    }
  }

  if (body.accion === 'emitir') {
    if (!body.venta_id) return jsonResponse({ error: 'venta_id es obligatorio' }, 400)

    const { data: venta, error: ventaError } = await callerClient
      .from('ventas')
      .select('id, total, estado, cliente:clientes(cuit, condicion_iva), factura_c:facturas_c(id)')
      .eq('id', body.venta_id)
      .single()
    if (ventaError || !venta) return jsonResponse({ error: 'Venta no encontrada' }, 404)
    if (venta.factura_c) return jsonResponse({ error: 'Esta venta ya tiene una Factura C emitida' }, 400)

    try {
      const ultimoNumero = await afip.ElectronicBilling.getLastVoucher(Number(puntoVenta), CBTE_TIPO_FACTURA_C)
      const proximoNumero = ultimoNumero + 1

      const hoy = new Date()
      const fechaArca = Number(
        `${hoy.getFullYear()}${String(hoy.getMonth() + 1).padStart(2, '0')}${String(hoy.getDate()).padStart(2, '0')}`,
      )

      const cuitCliente = venta.cliente?.cuit?.replace(/\D/g, '') ?? ''
      const tieneCuit = cuitCliente.length === 11
      const condicionIvaReceptor =
        CONDICION_IVA_ARCA[venta.cliente?.condicion_iva ?? 'consumidor_final'] ?? CONDICION_IVA_CONSUMIDOR_FINAL

      // Factura C: monotributo, no discrimina IVA — ImpNeto = ImpTotal, ImpIVA = 0.
      const data = {
        CantReg: 1,
        PtoVta: Number(puntoVenta),
        CbteTipo: CBTE_TIPO_FACTURA_C,
        Concepto: 1, // Productos
        DocTipo: tieneCuit ? DOC_TIPO_CUIT : DOC_TIPO_CONSUMIDOR_FINAL,
        DocNro: tieneCuit ? Number(cuitCliente) : 0,
        CbteDesde: proximoNumero,
        CbteHasta: proximoNumero,
        CbteFch: fechaArca,
        ImpTotal: venta.total,
        ImpTotConc: 0,
        ImpNeto: venta.total,
        ImpOpEx: 0,
        ImpIVA: 0,
        ImpTrib: 0,
        MonId: 'PES',
        MonCotiz: 1,
        CondicionIVAReceptorId: condicionIvaReceptor,
      }

      const resultadoCrudo = await afip.ElectronicBilling.createVoucher(data, true)
      const detalle = Array.isArray(resultadoCrudo.FeDetResp.FECAEDetResponse)
        ? resultadoCrudo.FeDetResp.FECAEDetResponse[0]
        : resultadoCrudo.FeDetResp.FECAEDetResponse

      return jsonResponse({
        ok: true,
        cae: detalle.CAE,
        caeFchVto: detalle.CAEFchVto,
        numeroFactura: String(proximoNumero).padStart(8, '0'),
        puntoVenta: puntoVenta.padStart(4, '0'),
        ambiente,
        resultadoCrudo,
      })
    } catch (err) {
      return jsonResponse({ ok: false, error: mensajeError(err) }, 502)
    }
  }

  return jsonResponse({ error: 'Acción no reconocida' }, 400)
})
