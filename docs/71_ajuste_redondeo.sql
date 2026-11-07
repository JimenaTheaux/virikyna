-- 71 — Ajuste por redondeo: en comprobantes de compra (fuera del IVA) y en pagos y cobros de
--      cuenta corriente
--
-- Estado: ver el bloque "APLICADO" al final del encabezado (se completa al aplicar).
-- Base: docs/DIAGNOSTICO_AJUSTE_REDONDEO.md (2026-11-07). Decisiones D1–D6 aprobadas el 2026-11-07.
-- Schema relevado sobre supabase/schema/schema.sql (regenerado con docs/70).
--
-- Correr desde la raíz del repo, después de 70. La PARTE A es re-corrible (IF NOT EXISTS / DROP IF
-- EXISTS + CREATE OR REPLACE). La PARTE B solo lee. La PARTE C es un test (BEGIN … ROLLBACK) que no
-- consume secuencias: se puede correr en producción.
--
-- Pedido de la dueña (2026-11-07): un ajuste de centavos que sume o reste sobre el TOTAL FINAL, fuera
-- del IVA. Sin tope. Lo usan admin y cajeros.
--
-- Qué hace:
--   1. facturas_compra.ajuste_redondeo (con signo, default 0). total = total_sin_iva + iva + ajuste,
--      con un CHECK que lo hace cumplir. El ajuste no toca ítems, IVA, costo de productos ni stock.
--   2. cargar_factura_compra / cargar_factura_compra_contado: + p_ajuste_redondeo DEFAULT 0 (las apps
--      viejas no lo mandan y siguen igual). El total no puede quedar negativo. D5: el subtotal sin IVA
--      es la suma de las líneas ya redondeadas (igual que la pantalla y que precio_total_sin_iva).
--      Antes sumaba las líneas sin redondear y podía diferir en 0,01.
--   3. editar_factura_compra: + p_ajuste_redondeo DEFAULT NULL. Al recalcular por cambio de alícuota
--      CONSERVA el ajuste (antes lo habría borrado). Cambiar el ajuste: solo admin y sin pagos ni NC
--      aplicados (D3, misma regla que el IVA).
--   4. pagos_proveedor.ajuste_redondeo y pagos_cliente.ajuste_redondeo (con signo, default 0).
--      Lo que el pago cancela = monto (plata, suma de los medios) + ajuste. monto sigue siendo solo
--      plata: egresos, medios, movimientos de cuenta y cierres no cambian.
--        + positivo: faltaron centavos y se dan por pagados. Tiene que quedar aplicado entero a
--          comprobantes (no genera saldo a favor sin plata).
--        − negativo: sobraron centavos y no quedan a cuenta. monto + ajuste tiene que ser > 0.
--      Ajuste solo (sin medios, D4): permitido si es positivo y hay comprobantes con saldo. No genera
--      egresos ni movimientos, y en Local no exige caja abierta (el cierre suma medios, y no tiene).
--      forma_pago pasa a NULL solo en ese caso (CHECK): así "ajuste" no aparece como medio.
--   5. registrar_pago_proveedor_v3 y registrar_cobro_cliente: + p_ajuste_redondeo DEFAULT 0.
--   6. Vistas (mismas columnas en el mismo orden + nuevas al final, security_invoker repetido):
--        facturas_compra_saldo: + ajuste_redondeo.
--        pagos_proveedor_a_cuenta / pagos_cliente_a_cuenta: a_cuenta = monto + ajuste − aplicado;
--          vigente = monto + ajuste > 0 (y no es reversión ni revertido); + ajuste_redondeo.
--        proveedores_saldo / clientes_saldo: total pagado = Σ (monto + ajuste).
--        proveedores_a_cuenta: sin cambios (se recrea igual porque depende de la anterior).
--   7. revertir_movimiento: la reversión de un pago o cobro copia también el ajuste en negativo.
--
-- Cambios de firma: DROP de la versión vieja + CREATE de la nueva (CREATE OR REPLACE con un
-- parámetro más dejaría dos funciones y PostgREST no sabría a cuál llamar). Se repiten los GRANT.
-- registrar_pago_proveedor_v2 y cargar_factura_compra_contado llaman a v3 / cargar con parámetros
-- con nombre: siguen andando sin tocarlas (contado igual se recrea para pasar el ajuste).
--
-- APLICADO: 2026-11-07 en producción (backup previo virikyna_2026-11-07_pre-docs71-aplicar). Antes se
-- probó entera, dos veces seguidas, sobre la restauración local de virikyna_2026-11-07_pre-docs71-test.
-- PARTE B: una sola firma por función (con p_ajuste_redondeo), anon sin EXECUTE, security_invoker en las
-- 6 vistas, 31 facturas con total = sin IVA + IVA + ajuste. PARTE C: OK T1–T15 (ROLLBACK, sin restos).

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios
-- ════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 1 y 4. Columnas y restricciones ────────────────────────────────────────────────────────────────
ALTER TABLE facturas_compra ADD COLUMN IF NOT EXISTS ajuste_redondeo NUMERIC(12,2) NOT NULL DEFAULT 0;
ALTER TABLE pagos_proveedor ADD COLUMN IF NOT EXISTS ajuste_redondeo NUMERIC(12,2) NOT NULL DEFAULT 0;
ALTER TABLE pagos_cliente   ADD COLUMN IF NOT EXISTS ajuste_redondeo NUMERIC(12,2) NOT NULL DEFAULT 0;

ALTER TABLE pagos_proveedor ALTER COLUMN forma_pago DROP NOT NULL;
ALTER TABLE pagos_cliente   ALTER COLUMN forma_pago DROP NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'facturas_compra_total_cuadra') THEN
    ALTER TABLE facturas_compra ADD CONSTRAINT facturas_compra_total_cuadra
      CHECK (total = total_sin_iva + iva + ajuste_redondeo);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pagos_proveedor_forma_pago_o_ajuste') THEN
    ALTER TABLE pagos_proveedor ADD CONSTRAINT pagos_proveedor_forma_pago_o_ajuste
      CHECK (forma_pago IS NOT NULL OR (monto = 0 AND ajuste_redondeo <> 0));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pagos_cliente_forma_pago_o_ajuste') THEN
    ALTER TABLE pagos_cliente ADD CONSTRAINT pagos_cliente_forma_pago_o_ajuste
      CHECK (forma_pago IS NOT NULL OR (monto = 0 AND ajuste_redondeo <> 0));
  END IF;
END $$;

COMMENT ON COLUMN facturas_compra.ajuste_redondeo IS 'docs/71: ajuste por redondeo con signo, fuera del IVA. total = total_sin_iva + iva + ajuste_redondeo (CHECK facturas_compra_total_cuadra). No toca ítems, costo ni stock.';
COMMENT ON COLUMN pagos_proveedor.ajuste_redondeo IS 'docs/71: ajuste por redondeo con signo. Lo que el pago cancela = monto (plata) + ajuste_redondeo. Positivo: centavos que faltaron, aplicado entero a comprobantes. Negativo: centavos que sobraron y no quedan a cuenta. No mueve caja.';
COMMENT ON COLUMN pagos_cliente.ajuste_redondeo IS 'docs/71: ajuste por redondeo con signo. Lo que el cobro cancela = monto (plata) + ajuste_redondeo. Positivo: centavos que faltaron, aplicado entero a ventas. Negativo: centavos que sobraron y no quedan a cuenta. No mueve caja.';
COMMENT ON COLUMN pagos_proveedor.forma_pago IS 'Medio del pago, o mixto si tiene varios (detalle en pagos_proveedor_medios). NULL solo en un ajuste por redondeo sin plata (monto 0, docs/71).';
COMMENT ON COLUMN pagos_cliente.forma_pago IS 'docs/68: medio del cobro, o combinado si tiene varios (detalle en pagos_cliente_medios). NULL solo en un ajuste por redondeo sin plata (monto 0, docs/71).';

-- ── 2. cargar_factura_compra ───────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS cargar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date,
  forma_pago_compra, jsonb, uuid, numeric, text, uuid, boolean);

CREATE OR REPLACE FUNCTION cargar_factura_compra(
  p_proveedor_id uuid, p_tipo_comprobante tipo_comprobante_compra, p_letra letra_comprobante_compra,
  p_punto_venta text, p_numero_comprobante text, p_fecha_comprobante date, p_fecha_fiscal date,
  p_forma_pago forma_pago_compra, p_items jsonb, p_copiada_de_id uuid DEFAULT NULL,
  p_iva_alicuota numeric DEFAULT 21, p_tipo_compra text DEFAULT 'articulos', p_borrador_id uuid DEFAULT NULL,
  p_devuelve_mercaderia boolean DEFAULT false,
  p_ajuste_redondeo numeric DEFAULT 0  -- docs/71
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_factura_id UUID;
  v_item JSONB;
  v_precio_total_sin_iva NUMERIC;
  v_total_sin_iva NUMERIC := 0;
  v_iva NUMERIC;
  v_total NUMERIC;
  v_ajuste NUMERIC := ROUND(COALESCE(p_ajuste_redondeo, 0), 2);  -- docs/71
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
  v_nc BOOLEAN := p_tipo_comprobante = 'nota_credito';             -- docs/55
  v_devuelve BOOLEAN := COALESCE(p_devuelve_mercaderia, false);    -- docs/55
  v_falta TEXT;                                                    -- docs/55
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

  -- docs/55: devolución de mercadería, solo en una NC de artículos. Tiene que alcanzar el stock de
  -- cada producto en el depósito de su ítem (sumando ítems repetidos). Las filas se bloquean antes
  -- de mirar, así dos devoluciones a la vez no dejan el stock en negativo.
  IF v_devuelve AND (NOT v_nc OR p_tipo_compra <> 'articulos') THEN
    RAISE EXCEPTION 'La devolución de mercadería es solo para notas de crédito de artículos';
  END IF;
  IF v_devuelve THEN
    PERFORM 1 FROM stock_ubicaciones s
    WHERE (s.producto_id, s.ubicacion) IN (
      SELECT NULLIF(i->>'producto_id', '')::UUID, COALESCE((i->>'ubicacion')::ubicacion_stock, 'local')
      FROM jsonb_array_elements(p_items) AS i WHERE NULLIF(i->>'producto_id', '') IS NOT NULL)
    FOR UPDATE;

    SELECT string_agg(format('%s (%s): hay %s, se devuelven %s', p.nombre,
             CASE WHEN x.ubicacion = 'deposito' THEN 'depósito' ELSE 'local' END,
             trim_scale(COALESCE(s.cantidad, 0)), trim_scale(x.pedida)), '; ' ORDER BY p.nombre)
    INTO v_falta
    FROM (
      SELECT NULLIF(i->>'producto_id', '')::UUID AS producto_id,
             COALESCE((i->>'ubicacion')::ubicacion_stock, 'local') AS ubicacion,
             SUM((i->>'cantidad')::NUMERIC) AS pedida
      FROM jsonb_array_elements(p_items) AS i
      WHERE NULLIF(i->>'producto_id', '') IS NOT NULL
      GROUP BY 1, 2
    ) x
    JOIN productos p ON p.id = x.producto_id
    LEFT JOIN stock_ubicaciones s ON s.producto_id = x.producto_id AND s.ubicacion = x.ubicacion
    WHERE COALESCE(s.cantidad, 0) < x.pedida;

    IF v_falta IS NOT NULL THEN
      RAISE EXCEPTION 'No alcanza el stock para devolver: %', v_falta;
    END IF;
  END IF;

  -- docs/33: la FK ya lo garantiza; esto da un mensaje legible en vez del error de constraint.
  IF p_copiada_de_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM facturas_compra WHERE id = p_copiada_de_id) THEN
    RAISE EXCEPTION 'La factura que se quiso copiar no existe';
  END IF;

  -- docs/71 (D5): suma de las líneas YA redondeadas, igual que la pantalla y que precio_total_sin_iva.
  SELECT COALESCE(SUM(ROUND((i->>'cantidad')::NUMERIC * (i->>'precio_unitario_sin_iva')::NUMERIC
           * (1 - COALESCE((i->>'descuento_porcentaje')::NUMERIC,0)/100.0), 2)), 0)
  INTO v_total_sin_iva
  FROM jsonb_array_elements(p_items) AS i;

  v_iva := ROUND(v_total_sin_iva * p_iva_alicuota / 100, 2);  -- docs/45 (antes: × 0.21 fijo)
  v_total := v_total_sin_iva + v_iva + v_ajuste;               -- docs/71: + ajuste, fuera del IVA

  IF v_total < 0 THEN
    RAISE EXCEPTION 'El total del comprobante no puede quedar negativo: el ajuste por redondeo (%) es mayor que el total (%)',
      formato_pesos(v_ajuste), formato_pesos(v_total_sin_iva + v_iva);
  END IF;

  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, letra, punto_venta, numero_comprobante,
         fecha_comprobante, fecha_fiscal, forma_pago, total_sin_iva, iva, total, usuario_id, copiada_de_id,
         iva_alicuota,  -- docs/45
         tipo_compra,   -- docs/53
         devuelve_mercaderia,  -- docs/55
         ajuste_redondeo)      -- docs/71
  VALUES (p_proveedor_id, p_tipo_comprobante, p_letra, p_punto_venta, p_numero_comprobante,
         p_fecha_comprobante, p_fecha_fiscal, p_forma_pago, v_total_sin_iva, v_iva, v_total, auth.uid(), p_copiada_de_id,
         p_iva_alicuota,
         p_tipo_compra,
         v_devuelve,
         v_ajuste)
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

    -- docs/55: una NC no suma stock nunca (antes sumaba como una compra). Con devolución de
    -- mercadería, resta lo devuelto (ajuste con referencia a la NC, igual que las devoluciones de
    -- venta de docs/24: el Historial no lo ofrece revertir suelto, se revierte anulando la NC).
    IF v_producto_id IS NOT NULL AND NOT v_nc THEN
      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, referencia_id, usuario_id, origen)  -- docs/70: origen
      VALUES (v_producto_id, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'),
             'compra', (v_item->>'cantidad')::NUMERIC, v_factura_id, auth.uid(), 'compra');

      INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
      VALUES (v_producto_id, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'), (v_item->>'cantidad')::NUMERIC)
      ON CONFLICT (producto_id, ubicacion)
      DO UPDATE SET cantidad = stock_ubicaciones.cantidad + (v_item->>'cantidad')::NUMERIC;
    ELSIF v_producto_id IS NOT NULL AND v_devuelve THEN
      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id, origen)  -- docs/70: origen
      VALUES (v_producto_id, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'), 'ajuste',
             -1 * (v_item->>'cantidad')::NUMERIC,
             'Devolucion a proveedor: NC ' || COALESCE(NULLIF(btrim(p_numero_comprobante), ''), 'sin numero'),
             v_factura_id, auth.uid(), 'devolucion_proveedor');

      UPDATE stock_ubicaciones SET cantidad = cantidad - (v_item->>'cantidad')::NUMERIC
      WHERE producto_id = v_producto_id AND ubicacion = COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local');
    END IF;
  END LOOP;

  PERFORM set_config('virikyna.origen_precio', 'factura', true);  -- docs/67
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
      AND NOT v_nc  -- docs/55: una NC nunca toca costo, proveedor ni márgenes
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
  PERFORM set_config('virikyna.origen_precio', '', true);  -- docs/67

  RETURN v_factura_id;
END;
$$;

REVOKE ALL ON FUNCTION cargar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date,
  forma_pago_compra, jsonb, uuid, numeric, text, uuid, boolean, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cargar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date,
  forma_pago_compra, jsonb, uuid, numeric, text, uuid, boolean, numeric) TO authenticated, service_role;

-- ── 2. cargar_factura_compra_contado ───────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS cargar_factura_compra_contado(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text,
  date, date, jsonb, origen_egreso, uuid, numeric, text, uuid);

CREATE OR REPLACE FUNCTION cargar_factura_compra_contado(
  p_proveedor_id uuid, p_tipo_comprobante tipo_comprobante_compra, p_letra letra_comprobante_compra,
  p_punto_venta text, p_numero_comprobante text, p_fecha_comprobante date, p_fecha_fiscal date,
  p_items jsonb, p_origen origen_egreso, p_copiada_de_id uuid DEFAULT NULL, p_iva_alicuota numeric DEFAULT 21,
  p_tipo_compra text DEFAULT 'articulos', p_borrador_id uuid DEFAULT NULL,
  p_ajuste_redondeo numeric DEFAULT 0  -- docs/71
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_factura_id uuid;
  v_f facturas_compra%ROWTYPE;
  v_nota text;
  v_pago jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF p_origen IS NULL THEN
    RAISE EXCEPTION 'Falta el origen del pago (caja de Local o Caja Gestión)';
  END IF;
  IF p_tipo_comprobante = 'nota_credito' THEN
    RAISE EXCEPTION 'Una nota de crédito no se paga de contado: cargala en cuenta corriente';
  END IF;
  -- Caja de Local: el egreso entra en el cierre del día; sin apertura (o ya con Cierre Z) no hay caja.
  IF p_origen = 'turno' AND NOT EXISTS (SELECT 1 FROM aperturas_caja WHERE cierre_z_id IS NULL) THEN
    RAISE EXCEPTION 'Abrí la caja para pagar de contado';
  END IF;

  v_factura_id := cargar_factura_compra(
    p_proveedor_id => p_proveedor_id, p_tipo_comprobante => p_tipo_comprobante, p_letra => p_letra,
    p_punto_venta => p_punto_venta, p_numero_comprobante => p_numero_comprobante,
    p_fecha_comprobante => p_fecha_comprobante, p_fecha_fiscal => p_fecha_fiscal,
    p_forma_pago => 'contado', p_items => p_items, p_copiada_de_id => p_copiada_de_id,
    p_iva_alicuota => p_iva_alicuota, p_tipo_compra => p_tipo_compra, p_borrador_id => p_borrador_id,
    p_ajuste_redondeo => p_ajuste_redondeo);  -- docs/71

  -- El monto es el total que calculó cargar_factura_compra (ya con el ajuste), no uno que mande la pantalla.
  SELECT * INTO v_f FROM facturas_compra WHERE id = v_factura_id;
  IF v_f.total IS NULL OR v_f.total <= 0 THEN
    RAISE EXCEPTION 'Para pagar de contado el total de la factura tiene que ser mayor a cero';
  END IF;

  v_nota := 'Contado: ' || concat_ws(' ',
    CASE v_f.tipo_comprobante
      WHEN 'factura' THEN 'Factura' WHEN 'remito' THEN 'Remito' WHEN 'cupon' THEN 'Cupon'
      WHEN 'presupuesto' THEN 'Presupuesto' WHEN 'nota_debito' THEN 'Nota de debito'
      ELSE v_f.tipo_comprobante::text END,
    v_f.letra::text,
    COALESCE(NULLIF(concat_ws('-', NULLIF(btrim(v_f.punto_venta), ''), NULLIF(btrim(v_f.numero_comprobante), '')), ''), 'sin numero'));

  v_pago := registrar_pago_proveedor_v2(
    p_proveedor_id => p_proveedor_id, p_monto => v_f.total, p_forma_pago => 'efectivo',
    p_factura_ids => ARRAY[v_factura_id], p_origen => p_origen, p_nota => v_nota);

  -- Defensivo: la factura recién cargada no tiene aplicaciones, así que el pago entra entero.
  IF (v_pago->>'aplicado_pago')::numeric <> v_f.total OR (v_pago->>'a_cuenta')::numeric <> 0 THEN
    RAISE EXCEPTION 'No se pudo aplicar el pago completo a la factura';
  END IF;

  RETURN jsonb_build_object('factura_id', v_factura_id, 'pago_id', v_pago->>'pago_id', 'monto', v_f.total);
END;
$$;

REVOKE ALL ON FUNCTION cargar_factura_compra_contado(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text,
  date, date, jsonb, origen_egreso, uuid, numeric, text, uuid, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cargar_factura_compra_contado(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text,
  date, date, jsonb, origen_egreso, uuid, numeric, text, uuid, numeric) TO authenticated, service_role;
COMMENT ON FUNCTION cargar_factura_compra_contado(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text,
  date, date, jsonb, origen_egreso, uuid, numeric, text, uuid, numeric) IS 'docs/57 + docs/71: carga una factura de compra de contado y registra su pago en efectivo (total del servidor, con el ajuste por redondeo) en la misma transacción. turno = caja de Local (exige caja abierta); general = Caja Gestión (admin).';

-- ── 3. editar_factura_compra ───────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS editar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date,
  forma_pago_compra, numeric);

CREATE OR REPLACE FUNCTION editar_factura_compra(
  p_factura_id uuid, p_tipo_comprobante tipo_comprobante_compra DEFAULT NULL,
  p_letra letra_comprobante_compra DEFAULT NULL, p_punto_venta text DEFAULT NULL,
  p_numero_comprobante text DEFAULT NULL, p_fecha_comprobante date DEFAULT NULL, p_fecha_fiscal date DEFAULT NULL,
  p_forma_pago forma_pago_compra DEFAULT NULL, p_iva_alicuota numeric DEFAULT NULL,
  p_ajuste_redondeo numeric DEFAULT NULL  -- docs/71
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_tipo_actual tipo_comprobante_compra;
  v_alicuota_actual NUMERIC;    -- docs/45
  v_forma_pago_actual forma_pago_compra;  -- docs/57
  v_ajuste_actual NUMERIC;      -- docs/71
  v_total_sin_iva NUMERIC;
  v_tipo_nuevo tipo_comprobante_compra;
  v_alicuota_nueva NUMERIC;
  v_ajuste_nuevo NUMERIC;
  v_iva_nuevo NUMERIC;
  v_cambia_importes BOOLEAN;
  v_tiene_aplicaciones BOOLEAN;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede editar una factura de compra ya cargada';
  END IF;
  IF EXISTS (SELECT 1 FROM facturas_compra WHERE id = p_factura_id AND anulada = true) THEN
    RAISE EXCEPTION 'Esta factura está anulada, no se edita';
  END IF;
  IF p_iva_alicuota IS NOT NULL AND p_iva_alicuota NOT IN (0, 21) THEN
    RAISE EXCEPTION 'Alícuota de IVA inválida: tiene que ser 21 %% o exento (0)';
  END IF;

  SELECT tipo_comprobante, iva_alicuota, forma_pago, ajuste_redondeo, total_sin_iva
  INTO v_tipo_actual, v_alicuota_actual, v_forma_pago_actual, v_ajuste_actual, v_total_sin_iva
  FROM facturas_compra WHERE id = p_factura_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Factura de compra no encontrada';
  END IF;

  -- docs/45 + docs/71: tipo, alícuota y ajuste definen el total (y, de/a NC, si suma o resta deuda).
  -- Con pagos o NC aplicados vigentes no se tocan: cambiaría lo que ya se imputó. Mandar el mismo
  -- valor no cuenta como cambio (la UI manda todos los campos siempre).
  v_tipo_nuevo := COALESCE(p_tipo_comprobante, v_tipo_actual);
  v_alicuota_nueva := COALESCE(p_iva_alicuota, v_alicuota_actual);
  v_ajuste_nuevo := COALESCE(ROUND(p_ajuste_redondeo, 2), v_ajuste_actual);
  v_cambia_importes := v_tipo_nuevo IS DISTINCT FROM v_tipo_actual
                       OR v_alicuota_nueva IS DISTINCT FROM v_alicuota_actual
                       OR v_ajuste_nuevo IS DISTINCT FROM v_ajuste_actual;
  v_tiene_aplicaciones := EXISTS (
    SELECT 1 FROM pagos_proveedor_aplicaciones
    WHERE (factura_compra_id = p_factura_id OR nota_credito_id = p_factura_id)
      AND revertida_at IS NULL);

  IF v_cambia_importes AND v_tiene_aplicaciones THEN
    RAISE EXCEPTION 'Este comprobante ya tiene pagos o notas de crédito aplicados: no se puede cambiar el tipo, el IVA ni el ajuste por redondeo. Revertí esos pagos primero';
  END IF;
  -- docs/57: la forma de pago es una etiqueta (cambiarla no crea ni borra pagos). Con pagos aplicados
  -- queda fija, para que una factura pagada de contado no pase a figurar en cuenta corriente.
  IF p_forma_pago IS NOT NULL AND p_forma_pago IS DISTINCT FROM v_forma_pago_actual AND v_tiene_aplicaciones THEN
    RAISE EXCEPTION 'Este comprobante ya tiene pagos aplicados: no se puede cambiar la forma de pago. Revertí esos pagos primero';
  END IF;

  v_iva_nuevo := ROUND(v_total_sin_iva * v_alicuota_nueva / 100, 2);
  IF v_cambia_importes AND v_total_sin_iva + v_iva_nuevo + v_ajuste_nuevo < 0 THEN
    RAISE EXCEPTION 'El total del comprobante no puede quedar negativo: el ajuste por redondeo (%) es mayor que el total (%)',
      formato_pesos(v_ajuste_nuevo), formato_pesos(v_total_sin_iva + v_iva_nuevo);
  END IF;

  UPDATE facturas_compra SET
    tipo_comprobante = v_tipo_nuevo,
    letra = COALESCE(p_letra, letra),
    punto_venta = COALESCE(p_punto_venta, punto_venta),
    numero_comprobante = COALESCE(p_numero_comprobante, numero_comprobante),
    fecha_comprobante = COALESCE(p_fecha_comprobante, fecha_comprobante),
    fecha_fiscal = COALESCE(p_fecha_fiscal, fecha_fiscal),
    forma_pago = COALESCE(p_forma_pago, forma_pago),
    -- docs/45: mismo cálculo que cargar_factura_compra, sobre el total sin IVA guardado.
    -- docs/71: el ajuste se conserva (antes, cambiar la alícuota lo habría borrado del total).
    iva_alicuota = v_alicuota_nueva,
    ajuste_redondeo = v_ajuste_nuevo,
    iva = CASE WHEN v_cambia_importes THEN v_iva_nuevo ELSE iva END,
    total = CASE WHEN v_cambia_importes THEN total_sin_iva + v_iva_nuevo + v_ajuste_nuevo ELSE total END
  WHERE id = p_factura_id;
END;
$$;

REVOKE ALL ON FUNCTION editar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date,
  forma_pago_compra, numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION editar_factura_compra(uuid, tipo_comprobante_compra, letra_comprobante_compra, text, text, date, date,
  forma_pago_compra, numeric, numeric) TO authenticated, service_role;

-- ── 5. registrar_pago_proveedor_v3 ─────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS registrar_pago_proveedor_v3(uuid, jsonb, uuid[], uuid[], origen_egreso, uuid, date, text, numeric);

CREATE OR REPLACE FUNCTION registrar_pago_proveedor_v3(
  p_proveedor_id uuid, p_medios jsonb, p_factura_ids uuid[] DEFAULT NULL, p_nota_credito_ids uuid[] DEFAULT NULL,
  p_origen origen_egreso DEFAULT 'turno', p_cierre_caja_id uuid DEFAULT NULL, p_fecha date DEFAULT NULL,
  p_nota text DEFAULT NULL, p_monto numeric DEFAULT NULL,
  p_ajuste_redondeo numeric DEFAULT 0  -- docs/71
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_fecha DATE := COALESCE(p_fecha, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);
  v_nota TEXT := NULLIF(trim(p_nota), '');
  v_ajuste NUMERIC := ROUND(COALESCE(p_ajuste_redondeo, 0), 2);  -- docs/71
  -- Medios ya validados (en orden).
  v_m_medio forma_pago_egreso[] := '{}';
  v_m_monto NUMERIC[] := '{}';
  v_m_numero TEXT[] := '{}';
  v_m_banco TEXT[] := '{}';
  v_m_salida DATE[] := '{}';
  v_m_pago DATE[] := '{}';
  v_m_ids UUID[] := '{}';
  v_elem jsonb;
  v_medio_txt text;
  v_medio forma_pago_egreso;
  v_m_val NUMERIC;
  v_es_cheque BOOLEAN;
  v_num TEXT;
  v_sal DATE;
  v_pag DATE;
  v_cant INT := 0;
  v_monto NUMERIC := 0;
  v_forma_cabecera forma_pago_egreso;
  v_medio_id UUID;
  v_desc TEXT;
  v_factura_ids UUID[];
  v_nc_ids UUID[];
  v_mal facturas_compra%ROWTYPE;
  v_doc_ids UUID[] := '{}';
  v_doc_saldos NUMERIC[] := '{}';
  v_nc_orden UUID[] := '{}';
  v_nc_disp NUMERIC[] := '{}';
  v_plan_doc UUID[] := '{}';
  v_plan_monto NUMERIC[] := '{}';
  v_plan_nc UUID[] := '{}';
  v_pago_docs UUID[] := '{}';
  v_n INT;
  v_m INT;
  i INT;
  j INT;
  v_aplicar NUMERIC;
  v_total_nc NUMERIC := 0;
  v_rest NUMERIC;
  v_pago_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  -- Mismo criterio que registrar_egreso_general: origen 'general' (Gestión) es solo admin.
  IF p_origen = 'general' AND NOT EXISTS (
    SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true
  ) THEN
    RAISE EXCEPTION 'Solo un administrador puede registrar un pago de origen general';
  END IF;

  -- ── Medios ──
  IF p_medios IS NOT NULL AND jsonb_typeof(p_medios) <> 'array' THEN
    RAISE EXCEPTION 'Los medios de pago tienen que venir como lista';
  END IF;
  FOR v_elem IN SELECT e FROM jsonb_array_elements(COALESCE(p_medios, '[]'::jsonb)) AS e LOOP
    v_cant := v_cant + 1;
    v_medio_txt := v_elem->>'medio';
    IF v_medio_txt IS NULL OR v_medio_txt NOT IN ('efectivo', 'transferencia', 'cheque', 'echeq') THEN
      RAISE EXCEPTION 'Medio de pago % no válido (efectivo, transferencia, cheque o echeq)', COALESCE(v_medio_txt, 'vacío');
    END IF;
    v_medio := v_medio_txt::forma_pago_egreso;
    BEGIN
      v_m_val := round((v_elem->>'monto')::numeric, 2);
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'El monto del medio % no es un número', v_cant;
    END;
    IF v_m_val IS NULL OR v_m_val <= 0 THEN
      RAISE EXCEPTION 'Cada medio tiene que tener un monto mayor a cero (medio %)', v_cant;
    END IF;
    v_es_cheque := v_medio IN ('cheque', 'echeq');
    v_num := NULL; v_sal := NULL; v_pag := NULL;
    IF v_es_cheque THEN
      v_num := NULLIF(trim(v_elem->>'numero'), '');
      IF v_num IS NULL THEN
        RAISE EXCEPTION 'El número de cheque es obligatorio';
      END IF;
      v_pag := NULLIF(v_elem->>'fecha_pago', '')::date;
      IF v_pag IS NULL THEN
        RAISE EXCEPTION 'La fecha de pago del cheque % es obligatoria', v_num;
      END IF;
      v_sal := COALESCE(NULLIF(v_elem->>'fecha_salida', '')::date, v_fecha);
      IF v_pag < v_sal THEN
        RAISE EXCEPTION 'El cheque % se cobra antes de la fecha de salida', v_num;
      END IF;
      IF COALESCE((v_elem->>'propio')::boolean, true) = false THEN
        RAISE EXCEPTION 'Por ahora solo se registran cheques propios';
      END IF;
    END IF;
    v_m_medio := array_append(v_m_medio, v_medio);
    v_m_monto := array_append(v_m_monto, v_m_val);
    v_m_numero := array_append(v_m_numero, v_num);
    v_m_banco := array_append(v_m_banco, CASE WHEN v_es_cheque THEN NULLIF(trim(v_elem->>'banco'), '') END);
    v_m_salida := array_append(v_m_salida, v_sal);
    v_m_pago := array_append(v_m_pago, v_pag);
    v_monto := v_monto + v_m_val;
  END LOOP;

  IF p_monto IS NOT NULL AND round(p_monto, 2) <> v_monto THEN
    RAISE EXCEPTION 'La suma de los medios (%) no coincide con el total del pago (%)', v_monto, round(p_monto, 2);
  END IF;

  SELECT array_agg(DISTINCT x) INTO v_factura_ids FROM unnest(p_factura_ids) AS x WHERE x IS NOT NULL;
  SELECT array_agg(DISTINCT x) INTO v_nc_ids FROM unnest(p_nota_credito_ids) AS x WHERE x IS NOT NULL;

  -- docs/71: un ajuste positivo solo (sin plata) también es un pago válido.
  IF v_monto = 0 AND v_nc_ids IS NULL AND v_ajuste <= 0 THEN
    RAISE EXCEPTION 'Ingresá un monto mayor a cero o elegí una nota de crédito para aplicar';
  END IF;
  IF v_ajuste < 0 AND v_monto + v_ajuste <= 0 THEN
    RAISE EXCEPTION 'El ajuste por redondeo (%) no puede ser mayor que lo que se paga (%)',
      formato_pesos(v_ajuste), formato_pesos(v_monto);
  END IF;

  -- Serializa los pagos de un mismo proveedor: dos cajas pagando la misma factura a la vez no
  -- pueden leer el mismo saldo y sobrepagarla.
  PERFORM 1 FROM proveedores WHERE id = p_proveedor_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Proveedor no encontrado';
  END IF;

  -- ── Validación de comprobantes a pagar (igual que v2) ──
  IF v_factura_ids IS NOT NULL THEN
    IF (SELECT count(*) FROM facturas_compra WHERE id = ANY(v_factura_ids)) <> cardinality(v_factura_ids) THEN
      RAISE EXCEPTION 'Alguno de los comprobantes elegidos no existe';
    END IF;
    SELECT * INTO v_mal FROM facturas_compra WHERE id = ANY(v_factura_ids) AND proveedor_id <> p_proveedor_id LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El comprobante % no es de este proveedor', COALESCE(v_mal.numero_comprobante, 'sin número');
    END IF;
    SELECT * INTO v_mal FROM facturas_compra WHERE id = ANY(v_factura_ids) AND anulada LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El comprobante % está anulado, no se le registran pagos', COALESCE(v_mal.numero_comprobante, 'sin número');
    END IF;
    SELECT * INTO v_mal FROM facturas_compra WHERE id = ANY(v_factura_ids) AND tipo_comprobante = 'nota_credito' LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El comprobante % es una nota de crédito: se aplica como crédito, no se paga', COALESCE(v_mal.numero_comprobante, 'sin número');
    END IF;
  END IF;

  -- ── Validación de notas de crédito (igual que v2) ──
  IF v_nc_ids IS NOT NULL THEN
    IF (SELECT count(*) FROM facturas_compra WHERE id = ANY(v_nc_ids)) <> cardinality(v_nc_ids) THEN
      RAISE EXCEPTION 'Alguna de las notas de crédito elegidas no existe';
    END IF;
    SELECT * INTO v_mal FROM facturas_compra WHERE id = ANY(v_nc_ids) AND proveedor_id <> p_proveedor_id LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'La nota de crédito % no es de este proveedor', COALESCE(v_mal.numero_comprobante, 'sin número');
    END IF;
    SELECT * INTO v_mal FROM facturas_compra WHERE id = ANY(v_nc_ids) AND anulada LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'La nota de crédito % está anulada', COALESCE(v_mal.numero_comprobante, 'sin número');
    END IF;
    SELECT * INTO v_mal FROM facturas_compra WHERE id = ANY(v_nc_ids) AND tipo_comprobante <> 'nota_credito' LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El comprobante % no es una nota de crédito', COALESCE(v_mal.numero_comprobante, 'sin número');
    END IF;
  END IF;

  -- ── Comprobantes a cancelar: los elegidos, o todos los pendientes; más viejos primero ──
  SELECT COALESCE(array_agg(d.id ORDER BY d.fecha_comprobante, d.created_at, d.id), '{}'),
         COALESCE(array_agg(d.saldo ORDER BY d.fecha_comprobante, d.created_at, d.id), '{}')
  INTO v_doc_ids, v_doc_saldos
  FROM (
    SELECT fc.id, fc.fecha_comprobante, fc.created_at,
           fc.total - COALESCE((SELECT SUM(a.monto) FROM pagos_proveedor_aplicaciones a
                                WHERE a.factura_compra_id = fc.id AND a.revertida_at IS NULL), 0) AS saldo
    FROM facturas_compra fc
    WHERE fc.proveedor_id = p_proveedor_id
      AND NOT fc.anulada
      AND fc.tipo_comprobante <> 'nota_credito'
      AND (v_factura_ids IS NULL OR fc.id = ANY(v_factura_ids))
  ) d
  WHERE d.saldo > 0;
  v_n := cardinality(v_doc_ids);

  -- ── NC con crédito disponible, más viejas primero ──
  IF v_nc_ids IS NOT NULL THEN
    SELECT COALESCE(array_agg(d.id ORDER BY d.fecha_comprobante, d.created_at, d.id), '{}'),
           COALESCE(array_agg(d.disp ORDER BY d.fecha_comprobante, d.created_at, d.id), '{}')
    INTO v_nc_orden, v_nc_disp
    FROM (
      SELECT fc.id, fc.fecha_comprobante, fc.created_at,
             fc.total - COALESCE((SELECT SUM(a.monto) FROM pagos_proveedor_aplicaciones a
                                  WHERE a.nota_credito_id = fc.id AND a.revertida_at IS NULL), 0) AS disp
      FROM facturas_compra fc
      WHERE fc.id = ANY(v_nc_ids)
    ) d
    WHERE d.disp > 0;
  END IF;
  v_m := cardinality(v_nc_orden);

  -- ── Paso 1: crédito de NC contra los comprobantes ──
  i := 1;
  j := 1;
  WHILE i <= v_n AND j <= v_m LOOP
    v_aplicar := LEAST(v_doc_saldos[i], v_nc_disp[j]);
    v_plan_doc := array_append(v_plan_doc, v_doc_ids[i]);
    v_plan_monto := array_append(v_plan_monto, v_aplicar);
    v_plan_nc := array_append(v_plan_nc, v_nc_orden[j]);
    v_doc_saldos[i] := v_doc_saldos[i] - v_aplicar;
    v_nc_disp[j] := v_nc_disp[j] - v_aplicar;
    v_total_nc := v_total_nc + v_aplicar;
    IF v_doc_saldos[i] <= 0 THEN i := i + 1; END IF;
    IF v_nc_disp[j] <= 0 THEN j := j + 1; END IF;
  END LOOP;

  IF v_monto = 0 AND v_ajuste = 0 AND v_total_nc = 0 THEN
    RAISE EXCEPTION 'No hay saldo pendiente al que aplicar la nota de crédito';
  END IF;

  -- ── Paso 2: repartir lo que cancela el pago (plata + ajuste, docs/71), más viejos primero.
  --    Lo que sobra queda a cuenta ──
  v_rest := v_monto + v_ajuste;
  i := 1;
  WHILE i <= v_n AND v_rest > 0 LOOP
    v_aplicar := LEAST(v_doc_saldos[i], v_rest);
    IF v_aplicar > 0 THEN
      v_plan_doc := array_append(v_plan_doc, v_doc_ids[i]);
      v_plan_monto := array_append(v_plan_monto, v_aplicar);
      v_plan_nc := array_append(v_plan_nc, NULL::UUID);
      v_pago_docs := array_append(v_pago_docs, v_doc_ids[i]);
      v_doc_saldos[i] := v_doc_saldos[i] - v_aplicar;
      v_rest := v_rest - v_aplicar;
    END IF;
    i := i + 1;
  END LOOP;

  -- docs/71: un ajuste positivo da por pagados centavos que faltaron; si sobra, crearía saldo a
  -- favor sin plata que lo respalde.
  IF v_ajuste > 0 AND v_rest > 0 THEN
    RAISE EXCEPTION 'El ajuste por redondeo tiene que quedar aplicado a comprobantes: con este pago sobran % (no hay tanto saldo pendiente)',
      formato_pesos(v_rest);
  END IF;

  -- ── Escritura ──
  -- Sin medios (solo NC) la cabecera queda en efectivo, como hacía v2 con monto 0.
  -- docs/71: un ajuste solo (sin plata ni NC) no tiene forma de pago.
  v_forma_cabecera := CASE WHEN v_cant = 0 AND v_total_nc = 0 THEN NULL
                           WHEN v_cant = 0 THEN 'efectivo'::forma_pago_egreso
                           WHEN v_cant = 1 THEN v_m_medio[1]
                           ELSE 'mixto'::forma_pago_egreso END;

  INSERT INTO pagos_proveedor (
    proveedor_id, factura_compra_id, monto, forma_pago, usuario_id, fecha, nota,
    cheque_numero, cheque_fecha_salida, cheque_fecha_vencimiento,
    ajuste_redondeo  -- docs/71
  )
  VALUES (
    p_proveedor_id,
    -- deprecated: solo si todo el pago cancela una única factura (compatibilidad con las pantallas actuales)
    CASE WHEN cardinality(v_pago_docs) = 1 AND v_rest = 0 THEN v_pago_docs[1] END,
    v_monto, v_forma_cabecera, auth.uid(), v_fecha, v_nota,
    -- Con un solo cheque, también en la cabecera: lo leen las apps que no conocen los medios.
    CASE WHEN v_cant = 1 AND v_m_medio[1] IN ('cheque', 'echeq') THEN v_m_numero[1] END,
    CASE WHEN v_cant = 1 AND v_m_medio[1] IN ('cheque', 'echeq') THEN v_m_salida[1] END,
    CASE WHEN v_cant = 1 AND v_m_medio[1] IN ('cheque', 'echeq') THEN v_m_pago[1] END,
    v_ajuste
  )
  RETURNING id INTO v_pago_id;

  INSERT INTO pagos_proveedor_aplicaciones
    (factura_compra_id, monto, pago_proveedor_id, nota_credito_id, operacion_id, usuario_id)
  SELECT t.doc, t.monto, CASE WHEN t.nc IS NULL THEN v_pago_id END, t.nc, v_pago_id, auth.uid()
  FROM unnest(v_plan_doc, v_plan_monto, v_plan_nc) AS t(doc, monto, nc);

  FOR i IN 1 .. v_cant LOOP
    INSERT INTO pagos_proveedor_medios (pago_proveedor_id, medio, monto, numero, banco, fecha_salida, fecha_pago, orden)
    VALUES (v_pago_id, v_m_medio[i], v_m_monto[i], v_m_numero[i], v_m_banco[i], v_m_salida[i], v_m_pago[i], i)
    RETURNING id INTO v_medio_id;
    v_m_ids := array_append(v_m_ids, v_medio_id);

    -- Con varios medios, el egreso dice cuál es (Egresos y el cierre lo listan por renglón).
    v_desc := 'Pago a proveedor' || COALESCE(' — ' || v_nota, '') ||
      CASE WHEN v_cant > 1 THEN ' (' ||
        CASE v_m_medio[i] WHEN 'efectivo' THEN 'efectivo' WHEN 'transferencia' THEN 'transferencia'
          WHEN 'cheque' THEN 'cheque N° ' || v_m_numero[i] ELSE 'echeq N° ' || v_m_numero[i] END || ')'
      ELSE '' END;

    INSERT INTO egresos (cierre_caja_id, origen, categoria, monto, descripcion, forma_pago, usuario_id, fecha,
                         pago_proveedor_id, pago_proveedor_medio_id)
    VALUES (p_cierre_caja_id, p_origen, 'pago_proveedor', v_m_monto[i], v_desc,
            v_m_medio[i], auth.uid(), v_fecha, v_pago_id, v_medio_id);

    -- Cheque y echeq no impactan cuentas (no son plata líquida al registrarse — docs/15).
    -- docs/58: el efectivo de Local (origen 'turno') sale del cajón y queda en el Cierre Z; la cuenta
    -- Efectivo (Caja Gestión) solo baja con lo que paga Gestión. La transferencia sale del banco igual.
    IF v_m_medio[i] = 'transferencia' OR (v_m_medio[i] = 'efectivo' AND p_origen = 'general') THEN
      INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
      SELECT cuenta_id, 'pago_proveedor', -abs(v_m_monto[i]), v_pago_id, auth.uid()
      FROM cuenta_forma_pago WHERE forma_pago = v_m_medio[i]::text::forma_pago_venta;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'pago_id', v_pago_id,
    'monto', v_monto,
    'ajuste_redondeo', v_ajuste,  -- docs/71
    'aplicado_pago', v_monto + v_ajuste - v_rest,
    'aplicado_nota_credito', v_total_nc,
    'a_cuenta', v_rest,
    'medios', to_jsonb(v_m_ids),
    'aplicaciones', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', a.id,
               'factura_compra_id', a.factura_compra_id,
               'monto', a.monto,
               'fuente', CASE WHEN a.nota_credito_id IS NULL THEN 'pago' ELSE 'nota_credito' END,
               'nota_credito_id', a.nota_credito_id
             ) ORDER BY a.created_at, a.id)
      FROM pagos_proveedor_aplicaciones a
      WHERE a.operacion_id = v_pago_id
    ), '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION registrar_pago_proveedor_v3(uuid, jsonb, uuid[], uuid[], origen_egreso, uuid, date, text, numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION registrar_pago_proveedor_v3(uuid, jsonb, uuid[], uuid[], origen_egreso, uuid, date, text, numeric, numeric) TO authenticated, service_role;
COMMENT ON FUNCTION registrar_pago_proveedor_v3(uuid, jsonb, uuid[], uuid[], origen_egreso, uuid, date, text, numeric, numeric) IS 'docs/65 + docs/71: pago a proveedor con varios medios. Cancela plata + p_ajuste_redondeo (con signo): positivo = centavos que faltaron (aplicado entero, o error), negativo = centavos que sobraron. Un ajuste positivo solo (sin medios) no mueve caja.';

-- ── 5. registrar_cobro_cliente ─────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS registrar_cobro_cliente(uuid, jsonb, uuid[], origen_egreso, date, text, numeric);

CREATE OR REPLACE FUNCTION registrar_cobro_cliente(
  p_cliente_id uuid, p_medios jsonb, p_venta_ids uuid[] DEFAULT NULL, p_origen origen_egreso DEFAULT 'turno',
  p_fecha date DEFAULT NULL, p_nota text DEFAULT NULL, p_monto numeric DEFAULT NULL,
  p_ajuste_redondeo numeric DEFAULT 0  -- docs/71
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_hoy DATE := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_fecha DATE;
  v_nota TEXT := NULLIF(btrim(p_nota), '');
  v_ajuste NUMERIC := ROUND(COALESCE(p_ajuste_redondeo, 0), 2);  -- docs/71
  v_elem jsonb;
  v_txt text;
  v_val NUMERIC;
  v_m_forma forma_pago_venta[] := '{}';
  v_m_monto NUMERIC[] := '{}';
  v_cant INT := 0;
  v_monto NUMERIC := 0;
  v_venta_ids UUID[];
  v_mal RECORD;
  v_cobrable NUMERIC;
  v_doc_ids UUID[] := '{}';
  v_doc_saldos NUMERIC[] := '{}';
  v_plan_doc UUID[] := '{}';
  v_plan_monto NUMERIC[] := '{}';
  v_rest NUMERIC;
  v_aplicar NUMERIC;
  v_pago_id UUID;
  v_sin_medios BOOLEAN;
  i INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF p_origen IS NULL THEN
    RAISE EXCEPTION 'Falta el origen del cobro';
  END IF;
  IF p_origen = 'general' AND NOT EXISTS (
    SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true
  ) THEN
    RAISE EXCEPTION 'Solo un administrador puede registrar un cobro desde Gestión';
  END IF;

  -- docs/71: un ajuste positivo solo (sin medios) es válido; no entra a la caja.
  IF p_medios IS NOT NULL AND jsonb_typeof(p_medios) <> 'array' THEN
    RAISE EXCEPTION 'Los medios de cobro tienen que venir como lista';
  END IF;
  v_sin_medios := p_medios IS NULL OR jsonb_array_length(p_medios) = 0;
  IF v_sin_medios AND v_ajuste <= 0 THEN
    RAISE EXCEPTION 'Agregá al menos un medio de cobro';
  END IF;

  IF p_origen = 'turno' THEN
    -- El cobro de Local entra al Cierre del día: tiene que haber caja abierta y es de hoy.
    -- docs/71: un ajuste solo no entra al Cierre (no tiene medios): no exige caja abierta.
    IF NOT v_sin_medios AND NOT EXISTS (SELECT 1 FROM aperturas_caja WHERE cierre_z_id IS NULL) THEN
      RAISE EXCEPTION 'Abrí la caja para registrar un cobro';
    END IF;
    IF p_fecha IS NOT NULL AND p_fecha <> v_hoy THEN
      RAISE EXCEPTION 'Un cobro en la caja de Local es siempre de hoy';
    END IF;
    v_fecha := v_hoy;
  ELSE
    v_fecha := COALESCE(p_fecha, v_hoy);
    IF v_fecha > v_hoy THEN
      RAISE EXCEPTION 'La fecha del cobro no puede ser futura';
    END IF;
  END IF;

  -- ── Medios ──
  FOR v_elem IN SELECT e FROM jsonb_array_elements(COALESCE(p_medios, '[]'::jsonb)) AS e LOOP
    v_cant := v_cant + 1;
    v_txt := v_elem->>'forma_pago';
    IF v_txt IS NULL OR v_txt NOT IN ('efectivo', 'transferencia', 'qr', 'tarjeta_debito', 'tarjeta_credito') THEN
      RAISE EXCEPTION 'Medio de cobro % no válido (efectivo, transferencia, QR, débito o crédito)', COALESCE(v_txt, 'vacío');
    END IF;
    BEGIN
      v_val := round((v_elem->>'monto')::numeric, 2);
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'El monto del medio % no es un número', v_cant;
    END;
    IF v_val IS NULL OR v_val <= 0 THEN
      RAISE EXCEPTION 'Cada medio tiene que tener un monto mayor a cero (medio %)', v_cant;
    END IF;
    v_m_forma := array_append(v_m_forma, v_txt::forma_pago_venta);
    v_m_monto := array_append(v_m_monto, v_val);
    v_monto := v_monto + v_val;
  END LOOP;
  IF p_monto IS NOT NULL AND round(p_monto, 2) <> v_monto THEN
    RAISE EXCEPTION 'La suma de los medios (%) no coincide con el total del cobro (%)', v_monto, round(p_monto, 2);
  END IF;
  IF v_ajuste < 0 AND v_monto + v_ajuste <= 0 THEN
    RAISE EXCEPTION 'El ajuste por redondeo (%) no puede ser mayor que lo que se cobra (%)',
      formato_pesos(v_ajuste), formato_pesos(v_monto);
  END IF;

  SELECT array_agg(DISTINCT x) INTO v_venta_ids FROM unnest(p_venta_ids) AS x WHERE x IS NOT NULL;

  -- Serializa los cobros de un mismo cliente (dos cajas cobrando la misma venta a la vez).
  PERFORM 1 FROM clientes WHERE id = p_cliente_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cliente no encontrado';
  END IF;

  -- ── Ventas elegidas ──
  IF v_venta_ids IS NOT NULL THEN
    IF (SELECT count(*) FROM ventas WHERE id = ANY(v_venta_ids)) <> cardinality(v_venta_ids) THEN
      RAISE EXCEPTION 'Alguna de las ventas elegidas no existe';
    END IF;
    SELECT numero INTO v_mal FROM ventas WHERE id = ANY(v_venta_ids) AND cliente_id IS DISTINCT FROM p_cliente_id LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'La venta N° % no es de este cliente', v_mal.numero; END IF;
    SELECT numero INTO v_mal FROM ventas WHERE id = ANY(v_venta_ids) AND forma_pago <> 'cuenta_corriente' LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'La venta N° % no es a cuenta corriente', v_mal.numero; END IF;
    SELECT numero INTO v_mal FROM ventas WHERE id = ANY(v_venta_ids) AND estado = 'anulada' LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'La venta N° % está anulada', v_mal.numero; END IF;
    SELECT numero INTO v_mal FROM ventas WHERE id = ANY(v_venta_ids) AND estado_interno IS NOT NULL LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'La venta N° % es de consumo interno: no se cobra, se finaliza', v_mal.numero; END IF;
    SELECT numero INTO v_mal FROM ventas_cuenta_corriente_saldo WHERE id = ANY(v_venta_ids) AND saldo_pendiente <= 0 LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'La venta N° % ya está saldada', v_mal.numero; END IF;
  END IF;

  -- No se cobra más de lo que el cliente debe (sin contar consumo interno pendiente).
  -- docs/71: lo que cancela el cobro es plata + ajuste.
  SELECT saldo_cobrable INTO v_cobrable FROM clientes_saldo WHERE id = p_cliente_id;
  IF COALESCE(v_cobrable, 0) <= 0 THEN
    RAISE EXCEPTION 'Este cliente no tiene saldo a cobrar';
  END IF;
  IF v_monto + v_ajuste > v_cobrable THEN
    RAISE EXCEPTION 'El cobro (%) supera lo que debe el cliente (%)', v_monto + v_ajuste, v_cobrable;
  END IF;

  -- ── Ventas a cancelar: las elegidas, o todas las pendientes; más viejas primero ──
  SELECT COALESCE(array_agg(s.id ORDER BY s.created_at, s.id), '{}'),
         COALESCE(array_agg(s.saldo_pendiente ORDER BY s.created_at, s.id), '{}')
  INTO v_doc_ids, v_doc_saldos
  FROM ventas_cuenta_corriente_saldo s
  WHERE s.cliente_id = p_cliente_id
    AND s.estado <> 'anulada' AND s.estado_interno IS NULL
    AND s.saldo_pendiente > 0
    AND (v_venta_ids IS NULL OR s.id = ANY(v_venta_ids));

  v_rest := v_monto + v_ajuste;
  i := 1;
  WHILE i <= cardinality(v_doc_ids) AND v_rest > 0 LOOP
    v_aplicar := LEAST(v_doc_saldos[i], v_rest);
    v_plan_doc := array_append(v_plan_doc, v_doc_ids[i]);
    v_plan_monto := array_append(v_plan_monto, v_aplicar);
    v_rest := v_rest - v_aplicar;
    i := i + 1;
  END LOOP;

  -- docs/71: un ajuste positivo da por cobrados centavos que faltaron; si sobra, crearía saldo a
  -- favor sin plata que lo respalde.
  IF v_ajuste > 0 AND v_rest > 0 THEN
    RAISE EXCEPTION 'El ajuste por redondeo tiene que quedar aplicado a ventas: con este cobro sobran % (no hay tanto saldo pendiente en ventas)',
      formato_pesos(v_rest);
  END IF;

  -- ── Escritura ──
  INSERT INTO pagos_cliente (cliente_id, venta_id, monto, forma_pago, usuario_id, origen, fecha, nota, ajuste_redondeo)
  VALUES (p_cliente_id,
          CASE WHEN cardinality(v_plan_doc) = 1 AND v_rest = 0 THEN v_plan_doc[1] END,  -- deprecated
          v_monto,
          CASE WHEN v_cant = 0 THEN NULL  -- docs/71: ajuste solo
               WHEN v_cant = 1 THEN v_m_forma[1] ELSE 'combinado'::forma_pago_venta END,
          auth.uid(), p_origen, v_fecha, v_nota, v_ajuste)
  RETURNING id INTO v_pago_id;

  INSERT INTO pagos_cliente_aplicaciones (pago_cliente_id, venta_id, monto, operacion_id, usuario_id)
  SELECT v_pago_id, t.doc, t.monto, v_pago_id, auth.uid()
  FROM unnest(v_plan_doc, v_plan_monto) AS t(doc, monto);

  FOR i IN 1 .. v_cant LOOP
    INSERT INTO pagos_cliente_medios (pago_cliente_id, forma_pago, monto, orden)
    VALUES (v_pago_id, v_m_forma[i], v_m_monto[i], i);
    -- docs/58 + D13: lo cobrado en la caja de Local no toca cuentas acá (efectivo queda en el cajón;
    -- el resto entra a su cuenta al validar el Z, como las ventas). Gestión: directo a la cuenta.
    IF p_origen = 'general' THEN
      INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
      SELECT cuenta_id, 'pago_cliente', v_m_monto[i], v_pago_id, auth.uid()
      FROM cuenta_forma_pago WHERE forma_pago = v_m_forma[i];
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'pago_id', v_pago_id,
    'monto', v_monto,
    'ajuste_redondeo', v_ajuste,  -- docs/71
    'aplicado', v_monto + v_ajuste - v_rest,
    'a_cuenta', v_rest,
    'aplicaciones', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', a.id, 'venta_id', a.venta_id, 'monto', a.monto)
                       ORDER BY array_position(v_plan_doc, a.venta_id))
      FROM pagos_cliente_aplicaciones a WHERE a.operacion_id = v_pago_id
    ), '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION registrar_cobro_cliente(uuid, jsonb, uuid[], origen_egreso, date, text, numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION registrar_cobro_cliente(uuid, jsonb, uuid[], origen_egreso, date, text, numeric, numeric) TO authenticated, service_role;
COMMENT ON FUNCTION registrar_cobro_cliente(uuid, jsonb, uuid[], origen_egreso, date, text, numeric, numeric) IS 'docs/68 + docs/71: cobro de cuenta corriente con varios medios. Cancela plata + p_ajuste_redondeo (con signo): positivo = centavos que faltaron (aplicado entero, o error), negativo = centavos que sobraron. Un ajuste positivo solo (sin medios) no entra a la caja.';

-- ── 6. Vistas ──────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW facturas_compra_saldo WITH (security_invoker = on) AS
 SELECT fc.id,
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
        CASE
            WHEN (fc.anulada OR (fc.tipo_comprobante = 'nota_credito'::tipo_comprobante_compra)) THEN (0)::numeric
            ELSE (fc.total - x.aplicado)
        END AS saldo_pendiente,
    x.aplicado AS total_aplicado,
        CASE
            WHEN ((fc.tipo_comprobante = 'nota_credito'::tipo_comprobante_compra) AND (NOT fc.anulada)) THEN (fc.total - x.aplicado)
            ELSE (0)::numeric
        END AS credito_disponible,
        CASE
            WHEN fc.anulada THEN 'anulada'::text
            WHEN ((fc.total - x.aplicado) <= (0)::numeric) THEN 'pagada'::text
            WHEN (x.aplicado > (0)::numeric) THEN 'parcial'::text
            ELSE 'pendiente'::text
        END AS estado,
    fc.copiada_de_id,
    fc.iva_alicuota,
    fc.tipo_compra,
    fc.devuelve_mercaderia,
    fc.ajuste_redondeo  -- docs/71
   FROM (facturas_compra fc
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN (fc.tipo_comprobante = 'nota_credito'::tipo_comprobante_compra) THEN ( SELECT COALESCE(sum(a.monto), (0)::numeric) AS "coalesce"
                       FROM pagos_proveedor_aplicaciones a
                      WHERE ((a.nota_credito_id = fc.id) AND (a.revertida_at IS NULL)))
                    ELSE ( SELECT COALESCE(sum(a.monto), (0)::numeric) AS "coalesce"
                       FROM pagos_proveedor_aplicaciones a
                      WHERE ((a.factura_compra_id = fc.id) AND (a.revertida_at IS NULL)))
                END AS aplicado) x);

-- docs/71: lo que cancela cada pago es monto + ajuste_redondeo (ver docs/52 + docs/69 para el resto).
CREATE OR REPLACE VIEW pagos_proveedor_a_cuenta WITH (security_invoker = on) AS
 SELECT id,
    proveedor_id,
    fecha,
    created_at,
    monto,
    aplicado,
    vigente,
    a_cuenta,
    (a_cuenta - a_cuenta_libre) AS cancela_saldo_inicial,
    a_cuenta_libre,
    ajuste_redondeo
   FROM ( SELECT x.id,
            x.proveedor_id,
            x.fecha,
            x.created_at,
            x.monto,
            x.aplicado,
            x.vigente,
            x.a_cuenta,
            x.ajuste_redondeo,
            GREATEST((0)::numeric, LEAST(x.a_cuenta, (sum(GREATEST(x.a_cuenta, (0)::numeric)) OVER (PARTITION BY x.proveedor_id ORDER BY x.fecha, x.created_at, x.id) - GREATEST(p.saldo_inicial, (0)::numeric)))) AS a_cuenta_libre
           FROM (( SELECT pp.id,
                    pp.proveedor_id,
                    pp.fecha,
                    pp.created_at,
                    pp.monto,
                    pp.ajuste_redondeo,
                    ap.aplicado,
                    v.vigente,
                        CASE
                            WHEN v.vigente THEN ((pp.monto + pp.ajuste_redondeo) - ap.aplicado)
                            ELSE (0)::numeric
                        END AS a_cuenta
                   FROM ((pagos_proveedor pp
                     CROSS JOIN LATERAL ( SELECT COALESCE(sum(a.monto), (0)::numeric) AS aplicado
                           FROM pagos_proveedor_aplicaciones a
                          WHERE ((a.pago_proveedor_id = pp.id) AND (a.revertida_at IS NULL))) ap)
                     CROSS JOIN LATERAL ( SELECT (((pp.monto + pp.ajuste_redondeo) > (0)::numeric) AND (pp.revierte_pago_proveedor_id IS NULL) AND (NOT (EXISTS ( SELECT 1
                                   FROM pagos_proveedor r
                                  WHERE (r.revierte_pago_proveedor_id = pp.id))))) AS vigente) v)) x
             JOIN proveedores p ON ((p.id = x.proveedor_id)))) b;

COMMENT ON VIEW pagos_proveedor_a_cuenta IS 'docs/52 + docs/69 + docs/71: por pago, lo aplicado vigente y lo que queda a cuenta (monto + ajuste_redondeo − aplicado; 0 en reversiones, revertidos y operaciones solo de NC). cancela_saldo_inicial = parte que cancela el saldo inicial (pagos más viejos primero); a_cuenta_libre = lo que se puede aplicar a comprobantes.';

CREATE OR REPLACE VIEW proveedores_a_cuenta WITH (security_invoker = on) AS
 SELECT proveedor_id,
    sum(a_cuenta) AS a_cuenta,
    count(*) FILTER (WHERE (a_cuenta > (0)::numeric)) AS pagos_con_saldo,
    sum(a_cuenta_libre) AS a_cuenta_libre
   FROM pagos_proveedor_a_cuenta
  GROUP BY proveedor_id;

CREATE OR REPLACE VIEW proveedores_saldo WITH (security_invoker = on) AS
 SELECT p.id,
    p.razon_social,
    p.cuit,
    p.direccion,
    p.telefono,
    p.mail,
    p.contacto,
    p.margen_1_default,
    p.margen_2_default,
    p.saldo_inicial,
    p.created_at,
    ((p.saldo_inicial + COALESCE(facturado.total_facturado, (0)::numeric)) - COALESCE(pagado.total_pagado, (0)::numeric)) AS saldo_actual,
    p.observaciones,
    p.saldo_inicial_fecha,
    p.saldo_inicial_usuario_id,
    u.nombre AS saldo_inicial_usuario_nombre,
    (p.saldo_inicial - COALESCE((ac.a_cuenta - ac.a_cuenta_libre), (0)::numeric)) AS saldo_inicial_pendiente,
    COALESCE(ac.a_cuenta_libre, (0)::numeric) AS a_cuenta_libre
   FROM ((((proveedores p
     LEFT JOIN ( SELECT facturas_compra.proveedor_id,
            sum(
                CASE
                    WHEN (facturas_compra.tipo_comprobante = 'nota_credito'::tipo_comprobante_compra) THEN (- facturas_compra.total)
                    ELSE facturas_compra.total
                END) AS total_facturado
           FROM facturas_compra
          WHERE (facturas_compra.anulada = false)
          GROUP BY facturas_compra.proveedor_id) facturado ON ((facturado.proveedor_id = p.id)))
     LEFT JOIN ( SELECT pagos_proveedor.proveedor_id,
            sum(pagos_proveedor.monto + pagos_proveedor.ajuste_redondeo) AS total_pagado  -- docs/71
           FROM pagos_proveedor
          GROUP BY pagos_proveedor.proveedor_id) pagado ON ((pagado.proveedor_id = p.id)))
     LEFT JOIN proveedores_a_cuenta ac ON ((ac.proveedor_id = p.id)))
     LEFT JOIN perfiles_publico u ON ((u.id = p.saldo_inicial_usuario_id)));

CREATE OR REPLACE VIEW pagos_cliente_a_cuenta WITH (security_invoker = on) AS
 SELECT id,
    cliente_id,
    fecha,
    created_at,
    monto,
    origen,
    aplicado,
    vigente,
    a_cuenta,
    (a_cuenta - a_cuenta_libre) AS cancela_saldo_inicial,
    a_cuenta_libre,
    ajuste_redondeo
   FROM ( SELECT x.id,
            x.cliente_id,
            x.fecha,
            x.created_at,
            x.monto,
            x.origen,
            x.aplicado,
            x.vigente,
            x.a_cuenta,
            x.ajuste_redondeo,
            GREATEST((0)::numeric, LEAST(x.a_cuenta, (sum(GREATEST(x.a_cuenta, (0)::numeric)) OVER (PARTITION BY x.cliente_id ORDER BY x.fecha, x.created_at, x.id) - GREATEST(c.saldo_inicial, (0)::numeric)))) AS a_cuenta_libre
           FROM (( SELECT pc.id,
                    pc.cliente_id,
                    pc.fecha,
                    pc.created_at,
                    pc.monto,
                    pc.origen,
                    pc.ajuste_redondeo,
                    ap.aplicado,
                    v.vigente,
                        CASE
                            WHEN v.vigente THEN ((pc.monto + pc.ajuste_redondeo) - ap.aplicado)
                            ELSE (0)::numeric
                        END AS a_cuenta
                   FROM ((pagos_cliente pc
                     CROSS JOIN LATERAL ( SELECT COALESCE(sum(a.monto), (0)::numeric) AS aplicado
                           FROM pagos_cliente_aplicaciones a
                          WHERE ((a.pago_cliente_id = pc.id) AND (a.revertida_at IS NULL))) ap)
                     CROSS JOIN LATERAL ( SELECT (((pc.monto + pc.ajuste_redondeo) > (0)::numeric) AND (pc.revierte_pago_cliente_id IS NULL) AND (NOT (EXISTS ( SELECT 1
                                   FROM pagos_cliente r
                                  WHERE (r.revierte_pago_cliente_id = pc.id))))) AS vigente) v)) x
             JOIN clientes c ON ((c.id = x.cliente_id)))) b;

COMMENT ON VIEW pagos_cliente_a_cuenta IS 'docs/68 + docs/69 + docs/71: por cobro, lo aplicado vigente y lo que queda a cuenta (monto + ajuste_redondeo − aplicado; 0 en reversiones y revertidos). cancela_saldo_inicial = parte que cancela el saldo inicial (cobros más viejos primero); a_cuenta_libre = lo que se puede aplicar a ventas.';

CREATE OR REPLACE VIEW clientes_saldo WITH (security_invoker = on) AS
 SELECT c.id,
    c.razon_social,
    c.nombre_fantasia,
    c.cuit,
    c.domicilio,
    c.mail,
    c.celular,
    c.activo,
    c.saldo_inicial,
    c.created_at,
    ((c.saldo_inicial + COALESCE(vt.neto, (0)::numeric)) - COALESCE(pg.total_pagado, (0)::numeric)) AS saldo_actual,
    c.condicion_iva,
    c.tipo,
    c.perfil_id,
    COALESCE(vt.deuda_comprobantes, (0)::numeric) AS deuda_comprobantes,
    COALESCE(vt.interno_pendiente, (0)::numeric) AS consumo_interno_pendiente,
    COALESCE(ac.a_cuenta, (0)::numeric) AS a_cuenta,
    (((c.saldo_inicial + COALESCE(vt.neto, (0)::numeric)) - COALESCE(vt.interno_pendiente, (0)::numeric)) - COALESCE(pg.total_pagado, (0)::numeric)) AS saldo_cobrable,
    COALESCE(vt.comprobantes_abiertos, (0)::bigint) AS comprobantes_abiertos,
    c.saldo_inicial_fecha,
    c.saldo_inicial_usuario_id,
    u.nombre AS saldo_inicial_usuario_nombre,
    (c.saldo_inicial - COALESCE((ac.a_cuenta - ac.a_cuenta_libre), (0)::numeric)) AS saldo_inicial_pendiente,
    COALESCE(ac.a_cuenta_libre, (0)::numeric) AS a_cuenta_libre
   FROM ((((clientes c
     LEFT JOIN ( SELECT s.cliente_id,
            sum((s.total - s.total_devuelto)) FILTER (WHERE (s.estado_interno IS DISTINCT FROM 'finalizado'::estado_venta_interna)) AS neto,
            sum(s.saldo_pendiente) FILTER (WHERE (s.estado_interno IS NULL)) AS deuda_comprobantes,
            sum((s.total - s.total_devuelto)) FILTER (WHERE (s.estado_interno = 'pendiente'::estado_venta_interna)) AS interno_pendiente,
            count(*) FILTER (WHERE (s.estado_cuenta = ANY (ARRAY['pendiente'::text, 'parcial'::text, 'a_revisar'::text]))) AS comprobantes_abiertos
           FROM ventas_cuenta_corriente_saldo s
          WHERE (s.estado <> 'anulada'::estado_comprobante)
          GROUP BY s.cliente_id) vt ON ((vt.cliente_id = c.id)))
     LEFT JOIN ( SELECT pagos_cliente.cliente_id,
            sum(pagos_cliente.monto + pagos_cliente.ajuste_redondeo) AS total_pagado  -- docs/71
           FROM pagos_cliente
          GROUP BY pagos_cliente.cliente_id) pg ON ((pg.cliente_id = c.id)))
     LEFT JOIN ( SELECT pagos_cliente_a_cuenta.cliente_id,
            sum(pagos_cliente_a_cuenta.a_cuenta) AS a_cuenta,
            sum(pagos_cliente_a_cuenta.a_cuenta_libre) AS a_cuenta_libre
           FROM pagos_cliente_a_cuenta
          GROUP BY pagos_cliente_a_cuenta.cliente_id) ac ON ((ac.cliente_id = c.id)))
     LEFT JOIN perfiles_publico u ON ((u.id = c.saldo_inicial_usuario_id)));

-- Las vistas existentes conservan sus GRANT con CREATE OR REPLACE; se repiten por si se corre sobre
-- una base donde alguna se hubiera recreado sin ellos.
REVOKE ALL ON facturas_compra_saldo, pagos_proveedor_a_cuenta, proveedores_a_cuenta, proveedores_saldo,
              pagos_cliente_a_cuenta, clientes_saldo FROM PUBLIC, anon;
GRANT SELECT ON facturas_compra_saldo, pagos_proveedor_a_cuenta, proveedores_a_cuenta, proveedores_saldo,
                pagos_cliente_a_cuenta, clientes_saldo TO authenticated;
GRANT ALL ON facturas_compra_saldo, pagos_proveedor_a_cuenta, proveedores_a_cuenta, proveedores_saldo,
             pagos_cliente_a_cuenta, clientes_saldo TO service_role;

-- ── 7. revertir_movimiento: la reversión copia también el ajuste (en negativo) ─────────────────────
CREATE OR REPLACE FUNCTION revertir_movimiento(p_auditoria_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_auditoria auditoria%ROWTYPE;
  v_row JSONB;
  v_pago_orig_id UUID;
  v_pago_rev_id UUID;
  v_monto NUMERIC;
  v_egreso egresos%ROWTYPE;
  v_egreso_rev_id UUID;  -- docs/38
  v_medio pagos_proveedor_medios%ROWTYPE;  -- docs/65
  v_medio_rev_id UUID;
  v_mapa_medios JSONB := '{}'::jsonb;  -- medio original → medio espejo
  v_egresos_revertidos INT := 0;
  v_medio_cli pagos_cliente_medios%ROWTYPE;  -- docs/68
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

    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, usuario_id, origen)  -- docs/70: origen
    VALUES ((v_row->>'producto_id')::UUID, (v_row->>'ubicacion')::ubicacion_stock, 'ajuste',
            -1 * (v_row->>'cantidad')::NUMERIC, 'Reversión de ajuste (auditoría)', auth.uid(), 'reversion_ajuste');

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
      cheque_numero, cheque_fecha_salida, cheque_fecha_vencimiento, nota,
      ajuste_redondeo  -- docs/71
    )
    VALUES (
      (v_row->>'proveedor_id')::UUID, NULLIF(v_row->>'factura_compra_id','')::UUID,
      -1 * v_monto, (v_row->>'forma_pago')::forma_pago_egreso, auth.uid(), v_pago_orig_id,
      v_row->>'cheque_numero', NULLIF(v_row->>'cheque_fecha_salida','')::DATE, NULLIF(v_row->>'cheque_fecha_vencimiento','')::DATE,
      'Reversión desde Historial',
      -1 * COALESCE((v_row->>'ajuste_redondeo')::NUMERIC, 0)
    )
    RETURNING id INTO v_pago_rev_id;

    -- docs/65: cada medio del pago tiene su espejo negativo en la reversión (los cheques salen de
    -- la cartera vigente).
    FOR v_medio IN
      SELECT * FROM pagos_proveedor_medios WHERE pago_proveedor_id = v_pago_orig_id ORDER BY orden
    LOOP
      INSERT INTO pagos_proveedor_medios (pago_proveedor_id, medio, monto, numero, banco, fecha_salida, fecha_pago, propio, orden, revierte_medio_id)
      VALUES (v_pago_rev_id, v_medio.medio, -1 * v_medio.monto, v_medio.numero, v_medio.banco, v_medio.fecha_salida,
              v_medio.fecha_pago, v_medio.propio, v_medio.orden, v_medio.id)
      RETURNING id INTO v_medio_rev_id;
      v_mapa_medios := v_mapa_medios || jsonb_build_object(v_medio.id::text, v_medio_rev_id);
    END LOOP;

    IF v_monto <> 0 THEN
      -- docs/65: todos los egresos del pago (uno por medio), con su origen real (turno = caja de
      -- Local, general = Gestión). Antes se tomaba uno solo (LIMIT 1).
      FOR v_egreso IN
        SELECT * FROM egresos
        WHERE pago_proveedor_id = v_pago_orig_id AND revierte_egreso_id IS NULL
        ORDER BY created_at, id
      LOOP
        INSERT INTO egresos (origen, categoria, monto, descripcion, forma_pago, usuario_id, revierte_egreso_id,
                             pago_proveedor_id, pago_proveedor_medio_id)
        VALUES (v_egreso.origen, 'pago_proveedor', -1 * v_egreso.monto, 'Reversión de pago a proveedor',
                v_egreso.forma_pago, auth.uid(), v_egreso.id, v_pago_rev_id,
                (v_mapa_medios->>(v_egreso.pago_proveedor_medio_id::text))::UUID);
        v_egresos_revertidos := v_egresos_revertidos + 1;
      END LOOP;

      IF v_egresos_revertidos = 0 THEN
        -- Pago anterior a docs/31 sin egreso vinculado (el backfill vinculó todos los que había).
        INSERT INTO egresos (origen, categoria, monto, descripcion, forma_pago, usuario_id, pago_proveedor_id)
        VALUES ('turno', 'pago_proveedor', -1 * v_monto, 'Reversión de pago a proveedor',
                (v_row->>'forma_pago')::forma_pago_egreso, auth.uid(), v_pago_rev_id);
      END IF;

      -- docs/58: espejo de lo que el pago movió en cuentas (neto de correcciones). Un pago en
      -- efectivo de Local no movió la cuenta Efectivo, así que su reversión tampoco la mueve.
      -- Con varios medios suma todos los movimientos del pago, por cuenta.
      INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
      SELECT mc.cuenta_id, 'pago_proveedor', -1 * sum(mc.monto), v_pago_orig_id, auth.uid()
      FROM movimientos_cuenta mc
      WHERE mc.referencia_id = v_pago_orig_id AND mc.tipo = 'pago_proveedor'
      GROUP BY mc.cuenta_id
      HAVING sum(mc.monto) <> 0;
    END IF;

    -- Las aplicaciones de la operación (plata del pago y NC usadas en ese acto) dejan de contar:
    -- los comprobantes vuelven a su saldo anterior y la NC recupera su crédito.
    UPDATE pagos_proveedor_aplicaciones
    SET revertida_at = now(), revertida_por = auth.uid()
    WHERE operacion_id = v_pago_orig_id AND revertida_at IS NULL;

  ELSIF v_auditoria.tabla_afectada = 'pagos_cliente' THEN
    -- docs/68: reversión espejo del cobro. Copia el origen (un cobro de Local revertido resta del
    -- Cierre del día en que se revierte, igual que un egreso), invierte cada medio, devuelve a la
    -- cuenta solo lo que el cobro movió (neto) y deja sin efecto sus aplicaciones.
    v_pago_orig_id := (v_row->>'id')::UUID;
    v_monto := (v_row->>'monto')::NUMERIC;
    IF v_row->>'revierte_pago_cliente_id' IS NOT NULL OR v_monto < 0 THEN
      RAISE EXCEPTION 'Esto ya es la reversión de un cobro — no se revierte de nuevo';
    END IF;
    IF EXISTS (SELECT 1 FROM pagos_cliente WHERE revierte_pago_cliente_id = v_pago_orig_id) THEN
      RAISE EXCEPTION 'Este cobro ya fue revertido';
    END IF;

    INSERT INTO pagos_cliente (cliente_id, venta_id, monto, forma_pago, usuario_id, revierte_pago_cliente_id, origen, nota,
                               ajuste_redondeo)  -- docs/71
    SELECT pc.cliente_id, pc.venta_id, -1 * pc.monto, pc.forma_pago, auth.uid(), pc.id, pc.origen, 'Reversion desde Historial',
           -1 * pc.ajuste_redondeo
    FROM pagos_cliente pc WHERE pc.id = v_pago_orig_id
    RETURNING id INTO v_pago_rev_id;
    IF v_pago_rev_id IS NULL THEN RAISE EXCEPTION 'Cobro no encontrado'; END IF;

    FOR v_medio_cli IN SELECT * FROM pagos_cliente_medios WHERE pago_cliente_id = v_pago_orig_id ORDER BY orden LOOP
      INSERT INTO pagos_cliente_medios (pago_cliente_id, forma_pago, monto, orden, revierte_medio_id)
      VALUES (v_pago_rev_id, v_medio_cli.forma_pago, -1 * v_medio_cli.monto, v_medio_cli.orden, v_medio_cli.id);
    END LOOP;

    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
    SELECT mc.cuenta_id, 'pago_cliente', -1 * sum(mc.monto), v_pago_orig_id, auth.uid()
    FROM movimientos_cuenta mc
    WHERE mc.referencia_id = v_pago_orig_id AND mc.tipo = 'pago_cliente'
    GROUP BY mc.cuenta_id
    HAVING sum(mc.monto) <> 0;

    UPDATE pagos_cliente_aplicaciones
    SET revertida_at = now(), revertida_por = auth.uid()
    WHERE pago_cliente_id = v_pago_orig_id AND revertida_at IS NULL;

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
$$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (solo lectura)
-- ════════════════════════════════════════════════════════════════════════════════════════════════
SELECT 'una_sola_firma' AS control, p.proname, count(*) AS versiones,
       bool_and(pg_get_function_identity_arguments(p.oid) LIKE '%p_ajuste_redondeo%') AS con_ajuste
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
WHERE p.proname IN ('cargar_factura_compra', 'cargar_factura_compra_contado', 'editar_factura_compra',
                    'registrar_pago_proveedor_v3', 'registrar_cobro_cliente')
GROUP BY p.proname
UNION ALL
SELECT 'security_invoker', c.relname, NULL, COALESCE('security_invoker=on' = ANY (c.reloptions), false)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
WHERE c.relname IN ('facturas_compra_saldo', 'pagos_proveedor_a_cuenta', 'proveedores_a_cuenta', 'proveedores_saldo',
                    'pagos_cliente_a_cuenta', 'clientes_saldo')
UNION ALL
SELECT 'anon_sin_execute', p.proname, NULL, NOT has_function_privilege('anon', p.oid, 'EXECUTE')
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
WHERE p.proname IN ('cargar_factura_compra', 'cargar_factura_compra_contado', 'editar_factura_compra',
                    'registrar_pago_proveedor_v3', 'registrar_cobro_cliente')
UNION ALL
SELECT 'facturas_cuadran', 'facturas_compra', count(*), bool_and(total = total_sin_iva + iva + ajuste_redondeo)
FROM facturas_compra
ORDER BY 1, 2;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — tests (BEGIN … ROLLBACK). Corre como Alicia (admin) y como "Cajero de prueba".
-- Termina SIEMPRE con RAISE EXCEPTION 'RESULTADO: …' (la transacción aborta y no queda nada).
-- ════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
  c_alicia CONSTANT uuid := '696bd7fb-aa27-4051-b8cd-d611ee90d1ae';
  c_cajero CONSTANT uuid := 'c982462a-526a-4ee7-aade-4488b74966b3';
  v_prov uuid; v_cli uuid;
  v_f1 uuid; v_f2 uuid; v_f3 uuid; v_f4 uuid; v_nc uuid;
  v_v1 uuid; v_v2 uuid; v_v3 uuid;
  v_res jsonb; v_pago uuid; v_aud uuid;
  v_msg text;
  v_ok text[] := '{}';
  r RECORD;
  v_n numeric;
  v_items_100 jsonb := '[{"producto_id": null, "descripcion": "ZZ SERVICIO", "cantidad": 1, "precio_unitario_sin_iva": 100.01}]';
  v_hoy date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
BEGIN
  SET LOCAL virikyna.suppress_audit = 'false';
  INSERT INTO proveedores (razon_social) VALUES ('ZZ TEST DOCS71') RETURNING id INTO v_prov;
  INSERT INTO clientes (razon_social) VALUES ('ZZ TEST DOCS71') RETURNING id INTO v_cli;

  -- T1. Cajero: factura de servicios con ajuste −0,02 → total fuera del IVA.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_cajero, 'role', 'authenticated')::text, true);
  v_f1 := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
    p_punto_venta => '1', p_numero_comprobante => 'T1', p_fecha_comprobante => v_hoy, p_fecha_fiscal => NULL,
    p_forma_pago => 'cuenta_corriente', p_items => v_items_100, p_iva_alicuota => 21, p_tipo_compra => 'servicios',
    p_ajuste_redondeo => -0.02);
  SELECT * INTO r FROM facturas_compra_saldo WHERE id = v_f1;
  IF r.total_sin_iva <> 100.01 OR r.iva <> 21.00 OR r.ajuste_redondeo <> -0.02 OR r.total <> 120.99 OR r.saldo_pendiente <> 120.99 THEN
    RAISE EXCEPTION 'T1: % / % / % / % / %', r.total_sin_iva, r.iva, r.ajuste_redondeo, r.total, r.saldo_pendiente;
  END IF;
  v_ok := array_append(v_ok, 'T1');

  -- T2. Sin el parámetro (app vieja): ajuste 0. D5: dos líneas de 1,005 → cada una ROUND = 1,01, total
  --     2,02 (igual que la pantalla). Con la suma sin redondear de antes daba 2,01.
  v_f2 := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
    p_punto_venta => '1', p_numero_comprobante => 'T2', p_fecha_comprobante => v_hoy, p_fecha_fiscal => NULL,
    p_forma_pago => 'cuenta_corriente',
    p_items => '[{"producto_id": null, "descripcion": "A", "cantidad": 1, "precio_unitario_sin_iva": 1.005},
                 {"producto_id": null, "descripcion": "B", "cantidad": 1, "precio_unitario_sin_iva": 1.005}]',
    p_iva_alicuota => 0, p_tipo_compra => 'servicios');
  SELECT * INTO r FROM facturas_compra WHERE id = v_f2;
  IF r.ajuste_redondeo <> 0 OR r.total_sin_iva <> 2.02 OR r.total <> 2.02
     OR r.total_sin_iva <> (SELECT sum(precio_total_sin_iva) FROM facturas_compra_items WHERE factura_compra_id = v_f2) THEN
    RAISE EXCEPTION 'T2: % / % / %', r.ajuste_redondeo, r.total_sin_iva, r.total;
  END IF;
  v_ok := array_append(v_ok, 'T2');

  -- T3. Ajuste que deja el total negativo: rechaza.
  BEGIN
    PERFORM cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
      p_punto_venta => '1', p_numero_comprobante => 'T3', p_fecha_comprobante => v_hoy, p_fecha_fiscal => NULL,
      p_forma_pago => 'cuenta_corriente', p_items => v_items_100, p_iva_alicuota => 21, p_tipo_compra => 'servicios',
      p_ajuste_redondeo => -200);
    RAISE EXCEPTION 'T3: debía fallar';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg NOT LIKE 'El total del comprobante no puede quedar negativo%' THEN RAISE EXCEPTION 'T3: %', v_msg; END IF;
  END;
  v_ok := array_append(v_ok, 'T3');

  -- T4. NC con ajuste (D6): el crédito es el total con el ajuste.
  v_nc := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'nota_credito', p_letra => 'A',
    p_punto_venta => '1', p_numero_comprobante => 'T4', p_fecha_comprobante => v_hoy, p_fecha_fiscal => NULL,
    p_forma_pago => 'cuenta_corriente', p_items => '[{"producto_id": null, "descripcion": "NC", "cantidad": 1, "precio_unitario_sin_iva": 10}]',
    p_iva_alicuota => 0, p_tipo_compra => 'servicios', p_ajuste_redondeo => 0.03);
  IF (SELECT credito_disponible FROM facturas_compra_saldo WHERE id = v_nc) <> 10.03 THEN RAISE EXCEPTION 'T4'; END IF;
  v_ok := array_append(v_ok, 'T4');

  -- T5. Admin: editar alícuota conserva el ajuste; editar el ajuste recalcula; el cajero no edita.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_alicia, 'role', 'authenticated')::text, true);
  PERFORM editar_factura_compra(p_factura_id => v_f1, p_iva_alicuota => 0);
  SELECT * INTO r FROM facturas_compra WHERE id = v_f1;
  IF r.iva <> 0 OR r.ajuste_redondeo <> -0.02 OR r.total <> 99.99 THEN RAISE EXCEPTION 'T5a: % / % / %', r.iva, r.ajuste_redondeo, r.total; END IF;
  PERFORM editar_factura_compra(p_factura_id => v_f1, p_iva_alicuota => 21, p_ajuste_redondeo => 0.01);
  SELECT * INTO r FROM facturas_compra WHERE id = v_f1;
  IF r.iva <> 21 OR r.ajuste_redondeo <> 0.01 OR r.total <> 121.02 THEN RAISE EXCEPTION 'T5b: % / % / %', r.iva, r.ajuste_redondeo, r.total; END IF;
  PERFORM editar_factura_compra(p_factura_id => v_f1, p_numero_comprobante => 'T1-bis');  -- sin tocar importes
  IF (SELECT total FROM facturas_compra WHERE id = v_f1) <> 121.02 THEN RAISE EXCEPTION 'T5c'; END IF;
  v_ok := array_append(v_ok, 'T5');

  -- T6. Contado con ajuste (Caja Gestión, admin): el pago es el total con el ajuste.
  v_res := cargar_factura_compra_contado(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
    p_punto_venta => '1', p_numero_comprobante => 'T6', p_fecha_comprobante => v_hoy, p_fecha_fiscal => NULL,
    p_items => v_items_100, p_origen => 'general', p_iva_alicuota => 21, p_tipo_compra => 'servicios',
    p_ajuste_redondeo => -0.01);
  IF (v_res->>'monto')::numeric <> 121.00
     OR (SELECT estado FROM facturas_compra_saldo WHERE id = (v_res->>'factura_id')::uuid) <> 'pagada' THEN
    RAISE EXCEPTION 'T6: %', v_res;
  END IF;
  v_ok := array_append(v_ok, 'T6');

  -- T7. Con un pago aplicado no se cambia el ajuste.
  BEGIN
    PERFORM editar_factura_compra(p_factura_id => (v_res->>'factura_id')::uuid, p_ajuste_redondeo => 0);
    RAISE EXCEPTION 'T7: debía fallar';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg NOT LIKE '%ni el ajuste por redondeo%' THEN RAISE EXCEPTION 'T7: %', v_msg; END IF;
  END;
  v_ok := array_append(v_ok, 'T7');

  -- T8. Cajero (Local): pago 121 + ajuste +0,02 a T1 (121,02) → pagada, egreso de 121, nada a cuenta.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_cajero, 'role', 'authenticated')::text, true);
  v_res := registrar_pago_proveedor_v3(p_proveedor_id => v_prov,
    p_medios => '[{"medio": "efectivo", "monto": 121}]', p_factura_ids => ARRAY[v_f1], p_origen => 'turno',
    p_monto => 121, p_ajuste_redondeo => 0.02);
  v_pago := (v_res->>'pago_id')::uuid;
  IF (SELECT estado FROM facturas_compra_saldo WHERE id = v_f1) <> 'pagada'
     OR (v_res->>'a_cuenta')::numeric <> 0 OR (v_res->>'aplicado_pago')::numeric <> 121.02
     OR (SELECT sum(monto) FROM egresos WHERE pago_proveedor_id = v_pago) <> 121
     OR (SELECT a_cuenta FROM pagos_proveedor_a_cuenta WHERE id = v_pago) <> 0 THEN
    RAISE EXCEPTION 'T8: %', v_res;
  END IF;
  v_ok := array_append(v_ok, 'T8');

  -- T9. Ajuste negativo: T2 (2,02) se paga con 2,05 − 0,03 → pagada y nada a cuenta.
  v_res := registrar_pago_proveedor_v3(p_proveedor_id => v_prov,
    p_medios => '[{"medio": "efectivo", "monto": 2.05}]', p_factura_ids => ARRAY[v_f2], p_origen => 'turno',
    p_ajuste_redondeo => -0.03);
  IF (SELECT estado FROM facturas_compra_saldo WHERE id = v_f2) <> 'pagada' OR (v_res->>'a_cuenta')::numeric <> 0
     OR (SELECT a_cuenta FROM pagos_proveedor_a_cuenta WHERE id = (v_res->>'pago_id')::uuid) <> 0 THEN
    RAISE EXCEPTION 'T9: %', v_res;
  END IF;
  v_ok := array_append(v_ok, 'T9');

  -- T10. Ajuste negativo mayor que la plata, y ajuste positivo que sobraría: rechazan.
  BEGIN
    PERFORM registrar_pago_proveedor_v3(p_proveedor_id => v_prov, p_medios => '[{"medio": "efectivo", "monto": 1}]',
      p_origen => 'turno', p_ajuste_redondeo => -1);
    RAISE EXCEPTION 'T10a: debía fallar';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg NOT LIKE 'El ajuste por redondeo (%) no puede ser mayor%' THEN RAISE EXCEPTION 'T10a: %', v_msg; END IF;
  END;
  BEGIN
    PERFORM registrar_pago_proveedor_v3(p_proveedor_id => v_prov, p_medios => '[]', p_origen => 'turno', p_ajuste_redondeo => 0.05);
    RAISE EXCEPTION 'T10b: debía fallar';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg NOT LIKE 'El ajuste por redondeo tiene que quedar aplicado%' THEN RAISE EXCEPTION 'T10b: %', v_msg; END IF;
  END;
  v_ok := array_append(v_ok, 'T10');

  -- T11. Ajuste solo (sin plata): F3 de 1000,02 pagada con 1000 → quedan 0,02 → ajuste 0,02 solo.
  v_f3 := cargar_factura_compra(p_proveedor_id => v_prov, p_tipo_comprobante => 'factura', p_letra => 'A',
    p_punto_venta => '1', p_numero_comprobante => 'T11', p_fecha_comprobante => v_hoy, p_fecha_fiscal => NULL,
    p_forma_pago => 'cuenta_corriente', p_items => '[{"producto_id": null, "descripcion": "X", "cantidad": 1, "precio_unitario_sin_iva": 1000.02}]',
    p_iva_alicuota => 0, p_tipo_compra => 'servicios');
  PERFORM registrar_pago_proveedor_v3(p_proveedor_id => v_prov, p_medios => '[{"medio": "efectivo", "monto": 1000}]',
    p_factura_ids => ARRAY[v_f3], p_origen => 'turno');
  IF (SELECT saldo_pendiente FROM facturas_compra_saldo WHERE id = v_f3) <> 0.02 THEN RAISE EXCEPTION 'T11a'; END IF;
  v_res := registrar_pago_proveedor_v3(p_proveedor_id => v_prov, p_medios => '[]', p_factura_ids => ARRAY[v_f3],
    p_origen => 'turno', p_ajuste_redondeo => 0.02);
  SELECT * INTO r FROM pagos_proveedor WHERE id = (v_res->>'pago_id')::uuid;
  IF r.monto <> 0 OR r.ajuste_redondeo <> 0.02 OR r.forma_pago IS NOT NULL
     OR (SELECT estado FROM facturas_compra_saldo WHERE id = v_f3) <> 'pagada'
     OR EXISTS (SELECT 1 FROM egresos WHERE pago_proveedor_id = r.id)
     OR EXISTS (SELECT 1 FROM movimientos_cuenta WHERE referencia_id = r.id)
     OR (SELECT a_cuenta FROM pagos_proveedor_a_cuenta WHERE id = r.id) <> 0 THEN
    RAISE EXCEPTION 'T11b: %', row_to_json(r);
  END IF;
  v_ok := array_append(v_ok, 'T11');

  -- T12. Identidad de saldo del proveedor: saldo_actual = Σ saldo_pendiente − crédito NC − a cuenta libre.
  SELECT * INTO r FROM proveedores_saldo WHERE id = v_prov;
  SELECT COALESCE(sum(saldo_pendiente), 0) - COALESCE(sum(credito_disponible), 0) INTO v_n
  FROM facturas_compra_saldo WHERE proveedor_id = v_prov AND NOT anulada;
  IF r.saldo_actual <> v_n - r.a_cuenta_libre OR r.saldo_actual <> -10.03 THEN
    RAISE EXCEPTION 'T12: saldo % / comprobantes % / a cuenta %', r.saldo_actual, v_n, r.a_cuenta_libre;
  END IF;
  v_ok := array_append(v_ok, 'T12');

  -- T13. Admin revierte desde el Historial el pago de T8 (con ajuste) y el ajuste solo de T11.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_alicia, 'role', 'authenticated')::text, true);
  SELECT id INTO v_aud FROM auditoria WHERE tabla_afectada = 'pagos_proveedor' AND registro_id = v_pago AND accion = 'alta';
  IF v_aud IS NULL THEN RAISE EXCEPTION 'T13: sin auditoría del pago'; END IF;
  PERFORM revertir_movimiento(v_aud);
  IF (SELECT saldo_pendiente FROM facturas_compra_saldo WHERE id = v_f1) <> 121.02
     OR (SELECT ajuste_redondeo FROM pagos_proveedor WHERE revierte_pago_proveedor_id = v_pago) <> -0.02
     OR (SELECT sum(monto) FROM egresos WHERE pago_proveedor_id IN (v_pago, (SELECT id FROM pagos_proveedor WHERE revierte_pago_proveedor_id = v_pago))) <> 0 THEN
    RAISE EXCEPTION 'T13a';
  END IF;
  SELECT id INTO v_aud FROM auditoria WHERE tabla_afectada = 'pagos_proveedor' AND registro_id = (v_res->>'pago_id')::uuid AND accion = 'alta';
  PERFORM revertir_movimiento(v_aud);
  IF (SELECT saldo_pendiente FROM facturas_compra_saldo WHERE id = v_f3) <> 0.02 THEN RAISE EXCEPTION 'T13b'; END IF;
  SELECT * INTO r FROM proveedores_saldo WHERE id = v_prov;
  IF r.saldo_actual <> 121.02 + 0.02 - 10.03 THEN RAISE EXCEPTION 'T13c: %', r.saldo_actual; END IF;
  v_ok := array_append(v_ok, 'T13');

  -- T14. Cobros: 3 ventas a cta. cte. de prueba (número negativo: no consume la secuencia).
  INSERT INTO ventas (numero, cliente_id, forma_pago, subtotal, total, usuario_id, precio_oficial, precio_cobrado)
  OVERRIDING SYSTEM VALUE VALUES (-71001, v_cli, 'cuenta_corriente', 4500.02, 4500.02, c_alicia, 4500.02, 4500.02) RETURNING id INTO v_v1;
  INSERT INTO ventas (numero, cliente_id, forma_pago, subtotal, total, usuario_id, precio_oficial, precio_cobrado)
  OVERRIDING SYSTEM VALUE VALUES (-71002, v_cli, 'cuenta_corriente', 100, 100, c_alicia, 100, 100) RETURNING id INTO v_v2;
  INSERT INTO ventas (numero, cliente_id, forma_pago, subtotal, total, usuario_id, precio_oficial, precio_cobrado)
  OVERRIDING SYSTEM VALUE VALUES (-71003, v_cli, 'cuenta_corriente', 50.02, 50.02, c_alicia, 50.02, 50.02) RETURNING id INTO v_v3;

  -- Admin (Gestión): 4500 + 0,02 → venta 1 pagada; a la cuenta entra solo la plata.
  v_res := registrar_cobro_cliente(p_cliente_id => v_cli, p_medios => '[{"forma_pago": "efectivo", "monto": 4500}]',
    p_venta_ids => ARRAY[v_v1], p_origen => 'general', p_ajuste_redondeo => 0.02);
  v_pago := (v_res->>'pago_id')::uuid;
  IF (SELECT estado_cuenta FROM ventas_cuenta_corriente_saldo WHERE id = v_v1) <> 'pagada'
     OR (SELECT COALESCE(sum(monto), 0) FROM movimientos_cuenta WHERE referencia_id = v_pago) <> 4500
     OR (SELECT a_cuenta FROM pagos_cliente_a_cuenta WHERE id = v_pago) <> 0 THEN
    RAISE EXCEPTION 'T14a: %', v_res;
  END IF;
  -- Ajuste negativo: venta 2 (100) con 100,05 − 0,05.
  v_res := registrar_cobro_cliente(p_cliente_id => v_cli, p_medios => '[{"forma_pago": "transferencia", "monto": 100.05}]',
    p_venta_ids => ARRAY[v_v2], p_origen => 'general', p_ajuste_redondeo => -0.05);
  IF (SELECT estado_cuenta FROM ventas_cuenta_corriente_saldo WHERE id = v_v2) <> 'pagada' THEN RAISE EXCEPTION 'T14b'; END IF;
  -- Venta 3: 50 de plata y después, el cajero, 0,02 de ajuste solo (sin caja: no tiene medios).
  PERFORM registrar_cobro_cliente(p_cliente_id => v_cli, p_medios => '[{"forma_pago": "efectivo", "monto": 50}]',
    p_venta_ids => ARRAY[v_v3], p_origen => 'general');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_cajero, 'role', 'authenticated')::text, true);
  v_res := registrar_cobro_cliente(p_cliente_id => v_cli, p_medios => '[]', p_venta_ids => ARRAY[v_v3],
    p_origen => 'turno', p_ajuste_redondeo => 0.02);
  SELECT * INTO r FROM pagos_cliente WHERE id = (v_res->>'pago_id')::uuid;
  IF r.monto <> 0 OR r.ajuste_redondeo <> 0.02 OR r.forma_pago IS NOT NULL
     OR EXISTS (SELECT 1 FROM pagos_cliente_medios WHERE pago_cliente_id = r.id)
     OR (SELECT estado_cuenta FROM ventas_cuenta_corriente_saldo WHERE id = v_v3) <> 'pagada'
     OR (SELECT saldo_actual FROM clientes_saldo WHERE id = v_cli) <> 0 THEN
    RAISE EXCEPTION 'T14c: %', row_to_json(r);
  END IF;
  -- Sin deuda, un ajuste solo no se puede cobrar.
  BEGIN
    PERFORM registrar_cobro_cliente(p_cliente_id => v_cli, p_medios => '[]', p_origen => 'turno', p_ajuste_redondeo => 0.01);
    RAISE EXCEPTION 'T14d: debía fallar';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg <> 'Este cliente no tiene saldo a cobrar' THEN RAISE EXCEPTION 'T14d: %', v_msg; END IF;
  END;
  v_ok := array_append(v_ok, 'T14');

  -- T15. Admin revierte el cobro de la venta 1 (con ajuste): vuelve a deber 4500,02.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c_alicia, 'role', 'authenticated')::text, true);
  SELECT id INTO v_aud FROM auditoria WHERE tabla_afectada = 'pagos_cliente' AND registro_id = v_pago AND accion = 'alta';
  IF v_aud IS NULL THEN RAISE EXCEPTION 'T15: sin auditoría del cobro'; END IF;
  PERFORM revertir_movimiento(v_aud);
  IF (SELECT saldo_pendiente FROM ventas_cuenta_corriente_saldo WHERE id = v_v1) <> 4500.02
     OR (SELECT saldo_actual FROM clientes_saldo WHERE id = v_cli) <> 4500.02
     OR (SELECT COALESCE(sum(monto), 0) FROM movimientos_cuenta WHERE referencia_id = v_pago) <> 0 THEN
    RAISE EXCEPTION 'T15';
  END IF;
  v_ok := array_append(v_ok, 'T15');

  RAISE EXCEPTION 'RESULTADO: OK %', array_to_string(v_ok, ' ');
END $$;
ROLLBACK;
