import { useMemo, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { OrigenEgreso } from '../../types/database'
import { useComprobantesProveedor, useProveedor } from '../../lib/facturasCompra'
import { usePagosACuenta } from '../../lib/pagosACuenta'
import { esNotaCredito } from '../../lib/repartoPagoProveedor'
import { formatCurrency } from '../../lib/format'
import { friendlyError } from '../../lib/supabaseErrors'
import { Modal } from './Modal'
import { PagarProveedorModal } from './PagarProveedorModal'
import { AplicarACuentaModal } from './AplicarACuentaModal'
import { datosSaldoInicial } from './SaldoInicialCuenta'

type Props = {
  supabase: SupabaseClient
  proveedorId: string
  facturaIds: string[]
  notaCreditoIds: string[]
  origen: OrigenEgreso
  permitirAplicarACuenta: boolean
  onCerrar: () => void // sale de la bandeja
  onTerminado: (aviso: string) => void // pago registrado o pagos a cuenta aplicados
}

// Pago a proveedor como documento de la bandeja (docs/73): se minimiza para ir a otra pantalla (ej.
// revisar una factura) y vuelve tal cual. Vive en AppShell, fuera de la cuenta corriente que lo
// abrió (puede desmontarse): por eso trae sus propios datos. Son las mismas queries de la cuenta
// corriente (caché compartida): si algo cambia mientras está minimizado, la vista previa se
// actualiza sola; el RPC vuelve a validar todo al guardar.
export function PagoProveedorDocumento({
  supabase,
  proveedorId,
  facturaIds,
  notaCreditoIds,
  origen,
  permitirAplicarACuenta,
  onCerrar,
  onTerminado,
}: Props) {
  const proveedorQ = useProveedor(supabase, proveedorId)
  const comprobantesQ = useComprobantesProveedor(supabase, proveedorId)
  const aCuentaQ = usePagosACuenta(supabase, proveedorId)
  const [aplicar, setAplicar] = useState(false)

  const comprobantes = useMemo(() => comprobantesQ.data ?? [], [comprobantesQ.data])
  const proveedor = proveedorQ.data

  if (!proveedor || !comprobantesQ.data) {
    const error = proveedorQ.error ?? comprobantesQ.error
    return (
      <Modal title="Registrar pago a proveedor" onClose={onCerrar} minimizable etiquetaBandeja="Pago a proveedor">
        <p className="font-sans text-body-md text-ink-soft">
          {error ? friendlyError(error as Error) : proveedorQ.isPending || comprobantesQ.isPending ? 'Cargando...' : 'No se encontró el proveedor.'}
        </p>
      </Modal>
    )
  }

  const nombre = proveedor.razon_social
  const aCuenta = aCuentaQ.data?.total ?? 0
  const hayPendientes = comprobantes.some((c) => !c.anulada && !esNotaCredito(c) && Number(c.saldo_pendiente) > 0)
  const saldoInicial = datosSaldoInicial(proveedor)

  if (aplicar) {
    return (
      <AplicarACuentaModal
        supabase={supabase}
        proveedorId={proveedorId}
        proveedorNombre={nombre}
        comprobantes={comprobantes}
        facturaIds={facturaIds}
        aCuenta={aCuenta}
        onClose={onCerrar}
        onAplicado={(r) =>
          onTerminado(
            `Se aplicaron ${formatCurrency(Number(r.aplicado))} de pagos a cuenta.` +
              (Number(r.a_cuenta_restante) > 0 ? ` Siguen a cuenta ${formatCurrency(Number(r.a_cuenta_restante))}.` : ''),
          )
        }
      />
    )
  }

  return (
    <PagarProveedorModal
      minimizable
      supabase={supabase}
      proveedorId={proveedorId}
      proveedorNombre={nombre}
      comprobantes={comprobantes}
      facturaIds={facturaIds}
      notaCreditoIds={notaCreditoIds}
      origen={origen}
      aCuenta={aCuenta}
      saldoInicialPendiente={saldoInicial ? Math.max(saldoInicial.pendiente, 0) : 0}
      onAplicarACuenta={permitirAplicarACuenta && aCuenta > 0 && hayPendientes ? () => setAplicar(true) : undefined}
      onClose={onCerrar}
      onPagado={() => onTerminado('Pago registrado.')}
    />
  )
}
