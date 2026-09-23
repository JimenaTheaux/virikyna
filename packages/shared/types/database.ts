// Tipos TypeScript derivados de docs/06_estructura_de_datos.md — schema ya ejecutado en Supabase.
// Fuente de verdad: el SQL de ese doc. Si el schema cambia, actualizar este archivo a mano
// (o reemplazar por la salida de `supabase gen types typescript` una vez que el proyecto tenga CLI linkeado).

// ─────────────────────────────────────────────────────────────
// 1. Enums
// ─────────────────────────────────────────────────────────────

export type RolUsuario = 'admin' | 'cajero'
export type EstadoProducto = 'activo' | 'inactivo'
export type UbicacionStock = 'local' | 'deposito'
export type FormaPagoVenta =
  | 'efectivo'
  | 'transferencia'
  | 'qr'
  | 'tarjeta_debito'
  | 'tarjeta_credito'
  | 'cuenta_corriente'
  | 'combinado'
export type EstadoComprobante = 'sin_facturar' | 'facturado' | 'anulada'
export type TipoComprobanteCompra = 'factura' | 'remito' | 'cupon' | 'nota_credito' | 'nota_debito'
export type LetraComprobanteCompra = 'A' | 'B' | 'R' | 'X'
export type FormaPagoCompra = 'contado' | 'cuenta_corriente'
export type FormaPagoEgreso = 'efectivo' | 'transferencia' | 'cheque' | 'echeq'
export type TipoCierre = 'x' | 'z'
export type EstadoCierreZ = 'pendiente_validacion' | 'validado'
export type OrigenEgreso = 'turno' | 'general'
export type TipoMovimientoStock = 'venta' | 'compra' | 'ajuste'
// sueldo/servicio son categorías de Virikyna-Gestión (origen='general'); agua/descartables/super
// son las categorías de gasto de turno en Virikyna-Local (origen='turno') — ver docs/13.
export type CategoriaEgreso = 'pago_proveedor' | 'sueldo' | 'servicio' | 'otro' | 'agua' | 'descartables' | 'super'
// Obligatoria para Factura C desde RG 5616 (ver FEParamGetCondicionIvaReceptor de ARCA).
// Cubre los casos reales de Virikyna — nada de exterior ni IVA Liberado Ley 19.640.
export type CondicionIvaCliente =
  | 'consumidor_final'
  | 'responsable_inscripto'
  | 'monotributista'
  | 'exento'
  | 'no_categorizado'
export type TipoAccionAuditoria =
  | 'alta'
  | 'edicion'
  | 'eliminacion'
  | 'anulacion'
  | 'reversion'
  | 'nota_correccion'
export type TipoMovimientoCuenta =
  | 'saldo_inicial'
  | 'venta'
  | 'pago_cliente'
  | 'pago_proveedor'
  | 'egreso'
  | 'ingreso_manual'
  | 'cierre_z'
  | 'transferencia_interna'
  | 'retiro'

// ─────────────────────────────────────────────────────────────
// 2. Tablas sin FK
// ─────────────────────────────────────────────────────────────

export type Perfil = {
  id: string // = auth.users.id
  nombre: string
  rol: RolUsuario
  activo: boolean
  created_at: string
}

// Vista `perfiles_publico`: id + nombre solamente, visible para cualquier usuario autenticado
// (a diferencia de `perfiles`, que solo expone la fila propia por RLS). Usar esto, nunca
// `perfiles`, para listar/nombrar a otros usuarios (selector de usuario, filtros, "quién hizo esto").
export type PerfilPublico = {
  id: string
  nombre: string
}

export type Proveedor = {
  id: string
  razon_social: string
  cuit: string | null
  direccion: string | null
  telefono: string | null
  mail: string | null
  contacto: string | null
  margen_1_default: number
  margen_2_default: number
  saldo_inicial: number
  created_at: string
}

// CHECK chk_cliente_tiene_nombre: razon_social y nombre_fantasia no pueden ser ambos null.
export type Cliente = {
  id: string
  razon_social: string | null
  nombre_fantasia: string | null
  cuit: string | null
  domicilio: string | null
  mail: string | null
  celular: string | null
  activo: boolean
  saldo_inicial: number
  condicion_iva: CondicionIvaCliente
  created_at: string
}

// ─────────────────────────────────────────────────────────────
// 3. Tablas con FK (mismo orden de dependencia que el doc)
// ─────────────────────────────────────────────────────────────

export type Auditoria = {
  id: string
  tabla_afectada: string
  registro_id: string
  accion: TipoAccionAuditoria
  valores_anteriores: Record<string, unknown> | null
  valores_nuevos: Record<string, unknown> | null
  usuario_id: string
  revierte_auditoria_id: string | null
  nota: string | null
  created_at: string
}

export type Cuenta = {
  id: string
  nombre: string
  created_at: string
}

export type MovimientoCuenta = {
  id: string
  cuenta_id: string
  tipo: TipoMovimientoCuenta
  monto: number // positivo = ingreso, negativo = egreso
  descripcion: string | null
  referencia_id: string | null
  revierte_movimiento_id: string | null // si esta fila corrige/anula a otra, apunta a esa fila original
  usuario_id: string
  created_at: string
}

export type Producto = {
  id: string
  nombre: string
  descripcion: string | null
  codigo_barras: string | null
  codigo_interno: string | null
  proveedor_id: string | null
  marca: string | null
  costo: number
  margen_1: number
  margen_2: number
  iva_porcentaje: number
  precio_venta: number // columna generada — nunca escribir, solo leer
  stock_minimo: number
  estado: EstadoProducto
  created_at: string
  updated_at: string
}

export type StockUbicacion = {
  id: string
  producto_id: string
  ubicacion: UbicacionStock
  cantidad: number
}

export type MovimientoStock = {
  id: string
  producto_id: string
  ubicacion: UbicacionStock
  tipo: TipoMovimientoStock
  cantidad: number // positivo = ingreso, negativo = egreso
  motivo: string | null // obligatorio solo si tipo = 'ajuste', validado en el RPC
  referencia_id: string | null // venta_id o factura_compra_id, según tipo
  usuario_id: string
  created_at: string
}

export type Venta = {
  id: string
  numero: number
  cliente_id: string | null // null = consumidor final
  forma_pago: FormaPagoVenta // 'combinado' = ver detalle en VentaPago (venta_pagos)
  subtotal: number
  descuento_porcentaje: number
  recargo_porcentaje: number
  total: number // = precio_cobrado (docs/23) — lo que efectivamente se cobró
  precio_oficial: number // calculado por el sistema, sin el redondeo manual del cajero
  precio_cobrado: number // confirmado/editado por el cajero al cerrar la venta
  estado: EstadoComprobante
  nota: string | null
  terminal_id: string
  usuario_id: string
  created_at: string
}

export type VentaItem = {
  id: string
  venta_id: string
  producto_id: string
  cantidad: number
  precio_unitario: number // snapshot del precio al momento de vender
  descuento_porcentaje: number
  importe: number
}

export type VentaPago = {
  id: string
  venta_id: string
  forma_pago: FormaPagoVenta // nunca 'cuenta_corriente' ni 'combinado' acá
  monto: number
  usuario_id: string
  created_at: string
}

export type FacturaC = {
  id: string
  venta_id: string // 1:1 con Venta
  cae: string | null
  numero_factura: string | null
  punto_venta: string | null
  fecha_emision: string | null
  pdf_url: string | null
  enviado_a: string | null
  usuario_id: string
  created_at: string
}

export type FacturaCompra = {
  id: string
  proveedor_id: string
  tipo_comprobante: TipoComprobanteCompra
  letra: LetraComprobanteCompra | null
  punto_venta: string | null
  numero_comprobante: string | null
  fecha_comprobante: string // DATE
  fecha_fiscal: string | null // DATE
  forma_pago: FormaPagoCompra
  total_sin_iva: number
  iva: number
  total: number
  usuario_id: string
  anulada: boolean // exclusivo Gestión: anular_factura_compra revierte stock y marca esto
  created_at: string
}

export type FacturaCompraItem = {
  id: string
  factura_compra_id: string
  producto_id: string | null // null = ítem libre (ej. "juguetes varios", ajustes)
  descripcion: string
  cantidad: number
  precio_unitario_sin_iva: number
  descuento_porcentaje: number
  precio_total_sin_iva: number
  ubicacion: UbicacionStock
}

export type PagoProveedor = {
  id: string
  proveedor_id: string
  factura_compra_id: string | null // null = pago a cuenta general
  monto: number
  forma_pago: FormaPagoEgreso
  usuario_id: string
  revierte_pago_proveedor_id: string | null // Fase 8: si esta fila revierte a otra, apunta a la original
  // Solo se completan cuando forma_pago es 'cheque' o 'echeq' (docs/15_cheques_proveedor.sql).
  cheque_numero: string | null
  cheque_fecha_salida: string | null // DATE
  cheque_fecha_vencimiento: string | null // DATE
  created_at: string
}

export type PagoCliente = {
  id: string
  cliente_id: string
  venta_id: string | null // a qué venta se aplica; null = a cuenta general
  monto: number
  forma_pago: FormaPagoVenta
  usuario_id: string
  revierte_pago_cliente_id: string | null // Fase 8: si esta fila revierte a otra, apunta a la original
  created_at: string
}

export type CierreCaja = {
  id: string
  tipo: TipoCierre
  turno_fecha: string // DATE
  total_efectivo: number
  total_transferencia: number
  total_qr: number
  total_tarjeta: number
  total_cuenta_corriente: number
  total_egresos: number
  total_retiros: number // docs/17: retiros de efectivo del día, ya restados de efectivo_esperado
  efectivo_esperado: number
  efectivo_contado: number | null
  diferencia: number | null
  estado_validacion: EstadoCierreZ | null // solo aplica a tipo = 'z'
  validado_por: string | null
  validado_at: string | null
  usuario_id: string
  apertura_id: string | null // docs/21: apertura de caja vigente al momento de este cierre (X o Z)
  created_at: string
}

// Apertura de caja (docs/21_apertura_caja.sql) — arranca cada período de caja hasta el próximo
// Cierre Z. monto_esperado sale del efectivo_contado del último Cierre Z (0 si todavía no hubo
// ninguno); monto_real es lo que el cajero confirmó o corrigió que tiene físicamente. Ese
// monto_real pasa a ser la base de efectivo_esperado en cerrar_caja. Solo puede existir una fila
// con cierre_z_id null a la vez (índice único parcial) — no se puede reabrir mientras hay una
// caja abierta. Se "cierra" (cierre_z_id dejar de ser null) automáticamente al hacer el próximo
// Cierre Z, dentro de la misma transacción de cerrar_caja.
export type AperturaCaja = {
  id: string
  cierre_z_previo_id: string | null // Cierre Z del que sale monto_esperado; null en la primera apertura del sistema
  monto_esperado: number
  monto_real: number
  diferencia: number // monto_real - monto_esperado
  cierre_z_id: string | null // null mientras la caja sigue abierta
  usuario_id: string // quien abrió
  abierta_at: string
  created_at: string
}

export type Egreso = {
  id: string
  cierre_caja_id: string | null // null = egreso general no atado a un cierre puntual
  origen: OrigenEgreso
  categoria: CategoriaEgreso
  monto: number
  descripcion: string | null
  forma_pago: FormaPagoEgreso
  usuario_id: string
  revierte_egreso_id: string | null // Fase 8: si esta fila revierte a otra, apunta a la original
  fecha: string // DATE ('YYYY-MM-DD') — fecha real del egreso, editable desde el módulo Egresos
  // (default hoy). created_at sigue siendo el timestamp de carga en el sistema, no se toca.
  created_at: string
}

// Retiro de efectivo del turno hacia un admin (docs/14_retiro_efectivo_caja.sql). Es el ÚNICO
// camino por el que el efectivo de Local llega a Caja Gestión — el Cierre Z dejó de volcarlo
// (antes lo hacía `validar_cierre_z`, ver ese RPC). Cada retiro genera 1 fila acá + 1 movimiento
// de cuenta (tipo='retiro', ingreso a la cuenta Efectivo) vinculada por movimiento_cuenta_id.
export type RetiroCaja = {
  id: string
  fecha: string // DATE ('YYYY-MM-DD') — fecha del retiro, editable
  monto: number
  admin_receptor_id: string // perfiles.id, rol='admin' — quien recibe el efectivo
  cajero_id: string // perfiles.id — autocompleta con el usuario logueado, editable
  movimiento_cuenta_id: string // fila en movimientos_cuenta que este retiro generó
  usuario_id: string // quien registró la acción (auth.uid())
  created_at: string
}

// 'local' = creada desde Virikyna Local, 'gestion' = creada desde Virikyna Gestión. Separa
// las notas de cada app (docs/06_estructura_de_datos (1).md sección 15) — un cajero no ve ni
// crea notas de origen 'gestion', reforzado por RLS además del filtro explícito en la query.
export type OrigenNota = 'local' | 'gestion'

// Notas internas tipo post-it (docs/16_notas_internas.sql, docs/04_modulos_y_funciones.md
// módulo 11). Cada app solo lee/escribe su propio origen — ver docs/06 sección 15.
export type NotaInterna = {
  id: string
  mensaje: string
  autor_id: string // perfiles.id — quien la creó
  origen: OrigenNota
  archivada: boolean
  archivada_at: string | null
  created_at: string
}

// ─────────────────────────────────────────────────────────────
// 4. Vistas de saldo (docs/06_estructura_de_datos.md, sección 9) — heredan el RLS de las
// tablas que consultan, no hace falta política propia.
// ─────────────────────────────────────────────────────────────

export type FacturaCompraSaldo = FacturaCompra & {
  total_pagado: number
  saldo_pendiente: number
}

export type ProveedorSaldo = Proveedor & {
  saldo_actual: number
}

export type ClienteSaldo = Cliente & {
  saldo_actual: number
}

export type CuentaSaldo = Cuenta & {
  saldo_actual: number
}

// Vista `notas_internas_con_autor` (docs/16_notas_internas.sql) — misma nota + nombre del autor,
// para no depender de que el cliente tenga acceso directo a `perfiles` de otro usuario.
export type NotaInternaConAutor = NotaInterna & {
  autor_nombre: string
}
