import {
  ALICUOTAS_IVA_COMPRA,
  aAlicuotaIvaCompra,
  etiquetaCortaAlicuotaIva,
  type AlicuotaIvaCompra,
} from '../../lib/totalesCompra'
import { ControlSegmentado } from './ControlSegmentado'

const OPCIONES = ALICUOTAS_IVA_COMPRA.map((a) => ({ value: String(a), label: etiquetaCortaAlicuotaIva(a) }))

type Props = {
  value: AlicuotaIvaCompra
  onChange: (alicuota: AlicuotaIvaCompra) => void
  size?: 'compact' | 'touch'
  disabled?: boolean
}

// IVA del comprobante de compra (docs/45): "IVA 21%" / "Exento". Mismo control en la carga (Local,
// Gestión e Inventario) y en la edición. El default por tipo lo pone cada formulario con
// alicuotaDefault al cambiar el tipo.
export function SelectorAlicuotaIva({ value, onChange, size, disabled }: Props) {
  return (
    <ControlSegmentado
      legend="IVA del comprobante"
      opciones={OPCIONES}
      value={String(value)}
      onChange={(v) => onChange(aAlicuotaIvaCompra(v))}
      size={size}
      disabled={disabled}
    />
  )
}
