-- 38 — Seguridad pre-lanzamiento: cierre de accesos sin login y de escrituras directas
--
-- Se corre a mano en el SQL Editor de Supabase (proyecto ccpinvtleqlsukcqnili), en orden. Los
-- bloques 1 a 6 van juntos (una transacción); el bloque 7 se corre AL FINAL, después de las
-- pruebas, porque cualquier prueba que llame a confirmar_venta consume números aunque haga
-- ROLLBACK (las secuencias no se revierten).
--
-- Origen: auditoría pre-lanzamiento del 2026-10-08 (hallazgos #1, #3, #6, #15, #17, #18).
--
-- Relevado antes de escribir esto:
--   - Escrituras directas desde el cliente (grep de .from(...).insert/update/upsert/delete en
--     las 3 apps y packages/shared): solo clientes, productos, proveedores y notas_internas.
--     Ninguna de las 12 tablas del bloque 2: todas se escriben por RPC SECURITY DEFINER (dueño
--     postgres, que saltea RLS), así que bajar sus policies a SELECT no rompe ninguna pantalla.
--   - cuentas_saldo solo la lee Gestión (admin): con security_invoker un cajero ve 0 filas,
--     igual que en la tabla cuentas (policy cuentas_solo_admin).
--   - Las funciones de public tienen EXECUTE para PUBLIC (default de Postgres), y anon lo hereda:
--     revocar solo a anon no alcanza. authenticated y service_role tienen grants explícitos y no
--     pierden nada. carga_inicial_reclamar_operacion ya no tenía PUBLIC (docs/34c).
--   - Ninguna app consulta public antes del login; Auth (GoTrue) usa su propio schema.


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- BLOQUES 1 A 6 — correr juntos
-- ════════════════════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────────────────────
-- 1. Vistas (#1). Eran SECURITY DEFINER de hecho (dueño postgres, sin security_invoker):
--    salteaban RLS y anon las leía por REST. perfiles_publico además era auto-actualizable.
-- ────────────────────────────────────────────────────────────────────────────────────────────

-- Las de saldos pasan a respetar la RLS de quien consulta.
ALTER VIEW cuentas_saldo         SET (security_invoker = on);
ALTER VIEW clientes_saldo        SET (security_invoker = on);
ALTER VIEW proveedores_saldo     SET (security_invoker = on);
ALTER VIEW facturas_compra_saldo SET (security_invoker = on);

-- perfiles_publico y notas_internas_con_autor siguen definer a propósito: con invoker, la RLS de
-- perfiles (solo el propio perfil) dejaría sin nombre a los demás usuarios.
REVOKE ALL ON cuentas_saldo, clientes_saldo, proveedores_saldo, facturas_compra_saldo,
              perfiles_publico, notas_internas_con_autor FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON cuentas_saldo, clientes_saldo, proveedores_saldo, facturas_compra_saldo,
     perfiles_publico, notas_internas_con_autor FROM authenticated;
GRANT SELECT ON cuentas_saldo, clientes_saldo, proveedores_saldo, facturas_compra_saldo,
                perfiles_publico, notas_internas_con_autor TO authenticated;


-- ────────────────────────────────────────────────────────────────────────────────────────────
-- 2. Policies ALL → solo SELECT (#3). Mismo filtro de lectura (perfil activo). Las escrituras
--    siguen por RPC.
-- ────────────────────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS "ventas_todos" ON ventas;
CREATE POLICY "ventas_select" ON ventas FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));

DROP POLICY IF EXISTS "venta_items_todos" ON venta_items;
CREATE POLICY "venta_items_select" ON venta_items FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));

DROP POLICY IF EXISTS "venta_pagos_todos" ON venta_pagos;
CREATE POLICY "venta_pagos_select" ON venta_pagos FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));

DROP POLICY IF EXISTS "stock_ubicaciones_todos" ON stock_ubicaciones;
CREATE POLICY "stock_ubicaciones_select" ON stock_ubicaciones FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));

DROP POLICY IF EXISTS "facturas_c_todos" ON facturas_c;
CREATE POLICY "facturas_c_select" ON facturas_c FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));

DROP POLICY IF EXISTS "facturas_compra_todos" ON facturas_compra;
CREATE POLICY "facturas_compra_select" ON facturas_compra FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));

DROP POLICY IF EXISTS "facturas_compra_items_todos" ON facturas_compra_items;
CREATE POLICY "facturas_compra_items_select" ON facturas_compra_items FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));

DROP POLICY IF EXISTS "pagos_cliente_todos" ON pagos_cliente;
CREATE POLICY "pagos_cliente_select" ON pagos_cliente FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));

DROP POLICY IF EXISTS "pagos_proveedor_todos" ON pagos_proveedor;
CREATE POLICY "pagos_proveedor_select" ON pagos_proveedor FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));

DROP POLICY IF EXISTS "pagos_proveedor_aplicaciones_todos" ON pagos_proveedor_aplicaciones;
CREATE POLICY "pagos_proveedor_aplicaciones_select" ON pagos_proveedor_aplicaciones FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));

DROP POLICY IF EXISTS "egresos_todos" ON egresos;
CREATE POLICY "egresos_select" ON egresos FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));

DROP POLICY IF EXISTS "retiros_caja_todos" ON retiros_caja;
CREATE POLICY "retiros_caja_select" ON retiros_caja FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));


-- ────────────────────────────────────────────────────────────────────────────────────────────
-- 3. listar_admins (#15): era SECURITY DEFINER sin validación y anon la ejecutaba.
--    Ahora exige perfil activo (la usa RegistrarRetiroModal en Local, con sesión).
--    CREATE OR REPLACE conserva los grants; el REVOKE de anon/PUBLIC va en el bloque 4.
-- ────────────────────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION listar_admins()
RETURNS TABLE(id uuid, nombre text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles p WHERE p.id = auth.uid() AND p.activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  RETURN QUERY
  SELECT p.id, p.nombre FROM perfiles p WHERE p.rol = 'admin' AND p.activo = true ORDER BY p.nombre;
END;
$function$;


-- ────────────────────────────────────────────────────────────────────────────────────────────
-- 4. anon sin acceso a nada de public (#17). anon sigue existiendo para el login (Auth no usa
--    public) y PostgREST le responde 401 a cualquier consulta.
-- ────────────────────────────────────────────────────────────────────────────────────────────

REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM anon;   -- incluye las vistas
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM anon;
-- EXECUTE de PUBLIC: anon lo heredaba. authenticated y service_role tienen grant propio.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;

-- Lo que se cree de ahora en más (por postgres, que es quien corre el SQL Editor).
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES    FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon;
-- El EXECUTE a PUBLIC de funciones nuevas es un default global (no por schema): se revoca global.
-- authenticated y service_role lo siguen recibiendo por el default de public.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
-- Nota: los defaults de supabase_admin en public no se pueden cambiar desde postgres. Si algún
-- día aparece un objeto de supabase_admin en public, revocarle anon a mano.


-- ────────────────────────────────────────────────────────────────────────────────────────────
-- 5. search_path fijo (#18).
-- ────────────────────────────────────────────────────────────────────────────────────────────

ALTER FUNCTION fn_auditoria_generica() SET search_path = public;
ALTER FUNCTION redondear_precio_venta(numeric) SET search_path = public;


-- ────────────────────────────────────────────────────────────────────────────────────────────
-- 6. revertir_movimiento: la reversión de un egreso ahora deshace también su movimiento de
--    cuenta (#6). Antes, revertir un egreso en efectivo/transferencia dejaba la cuenta con el
--    descuento aplicado.
--    Se espeja lo que el egreso original movió de verdad (movimientos_cuenta con su id como
--    referencia): cheque/echeq no movió nada y la reversión tampoco; si el mapeo
--    cuenta_forma_pago cambió desde entonces, se revierte en la cuenta original. El
--    contra-movimiento apunta al egreso de reversión (mismo criterio que registrar_egreso_general,
--    docs/37 K6).
--    El resto de la función queda igual a la versión en producción.
-- ────────────────────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.revertir_movimiento(p_auditoria_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_auditoria auditoria%ROWTYPE;
  v_row JSONB;
  v_pago_orig_id UUID;
  v_pago_rev_id UUID;
  v_monto NUMERIC;
  v_egreso egresos%ROWTYPE;
  v_egreso_rev_id UUID;  -- docs/38
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede revertir movimientos';
  END IF;

  SELECT * INTO v_auditoria FROM auditoria WHERE id = p_auditoria_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Acción no encontrada'; END IF;
  IF EXISTS (SELECT 1 FROM auditoria WHERE revierte_auditoria_id = p_auditoria_id) THEN
    RAISE EXCEPTION 'Esta acción ya fue revertida';
  END IF;

  v_row := v_auditoria.valores_nuevos;

  IF v_auditoria.tabla_afectada = 'movimientos_stock' THEN
    IF (v_row->>'tipo') <> 'ajuste' OR v_row->>'referencia_id' IS NOT NULL THEN
      RAISE EXCEPTION 'Solo se puede revertir un ajuste de stock manual (no una venta, compra, ni una reposición automática)';
    END IF;

    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, usuario_id)
    VALUES ((v_row->>'producto_id')::UUID, (v_row->>'ubicacion')::ubicacion_stock, 'ajuste',
            -1 * (v_row->>'cantidad')::NUMERIC, 'Reversión de ajuste (auditoría)', auth.uid());

    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES ((v_row->>'producto_id')::UUID, (v_row->>'ubicacion')::ubicacion_stock, -1 * (v_row->>'cantidad')::NUMERIC)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad - (v_row->>'cantidad')::NUMERIC;

  ELSIF v_auditoria.tabla_afectada = 'egresos' THEN
    INSERT INTO egresos (cierre_caja_id, origen, categoria, monto, descripcion, forma_pago, usuario_id, revierte_egreso_id)
    VALUES (NULLIF(v_row->>'cierre_caja_id','')::UUID, (v_row->>'origen')::origen_egreso, (v_row->>'categoria')::categoria_egreso,
            -1 * (v_row->>'monto')::NUMERIC, 'Reversión: ' || COALESCE(v_row->>'descripcion', ''),
            (v_row->>'forma_pago')::forma_pago_egreso, auth.uid(), (v_row->>'id')::UUID)
    RETURNING id INTO v_egreso_rev_id;

    -- docs/38: contra-movimiento de cuenta, espejo de lo que movió el egreso original.
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, referencia_id, usuario_id)
    SELECT mc.cuenta_id, mc.tipo, -1 * mc.monto, 'Reversión de egreso', v_egreso_rev_id, auth.uid()
    FROM movimientos_cuenta mc
    WHERE mc.referencia_id = (v_row->>'id')::UUID;

  ELSIF v_auditoria.tabla_afectada = 'pagos_proveedor' THEN
    v_pago_orig_id := (v_row->>'id')::UUID;
    v_monto := (v_row->>'monto')::NUMERIC;

    IF v_row->>'revierte_pago_proveedor_id' IS NOT NULL OR v_monto < 0 THEN
      RAISE EXCEPTION 'Esto ya es la reversión de un pago — no se revierte de nuevo';
    END IF;

    INSERT INTO pagos_proveedor (
      proveedor_id, factura_compra_id, monto, forma_pago, usuario_id, revierte_pago_proveedor_id,
      cheque_numero, cheque_fecha_salida, cheque_fecha_vencimiento, nota
    )
    VALUES (
      (v_row->>'proveedor_id')::UUID, NULLIF(v_row->>'factura_compra_id','')::UUID,
      -1 * v_monto, (v_row->>'forma_pago')::forma_pago_egreso, auth.uid(), v_pago_orig_id,
      v_row->>'cheque_numero', NULLIF(v_row->>'cheque_fecha_salida','')::DATE, NULLIF(v_row->>'cheque_fecha_vencimiento','')::DATE,
      'Reversión desde Historial'
    )
    RETURNING id INTO v_pago_rev_id;

    IF v_monto <> 0 THEN
      -- El egreso original, con su origen real (turno = caja de Local, general = Gestión).
      SELECT * INTO v_egreso FROM egresos
      WHERE pago_proveedor_id = v_pago_orig_id AND revierte_egreso_id IS NULL
      LIMIT 1;

      IF FOUND THEN
        INSERT INTO egresos (origen, categoria, monto, descripcion, forma_pago, usuario_id, revierte_egreso_id, pago_proveedor_id)
        VALUES (v_egreso.origen, 'pago_proveedor', -1 * v_monto, 'Reversión de pago a proveedor',
                v_egreso.forma_pago, auth.uid(), v_egreso.id, v_pago_rev_id);
      ELSE
        -- Pago anterior a docs/31 sin egreso vinculado (el backfill vinculó todos los que había).
        INSERT INTO egresos (origen, categoria, monto, descripcion, forma_pago, usuario_id, pago_proveedor_id)
        VALUES ('turno', 'pago_proveedor', -1 * v_monto, 'Reversión de pago a proveedor',
                (v_row->>'forma_pago')::forma_pago_egreso, auth.uid(), v_pago_rev_id);
      END IF;

      -- Y si era efectivo/transferencia, había impactado en movimientos_cuenta — se revierte igual.
      IF (v_row->>'forma_pago') IN ('efectivo', 'transferencia') THEN
        INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
        SELECT cuenta_id, 'pago_proveedor', abs(v_monto), v_pago_orig_id, auth.uid()
        FROM cuenta_forma_pago WHERE forma_pago = (v_row->>'forma_pago')::forma_pago_venta;
      END IF;
    END IF;

    -- Las aplicaciones de la operación (plata del pago y NC usadas en ese acto) dejan de contar:
    -- los comprobantes vuelven a su saldo anterior y la NC recupera su crédito.
    UPDATE pagos_proveedor_aplicaciones
    SET revertida_at = now(), revertida_por = auth.uid()
    WHERE operacion_id = v_pago_orig_id AND revertida_at IS NULL;

  ELSIF v_auditoria.tabla_afectada = 'pagos_cliente' THEN
    INSERT INTO pagos_cliente (cliente_id, venta_id, monto, forma_pago, usuario_id, revierte_pago_cliente_id)
    VALUES ((v_row->>'cliente_id')::UUID, NULLIF(v_row->>'venta_id','')::UUID,
            -1 * (v_row->>'monto')::NUMERIC, (v_row->>'forma_pago')::forma_pago_venta, auth.uid(), (v_row->>'id')::UUID);

    -- El pago original siempre impacta en movimientos_cuenta (registrar_pago_cliente, docs/06 RPC 10).
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
    SELECT cuenta_id, 'pago_cliente', -abs((v_row->>'monto')::NUMERIC), (v_row->>'id')::UUID, auth.uid()
    FROM cuenta_forma_pago WHERE forma_pago = (v_row->>'forma_pago')::forma_pago_venta;

  ELSIF v_auditoria.tabla_afectada = 'movimientos_cuenta' THEN
    -- Mismo efecto que eliminar_movimiento_cuenta (docs/06 RPC 13), disparado desde el Historial.
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, revierte_movimiento_id, usuario_id)
    VALUES ((v_row->>'cuenta_id')::UUID, (v_row->>'tipo')::tipo_movimiento_cuenta,
            -1 * (v_row->>'monto')::NUMERIC, 'Reversión desde Historial', (v_row->>'id')::UUID, auth.uid());

  ELSE
    RAISE EXCEPTION 'Este tipo de movimiento no se revierte desde acá';
  END IF;

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, usuario_id, revierte_auditoria_id, nota)
  VALUES (v_auditoria.tabla_afectada, v_auditoria.registro_id, 'reversion', v_auditoria.valores_nuevos, auth.uid(),
          p_auditoria_id, 'Reversión de movimiento (' || v_auditoria.tabla_afectada || ')');
END;
$function$;

COMMIT;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- BLOQUE 7 — Numeración desde 1. Correr AL FINAL, después de todas las pruebas.
--   Solo si la tabla está vacía; si ya hay ventas/devoluciones no toca nada.
-- ════════════════════════════════════════════════════════════════════════════════════════════

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM ventas) THEN
    ALTER SEQUENCE ventas_numero_seq RESTART WITH 1;
  ELSE
    RAISE NOTICE 'ventas tiene filas: ventas_numero_seq no se reinicia';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM devoluciones) THEN
    ALTER SEQUENCE devoluciones_numero_seq RESTART WITH 1;
  ELSE
    RAISE NOTICE 'devoluciones tiene filas: devoluciones_numero_seq no se reinicia';
  END IF;
END $$;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- VERIFICACIÓN (solo lectura)
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- V1. Nada de public accesible para anon (0 filas = OK).
SELECT 'tabla/vista' AS tipo, c.relname AS objeto FROM pg_class c
WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'v', 'm', 'p')
  AND (has_table_privilege('anon', c.oid, 'SELECT') OR has_table_privilege('anon', c.oid, 'INSERT')
       OR has_table_privilege('anon', c.oid, 'UPDATE') OR has_table_privilege('anon', c.oid, 'DELETE'))
UNION ALL
SELECT 'secuencia', c.relname FROM pg_class c
-- CASE: sin él, el planner puede evaluar has_sequence_privilege sobre algo que no es secuencia.
WHERE c.relnamespace = 'public'::regnamespace
  AND CASE WHEN c.relkind = 'S' THEN has_sequence_privilege('anon', c.oid, 'USAGE') ELSE false END
UNION ALL
SELECT 'función', p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' FROM pg_proc p
WHERE p.pronamespace = 'public'::regnamespace AND has_function_privilege('anon', p.oid, 'EXECUTE');

-- V2. Vistas: invoker en las de saldos, definer en las otras dos.
SELECT relname, reloptions FROM pg_class
WHERE relnamespace = 'public'::regnamespace AND relkind = 'v' ORDER BY relname;

-- V3. Las 12 tablas sin policy de escritura (0 filas = OK).
SELECT tablename, policyname, cmd FROM pg_policies
WHERE schemaname = 'public' AND cmd <> 'SELECT'
  AND tablename IN ('ventas', 'venta_items', 'venta_pagos', 'stock_ubicaciones', 'facturas_c',
                    'facturas_compra', 'facturas_compra_items', 'pagos_cliente', 'pagos_proveedor',
                    'pagos_proveedor_aplicaciones', 'egresos', 'retiros_caja');

-- V4. Próximos números (después del bloque 7: 1 y 1).
SELECT sequencename, CASE WHEN last_value IS NULL THEN start_value ELSE last_value + increment_by END AS proximo
FROM pg_sequences WHERE schemaname = 'public' AND sequencename IN ('ventas_numero_seq', 'devoluciones_numero_seq');
