-- 33 — Copiar factura de compra: referencia a la factura de origen + aviso de comprobante repetido
--
-- docs/06_estructura_de_datos.md, sección 23, tiene el detalle. Correr en el SQL Editor de Supabase
-- (proyecto ccpinvtleqlsukcqnili), después de 32. Correr la PARTE A de una vez, una sola vez; la
-- PARTE B (verificación) y la PARTE C (tests, BEGIN … ROLLBACK) se pueden repetir.
--
-- Contexto (relevado contra la base real el 2026-10-05):
--   - cargar_factura_compra tiene UNA sola firma (9 parámetros) y su cuerpo es idéntico al de
--     docs/29 (comparado contra pg_get_functiondef).
--   - facturas_compra no tiene ningún UNIQUE sobre proveedor + tipo + letra + punto de venta +
--     número: el mismo comprobante se puede cargar dos veces sin aviso.
--   - facturas_compra_saldo coincide con docs/31 y ninguna vista ni función depende de ella.
--
-- Qué hace:
--   1. facturas_compra.copiada_de_id (UUID, null, FK a facturas_compra) + índice. Una factura
--      cargada copiando otra apunta a esa otra; las cargadas a mano quedan en null.
--   2. cargar_factura_compra: + p_copiada_de_id UUID DEFAULT NULL, como último parámetro. Valida
--      que la factura de origen exista: puede ser de otro proveedor (al copiar se puede cambiar
--      el proveedor) y puede estar anulada (anular y volver a cargar es la forma de corregir
--      ítems o montos, ver editar_factura_compra). Lo guarda en la fila nueva. El resto del
--      cuerpo es el de docs/29 sin cambios.
--      Por qué DROP + CREATE y no una sobrecarga: si quedaran vivas la firma de 9 parámetros y la
--      de 10 con default, una llamada de PostgREST con 9 argumentos (todas las apps hoy) encaja en
--      las dos y falla con PGRST203 ("Could not choose the best candidate function"). Con una sola
--      firma de 10 y default, las llamadas actuales siguen andando sin cambios.
--   3. facturas_compra_saldo: + copiada_de_id al final (CREATE OR REPLACE, mismo cuerpo que
--      docs/31). Así el tipo FacturaCompraSaldo = FacturaCompra & {...} sigue siendo cierto.
--   4. existe_comprobante_compra(...): comprobantes ya cargados con el mismo proveedor, tipo,
--      letra, punto de venta y número. Para un aviso en la UI, no bloquea nada.
--
-- Auditoría: no hace falta tocar nada. trg_auditoria_facturas_compra guarda to_jsonb(NEW), así
-- que la fila 'alta' de cada factura nueva ya incluye copiada_de_id (test C3).

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios (una transacción)
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ============================================================
-- 1. facturas_compra.copiada_de_id
-- Sin ON DELETE: las facturas de compra no se borran (se anulan), y si alguna vez se intentara
-- borrar una factura que tiene copias, conviene que falle en vez de perder la referencia.
-- ============================================================
ALTER TABLE facturas_compra ADD COLUMN copiada_de_id UUID REFERENCES facturas_compra(id);
CREATE INDEX idx_facturas_compra_copiada_de ON facturas_compra(copiada_de_id) WHERE copiada_de_id IS NOT NULL;

-- ============================================================
-- 2. cargar_factura_compra — versión de docs/29 + p_copiada_de_id
-- ============================================================
DROP FUNCTION cargar_factura_compra(UUID, tipo_comprobante_compra, letra_comprobante_compra, TEXT, TEXT,
                                    DATE, DATE, forma_pago_compra, JSONB);

CREATE FUNCTION cargar_factura_compra(
  p_proveedor_id UUID,
  p_tipo_comprobante tipo_comprobante_compra,
  p_letra letra_comprobante_compra,
  p_punto_venta TEXT,
  p_numero_comprobante TEXT,
  p_fecha_comprobante DATE,
  p_fecha_fiscal DATE,
  p_forma_pago forma_pago_compra,
  p_items JSONB,  -- [{"producto_id":"..."|null,"descripcion":"...","cantidad":1,"precio_unitario_sin_iva":100,"descuento_porcentaje":0,"ubicacion":"local"}]
  p_copiada_de_id UUID DEFAULT NULL  -- docs/33: factura de la que se copió esta (cualquier proveedor, también anulada)
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
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
  v_cambia_proveedor BOOLEAN;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  -- docs/33: la FK ya lo garantiza; esto da un mensaje legible en vez del error de constraint.
  IF p_copiada_de_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM facturas_compra WHERE id = p_copiada_de_id) THEN
    RAISE EXCEPTION 'La factura que se quiso copiar no existe';
  END IF;

  SELECT COALESCE(SUM((i->>'cantidad')::NUMERIC * (i->>'precio_unitario_sin_iva')::NUMERIC
           * (1 - COALESCE((i->>'descuento_porcentaje')::NUMERIC,0)/100.0)), 0)
  INTO v_total_sin_iva
  FROM jsonb_array_elements(p_items) AS i;

  v_iva := ROUND(v_total_sin_iva * 0.21, 2);
  v_total := v_total_sin_iva + v_iva;

  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, letra, punto_venta, numero_comprobante,
         fecha_comprobante, fecha_fiscal, forma_pago, total_sin_iva, iva, total, usuario_id, copiada_de_id)
  VALUES (p_proveedor_id, p_tipo_comprobante, p_letra, p_punto_venta, p_numero_comprobante,
         p_fecha_comprobante, p_fecha_fiscal, p_forma_pago, v_total_sin_iva, v_iva, v_total, auth.uid(), p_copiada_de_id)
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
    SELECT DISTINCT ON (x.producto_id) x.producto_id, x.precio
    FROM (
      SELECT NULLIF(t.i->>'producto_id','')::UUID AS producto_id,
             (t.i->>'precio_unitario_sin_iva')::NUMERIC AS precio,
             t.ord
      FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(i, ord)
    ) x
    WHERE x.producto_id IS NOT NULL
    ORDER BY x.producto_id, x.ord DESC
  LOOP
    SELECT proveedor_id, costo INTO v_producto_proveedor_id, v_costo_actual
    FROM productos WHERE id = v_row.producto_id FOR UPDATE;

    v_cambia_proveedor := v_producto_proveedor_id IS DISTINCT FROM p_proveedor_id;
    v_costo_nuevo := CASE WHEN v_actualiza_costo AND v_row.precio > 0
                          THEN ROUND(v_row.precio, 2) ELSE v_costo_actual END;

    IF v_cambia_proveedor OR v_costo_nuevo IS DISTINCT FROM v_costo_actual THEN
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
          updated_at = now()
      WHERE id = v_row.producto_id;

      IF v_cambia_proveedor THEN
        PERFORM set_config('virikyna.margen_auto_herencia', 'false', true);
      END IF;
    END IF;
  END LOOP;

  RETURN v_factura_id;
END;
$$;

GRANT EXECUTE ON FUNCTION cargar_factura_compra(UUID, tipo_comprobante_compra, letra_comprobante_compra, TEXT, TEXT,
                                                DATE, DATE, forma_pago_compra, JSONB, UUID) TO authenticated, service_role;

-- ============================================================
-- 3. facturas_compra_saldo — cuerpo de docs/31 + copiada_de_id al final
-- (CREATE OR REPLACE solo admite columnas nuevas al final; las existentes quedan igual)
-- ============================================================
CREATE OR REPLACE VIEW facturas_compra_saldo AS
SELECT
  fc.id,
  fc.proveedor_id,
  fc.tipo_comprobante,
  fc.letra,
  fc.punto_venta,
  fc.numero_comprobante,
  fc.fecha_comprobante,
  fc.fecha_fiscal,
  fc.forma_pago,
  fc.total_sin_iva,
  fc.iva,
  fc.total,
  fc.usuario_id,
  fc.created_at,
  fc.anulada,
  x.aplicado AS total_pagado,
  CASE WHEN fc.anulada OR fc.tipo_comprobante = 'nota_credito' THEN 0
       ELSE fc.total - x.aplicado END AS saldo_pendiente,
  x.aplicado AS total_aplicado,
  CASE WHEN fc.tipo_comprobante = 'nota_credito' AND NOT fc.anulada
       THEN fc.total - x.aplicado ELSE 0 END AS credito_disponible,
  CASE WHEN fc.anulada THEN 'anulada'
       WHEN fc.total - x.aplicado <= 0 THEN 'pagada'
       WHEN x.aplicado > 0 THEN 'parcial'
       ELSE 'pendiente' END AS estado,
  fc.copiada_de_id  -- docs/33
FROM facturas_compra fc
CROSS JOIN LATERAL (
  SELECT CASE WHEN fc.tipo_comprobante = 'nota_credito'
    THEN (SELECT COALESCE(SUM(a.monto), 0) FROM pagos_proveedor_aplicaciones a
          WHERE a.nota_credito_id = fc.id AND a.revertida_at IS NULL)
    ELSE (SELECT COALESCE(SUM(a.monto), 0) FROM pagos_proveedor_aplicaciones a
          WHERE a.factura_compra_id = fc.id AND a.revertida_at IS NULL)
  END AS aplicado
) x;

-- ============================================================
-- 4. existe_comprobante_compra — aviso de comprobante repetido (no bloquea)
--
--   - Sin número (null o en blanco) no devuelve nada: sin número no hay forma de decir que es el
--     mismo comprobante.
--   - Punto de venta y número se comparan sin espacios ni ceros a la izquierda: "0001"/"00012345"
--     es el mismo comprobante que "1"/"12345". Un punto de venta vacío equivale a null.
--   - Letra: comparación exacta, también con null (sin letra ≠ letra A).
--   - Devuelve también las anuladas (con anulada = true): la UI decide cómo avisar — recargar una
--     factura anulada es justamente el caso de "anular y volver a cargar".
--   - SECURITY INVOKER: lee con los permisos de quien llama (policy facturas_compra_todos).
-- ============================================================
CREATE FUNCTION existe_comprobante_compra(
  p_proveedor_id UUID,
  p_tipo tipo_comprobante_compra,
  p_letra letra_comprobante_compra,
  p_punto_venta TEXT,
  p_numero TEXT
) RETURNS TABLE (id UUID, fecha_comprobante DATE, total NUMERIC, anulada BOOLEAN)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT fc.id, fc.fecha_comprobante, fc.total, fc.anulada
  FROM facturas_compra fc
  WHERE btrim(p_numero) <> ''
    AND fc.proveedor_id = p_proveedor_id
    AND fc.tipo_comprobante = p_tipo
    AND fc.letra IS NOT DISTINCT FROM p_letra
    AND NULLIF(ltrim(btrim(fc.punto_venta), '0'), '') IS NOT DISTINCT FROM NULLIF(ltrim(btrim(p_punto_venta), '0'), '')
    AND ltrim(btrim(fc.numero_comprobante), '0') = ltrim(btrim(p_numero), '0')
  ORDER BY fc.fecha_comprobante DESC, fc.created_at DESC;
$$;

GRANT EXECUTE ON FUNCTION existe_comprobante_compra(UUID, tipo_comprobante_compra, letra_comprobante_compra, TEXT, TEXT)
  TO authenticated, service_role;

-- PostgREST: refrescar el caché de funciones (la firma de cargar_factura_compra cambió).
NOTIFY pgrst, 'reload schema';

COMMIT;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (después de A)
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- B1. Una sola firma de cargar_factura_compra, la de 10 parámetros (esperado: 1 fila, ..., uuid).
SELECT p.oid::regprocedure AS firma, p.proacl FROM pg_proc p
WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'cargar_factura_compra';

-- B2. Columna, FK e índice nuevos.
SELECT column_name, data_type, is_nullable FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'facturas_compra' AND column_name = 'copiada_de_id';
SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
WHERE conrelid = 'public.facturas_compra'::regclass AND contype = 'f';
SELECT indexdef FROM pg_indexes WHERE tablename = 'facturas_compra';

-- B3. La vista termina en copiada_de_id.
SELECT column_name FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'facturas_compra_saldo' ORDER BY ordinal_position DESC LIMIT 1;

-- B4. existe_comprobante_compra: STABLE (s) y SECURITY INVOKER (prosecdef = false).
SELECT p.oid::regprocedure, p.provolatile, p.prosecdef FROM pg_proc p WHERE p.proname = 'existe_comprobante_compra';

-- B5. Comprobantes que HOY ya están repetidos (informativo, no se toca nada): mismo criterio que
--     existe_comprobante_compra.
SELECT proveedor_id, tipo_comprobante, letra,
       NULLIF(ltrim(btrim(punto_venta), '0'), '') AS pv, ltrim(btrim(numero_comprobante), '0') AS numero,
       count(*) AS veces, array_agg(id ORDER BY created_at) AS ids
FROM facturas_compra
WHERE btrim(numero_comprobante) <> ''
GROUP BY 1, 2, 3, 4, 5
HAVING count(*) > 1;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — TESTS (después de A). Todo dentro de BEGIN … ROLLBACK: no deja datos.
-- Corren como el primer admin activo (auth.uid() vía request.jwt.claims). Ítems libres (sin
-- producto_id) para no tocar stock ni productos reales. Si un ASSERT falla, aborta con su mensaje.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $$
DECLARE
  v_admin UUID;
  pA UUID; pB UUID;
  f1 UUID; f2 UUID; f3 UUID; v_copia UUID;
  v_fc facturas_compra%ROWTYPE;
  v_items JSONB := '[{"producto_id":null,"descripcion":"TEST33 ítem libre","cantidad":2,"precio_unitario_sin_iva":100,"descuento_porcentaje":10,"ubicacion":"local"}]';
  v_n INT;
  v_ok BOOLEAN;
BEGIN
  SELECT id INTO v_admin FROM perfiles WHERE rol = 'admin' AND activo ORDER BY created_at LIMIT 1;
  ASSERT v_admin IS NOT NULL, 'setup: no hay admin activo';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  INSERT INTO proveedores (razon_social) VALUES ('TEST33 A') RETURNING id INTO pA;
  INSERT INTO proveedores (razon_social) VALUES ('TEST33 B') RETURNING id INTO pB;

  -- ── C1: carga sin p_copiada_de_id (llamada de 9 argumentos, como hoy) — igual que antes ──
  f1 := cargar_factura_compra(pA, 'factura', 'A', '0001', '00012345', '2026-10-01', NULL, 'cuenta_corriente', v_items);
  SELECT * INTO v_fc FROM facturas_compra WHERE id = f1;
  ASSERT v_fc.copiada_de_id IS NULL, 'C1: sin p_copiada_de_id la referencia queda en null';
  ASSERT v_fc.total_sin_iva = 180 AND v_fc.iva = 37.80 AND v_fc.total = 217.80, 'C1: totales (2 × 100 − 10% = 180 + IVA 21%)';
  ASSERT v_fc.usuario_id = v_admin, 'C1: usuario_id = auth.uid()';
  ASSERT (SELECT count(*) FROM facturas_compra_items WHERE factura_compra_id = f1 AND precio_total_sin_iva = 180) = 1,
         'C1: el ítem se guarda con su total';

  -- Misma llamada con argumentos nombrados, como la hace PostgREST (sin p_copiada_de_id).
  f3 := cargar_factura_compra(p_proveedor_id => pA, p_tipo_comprobante => 'remito', p_letra => NULL,
          p_punto_venta => NULL, p_numero_comprobante => NULL, p_fecha_comprobante => '2026-10-02',
          p_fecha_fiscal => NULL, p_forma_pago => 'contado', p_items => v_items);
  ASSERT (SELECT copiada_de_id FROM facturas_compra WHERE id = f3) IS NULL, 'C1: llamada nombrada sin el parámetro nuevo';

  -- ── C2: carga con p_copiada_de_id (a otro proveedor) guarda la referencia ──
  f2 := cargar_factura_compra(pB, 'factura', 'A', '0001', '00099999', '2026-10-03', NULL, 'contado', v_items, f1);
  ASSERT (SELECT copiada_de_id FROM facturas_compra WHERE id = f2) = f1, 'C2: copiada_de_id = factura de origen';
  ASSERT (SELECT copiada_de_id FROM facturas_compra_saldo WHERE id = f2) = f1, 'C2: la vista expone copiada_de_id';

  -- Origen inexistente → error legible, sin dejar nada cargado.
  v_ok := false;
  BEGIN
    PERFORM cargar_factura_compra(pA, 'factura', NULL, NULL, NULL, '2026-10-04', NULL, 'contado', v_items, gen_random_uuid());
  EXCEPTION WHEN raise_exception THEN
    v_ok := SQLERRM = 'La factura que se quiso copiar no existe';
  END;
  ASSERT v_ok, 'C2: copiar de una factura inexistente debería fallar con mensaje propio';

  -- Copiar de una factura anulada está permitido (anular y volver a cargar). La llamada va en una
  -- asignación aparte: dentro de un WHERE se ejecutaría una vez por fila y su INSERT no sería
  -- visible para ese mismo SELECT (mismo cuidado que cerrar_caja en los tests de docs/31).
  UPDATE facturas_compra SET anulada = true WHERE id = f3;
  v_copia := cargar_factura_compra(pA, 'remito', NULL, NULL, NULL, '2026-10-04', NULL, 'contado', v_items, f3);
  ASSERT (SELECT copiada_de_id FROM facturas_compra WHERE id = v_copia) = f3, 'C2: se puede copiar una factura anulada';

  -- ── C3: la fila 'alta' de auditoría incluye copiada_de_id ──
  ASSERT (SELECT valores_nuevos->>'copiada_de_id' FROM auditoria
          WHERE tabla_afectada = 'facturas_compra' AND registro_id = f2 AND accion = 'alta') = f1::text,
         'C3: auditoría alta con copiada_de_id = origen';
  ASSERT (SELECT valores_nuevos ? 'copiada_de_id' AND valores_nuevos->'copiada_de_id' = 'null'::jsonb FROM auditoria
          WHERE tabla_afectada = 'facturas_compra' AND registro_id = f1 AND accion = 'alta'),
         'C3: en una carga sin copia la clave existe y vale null';

  -- ── C4: existe_comprobante_compra ──
  -- Mismo comprobante escrito sin ceros a la izquierda → encuentra f1.
  SELECT count(*) INTO v_n FROM existe_comprobante_compra(pA, 'factura', 'A', '1', '12345') e WHERE e.id = f1;
  ASSERT v_n = 1, 'C4: encuentra el duplicado (0001-00012345 = 1-12345)';
  ASSERT (SELECT anulada FROM existe_comprobante_compra(pA, 'factura', 'A', ' 0001 ', '00012345 ')) = false,
         'C4: devuelve anulada y tolera espacios';
  -- Sin número → nada.
  ASSERT NOT EXISTS (SELECT 1 FROM existe_comprobante_compra(pA, 'factura', 'A', '0001', '')), 'C4: número vacío → sin resultados';
  ASSERT NOT EXISTS (SELECT 1 FROM existe_comprobante_compra(pA, 'factura', 'A', '0001', NULL)), 'C4: número null → sin resultados';
  -- Cambia letra, tipo, proveedor o punto de venta → no es el mismo comprobante.
  ASSERT NOT EXISTS (SELECT 1 FROM existe_comprobante_compra(pA, 'factura', 'B', '0001', '00012345')), 'C4: otra letra';
  ASSERT NOT EXISTS (SELECT 1 FROM existe_comprobante_compra(pA, 'factura', NULL, '0001', '00012345')), 'C4: sin letra';
  ASSERT NOT EXISTS (SELECT 1 FROM existe_comprobante_compra(pA, 'remito', 'A', '0001', '00012345')), 'C4: otro tipo';
  ASSERT NOT EXISTS (SELECT 1 FROM existe_comprobante_compra(pB, 'factura', 'A', '0001', '00012345')), 'C4: otro proveedor';
  ASSERT NOT EXISTS (SELECT 1 FROM existe_comprobante_compra(pA, 'factura', 'A', '0002', '00012345')), 'C4: otro punto de venta';

  RAISE NOTICE 'docs/33: todos los tests pasaron';
END;
$$;

ROLLBACK;
