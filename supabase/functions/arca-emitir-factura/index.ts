// Edge Function: arca-emitir-factura
//
// Integración real (no mock) con ARCA (WSFEv1) para Factura C. Si el body no trae
// `ambiente: "produccion"` se usa homologación (para pruebas: dummy, consultas). Los botones de
// emitir (arcaFacturacion.ts) mandan siempre "produccion" desde docs/59 — hasta entonces no lo
// mandaban y las 43 Factura C del 19/10 al 26/10 salieron en homologación, sin validez fiscal.
// `emitir` reserva la venta antes de hablar con ARCA y guarda el CAE apenas lo consigue (docs/66):
// antes, dos pantallas emitiendo la misma venta conseguían dos CAE reales, y si la app se cerraba
// entre la respuesta de ARCA y el guardado el comprobante quedaba huérfano. `reemitir` sigue
// devolviendo el CAE para que lo guarde quien llama (reemitir_factura_c_produccion, docs/59).
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

// Presente en TODAS las acciones, pero opcional — ausente u "homologacion" = homologación.
// Solo "produccion" activa el ambiente real, y requiere ARCA_PROD_CERT y ARCA_PROD_KEY
// cargados como secretos.
type Ambiente = 'homologacion' | 'produccion'

type Body =
  | { accion: 'dummy'; ambiente?: Ambiente }
  | { accion: 'ultimo_autorizado'; ambiente?: Ambiente }
  | { accion: 'emitir'; venta_id: string; ambiente?: Ambiente }
  // Re-emite en producción una venta cuya Factura C quedó en homologación (docs/59), con la
  // fecha de comprobante indicada (YYYY-MM-DD). Solo admin, solo producción.
  | { accion: 'reemitir'; venta_id: string; fecha: string; ambiente?: Ambiente }
  | { accion: 'consultar'; numero: number; ambiente?: Ambiente }

// ARCA acepta, para Concepto 1 (productos), una fecha de comprobante de hasta 5 días antes de
// la emisión. Se valida acá para dar un mensaje claro antes de pedir número.
const DIAS_ATRAS_MAXIMO = 5

// Con la venta reservada (docs/66), la función no puede tardar más que el vencimiento de la reserva
// (5 minutos, en reservar_emision_factura_c): si no, otra pantalla la toma mientras esta sigue viva.
// Si llegar a pedir el CAE tardó más de esto, no se pide; y el pedido mismo tiene su propio límite.
const LIMITE_ANTES_DE_PEDIR_CAE_MS = 60 * 1000
const LIMITE_PEDIDO_CAE_MS = 60 * 1000

const MENSAJE_REVISAR = 'Posible factura ya emitida en ARCA para esta venta. Revisar con admin.'

// Errores después de los cuales la reserva NO se libera: o no se sabe si ARCA emitió, o la venta
// quedó para revisar. La reserva vence sola y el próximo intento compara contra ARCA.
class SinLiberar extends Error {}
class EmisionIncierta extends SinLiberar {}
class ParaRevisar extends SinLiberar {
  constructor() {
    super(MENSAJE_REVISAR)
  }
}

type Reserva =
  | { resultado: 'reservada'; token: string; pendiente_ultimo_arca?: number | null; pendiente_ambiente?: Ambiente | null }
  | { resultado: 'en_curso' | 'revisar' | 'ya_facturada' | 'no_encontrada' }

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

// El runtime de Edge Functions corre en UTC: con getDate() a secas, una factura emitida
// después de las 21hs de Argentina salía con la fecha del día siguiente.
function fechaArgentina(fecha = new Date()): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Argentina/Buenos_Aires' }).format(fecha)
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

type VentaAFacturar = {
  total: number
  cliente: { cuit: string | null; condicion_iva: string | null } | null
}

// Pide el próximo número y el CAE a ARCA. `fecha` es la fecha del comprobante (YYYY-MM-DD).
// `antesDePedirCae` corre con el último número autorizado, justo antes de pedir el CAE: si tira,
// no se pide. Un error de ARCA con código ("(10016) …", lo arma el SDK desde la respuesta) o un
// Resultado distinto de "A" es un rechazo: no se emitió nada. Cualquier otro error al pedir el CAE
// (red, timeout) es EmisionIncierta: ARCA pudo haberlo emitido igual.
async function emitirComprobante(
  // deno-lint-ignore no-explicit-any
  afip: any,
  puntoVenta: string,
  venta: VentaAFacturar,
  fecha: string,
  ambiente: Ambiente,
  antesDePedirCae?: (ultimoNumero: number) => Promise<void>,
) {
  const ultimoNumero = await afip.ElectronicBilling.getLastVoucher(Number(puntoVenta), CBTE_TIPO_FACTURA_C)
  if (antesDePedirCae) await antesDePedirCae(ultimoNumero)
  const proximoNumero = ultimoNumero + 1

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
    CbteFch: Number(fecha.replaceAll('-', '')),
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

  let timer: number | undefined
  // deno-lint-ignore no-explicit-any
  let resultadoCrudo: any
  try {
    resultadoCrudo = await Promise.race([
      afip.ElectronicBilling.createVoucher(data, true),
      new Promise((_, reject) => {
        timer = setTimeout(
          () => reject(new EmisionIncierta(`ARCA no respondió en ${LIMITE_PEDIDO_CAE_MS / 1000} segundos`)),
          LIMITE_PEDIDO_CAE_MS,
        )
      }),
    ])
  } catch (err) {
    if (err instanceof SinLiberar || /^\(\d+\) /.test(mensajeError(err))) throw err
    throw new EmisionIncierta(mensajeError(err))
  } finally {
    clearTimeout(timer)
  }
  const detalle = Array.isArray(resultadoCrudo.FeDetResp.FECAEDetResponse)
    ? resultadoCrudo.FeDetResp.FECAEDetResponse[0]
    : resultadoCrudo.FeDetResp.FECAEDetResponse

  // El SDK ya tira error si ARCA rechaza con observaciones; esto cubre cualquier otra
  // respuesta sin aprobación o sin CAE, para que nunca se guarde un comprobante vacío.
  if (detalle?.Resultado !== 'A' || !/^\d{14}$/.test(String(detalle?.CAE ?? ''))) {
    const mensaje = `ARCA no aprobó el comprobante (Resultado: ${detalle?.Resultado ?? '—'}, CAE: ${detalle?.CAE ?? '—'})`
    // Aprobado pero sin un CAE válido: no se sabe qué quedó en ARCA.
    throw detalle?.Resultado === 'A' ? new EmisionIncierta(mensaje) : new Error(mensaje)
  }

  return {
    ok: true,
    cae: String(detalle.CAE),
    caeFchVto: detalle.CAEFchVto,
    numeroFactura: String(proximoNumero).padStart(8, '0'),
    puntoVenta: puntoVenta.padStart(4, '0'),
    fecha,
    ambiente,
    resultadoCrudo,
  }
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

  // Producción la usa cualquier usuario activo: los cajeros emiten las Factura C del día a día.
  // Solo la re-emisión (corrección de comprobantes viejos) queda para admin.
  if (body.accion === 'reemitir' && (ambiente !== 'produccion' || perfil.rol !== 'admin')) {
    return jsonResponse({ error: 'La re-emisión es solo en producción y solo para un administrador' }, 403)
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

    // Reserva (docs/66): una sola pantalla por venta habla con ARCA. Las RPC van con el usuario que
    // llama, así auditoría y "Revisar emisión" muestran quién fue.
    const { data: reserva, error: reservaError } = await callerClient.rpc('reservar_emision_factura_c', {
      p_venta_id: venta.id,
    })
    if (reservaError) return jsonResponse({ ok: false, error: `No se pudo reservar la venta: ${reservaError.message}` }, 500)
    const r = reserva as Reserva
    if (r.resultado === 'en_curso') return jsonResponse({ ok: false, error: 'Ya se está emitiendo desde otra pantalla.' }, 409)
    if (r.resultado === 'revisar') return jsonResponse({ ok: false, error: MENSAJE_REVISAR }, 409)
    if (r.resultado === 'ya_facturada') return jsonResponse({ error: 'Esta venta ya tiene una Factura C emitida' }, 400)
    if (r.resultado !== 'reservada') return jsonResponse({ error: 'Venta no encontrada' }, 404)

    const token = r.token
    const reservadaEn = Date.now()
    const marcarRevisar = async (ultimoActual: number) => {
      const { data: marcada, error } = await callerClient.rpc('marcar_revisar_emision_factura_c', {
        p_venta_id: venta.id,
        p_token: token,
        p_ultimo_actual: ultimoActual,
      })
      if (error || !marcada) console.error(`No se pudo marcar para revisar la venta ${venta.id}:`, error?.message)
    }

    try {
      const resultado = await emitirComprobante(afip, puntoVenta, venta, fechaArgentina(), ambiente, async (ultimo) => {
        // Se tomó una reserva vencida cuyo intento llegó a pedir el CAE en producción: si ARCA tiene
        // otro último número, ese intento pudo haber emitido. Uno de homologación no tiene validez
        // fiscal, no hay nada que cuidar.
        if (r.pendiente_ultimo_arca != null && r.pendiente_ambiente === 'produccion') {
          const actual =
            ambiente === 'produccion'
              ? ultimo
              : await crearAfip('produccion').ElectronicBilling.getLastVoucher(
                  Number(obtenerPuntoVenta('produccion')),
                  CBTE_TIPO_FACTURA_C,
                )
          if (actual !== r.pendiente_ultimo_arca) {
            await marcarRevisar(actual)
            throw new ParaRevisar()
          }
        }
        if (Date.now() - reservadaEn > LIMITE_ANTES_DE_PEDIR_CAE_MS) {
          throw new Error('ARCA tardó demasiado en responder y no se pidió el CAE. Probá de nuevo.')
        }
        const { data: registrado, error } = await callerClient.rpc('registrar_ultimo_arca_emision_factura_c', {
          p_venta_id: venta.id,
          p_token: token,
          p_ambiente: ambiente,
          p_ultimo: ultimo,
        })
        if (error || !registrado) {
          throw new Error(`No se pudo registrar la reserva de la venta: ${error?.message ?? 'la tomó otra pantalla'}`)
        }
      })

      // Se guarda acá y no en el cliente: si la app se cierra ahora, el CAE no se pierde.
      const { error: guardarError } = await callerClient.rpc('emitir_factura_c', {
        p_venta_id: venta.id,
        p_cae: resultado.cae,
        p_numero_factura: resultado.numeroFactura,
        p_punto_venta: resultado.puntoVenta,
        p_ambiente: resultado.ambiente,
      })
      if (guardarError) {
        console.error(
          `CAE emitido sin guardar — venta ${venta.id}, ${resultado.puntoVenta}-${resultado.numeroFactura}, CAE ${resultado.cae}:`,
          guardarError.message,
        )
        // Queda bloqueada: no se vuelve a emitir hasta que un admin la revise.
        await marcarRevisar(Number(resultado.numeroFactura))
        return jsonResponse(
          {
            ok: false,
            error: `ARCA emitió el CAE ${resultado.cae} (comprobante ${resultado.puntoVenta}-${resultado.numeroFactura}) pero no se pudo guardar (${guardarError.message}). Anotalo a mano.`,
          },
          502,
        )
      }
      return jsonResponse({ ...resultado, guardada: true })
    } catch (err) {
      if (err instanceof ParaRevisar) return jsonResponse({ ok: false, error: err.message }, 409)
      if (err instanceof EmisionIncierta) {
        return jsonResponse(
          {
            ok: false,
            error: `No se sabe si ARCA emitió la factura (${err.message}). No la vuelvas a emitir ahora: en 5 minutos el sistema lo controla solo.`,
          },
          502,
        )
      }
      if (!(err instanceof SinLiberar)) {
        const { error } = await callerClient.rpc('liberar_emision_factura_c', { p_venta_id: venta.id, p_token: token })
        if (error) console.error(`No se pudo liberar la reserva de la venta ${venta.id}:`, error.message)
      }
      return jsonResponse({ ok: false, error: mensajeError(err) }, 502)
    }
  }

  if (body.accion === 'reemitir') {
    if (!body.venta_id) return jsonResponse({ error: 'venta_id es obligatorio' }, 400)
    const hoy = fechaArgentina()
    const minima = fechaArgentina(new Date(Date.now() - DIAS_ATRAS_MAXIMO * 24 * 60 * 60 * 1000))
    if (!/^\d{4}-\d{2}-\d{2}$/.test(body.fecha ?? '') || body.fecha > hoy || body.fecha < minima) {
      return jsonResponse({ error: `fecha tiene que estar entre ${minima} y ${hoy}` }, 400)
    }

    const { data: venta, error: ventaError } = await callerClient
      .from('ventas')
      .select('id, total, cliente:clientes(cuit, condicion_iva), factura_c:facturas_c(id, ambiente)')
      .eq('id', body.venta_id)
      .single()
    if (ventaError || !venta) return jsonResponse({ error: 'Venta no encontrada' }, 404)
    if (!venta.factura_c) return jsonResponse({ error: 'Esta venta no tiene Factura C para re-emitir' }, 400)
    if (venta.factura_c.ambiente !== 'homologacion') {
      return jsonResponse({ error: 'Esta Factura C ya es de producción, no se re-emite' }, 400)
    }

    try {
      return jsonResponse(await emitirComprobante(afip, puntoVenta, venta, body.fecha, ambiente))
    } catch (err) {
      return jsonResponse({ ok: false, error: mensajeError(err) }, 502)
    }
  }

  return jsonResponse({ error: 'Acción no reconocida' }, 400)
})
