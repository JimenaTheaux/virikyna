import type { ReactNode } from 'react'
import { BottomSheet } from '../BottomSheet'
import { Modal } from '../Modal'
import type { CargaInicialFinalizarResultado } from '../../../types/database'
import { formatCantidad } from '../../../lib/cargaInicial'

export type Variante = 'escritorio' | 'celular'

// Diálogo según el dispositivo: Modal centrado en escritorio, BottomSheet a pantalla completa en
// celular. Siempre con role="dialog", Esc y foco atrapado.
export function Dialogo({
  celular,
  title,
  onClose,
  footer,
  children,
}: {
  celular: boolean
  title: string
  onClose: () => void
  footer?: ReactNode
  children: ReactNode
}) {
  return celular ? (
    <BottomSheet title={title} onClose={onClose} footer={footer} dialogo={{ onEscape: onClose }}>
      {children}
    </BottomSheet>
  ) : (
    <Modal title={title} onClose={onClose} footer={footer} widthClassName="max-w-[520px]" dialogo={{ onEscape: onClose }}>
      {children}
    </Modal>
  )
}

// Pie de diálogo: secundario a la izquierda, primario (o destructivo) a la derecha.
export function BotonesDialogo({
  celular,
  onCancelar,
  onConfirmar,
  confirmarLabel,
  confirmando,
  deshabilitado,
  destructivo,
  cancelarLabel = 'Cancelar',
}: {
  celular: boolean
  onCancelar: () => void
  onConfirmar?: () => void
  confirmarLabel?: string
  confirmando?: boolean
  deshabilitado?: boolean
  destructivo?: boolean
  cancelarLabel?: string
}) {
  const alto = celular ? 'min-h-12' : 'py-3'
  return (
    <div className="flex justify-end gap-3">
      <button
        type="button"
        data-autofocus
        onClick={onCancelar}
        className={`rounded px-4 font-sans text-label-bold text-ink-soft hover:bg-bg ${alto} ${celular ? 'flex-1' : ''}`}
      >
        {cancelarLabel}
      </button>
      {onConfirmar && (
        <button
          type="button"
          onClick={onConfirmar}
          disabled={confirmando || deshabilitado}
          className={`rounded px-4 font-sans text-label-bold transition disabled:opacity-60 ${alto} ${celular ? 'flex-1' : ''} ${
            destructivo
              ? 'border border-error text-error hover:bg-error hover:text-white'
              : 'bg-accent text-white hover:bg-accent-dark'
          }`}
        >
          {confirmando ? 'Un momento...' : confirmarLabel}
        </button>
      )}
    </div>
  )
}

export function ResultadoFinalizar({ resultado }: { resultado: CargaInicialFinalizarResultado }) {
  // Sin borradores para aplicar: típico de un reintento cuya primera llamada sí llegó (los
  // borradores se borran en la misma transacción que los aplica, docs/34c).
  if (resultado.items === 0) {
    return (
      <p className="font-sans text-body-md text-ink">
        No había filas para aplicar: tu carga ya estaba aplicada. Lo cargado se ve en "Inventario total".
      </p>
    )
  }
  const lineas: [string, number][] = [
    ['Productos nuevos', resultado.productos_creados],
    ['Productos con datos reemplazados', resultado.productos_reemplazados],
    ['Stock sumado a productos existentes', resultado.stock_sumado],
    ['Cargados por otra persona en el medio (se sumó el stock)', resultado.fusionados],
  ]
  return (
    <div className="flex flex-col gap-stack-md font-sans text-body-md text-ink">
      <p>
        Se aplicaron <strong>{resultado.items}</strong> fila{resultado.items === 1 ? '' : 's'} ·{' '}
        <strong>{formatCantidad(resultado.unidades)}</strong> unidades en Local.
      </p>
      <ul className="flex flex-col gap-1">
        {lineas
          .filter(([, n]) => n > 0)
          .map(([label, n]) => (
            <li key={label} className="flex justify-between gap-3 border-b border-line py-1 last:border-0">
              <span>{label}</span>
              <strong>{n}</strong>
            </li>
          ))}
      </ul>
      {resultado.precios_no_aplicados > 0 && (
        <p className="rounded bg-badge-amber-bg px-3 py-2 text-badge-amber-text">
          {resultado.precios_no_aplicados} producto{resultado.precios_no_aplicados === 1 ? '' : 's'} ya tenía
          {resultado.precios_no_aplicados === 1 ? '' : 'n'} costo cargado: se actualizaron los datos y el stock, pero el
          precio sigue saliendo del costo.
        </p>
      )}
      {resultado.codigos_generados.length > 0 && (
        <div>
          <p className="mb-1 font-sans text-label-bold">Códigos generados (para etiquetar)</p>
          <ul className="flex flex-col gap-1">
            {resultado.codigos_generados.map((c) => (
              <li key={c.producto_id} className="flex justify-between gap-3">
                <span className="[overflow-wrap:anywhere]">{c.nombre}</span>
                <span className="font-mono">{c.codigo}</span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}

// Texto corto de lo que va a hacer un borrador al finalizar.
export function textoAccion(accion: 'nuevo' | 'sumar' | 'reemplazar', tieneProducto: boolean): string | null {
  if (accion === 'sumar') return 'Suma stock'
  if (accion === 'reemplazar') return tieneProducto ? 'Reemplaza datos' : 'Con mis datos'
  return null
}
