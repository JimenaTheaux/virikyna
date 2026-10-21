-- 54 — Borradores (fase 1: factura de compra / nota de crédito)
--
-- ⏳ NO APLICADO todavía. Correr desde la raíz del repo con
-- `npx supabase db query --linked -f docs/54_borradores.sql` (o en el SQL Editor del proyecto
-- ccpinvtleqlsukcqnili), después de 53. La PARTE A va una sola vez; la PARTE B (verificación) y la
-- PARTE C (test, BEGIN … ROLLBACK) se pueden repetir.
--
-- Contexto: diagnóstico del 2026-10-21 (opción B, tabla genérica). Una factura a medio cargar se
-- perdía al cerrar el modal, la app o con un corte de luz. Un borrador NO toca nada del negocio
-- (stock, costos, saldos, caja): es solo el formulario guardado como JSON. Todo se valida y aplica
-- recién al confirmar, con el mismo cargar_factura_compra de siempre.
--
-- Qué hace:
--   1. Tabla borradores: tipo ('factura_compra'; fase 2 suma los demás formularios), sistema
--      ('local' | 'gestion' | 'inventario'), payload jsonb, resumen (para el listado), autor,
--      último editor, fechas y version (control optimista: el UPDATE de la app filtra por la
--      version que leyó; si otro guardó antes, no actualiza nada y la app avisa).
--      Un trigger fija autor/fechas/version y deja inmutables id, tipo, sistema, autor y alta.
--      SIN trigger de auditoría a propósito: el autoguardado la inundaría.
--   2. RLS: leer, cualquier perfil activo. Escribir (alta, cambio, baja), cualquier perfil activo
--      desde el sistema donde se creó: chequeo blando con el header x-virikyna-app que mandan las
--      apps (app_cliente()). Sin header (SQL Editor, apps viejas) no se frena: no es seguridad, es
--      que una app no pise borradores de otra. anon no tiene acceso.
--   3. cargar_factura_compra(…, p_borrador_id uuid DEFAULT NULL): borra el borrador en la misma
--      transacción; si ya no existe, falla sin cargar nada. Sin el parámetro, igual que hoy.
--      Agregar un parámetro cambia la firma: DROP + CREATE + grants (patrón docs/45 y docs/53).

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios (una sola vez)
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ─── app_cliente(): de qué app viene la llamada (header de PostgREST) ─────────────────────────
CREATE OR REPLACE FUNCTION public.app_cliente()
RETURNS text
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT NULLIF(current_setting('request.headers', true), '')::json ->> 'x-virikyna-app'
$$;

COMMENT ON FUNCTION public.app_cliente() IS
  'Header x-virikyna-app de la llamada (local | gestion | inventario), o NULL fuera de las apps. Chequeo blando de borradores, no es seguridad. docs/54.';

REVOKE ALL ON FUNCTION public.app_cliente() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.app_cliente() TO authenticated, service_role;

-- ─── Tabla ────────────────────────────────────────────────────────────────────────────────────
CREATE TABLE public.borradores (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo TEXT NOT NULL CHECK (tipo IN ('factura_compra')),
  sistema TEXT NOT NULL CHECK (sistema IN ('local', 'gestion', 'inventario')),
  payload JSONB NOT NULL CHECK (jsonb_typeof(payload) = 'object' AND octet_length(payload::text) <= 500000),
  resumen TEXT,
  usuario_id UUID NOT NULL DEFAULT auth.uid() REFERENCES public.perfiles(id),
  actualizado_por UUID NOT NULL DEFAULT auth.uid() REFERENCES public.perfiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  version INTEGER NOT NULL DEFAULT 1
);

COMMENT ON TABLE public.borradores IS
  'Formularios a medio cargar (docs/54). No modifican nada del negocio: se aplican recién al confirmar. Sin auditoría a propósito.';

CREATE INDEX idx_borradores_tipo_updated ON public.borradores (tipo, updated_at DESC);

CREATE OR REPLACE FUNCTION public.borradores_mantener()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.usuario_id := COALESCE(auth.uid(), NEW.usuario_id);
    NEW.actualizado_por := NEW.usuario_id;
    NEW.created_at := now();
    NEW.updated_at := now();
    NEW.version := 1;
  ELSE
    NEW.id := OLD.id;
    NEW.tipo := OLD.tipo;
    NEW.sistema := OLD.sistema;
    NEW.usuario_id := OLD.usuario_id;
    NEW.created_at := OLD.created_at;
    NEW.actualizado_por := COALESCE(auth.uid(), NEW.actualizado_por);
    NEW.updated_at := now();
    NEW.version := OLD.version + 1;
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.borradores_mantener() IS
  'Trigger (borradores): autor, fechas y version los pone la base; id, tipo, sistema, autor y alta no cambian. docs/54.';

REVOKE EXECUTE ON FUNCTION public.borradores_mantener() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_borradores_mantener
  BEFORE INSERT OR UPDATE ON public.borradores
  FOR EACH ROW EXECUTE FUNCTION public.borradores_mantener();

-- ─── RLS ──────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.borradores ENABLE ROW LEVEL SECURITY;

CREATE POLICY borradores_select ON public.borradores FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = (SELECT auth.uid()) AND perfiles.activo = true));

CREATE POLICY borradores_insert ON public.borradores FOR INSERT WITH CHECK (
  EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = (SELECT auth.uid()) AND perfiles.activo = true)
  AND usuario_id = (SELECT auth.uid())
  AND (app_cliente() IS NULL OR app_cliente() = sistema));

CREATE POLICY borradores_update ON public.borradores FOR UPDATE
  USING (
    EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = (SELECT auth.uid()) AND perfiles.activo = true)
    AND (app_cliente() IS NULL OR app_cliente() = sistema))
  WITH CHECK (
    EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = (SELECT auth.uid()) AND perfiles.activo = true)
    AND (app_cliente() IS NULL OR app_cliente() = sistema));

CREATE POLICY borradores_delete ON public.borradores FOR DELETE USING (
  EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = (SELECT auth.uid()) AND perfiles.activo = true)
  AND (app_cliente() IS NULL OR app_cliente() = sistema));

-- Los default privileges de Supabase dan todo a anon y authenticated: se deja solo lo necesario.
REVOKE ALL ON TABLE public.borradores FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.borradores TO authenticated;
GRANT ALL ON TABLE public.borradores TO service_role;

-- ─── cargar_factura_compra: + p_borrador_id ───────────────────────────────────────────────────
DROP FUNCTION public.cargar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date, forma_pago_compra, jsonb, uuid, numeric, text);

CREATE FUNCTION public.cargar_factura_compra(p_proveedor_id uuid, p_tipo_comprobante tipo_comprobante_compra, p_letra letra_comprobante_compra, p_punto_venta text, p_numero_comprobante text, p_fecha_comprobante date, p_fecha_fiscal date, p_forma_pago forma_pago_compra, p_items jsonb, p_copiada_de_id uuid DEFAULT NULL::uuid, p_iva_alicuota numeric DEFAULT 21, p_tipo_compra text DEFAULT 'articulos'::text, p_borrador_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_factura_id UUID;
  v_item JSONB;
  v_precio_total_sin_iva NUMERIC;
  v_total_sin_iva NUMERIC := 0;
  v_iva NUMERIC;
  v_total NUMERIC;
  v_producto_id UUID;
  v_producto_proveedor_id UUID;
  v_actualiza_costo BOOLEAN := p_tipo_comprobante NOT IN ('nota_credito', 'nota_debito');
  v_row RECORD;
  v_costo_actual NUMERIC;
  v_costo_nuevo NUMERIC;
  v_costo_linea NUMERIC;     -- docs/45
  v_cambia_proveedor BOOLEAN;
  v_precio_manual NUMERIC;   -- docs/34
  v_pone_costo BOOLEAN;      -- docs/34
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  -- docs/54: confirmar un borrador lo elimina en la misma transacción. Va primero: si dos personas
  -- confirman el mismo borrador a la vez, la segunda espera el lock de la fila, no la encuentra y
  -- no se carga la factura dos veces. Si algo de abajo falla, el borrador vuelve con el ROLLBACK.
  IF p_borrador_id IS NOT NULL THEN
    DELETE FROM borradores WHERE id = p_borrador_id AND tipo = 'factura_compra';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'El borrador ya no existe: otro usuario lo confirmó o lo eliminó';
    END IF;
  END IF;

  -- docs/45: solo 21 o exento. El CHECK de la tabla también lo frena; esto da un mensaje legible.
  IF p_iva_alicuota IS NULL OR p_iva_alicuota NOT IN (0, 21) THEN
    RAISE EXCEPTION 'Alícuota de IVA inválida: tiene que ser 21 %% o exento (0)';
  END IF;

  -- docs/53: tipo de compra válido; en servicios ningún ítem lleva producto y la cantidad es 1.
  -- Sin esto, un payload armado a mano con producto_id movería stock y costo desde un servicio.
  IF p_tipo_compra IS NULL OR p_tipo_compra NOT IN ('articulos', 'servicios') THEN
    RAISE EXCEPTION 'Tipo de compra inválido: tiene que ser artículos o servicios';
  END IF;
  IF p_tipo_compra = 'servicios' THEN
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) AS i WHERE NULLIF(i->>'producto_id', '') IS NOT NULL) THEN
      RAISE EXCEPTION 'Una factura de servicios no lleva productos del inventario';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) AS i WHERE (i->>'cantidad')::NUMERIC IS DISTINCT FROM 1) THEN
      RAISE EXCEPTION 'En una factura de servicios cada ítem va con cantidad 1';
    END IF;
  END IF;

  -- docs/33: la FK ya lo garantiza; esto da un mensaje legible en vez del error de constraint.
  IF p_copiada_de_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM facturas_compra WHERE id = p_copiada_de_id) THEN
    RAISE EXCEPTION 'La factura que se quiso copiar no existe';
  END IF;

  SELECT COALESCE(SUM((i->>'cantidad')::NUMERIC * (i->>'precio_unitario_sin_iva')::NUMERIC
           * (1 - COALESCE((i->>'descuento_porcentaje')::NUMERIC,0)/100.0)), 0)
  INTO v_total_sin_iva
  FROM jsonb_array_elements(p_items) AS i;

  v_iva := ROUND(v_total_sin_iva * p_iva_alicuota / 100, 2);  -- docs/45 (antes: × 0.21 fijo)
  v_total := v_total_sin_iva + v_iva;

  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, letra, punto_venta, numero_comprobante,
         fecha_comprobante, fecha_fiscal, forma_pago, total_sin_iva, iva, total, usuario_id, copiada_de_id,
         iva_alicuota,  -- docs/45
         tipo_compra)   -- docs/53
  VALUES (p_proveedor_id, p_tipo_comprobante, p_letra, p_punto_venta, p_numero_comprobante,
         p_fecha_comprobante, p_fecha_fiscal, p_forma_pago, v_total_sin_iva, v_iva, v_total, auth.uid(), p_copiada_de_id,
         p_iva_alicuota,
         p_tipo_compra)
  RETURNING id INTO v_factura_id;

  -- Ítems y stock, línea por línea (igual que docs/13)
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_precio_total_sin_iva := ROUND((v_item->>'cantidad')::NUMERIC * (v_item->>'precio_unitario_sin_iva')::NUMERIC
                              * (1 - COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0)/100.0), 2);

    INSERT INTO facturas_compra_items (factura_compra_id, producto_id, descripcion, cantidad,
           precio_unitario_sin_iva, descuento_porcentaje, precio_total_sin_iva, ubicacion)
    VALUES (v_factura_id, NULLIF(v_item->>'producto_id','')::UUID, v_item->>'descripcion',
           (v_item->>'cantidad')::NUMERIC, (v_item->>'precio_unitario_sin_iva')::NUMERIC,
           COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0), v_precio_total_sin_iva,
           COALESCE((v_item->>'ubicacion')::ubicacion_stock, 'local'));

    v_producto_id := NULLIF(v_item->>'producto_id','')::UUID;

    IF v_producto_id IS NOT NULL THEN
      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, referencia_id, usuario_id)
      VALUES (v_producto_id, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'),
             'compra', (v_item->>'cantidad')::NUMERIC, v_factura_id, auth.uid());

      INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
      VALUES (v_producto_id, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'), (v_item->>'cantidad')::NUMERIC)
      ON CONFLICT (producto_id, ubicacion)
      DO UPDATE SET cantidad = stock_ubicaciones.cantidad + (v_item->>'cantidad')::NUMERIC;
    END IF;
  END LOOP;

  -- Producto: proveedor/márgenes (docs/13) + costo. Una pasada por producto, con el precio de su
  -- ÚLTIMA línea en la factura (DISTINCT ON + ORDER BY ord DESC).
  FOR v_row IN
    SELECT DISTINCT ON (x.producto_id) x.producto_id, x.precio, x.descuento
    FROM (
      SELECT NULLIF(t.i->>'producto_id','')::UUID AS producto_id,
             (t.i->>'precio_unitario_sin_iva')::NUMERIC AS precio,
             COALESCE((t.i->>'descuento_porcentaje')::NUMERIC, 0) AS descuento,  -- docs/45
             t.ord
      FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(i, ord)
    ) x
    WHERE x.producto_id IS NOT NULL
    ORDER BY x.producto_id, x.ord DESC
  LOOP
    SELECT proveedor_id, costo, precio_manual INTO v_producto_proveedor_id, v_costo_actual, v_precio_manual  -- docs/34
    FROM productos WHERE id = v_row.producto_id FOR UPDATE;

    -- docs/45: el costo es el precio unitario sin IVA con el descuento de la línea ya aplicado.
    v_costo_linea := ROUND(v_row.precio * (1 - v_row.descuento / 100.0), 2);

    -- Producto sin proveedor (null): IS DISTINCT FROM da true → toma proveedor y márgenes default.
    v_cambia_proveedor := v_producto_proveedor_id IS DISTINCT FROM p_proveedor_id;
    -- docs/34: la factura le pone costo (no NC/ND, costo > 0). Desde ahí el precio sale de la fórmula.
    v_pone_costo := v_actualiza_costo AND v_costo_linea > 0;  -- docs/45: costo con descuento
    v_costo_nuevo := CASE WHEN v_pone_costo
                          THEN v_costo_linea ELSE v_costo_actual END;

    IF v_cambia_proveedor OR v_costo_nuevo IS DISTINCT FROM v_costo_actual
       OR (v_pone_costo AND v_precio_manual IS NOT NULL) THEN  -- docs/34
      IF v_cambia_proveedor THEN
        PERFORM set_config('virikyna.margen_auto_herencia', 'true', true);
      END IF;

      UPDATE productos
      SET proveedor_id = p_proveedor_id,
          margen_1 = CASE WHEN v_cambia_proveedor
                          THEN (SELECT margen_1_default FROM proveedores WHERE id = p_proveedor_id)
                          ELSE margen_1 END,
          margen_2 = CASE WHEN v_cambia_proveedor
                          THEN (SELECT margen_2_default FROM proveedores WHERE id = p_proveedor_id)
                          ELSE margen_2 END,
          costo = v_costo_nuevo,
          precio_manual = CASE WHEN v_pone_costo THEN NULL ELSE precio_manual END,  -- docs/34
          updated_at = now()
      WHERE id = v_row.producto_id;

      IF v_cambia_proveedor THEN
        PERFORM set_config('virikyna.margen_auto_herencia', 'false', true);
      END IF;
    END IF;
  END LOOP;

  RETURN v_factura_id;
END;
$function$;


REVOKE ALL ON FUNCTION public.cargar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date, forma_pago_compra, jsonb, uuid, numeric, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cargar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date, forma_pago_compra, jsonb, uuid, numeric, text, uuid) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (solo lectura)
-- Esperado: 1 firma de cargar_factura_compra (con uuid al final) sin anon; tabla con RLS y 4
-- políticas; authenticated solo con SELECT/INSERT/UPDATE/DELETE; anon sin nada; sin triggers de
-- auditoría en borradores.
-- ════════════════════════════════════════════════════════════════════════════════════════════
SELECT 'firma' AS chequeo, p.oid::regprocedure::text AS valor, array_to_string(p.proacl, ',') AS detalle
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('cargar_factura_compra', 'app_cliente', 'borradores_mantener')
UNION ALL
SELECT 'rls', relrowsecurity::text, (SELECT string_agg(polname, ',' ORDER BY polname) FROM pg_policy WHERE polrelid = c.oid)
FROM pg_class c WHERE c.oid = 'public.borradores'::regclass
UNION ALL
SELECT 'grants ' || grantee, string_agg(privilege_type, ',' ORDER BY privilege_type), NULL
FROM information_schema.role_table_grants
WHERE table_schema = 'public' AND table_name = 'borradores' AND grantee IN ('anon', 'authenticated')
GROUP BY grantee
UNION ALL
SELECT 'triggers', string_agg(tgname, ',' ORDER BY tgname), NULL
FROM pg_trigger WHERE tgrelid = 'public.borradores'::regclass AND NOT tgisinternal;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (no deja nada: BEGIN … ROLLBACK)
-- Corre como un admin activo, la mayor parte con el rol authenticated (RLS de verdad) y el header
-- x-virikyna-app simulado. Resultado: una tabla, todo ok = true.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

SELECT set_config('request.jwt.claims',
                  json_build_object('sub', (SELECT id FROM perfiles WHERE activo AND rol = 'admin' ORDER BY created_at LIMIT 1),
                                    'role', 'authenticated')::text, true);

CREATE TEMP TABLE t54 (orden int, caso text, ok boolean, detalle text) ON COMMIT DROP;
GRANT ALL ON t54 TO authenticated, anon;

DO $test$
DECLARE
  v_prov uuid := (SELECT id FROM proveedores ORDER BY razon_social LIMIT 1);
  v_yo uuid := auth.uid();
  v_b uuid;
  v_b2 uuid;
  v_f uuid;
  v_row borradores%ROWTYPE;
  v_n int;
  v_saldo0 numeric;
  v_items jsonb := '[{"producto_id": null, "descripcion": "test 54", "cantidad": 1, "precio_unitario_sin_iva": 100}]';
BEGIN
  SELECT saldo_actual INTO v_saldo0 FROM proveedores_saldo WHERE id = v_prov;
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_config('request.headers', '{"x-virikyna-app": "gestion"}', true);

  -- 1. Alta desde Gestión: la base pone autor, version 1 (aunque la app mande otra cosa).
  INSERT INTO borradores (tipo, sistema, payload, resumen, version, usuario_id)
  VALUES ('factura_compra', 'gestion', '{"proveedorId": "x"}', 'test 54', 99, v_yo)
  RETURNING * INTO v_row;
  v_b := v_row.id;
  INSERT INTO t54 VALUES (1, 'alta: version 1, autor = yo',
    v_row.version = 1 AND v_row.usuario_id = v_yo AND v_row.actualizado_por = v_yo, format('v%s', v_row.version));

  -- 2. Edición con la version leída: pasa a 2. Intentar cambiar sistema/tipo no cambia nada.
  UPDATE borradores SET payload = '{"proveedorId": "y"}', sistema = 'local', version = 1
  WHERE id = v_b AND version = 1 RETURNING * INTO v_row;
  INSERT INTO t54 VALUES (2, 'edición: version 2, sistema fijo',
    v_row.version = 2 AND v_row.sistema = 'gestion' AND v_row.payload ->> 'proveedorId' = 'y', format('v%s %s', v_row.version, v_row.sistema));

  -- 3. Control optimista: un UPDATE con la version vieja no actualiza nada.
  UPDATE borradores SET payload = '{"proveedorId": "z"}' WHERE id = v_b AND version = 1;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  INSERT INTO t54 VALUES (3, 'version vieja: 0 filas', v_n = 0, format('%s filas', v_n));

  -- 4. Desde Local: lo ve, pero no lo cambia ni lo borra.
  PERFORM set_config('request.headers', '{"x-virikyna-app": "local"}', true);
  SELECT count(*) INTO v_n FROM borradores WHERE id = v_b;
  UPDATE borradores SET resumen = 'pisado' WHERE id = v_b;
  DELETE FROM borradores WHERE id = v_b;
  INSERT INTO t54 SELECT 4, 'otro sistema: ve 1, no cambia ni borra',
    v_n = 1 AND resumen = 'test 54' AND version = 2, format('ve %s resumen %s', v_n, resumen)
  FROM borradores WHERE id = v_b;

  -- 5. Alta desde Local de un borrador "de Gestión": rechazada por RLS.
  BEGIN
    INSERT INTO borradores (tipo, sistema, payload) VALUES ('factura_compra', 'gestion', '{}');
    INSERT INTO t54 VALUES (5, 'alta con sistema ajeno rechazada', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t54 VALUES (5, 'alta con sistema ajeno rechazada', SQLSTATE = '42501', SQLERRM);
  END;

  -- 6. Confirmar desde Gestión con p_borrador_id: factura creada y borrador eliminado.
  PERFORM set_config('request.headers', '{"x-virikyna-app": "gestion"}', true);
  v_f := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
           p_punto_venta => '9999', p_numero_comprobante => 'T54-6', p_fecha_comprobante => current_date,
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente', p_items => v_items,
           p_iva_alicuota => 0, p_borrador_id => v_b);
  INSERT INTO t54 SELECT 6, 'confirmar: factura creada, borrador eliminado',
    EXISTS (SELECT 1 FROM facturas_compra WHERE id = v_f) AND NOT EXISTS (SELECT 1 FROM borradores WHERE id = v_b), NULL;

  -- 7. Confirmar otra vez el mismo borrador: rechazado, sin segunda factura.
  BEGIN
    PERFORM cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
             p_punto_venta => '9999', p_numero_comprobante => 'T54-7', p_fecha_comprobante => current_date,
             p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente', p_items => v_items,
             p_iva_alicuota => 0, p_borrador_id => v_b);
    INSERT INTO t54 VALUES (7, 'segunda confirmación rechazada', false, 'no dio error');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t54 SELECT 7, 'segunda confirmación rechazada',
      SQLERRM LIKE 'El borrador ya no existe%' AND NOT EXISTS (SELECT 1 FROM facturas_compra WHERE numero_comprobante = 'T54-7'), SQLERRM;
  END;

  -- 8. Factura con error de validación + borrador: el borrador no se pierde.
  INSERT INTO borradores (tipo, sistema, payload) VALUES ('factura_compra', 'gestion', '{}') RETURNING id INTO v_b2;
  BEGIN
    PERFORM cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
             p_punto_venta => '9999', p_numero_comprobante => 'T54-8', p_fecha_comprobante => current_date,
             p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente', p_items => v_items,
             p_iva_alicuota => 10.5, p_borrador_id => v_b2);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO t54 SELECT 8, 'factura rechazada: el borrador sigue', EXISTS (SELECT 1 FROM borradores WHERE id = v_b2), NULL;

  -- 9. Llamada sin p_borrador_id (apps de antes): carga igual.
  v_f := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
           p_punto_venta => '9999', p_numero_comprobante => 'T54-9', p_fecha_comprobante => current_date,
           p_fecha_fiscal => NULL, p_forma_pago => 'cuenta_corriente', p_items => v_items, p_iva_alicuota => 0);
  INSERT INTO t54 SELECT 9, 'sin p_borrador_id: carga como antes', EXISTS (SELECT 1 FROM facturas_compra WHERE id = v_f), NULL;

  -- 10. Sin header (SQL Editor / app vieja): no se frena.
  PERFORM set_config('request.headers', '', true);
  UPDATE borradores SET resumen = 'sin header' WHERE id = v_b2;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  INSERT INTO t54 VALUES (10, 'sin header: se puede editar', v_n = 1, format('%s filas', v_n));

  -- 11. Un borrador no toca el saldo: solo cuentan las 2 facturas confirmadas (100 + 100).
  INSERT INTO t54 SELECT 11, 'saldo: solo las facturas confirmadas (+200)',
    saldo_actual - v_saldo0 = 200, format('delta %s', saldo_actual - v_saldo0)
  FROM proveedores_saldo WHERE id = v_prov;

  -- 12. anon no ve ni escribe.
  EXECUTE 'SET LOCAL ROLE anon';
  BEGIN
    SELECT count(*) INTO v_n FROM borradores;
    INSERT INTO t54 VALUES (12, 'anon sin acceso', false, format('ve %s', v_n));
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO t54 VALUES (12, 'anon sin acceso', SQLSTATE = '42501', SQLERRM);
  END;
  EXECUTE 'RESET ROLE';
END
$test$;

SELECT * FROM t54 ORDER BY orden;

ROLLBACK;
