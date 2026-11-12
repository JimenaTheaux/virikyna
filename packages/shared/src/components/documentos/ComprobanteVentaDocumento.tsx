// Detalle de venta (Comprobante X / Factura C) como documento de la bandeja (docs/73) — Facturación
// y Ventas del día, en Local y Gestión. Al restaurarlo se vuelve a leer la venta (puede haberse
// facturado mientras estaba minimizado); lo tipeado en Mail / WhatsApp queda como estaba.

import { useState, type ComponentType } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import {
  armarDatosComprobanteVenta,
  cargarComprobanteVenta,
  type DatosComprobante,
  type VentaConComprobante,
} from '../../../lib/comprobante'
import type { ComprobanteModalProps } from '../ComprobanteModal'
import { useAlRestaurar } from './contexto'
import type { BandejaApi } from './DocumentosAbiertos'

type Props = {
  supabase: SupabaseClient
  ventaId: string
  etiqueta: string
  datosIniciales: DatosComprobante
  ComprobanteModal: ComponentType<ComprobanteModalProps>
  conNota?: boolean
  onClose: () => void
}

function ComprobanteVentaDocumento({ supabase, ventaId, etiqueta, datosIniciales, ComprobanteModal, conNota, onClose }: Props) {
  const [datos, setDatos] = useState(datosIniciales)
  useAlRestaurar(() => {
    // Mismo armado que el historial del producto (docs/70), con la nota solo si se mostraba.
    cargarComprobanteVenta(supabase, ventaId)
      .then((nuevos) => setDatos(conNota ? nuevos : { ...nuevos, nota: undefined }))
      .catch(() => {
        // Sin red: queda lo que se estaba viendo.
      })
  })
  return <ComprobanteModal datos={datos} onClose={onClose} minimizable etiquetaBandeja={etiqueta} />
}

// Abre (o trae al frente) el detalle de una venta. Una venta = un documento: abrirla otra vez desde
// otra pestaña de Facturación no la duplica.
export async function abrirComprobanteVenta(
  bandeja: BandejaApi,
  {
    supabase,
    venta,
    ComprobanteModal,
    conNota = true,
  }: { supabase: SupabaseClient; venta: VentaConComprobante; ComprobanteModal: ComponentType<ComprobanteModalProps>; conNota?: boolean },
) {
  const clave = `venta:${venta.id}`
  if (bandeja.documentos.some((d) => d.clave === clave)) {
    bandeja.restaurar(clave)
    return true
  }
  const datos = await armarDatosComprobanteVenta(supabase, venta, { conNota })
  const etiqueta = `Venta #${venta.numero}`
  return bandeja.abrir({
    clave,
    tipo: 'detalle_venta',
    etiqueta,
    render: ({ cerrar }) => (
      <ComprobanteVentaDocumento
        supabase={supabase}
        ventaId={venta.id}
        etiqueta={etiqueta}
        datosIniciales={datos}
        ComprobanteModal={ComprobanteModal}
        conNota={conNota}
        onClose={cerrar}
      />
    ),
  })
}
