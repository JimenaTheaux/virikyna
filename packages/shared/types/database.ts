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
// 'presupuesto' (docs/31): se comporta igual que remito — suma deuda, actualiza costo, se paga.
export type TipoComprobanteCompra = 'factura' | 'remito' | 'cupon' | 'presupuesto' | 'nota_credito' | 'nota_debito'
export type LetraComprobanteCompra = 'A' | 'B' | 'R' | 'X'
export type FormaPagoCompra = 'contado' | 'cuenta_corriente'
export type FormaPagoEgreso = 'efectivo' | 'transferencia' | 'cheque' | 'echeq'
export type TipoCierre = 'x' | 'z'
export type EstadoCierreZ = 'pendiente_validacion' | 'validado'
export type OrigenEgreso = 'turno' | 'general'
// 'inicial' (docs/34): stock cargado en la carga inicial de inventario.
export type TipoMovimientoStock = 'venta' | 'compra' | 'ajuste' | 'inicial'
export type MotivoDevolucion = 'regalo' | 'defectuoso' | 'arrepentimiento' | 'otro'
export type EstadoDevolucion = 'activa' | 'anulada'
export type TipoItemDevolucion = 'devuelto' | 'nuevo'
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
  costo: number | null // null = sin costo (carga inicial, docs/34): el precio sale de precio_manual
  margen_1: number
  margen_2: number
  iva_porcentaje: number
  precio_manual: number | null // precio cargado a mano, exacto. Gana sobre la fórmula; una factura con costo lo borra
  precio_calculado: number | null // columna generada — precio exacto de la fórmula, 2 decimales; null sin costo. Nunca escribir
  precio_venta: number // columna generada — precio_manual, o la fórmula con redondeo escalonado. Nunca escribir
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
  copiada_de_id: string | null // docs/33: factura de la que se copió esta (cualquier proveedor, también anulada)
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
  // DEPRECATED (docs/31): la imputación vive en pagos_proveedor_aplicaciones. Solo se completa
  // cuando todo el pago cancela una única factura — no usar para calcular saldos.
  factura_compra_id: string | null
  monto: number // 0 = operación que solo aplicó notas de crédito (sin egreso)
  forma_pago: FormaPagoEgreso
  usuario_id: string
  revierte_pago_proveedor_id: string | null // Fase 8: si esta fila revierte a otra, apunta a la original
  // Solo se completan cuando forma_pago es 'cheque' o 'echeq' (docs/15_cheques_proveedor.sql).
  cheque_numero: string | null
  cheque_fecha_salida: string | null // DATE
  cheque_fecha_vencimiento: string | null // DATE
  fecha: string // DATE — docs/31, fecha del pago (default hoy AR)
  nota: string | null // docs/31
  created_at: string
}

// docs/31 — una fila = "este monto cancela este comprobante, y sale de un pago o de una NC".
// Nunca se borra: revertir el pago marca revertida_at; las vistas solo cuentan las vigentes.
export type PagoProveedorAplicacion = {
  id: string
  factura_compra_id: string // comprobante cancelado
  monto: number // > 0
  pago_proveedor_id: string | null // fuente: plata de un pago
  nota_credito_id: string | null // fuente: crédito de una NC (exactamente una de las dos fuentes)
  operacion_id: string // pagos_proveedor de la operación que creó la fila (lo que se revierte)
  usuario_id: string
  revertida_at: string | null // null = vigente
  revertida_por: string | null
  created_at: string
}

// Retorno de registrar_pago_proveedor_v2 (docs/31).
export type RegistrarPagoProveedorV2Resultado = {
  pago_id: string
  monto: number
  aplicado_pago: number
  aplicado_nota_credito: number
  a_cuenta: number // sobrante sin comprobante (solo posible sin selección de facturas)
  aplicaciones: {
    id: string
    factura_compra_id: string
    monto: number
    fuente: 'pago' | 'nota_credito'
    nota_credito_id: string | null
  }[]
}

// Fila de existe_comprobante_compra (docs/33): comprobante ya cargado con el mismo proveedor, tipo,
// letra, punto de venta y número (sin ceros a la izquierda). Solo para avisar, no bloquea la carga.
export type ComprobanteCompraExistente = Pick<FacturaCompra, 'id' | 'fecha_comprobante' | 'total' | 'anulada'>

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
  // docs/24: devoluciones/cambios del día, netos con signo por medio (+ el comercio cobró una
  // diferencia, − devolvió plata al cliente). total_efectivo/transferencia/qr/tarjeta siguen siendo
  // solo ventas; el neto en efectivo ya está sumado en efectivo_esperado.
  cantidad_devoluciones: number
  total_devoluciones_efectivo: number
  total_devoluciones_transferencia: number
  total_devoluciones_qr: number
  total_devoluciones_tarjeta: number
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
  revisada_por: string | null // docs/27: admin que marcó la diferencia como revisada; null = pendiente
  revisada_at: string | null
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
  pago_proveedor_id: string | null // docs/31: pago que generó este egreso (categoria 'pago_proveedor')
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

// docs/31 — calculado en la vista, nunca guardado. En una NC: pendiente = sin usar, pagada = agotada.
export type EstadoFacturaCompra = 'anulada' | 'pendiente' | 'parcial' | 'pagada'

export type FacturaCompraSaldo = FacturaCompra & {
  total_pagado: number // = total_aplicado (se mantiene por compatibilidad)
  saldo_pendiente: number // lo que falta pagar; 0 en notas de crédito y anuladas
  total_aplicado: number // comprobante: pagos + NC aplicadas · NC: crédito ya usado
  credito_disponible: number // solo NC no anuladas: total − aplicado; 0 en el resto
  estado: EstadoFacturaCompra
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

// Devolución / cambio sobre una venta ya emitida (docs/24_devoluciones_cambios.sql). Documento nuevo
// vinculado a la venta — nunca modifica la venta original.
export type Devolucion = {
  id: string
  numero: number
  venta_id: string
  fecha: string // DATE — día de caja en el que impacta
  usuario_id: string
  motivo: MotivoDevolucion
  motivo_detalle: string | null // obligatorio si motivo = 'otro'
  observaciones: string | null
  diferencia_monto: number // nuevos − devueltos: > 0 paga el cliente, < 0 a favor del cliente
  diferencia_forma_pago: FormaPagoVenta | null // null si diferencia_monto = 0; 'combinado' = ver DevolucionPago
  estado: EstadoDevolucion
  anulada_por: string | null
  anulada_at: string | null
  motivo_anulacion: string | null
  created_at: string
}

export type DevolucionItem = {
  id: string
  devolucion_id: string
  tipo: TipoItemDevolucion
  producto_id: string
  cantidad: number
  precio_unitario: number // snapshot al momento
  reingresa_stock: boolean // false = mercadería defectuosa, separada del stock
}

export type DevolucionPago = {
  id: string
  devolucion_id: string
  forma_pago: FormaPagoVenta // nunca 'cuenta_corriente' ni 'combinado' acá
  monto: number // siempre positivo — el sentido lo da el signo de Devolucion.diferencia_monto
}

// ─────────────────────────────────────────────────────────────
// 5. Carga inicial de inventario (docs/34_carga_inicial.sql, docs/06 sección 24)
// ─────────────────────────────────────────────────────────────

// Fila única. Se lee directo; se cambia solo con abrir_carga_inicial / cerrar_carga_inicial (admin).
export type Configuracion = {
  id: string
  fila_unica: boolean // siempre true — garantiza una sola fila
  carga_inicial_abierta: boolean
  abierta_at: string | null
  abierta_por: string | null
  cerrada_at: string | null
  cerrada_por: string | null
  updated_at: string
  // docs/34b: último vaciado de datos (lo pone el script de reset). Lo guardado en el navegador
  // con una marca anterior se descarta.
  datos_reset_at: string | null
}

export type AccionCargaInicial = 'nuevo' | 'sumar' | 'reemplazar'

// Borrador de un usuario (RLS: cada uno ve solo los suyos). También es el retorno de
// carga_inicial_guardar_item — salvo el reintento (mismo p_client_id, docs/34c) de una operación
// cuya fila ya se finalizó o eliminó: ahí vuelve solo `id` y el resto en null.
export type CargaInicialItem = {
  id: string
  usuario_id: string
  codigo_barras: string | null // null = se genera un EAN-13 interno al finalizar
  nombre: string
  marca: string | null
  descripcion: string | null
  precio: number // > 0
  cantidad: number // > 0, siempre a la ubicación 'local'
  accion: AccionCargaInicial
  producto_id: string | null // el producto existente, si el código ya estaba (sumar/reemplazar)
  created_at: string
  updated_at: string
}

// docs/34c: un client_id (generado por el cliente) = una sola aplicación de
// carga_inicial_guardar_item / carga_inicial_editar_producto. RLS: cada usuario lee las suyas; se
// escribe solo desde esas RPCs.
export type CargaInicialOperacion = {
  client_id: string
  usuario_id: string
  operacion: 'guardar_item' | 'editar_producto'
  item_id: string | null // borrador (guardar_item) o producto (editar_producto)
  resultado: CargaInicialEditarResultado | null // editar_producto: lo que devolvió la primera vez
  created_at: string
}

// Retorno de carga_inicial_buscar_codigo.
export type CargaInicialBusqueda = {
  codigo: string // normalizado (sin espacios)
  producto: {
    id: string
    nombre: string
    marca: string | null
    descripcion: string | null
    codigo_barras: string | null
    estado: EstadoProducto
    precio_venta: number
    precio_manual: number | null
    tiene_costo: boolean // true = el precio sale del costo y no se puede cambiar en la carga inicial
    stock_local: number
  } | null
  mi_borrador: CargaInicialItem | null
  borradores_otros: {
    id: string
    usuario_id: string
    usuario_nombre: string
    nombre: string
    marca: string | null
    precio: number
    cantidad: number
    accion: AccionCargaInicial
    updated_at: string
  }[]
}

// Retorno de carga_inicial_finalizar.
export type CargaInicialFinalizarResultado = {
  items: number
  productos_creados: number
  productos_reemplazados: number
  stock_sumado: number
  fusionados: number // 'nuevo' cuyo código apareció en el medio (otro usuario): se sumó el stock
  precios_no_aplicados: number // 'reemplazar' sobre un producto con costo: el precio no se tocó
  unidades: number
  codigos_generados: { producto_id: string; nombre: string; codigo: string }[]
}

// Retorno de carga_inicial_editar_producto.
export type CargaInicialEditarResultado = {
  producto_id: string
  precio_venta: number
  cantidad_anterior: number | null // null si no se mandó cantidad
  cantidad_nueva: number | null
  delta: number // movimiento 'inicial' registrado (0 = sin cambio)
}

// Retorno de carga_inicial_resumen.
export type CargaInicialResumen = {
  abierta: boolean
  abierta_at: string | null
  abierta_por_nombre: string | null // docs/34b
  cerrada_at: string | null
  cerrada_por_nombre: string | null // docs/34b
  productos: number // productos con algún movimiento 'inicial'
  unidades: number // suma neta de movimientos 'inicial'
  valor: number // docs/34b: unidades × precio_venta actual
  borradores: number // pendientes de todos los usuarios
  unidades_borradores: number
  por_usuario: {
    usuario_id: string
    nombre: string
    productos: number
    unidades: number
    valor: number // docs/34b
    borradores: number
    unidades_borradores: number
  }[]
}

// Retorno de cerrar_carga_inicial.
export type CerrarCargaInicialResultado = {
  configuracion: Configuracion
  borradores_pendientes: number
  usuarios_con_borradores: number
}
