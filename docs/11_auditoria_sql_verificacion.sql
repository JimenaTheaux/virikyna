-- ============================================================
-- Auditoría final — verificación contra Supabase real
-- Corré esto en el SQL Editor de Supabase (proyecto ccpinvtleqlsukcqnili)
-- y pegame el resultado de cada bloque. No hace falta compartir ninguna key.
-- ============================================================

-- ============================================================
-- PUNTO 3a — Policies RLS por tabla (comparar contra docs/06, sección 5)
-- Tablas esperadas con RLS habilitado y su patrón documentado:
--   perfiles, ventas, movimientos_stock, cierres_caja, auditoria,
--   cuentas, cuenta_forma_pago, movimientos_cuenta,
--   proveedores, productos, stock_ubicaciones, clientes,
--   facturas_compra, facturas_compra_items, pagos_proveedor,
--   pagos_cliente, facturas_c, egresos
-- ============================================================
SELECT schemaname, tablename, rowsecurity AS rls_habilitado
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY tablename;

SELECT schemaname, tablename, policyname, cmd, roles, qual, with_check
FROM pg_policies
WHERE schemaname = 'public'
ORDER BY tablename, cmd;

-- ============================================================
-- PUNTO 3b — Triggers (comparar contra docs/06, sección 6 y 11)
-- Esperados:
--   trg_auditoria_productos, trg_auditoria_proveedores, trg_auditoria_clientes,
--   trg_auditoria_ventas, trg_auditoria_stock_ubicaciones, trg_auditoria_egresos,
--   trg_auditoria_pagos_proveedor, trg_auditoria_pagos_cliente,
--   trg_auditoria_facturas_compra, trg_auditoria_movimientos_cuenta,
--   trg_proteger_margen_producto, trg_proteger_margen_proveedor,
--   trg_proteger_eliminacion_cliente
-- (movimientos_stock NO debería tener trigger propio — es en sí mismo un log)
-- ============================================================
SELECT
  c.relname AS tabla,
  t.tgname AS trigger,
  pg_get_triggerdef(t.oid) AS definicion
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT t.tgisinternal
  AND n.nspname = 'public'
ORDER BY c.relname, t.tgname;

-- ============================================================
-- PUNTO 4 — RPCs desplegados (comparar firma contra docs/06, sección 7 y 8, y sección 11)
-- Esperados (nombre, y # de parámetros aprox. según doc):
--   revertir_edicion, anular_venta, revertir_movimiento, agregar_nota_correccion,
--   confirmar_venta, cargar_factura_compra, ajustar_stock, emitir_factura_c,
--   registrar_pago_proveedor, registrar_egreso_general, cerrar_caja, validar_cierre_z,
--   cargar_saldos_iniciales, registrar_movimiento_caja_general, registrar_pago_cliente,
--   transferir_entre_cuentas, editar_movimiento_cuenta, eliminar_movimiento_cuenta,
--   editar_factura_compra, anular_factura_compra, actualizar_precios_masivo,
--   fn_auditoria_generica, fn_proteger_margen_producto, fn_proteger_margen_proveedor,
--   fn_proteger_eliminacion_cliente
-- ============================================================
SELECT
  r.routine_name,
  r.data_type AS retorno,
  r.security_type,
  string_agg(p.parameter_name || ' ' || p.data_type, ', ' ORDER BY p.ordinal_position) AS parametros
FROM information_schema.routines r
LEFT JOIN information_schema.parameters p
  ON p.specific_schema = r.specific_schema AND p.specific_name = r.specific_name
WHERE r.routine_schema = 'public'
GROUP BY r.routine_name, r.data_type, r.security_type, r.specific_name
ORDER BY r.routine_name;

-- ============================================================
-- PUNTO 4b — Vistas esperadas (docs/06 sección 9)
-- perfiles_publico, facturas_compra_saldo, proveedores_saldo, clientes_saldo
-- ============================================================
SELECT table_name AS vista, view_definition
FROM information_schema.views
WHERE table_schema = 'public'
ORDER BY table_name;

-- ============================================================
-- PUNTO 4c — Enums desplegados (docs/06 sección 1) — para confirmar que
-- 'anulada' se agregó a estado_comprobante y que no falta ningún tipo.
-- ============================================================

