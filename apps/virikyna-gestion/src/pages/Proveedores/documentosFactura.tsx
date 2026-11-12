import type { BorradorConNombres, FacturaCompraSaldo, PayloadBorradorFactura } from '@virikyna/shared'
import { etiquetaComprobanteCompra } from '@virikyna/shared'
import { avisarCambioDatos } from '@virikyna/shared/lib/cambiosDatos'
import type { BandejaApi } from '@virikyna/shared/src/components/documentos/DocumentosAbiertos'
import { CargarFacturaCompraModal } from './CargarFacturaCompraModal'
import { FacturaCompraDetalleModal } from './FacturaCompraDetalleModal'

// Documentos de la bandeja (docs/73) que se abren desde Proveedores → Facturas de compra. Viven en
// AppShell: no dependen del listado (puede desmontarse); le avisan con avisarCambioDatos.
// Gestión es solo admin.

type OpcionesCarga = { copiadaDeId?: string; borrador?: BorradorConNombres<PayloadBorradorFactura> }

export function abrirCargaFactura(bandeja: BandejaApi, { copiadaDeId, borrador }: OpcionesCarga = {}) {
  // Un borrador se reconoce por su id (también si la factura abierta lo creó: alias desde la planilla).
  const clave = borrador
    ? `factura_compra:borrador:${borrador.id}`
    : `factura_compra:${copiadaDeId ? 'copia' : 'nueva'}:${crypto.randomUUID()}`
  return bandeja.abrir({
    clave,
    tipo: 'factura_compra',
    etiqueta: borrador?.resumen || (copiadaDeId ? 'Copia de factura' : 'Factura nueva'),
    roles: ['admin'],
    render: ({ cerrar }) => (
      <CargarFacturaCompraModal
        minimizable
        copiadaDeId={copiadaDeId}
        borrador={borrador}
        onClose={() => {
          cerrar()
          avisarCambioDatos('borradores_factura')
        }}
        onSaved={() => {
          cerrar()
          avisarCambioDatos('facturas_compra')
          avisarCambioDatos('borradores_factura')
        }}
      />
    ),
  })
}

export function abrirDetalleFactura(bandeja: BandejaApi, factura: FacturaCompraSaldo, proveedorNombre: string) {
  return bandeja.abrir({
    clave: `factura_compra:detalle:${factura.id}`,
    tipo: 'detalle_factura_compra',
    etiqueta: `${proveedorNombre} · ${etiquetaComprobanteCompra(factura)}`,
    roles: ['admin'],
    render: ({ cerrar }) => (
      <FacturaCompraDetalleModal
        minimizable
        factura={factura}
        proveedorNombre={proveedorNombre}
        onClose={cerrar}
        onChanged={() => avisarCambioDatos('facturas_compra')}
        onCopiar={() => {
          cerrar()
          abrirCargaFactura(bandeja, { copiadaDeId: factura.id })
        }}
      />
    ),
  })
}
