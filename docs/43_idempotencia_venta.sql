-- 43 — Idempotencia de confirmar_venta (un cobro reintentado nunca crea dos ventas)
--
-- docs/06_estructura_de_datos.md, sección "ventas.client_id", tiene el detalle. Correr desde la raíz
-- del repo con `npx supabase db query --linked -f docs/43_idempotencia_venta.sql` (o en el SQL Editor
-- del proyecto ccpinvtleqlsukcqnili), después de 42. La PARTE A va una sola vez; la PARTE B
-- (verificación) y la PARTE C (test, BEGIN … ROLLBACK) se pueden repetir.
--
-- Contexto (relevado contra la base real el 2026-10-13):
--   - confirmar_venta ya tiene el snapshot de docs/42 aplicado (pg_get_functiondef). El cuerpo de
--     abajo es ese, copiado tal cual, + p_client_id.
--   - Grants actuales: EXECUTE para authenticated y service_role, sin PUBLIC ni anon.
--   - El único que llama a confirmar_venta es Ventas de Virikyna Local (VentasPage.tsx).
--   - El problema: Local graba la venta y recién después saca el ticket de la barra. Si la app se
--     recarga, se cierra o pierde la respuesta del RPC en el medio, la venta queda grabada pero el
--     ticket sigue ahí — y se puede volver a cobrar.
--
-- Qué hace:
--   1. ventas.client_id (text, null): identificador del intento de cobro que manda la app
--      (`<ticket.id>:<n° de intento>`). Índice único parcial (solo filas con valor): las ventas
--      viejas y las que no lo mandan quedan en null y no chocan entre sí.
--   2. confirmar_venta(…, p_client_id text DEFAULT NULL):
--      - Si ya existe una venta con ese client_id, devuelve su id sin tocar nada (ni stock, ni
--        pagos, ni ítems). Reintentar con el mismo id es seguro.
--      - Dos llamadas simultáneas con el mismo id: el INSERT usa ON CONFLICT DO NOTHING sobre el
--        índice único, la segunda espera a que la primera termine y devuelve la misma venta.
--      - Sin p_client_id se comporta exactamente como antes.
--      Agregar un parámetro cambia la firma: CREATE OR REPLACE crearía una sobrecarga, así que va
--      DROP + CREATE y se vuelven a poner los grants (authenticated y service_role, como antes).

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios (una sola vez)
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

ALTER TABLE public.ventas ADD COLUMN IF NOT EXISTS client_id TEXT;

ALTER TABLE public.ventas DROP CONSTRAINT IF EXISTS ventas_client_id_largo;
ALTER TABLE public.ventas ADD CONSTRAINT ventas_client_id_largo CHECK (char_length(client_id) <= 100);

CREATE UNIQUE INDEX IF NOT EXISTS ventas_client_id_unico ON public.ventas (client_id) WHERE client_id IS NOT NULL;

COMMENT ON COLUMN public.ventas.client_id IS
  'Id del intento de cobro generado por Virikyna Local (<ticket>:<intento>). Único: un reintento con el mismo id devuelve la venta ya creada. docs/43.';

DROP FUNCTION public.confirmar_venta(uuid, forma_pago_venta, jsonb, numeric, text, numeric, jsonb, numeric);

CREATE FUNCTION public.confirmar_venta(p_cliente_id uuid, p_forma_pago forma_pago_venta, p_items jsonb, p_descuento_porcentaje numeric DEFAULT 0, p_nota text DEFAULT NULL::text, p_recargo_porcentaje numeric DEFAULT 0, p_pagos jsonb DEFAULT NULL::jsonb, p_precio_cobrado numeric DEFAULT NULL::numeric, p_client_id text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_venta_id UUID;
  v_item JSONB;
  v_pago JSONB;
  v_subtotal NUMERIC := 0;
  v_precio_oficial NUMERIC;
  v_precio_cobrado NUMERIC;
  v_ratio NUMERIC;
  v_importe NUMERIC;
  v_forma_pago_final forma_pago_venta;
  v_suma_pagos NUMERIC;
  v_suma_ajustada NUMERIC := 0;
  v_monto_ajustado NUMERIC;
  v_idx INT := 0;
  v_nombre TEXT;  -- docs/42
  v_marca TEXT;   -- docs/42
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  -- docs/43: reintento de un cobro que ya se grabó → la misma venta, sin volver a mover nada.
  IF p_client_id IS NOT NULL THEN
    SELECT id INTO v_venta_id FROM ventas WHERE client_id = p_client_id;
    IF FOUND THEN
      RETURN v_venta_id;
    END IF;
  END IF;

  SELECT COALESCE(SUM((i->>'cantidad')::NUMERIC * (i->>'precio_unitario')::NUMERIC
           * (1 - COALESCE((i->>'descuento_porcentaje')::NUMERIC,0)/100.0)), 0)
  INTO v_subtotal
  FROM jsonb_array_elements(p_items) AS i;

  v_precio_oficial := ROUND(v_subtotal * (1 - COALESCE(p_descuento_porcentaje,0)/100.0)
                    * (1 + COALESCE(p_recargo_porcentaje,0)/100.0), 2);

  IF p_pagos IS NOT NULL AND jsonb_array_length(p_pagos) > 0 THEN
    IF jsonb_array_length(p_pagos) > 2 THEN
      RAISE EXCEPTION 'Un pago combinado admite hasta 2 medios de pago';
    END IF;
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_pagos) AS p
      WHERE (p->>'forma_pago') IN ('cuenta_corriente', 'combinado')
    ) THEN
      RAISE EXCEPTION 'La cuenta corriente no puede combinarse con otro medio de pago';
    END IF;
    -- La validación de la suma se hace contra el precio OFICIAL: es el monto con el que se armó
    -- el reparto en PagoCombinadoModal, antes de que el cajero edite el precio final a cobrar.
    SELECT COALESCE(SUM((p->>'monto')::NUMERIC), 0) INTO v_suma_pagos FROM jsonb_array_elements(p_pagos) AS p;
    IF ROUND(v_suma_pagos, 2) <> v_precio_oficial THEN
      RAISE EXCEPTION 'La suma de los pagos (%) no coincide con el total de la venta (%)', v_suma_pagos, v_precio_oficial;
    END IF;
    v_forma_pago_final := CASE WHEN jsonb_array_length(p_pagos) = 1
      THEN (p_pagos->0->>'forma_pago')::forma_pago_venta
      ELSE 'combinado'::forma_pago_venta END;
  ELSE
    v_forma_pago_final := p_forma_pago;
  END IF;

  -- Corregido en QA: mensaje claro antes de chocar con el CHECK del schema
  IF v_forma_pago_final = 'cuenta_corriente' AND p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'Una venta a cuenta corriente necesita un cliente asignado';
  END IF;

  v_precio_cobrado := COALESCE(p_precio_cobrado, v_precio_oficial);
  IF v_precio_cobrado <= 0 THEN
    RAISE EXCEPTION 'El precio final a cobrar debe ser mayor a 0';
  END IF;

  INSERT INTO ventas (cliente_id, forma_pago, subtotal, descuento_porcentaje, recargo_porcentaje, total,
         precio_oficial, precio_cobrado, nota, usuario_id, client_id)
  VALUES (p_cliente_id, v_forma_pago_final, v_subtotal, COALESCE(p_descuento_porcentaje,0),
          COALESCE(p_recargo_porcentaje,0), v_precio_cobrado, v_precio_oficial, v_precio_cobrado, p_nota, auth.uid(),
          p_client_id)
  ON CONFLICT (client_id) WHERE client_id IS NOT NULL DO NOTHING
  RETURNING id INTO v_venta_id;

  -- docs/43: otra llamada con el mismo client_id la grabó mientras esta esperaba el índice único.
  IF v_venta_id IS NULL THEN
    SELECT id INTO v_venta_id FROM ventas WHERE client_id = p_client_id;
    RETURN v_venta_id;
  END IF;

  IF v_forma_pago_final <> 'cuenta_corriente' THEN
    IF p_pagos IS NOT NULL AND jsonb_array_length(p_pagos) > 0 THEN
      -- Reescala cada parte al precio cobrado, manteniendo la proporción del reparto original —
      -- la última parte absorbe el centavo de redondeo para que la suma dé exacta.
      v_ratio := CASE WHEN v_precio_oficial = 0 THEN 1 ELSE v_precio_cobrado / v_precio_oficial END;
      FOR v_pago IN SELECT * FROM jsonb_array_elements(p_pagos)
      LOOP
        v_idx := v_idx + 1;
        IF v_idx = jsonb_array_length(p_pagos) THEN
          v_monto_ajustado := v_precio_cobrado - v_suma_ajustada;
        ELSE
          v_monto_ajustado := ROUND((v_pago->>'monto')::NUMERIC * v_ratio, 2);
          v_suma_ajustada := v_suma_ajustada + v_monto_ajustado;
        END IF;
        INSERT INTO venta_pagos (venta_id, forma_pago, monto, usuario_id)
        VALUES (v_venta_id, (v_pago->>'forma_pago')::forma_pago_venta, v_monto_ajustado, auth.uid());
      END LOOP;
    ELSE
      INSERT INTO venta_pagos (venta_id, forma_pago, monto, usuario_id)
      VALUES (v_venta_id, v_forma_pago_final, v_precio_cobrado, auth.uid());
    END IF;
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_importe := ROUND((v_item->>'cantidad')::NUMERIC * (v_item->>'precio_unitario')::NUMERIC
                 * (1 - COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0)/100.0), 2);

    -- docs/42: snapshot de nombre y marca. Si el producto no existe, la FK del INSERT lo frena igual.
    SELECT nombre, marca INTO v_nombre, v_marca FROM productos WHERE id = (v_item->>'producto_id')::UUID;

    INSERT INTO venta_items (venta_id, producto_id, cantidad, precio_unitario, descuento_porcentaje, importe,
                             producto_nombre, producto_marca)
    VALUES (v_venta_id, (v_item->>'producto_id')::UUID, (v_item->>'cantidad')::NUMERIC,
            (v_item->>'precio_unitario')::NUMERIC, COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0), v_importe,
            v_nombre, v_marca);

    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, referencia_id, usuario_id)
    VALUES ((v_item->>'producto_id')::UUID, 'local', 'venta', -1 * (v_item->>'cantidad')::NUMERIC, v_venta_id, auth.uid());

    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES ((v_item->>'producto_id')::UUID, 'local', -1 * (v_item->>'cantidad')::NUMERIC)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad - (v_item->>'cantidad')::NUMERIC;
  END LOOP;

  RETURN v_venta_id;
END;
$function$;

-- Una función nueva nace con EXECUTE para PUBLIC: se saca y se deja como estaba.
REVOKE ALL ON FUNCTION public.confirmar_venta(uuid, forma_pago_venta, jsonb, numeric, text, numeric, jsonb, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirmar_venta(uuid, forma_pago_venta, jsonb, numeric, text, numeric, jsonb, numeric, text) TO authenticated, service_role;

COMMIT;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (se puede repetir)
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- B1. Una sola confirmar_venta, con p_client_id.
SELECT pg_get_function_identity_arguments(p.oid) AS argumentos
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'confirmar_venta';

-- B2. Grants: authenticated y service_role sí, anon no.
SELECT has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon,
       has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'confirmar_venta';

-- B3. Columna e índice único parcial.
SELECT column_name, data_type, is_nullable FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'ventas' AND column_name = 'client_id';
SELECT indexdef FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'ventas_client_id_unico';


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (no deja nada: BEGIN … ROLLBACK)
-- ⚠ confirmar_venta consume ventas.numero aunque se haga ROLLBACK (las secuencias no vuelven
--   atrás): el próximo número real salta uno por cada venta creada acá (3). Con ventas reales en la
--   base, no correrla (igual que la PARTE C de docs/42; ver docs/06, sección 25, "Numeración").
-- Resultado: una sola tabla con todas las filas ok = true.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

SELECT set_config('request.jwt.claims',
                  json_build_object('sub', (SELECT id FROM perfiles WHERE activo AND rol = 'admin' LIMIT 1),
                                    'role', 'authenticated')::text, true);

CREATE TEMP TABLE t43 (orden INT, test TEXT, obtenido TEXT, ok BOOLEAN) ON COMMIT DROP;

DO $$
DECLARE
  v_p UUID;
  v_v1 UUID;
  v_v2 UUID;
  v_v3 UUID;
  v_v4 UUID;
  v_stock NUMERIC;
BEGIN
  INSERT INTO productos (nombre, codigo_barras, precio_manual)
  VALUES ('test idempotencia 43', 'test-43-idem', 1000)
  RETURNING id INTO v_p;

  v_v1 := confirmar_venta(NULL, 'efectivo',
    jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 2, 'precio_unitario', 1000)),
    p_client_id => 'test-43:1');
  SELECT cantidad INTO v_stock FROM stock_ubicaciones WHERE producto_id = v_p AND ubicacion = 'local';

  -- Reintento con el mismo id (y otro carrito): misma venta, nada nuevo.
  v_v2 := confirmar_venta(NULL, 'qr',
    jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 5, 'precio_unitario', 1000)),
    p_client_id => 'test-43:1');

  INSERT INTO t43 VALUES
    (1, 'reintento devuelve la misma venta', v_v2::text, v_v2 = v_v1),
    (2, 'una sola venta con ese client_id',
        (SELECT count(*) FROM ventas WHERE client_id = 'test-43:1')::text,
        (SELECT count(*) FROM ventas WHERE client_id = 'test-43:1') = 1),
    (3, 'la venta quedó con el carrito del primer intento',
        (SELECT string_agg(cantidad::text, ',') FROM venta_items WHERE venta_id = v_v1),
        (SELECT count(*) FROM venta_items WHERE venta_id = v_v1) = 1
          AND (SELECT cantidad FROM venta_items WHERE venta_id = v_v1) = 2),
    (4, 'un solo pago', (SELECT count(*) FROM venta_pagos WHERE venta_id = v_v1)::text,
        (SELECT count(*) FROM venta_pagos WHERE venta_id = v_v1) = 1),
    (5, 'el stock se movió una sola vez',
        (SELECT cantidad FROM stock_ubicaciones WHERE producto_id = v_p AND ubicacion = 'local')::text,
        (SELECT cantidad FROM stock_ubicaciones WHERE producto_id = v_p AND ubicacion = 'local') = v_stock
          AND (SELECT count(*) FROM movimientos_stock WHERE referencia_id = v_v1) = 1);

  -- Otro intento del mismo ticket → venta nueva.
  v_v3 := confirmar_venta(NULL, 'efectivo',
    jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 1, 'precio_unitario', 1000)),
    p_client_id => 'test-43:2');
  INSERT INTO t43 VALUES (6, 'otro intento → otra venta', v_v3::text, v_v3 <> v_v1);

  -- Sin client_id: como antes, cada llamada es una venta (y null no choca con null).
  v_v4 := confirmar_venta(NULL, 'efectivo',
    jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 1, 'precio_unitario', 1000)));
  INSERT INTO t43 VALUES
    (7, 'sin client_id: venta nueva con client_id null',
        coalesce((SELECT client_id FROM ventas WHERE id = v_v4), '<null>'),
        v_v4 NOT IN (v_v1, v_v3) AND (SELECT client_id FROM ventas WHERE id = v_v4) IS NULL);
END;
$$;

SELECT * FROM t43 ORDER BY orden;

ROLLBACK;
