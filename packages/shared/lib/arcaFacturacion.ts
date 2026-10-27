// Emisión real de Factura C contra ARCA (WSFEv1), vía la Edge Function arca-emitir-factura
// (ver supabase/functions/arca-emitir-factura/index.ts). Reemplaza el mock de CAE que usaban
// Virikyna Local y Virikyna Gestión — la función solo consigue el CAE, este helper es el que
// además lo persiste con el RPC emitir_factura_c (docs/06_estructura_de_datos.md, docs/59).

import type { SupabaseClient } from '@supabase/supabase-js'
import { friendlyError } from './supabaseErrors'

export type AmbienteArca = 'homologacion' | 'produccion'

type RespuestaArca =
  | { ok: true; cae: string; caeFchVto: string; numeroFactura: string; puntoVenta: string; ambiente: AmbienteArca }
  | { ok: false; error: string }

async function llamarArcaEmitirFactura(
  supabase: SupabaseClient,
  ventaId: string,
  ambiente: AmbienteArca,
): Promise<RespuestaArca> {
  const { data, error } = await supabase.functions.invoke('arca-emitir-factura', {
    body: { accion: 'emitir', venta_id: ventaId, ambiente },
  })
  if (!error) return data as RespuestaArca

  // supabase-js solo expone un mensaje genérico en `error` ("Edge Function returned a
  // non-2xx status code") — el detalle real que manda la función viaja en error.context,
  // el Response crudo.
  if (error.context) {
    try {
      const body = await error.context.clone().json()
      if (body?.error) return { ok: false, error: body.error }
    } catch {
      // sigue abajo con el mensaje genérico si el body no era JSON
    }
  }
  return { ok: false, error: error.message ?? 'Error desconocido llamando a ARCA' }
}

export async function emitirFacturaCReal(
  supabase: SupabaseClient,
  venta: { id: string; numero: number },
  // Producción = comprobante fiscal real e irreversible (no hay Nota de Crédito). Homologación
  // solo para pruebas: hasta docs/59 este era el default y las Factura C del 19/10 al 26/10
  // salieron sin validez fiscal.
  ambiente: AmbienteArca = 'produccion',
): Promise<{ ok: boolean; mensaje: string }> {
  const resultado = await llamarArcaEmitirFactura(supabase, venta.id, ambiente)
  if (!resultado.ok) {
    return { ok: false, mensaje: `N° ${venta.numero}: ${resultado.error}` }
  }

  const { error: rpcError } = await supabase.rpc('emitir_factura_c', {
    p_venta_id: venta.id,
    p_cae: resultado.cae,
    p_numero_factura: resultado.numeroFactura,
    p_punto_venta: resultado.puntoVenta,
    // El que usó la función de verdad, no el pedido.
    p_ambiente: resultado.ambiente,
  })
  if (rpcError) {
    // Grave: ARCA ya emitió el CAE (comprobante fiscal real) pero no se pudo guardar acá.
    // No hay forma de "deshacerlo" del lado de ARCA — se muestra completo para no perderlo.
    return {
      ok: false,
      mensaje: `N° ${venta.numero}: ARCA emitió el CAE ${resultado.cae} (comprobante ${resultado.puntoVenta}-${resultado.numeroFactura}) pero no se pudo guardar (${friendlyError(rpcError)}). Anotalo a mano.`,
    }
  }

  return { ok: true, mensaje: `Factura C emitida para N° ${venta.numero} — CAE ${resultado.cae}.` }
}
