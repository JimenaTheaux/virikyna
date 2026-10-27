import { useEffect, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import { confirmacionFacturaC, type VentaAConfirmar } from '../../lib/confirmacionFacturaC'
import { ConfirmDialog } from './ConfirmDialog'

// Cliente embebido en los listados que pueden emitir Factura C: con cuit, para mostrar en la
// confirmación el documento que de verdad se informa a ARCA.
export const SELECT_CLIENTE_FACTURA = 'cliente:clientes(razon_social, nombre_fantasia, mail, celular, cuit)'

// El punto de venta vive en un secreto de arca-emitir-factura; la pantalla muestra el último que
// quedó registrado en producción. Si no hay ninguno (o falla la consulta), el renglón se omite.
async function ultimoPuntoVenta(supabase: SupabaseClient): Promise<string | null> {
  const { data } = await supabase
    .from('facturas_c')
    .select('punto_venta')
    .eq('ambiente', 'produccion')
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle()
  return (data?.punto_venta as string | null | undefined) ?? null
}

// Confirmación antes de emitir (Local, Gestión y Ventas del día): Factura C en producción es un
// comprobante fiscal irreversible. ConfirmDialog: foco en "Volver", Esc cancela. Se muestra recién
// cuando se sabe el punto de venta, para que el texto no cambie mientras se lee.
export function ConfirmarFacturaC({
  supabase,
  ventas,
  onCancel,
  onConfirm,
}: {
  supabase: SupabaseClient
  ventas: VentaAConfirmar[]
  onCancel: () => void
  onConfirm: () => void
}) {
  const [puntoVenta, setPuntoVenta] = useState<string | null | undefined>(undefined)

  useEffect(() => {
    let vigente = true
    ultimoPuntoVenta(supabase)
      .catch(() => null)
      .then((pv) => vigente && setPuntoVenta(pv))
    return () => {
      vigente = false
    }
  }, [supabase])

  if (puntoVenta === undefined) return null
  const { titulo, mensaje, confirmLabel } = confirmacionFacturaC(ventas, puntoVenta)
  return (
    <ConfirmDialog
      title={titulo}
      mensaje={mensaje}
      confirmLabel={confirmLabel}
      cancelLabel="Volver"
      onCancel={onCancel}
      onConfirm={onConfirm}
    />
  )
}
