import type { ReactNode } from 'react'
import { fechaLocalDeISO, formatCurrency, formatFechaCortaLocal } from '../../lib/format'
import { estadoSaldoInicial, tieneSaldoInicial } from '../../lib/saldoInicial'
import { EstadoBadge } from './EstadoBadge'
import { KpiCuenta, type FilaInicialComprobantes } from './CuentaCorrienteLayout'

// Saldo inicial en la cuenta corriente de proveedores y clientes (docs/69): un KPI en el resumen y
// una línea fija al principio de los comprobantes. No es un comprobante: no se selecciona ni se
// paga directo; los pagos (cobros) sin comprobante lo cancelan primero (lo calcula la base).

export type DatosSaldoInicial = {
  saldoInicial: number
  pendiente: number // lo que falta cancelar (saldo_inicial_pendiente); negativo si es a favor
  fecha: string | null
  usuario: string | null
}

type FilaVista = {
  saldo_inicial: number | string
  saldo_inicial_fecha?: string | null
  saldo_inicial_usuario_nombre?: string | null
  saldo_inicial_pendiente?: number | string | null
}

// null si la cuenta no tiene saldo inicial cargado.
export function datosSaldoInicial(c: FilaVista): DatosSaldoInicial | null {
  if (!tieneSaldoInicial(c)) return null
  const saldoInicial = Number(c.saldo_inicial)
  return {
    saldoInicial,
    // Sin docs/69 en la base no viene el pendiente: se muestra el saldo inicial entero.
    pendiente: c.saldo_inicial_pendiente == null ? saldoInicial : Number(c.saldo_inicial_pendiente),
    fecha: c.saldo_inicial_fecha ?? null,
    usuario: c.saldo_inicial_usuario_nombre ?? null,
  }
}

const negativo = (n: number) => `−${formatCurrency(Math.abs(n))}`

export function KpiSaldoInicial({ datos }: { datos: DatosSaldoInicial }) {
  const { saldoInicial, pendiente, fecha } = datos
  return (
    <KpiCuenta label="Saldo inicial">
      <span className={saldoInicial < 0 ? 'text-success' : ''}>
        {saldoInicial < 0 ? negativo(saldoInicial) : formatCurrency(saldoInicial)}
      </span>
      <span className="block font-sans text-label-md text-ink-soft">
        {saldoInicial < 0 ? 'a favor' : pendiente > 0 ? `pendiente ${formatCurrency(pendiente)}` : 'cancelado'}
        {fecha ? ` · ${formatFechaCortaLocal(fecha)}` : ''}
      </span>
    </KpiCuenta>
  )
}

// La línea se ve en "Todos" siempre, en "Pendientes" mientras falte cancelarla y en
// "Pagados/Cobrados" cuando ya está cancelada. Los filtros de tipo o número la ocultan (no es un
// comprobante); el rango de fechas mira el día en que se cargó.
export function verFilaSaldoInicial(
  datos: DatosSaldoInicial | null,
  vista: 'pendientes' | 'cerrados' | 'todos' | 'otra',
  filtros: { desde: string; hasta: string; filtroDeComprobante: boolean },
): datos is DatosSaldoInicial {
  if (!datos || vista === 'otra' || filtros.filtroDeComprobante) return false
  const dia = datos.fecha ? fechaLocalDeISO(datos.fecha) : null
  if (dia && ((filtros.desde && dia < filtros.desde) || (filtros.hasta && dia > filtros.hasta))) return false
  if (vista === 'pendientes') return datos.pendiente > 0
  if (vista === 'cerrados') return datos.pendiente <= 0
  return true
}

// Celdas por id de columna de TablaComprobantes. `columnaTipo`: el proveedor tiene columna "Tipo";
// en el cliente la etiqueta va junto al texto. `columnaCancelado`: "aplicado" / "cobrado".
export function filaSaldoInicial(
  datos: DatosSaldoInicial,
  opciones: { columnaTipo?: string; columnaTexto: string; columnaCancelado: string; textoCancelado: string },
): FilaInicialComprobantes {
  const { saldoInicial, pendiente, fecha, usuario } = datos
  const estado = estadoSaldoInicial(saldoInicial, pendiente)
  const etiqueta = (
    <span className="inline-block whitespace-nowrap rounded-[6px] border border-line bg-surface px-2 py-0.5 font-sans text-table-row font-semibold text-accent-darker">
      Saldo inicial
    </span>
  )
  const celdas: Record<string, ReactNode> = {
    fecha: <span className="tabular-nums text-ink-soft">{fecha ? formatFechaCortaLocal(fecha) : '—'}</span>,
    [opciones.columnaTexto]: (
      <span className="[overflow-wrap:anywhere]">
        {!opciones.columnaTipo && <span className="mr-2">{etiqueta}</span>}
        <span className="text-ink">Deuda al arrancar el sistema</span>
        <span className="block text-label-md text-ink-soft">
          No es un comprobante{usuario ? ` · cargó ${usuario}` : ''}
        </span>
      </span>
    ),
    total: (
      <span className={`font-semibold tabular-nums ${saldoInicial < 0 ? 'text-success' : 'text-ink'}`}>
        {saldoInicial < 0 ? negativo(saldoInicial) : formatCurrency(saldoInicial)}
      </span>
    ),
    [opciones.columnaCancelado]: (
      <span className="tabular-nums text-ink-soft" title={opciones.textoCancelado}>
        {formatCurrency(saldoInicial > 0 ? saldoInicial - Math.max(pendiente, 0) : 0)}
      </span>
    ),
    saldo: (
      <span className={`font-semibold tabular-nums ${pendiente > 0 ? 'text-error' : pendiente < 0 ? 'text-success' : 'text-ink-soft'}`}>
        {pendiente < 0 ? negativo(pendiente) : formatCurrency(pendiente)}
      </span>
    ),
    estado: <EstadoBadge variant={estado.variant}>{estado.label}</EstadoBadge>,
  }
  if (opciones.columnaTipo) celdas[opciones.columnaTipo] = etiqueta
  return { etiqueta: 'Saldo inicial', celdas }
}
