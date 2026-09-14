import type { Cliente, MovimientoCuenta, Proveedor } from '@virikyna/shared'

export type MovimientoCuentaConUsuario = MovimientoCuenta & {
  usuario: { nombre: string } | null
}

export type SaldoProveedor = Pick<Proveedor, 'id' | 'razon_social' | 'saldo_inicial'>
export type SaldoCliente = Pick<Cliente, 'id' | 'razon_social' | 'nombre_fantasia' | 'saldo_inicial'>
