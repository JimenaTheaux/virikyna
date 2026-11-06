-- 70 — Historial de movimientos del producto (fase 1: base de datos)
--
-- ✅ APLICADO en producción el 2026-11-06 ~14:10 (PARTE A sola, con `supabase db query --linked -f`),
--    backup previo virikyna_2026-11-06_pre-docs70-aplicar (schema idéntico al probado).
--    PARTE B en producción: 3323 movimientos, 0 sin origen, 0 distintos de la clasificación,
--    0 productos que no cuadran, en los 2370 productos la última fila = stock actual, resumen cierra
--    en todos, 0 filas de datos vacías, 2164 altas reconstruidas, 0 productos sin alta. Alerta de
--    precios (precios_cambiados, pendientes 207 / últimos 30 días 224) con el mismo md5 antes y después.
--    Probado antes en restauración local (backup virikyna_2026-11-06_pre-docs70-test): PARTE A dos
--    veces seguidas (re-corrible), PARTE B ok, PARTE C 12/12. Sin sobrecargas nuevas.
--    Precio de origen factura sin link a la factura: 2 (SQUISHY BUTTER MANTECA, factura borrada en
--    docs/46; DIDACTICO TORRE FLOR…, script del 27/10 sin movimiento de compra).
-- Base: docs/DIAGNOSTICO_HISTORIAL_MOVIMIENTOS.md (2026-11-05) + decisiones D1–D10 cerradas.
-- Schema relevado sobre el backup virikyna_2026-11-06_pre-docs70-test (post docs/68 y docs/69).
--
-- Correr desde la raíz del repo, después de 69. La PARTE A es re-corrible (IF NOT EXISTS / CREATE
-- OR REPLACE / backfills con WHERE … IS NULL / NOT EXISTS). La PARTE B solo lee. La PARTE C es un
-- test (BEGIN … ROLLBACK) que llama a confirmar_venta y crear_devolucion: SOLO en la restauración
-- local, nunca en producción.
--
-- Qué hace (sin UI):
--   1. Índice movimientos_stock (producto_id, created_at, id); reemplaza idx_movimientos_stock_producto.
--   2. movimientos_stock.origen (NOT NULL + CHECK coherente con tipo): venta, anulacion_venta,
--      devolucion_cliente, cambio_entrega, anulacion_devolucion, compra, compra_correccion,
--      devolucion_proveedor, anulacion_compra, ajuste_manual, reversion_ajuste, carga_inicial,
--      carga_inicial_correccion. Backfill con clasificar_movimiento_stock (tipo + tabla de
--      referencia_id + motivo). Trigger de respaldo: un INSERT sin origen (script) se clasifica solo.
--   3. Las 11 RPCs que mueven stock escriben origen explícito (misma firma, mismo comportamiento):
--      ajustar_stock, anular_devolucion, anular_factura_compra, anular_venta,
--      carga_inicial_editar_producto, carga_inicial_finalizar, cargar_factura_compra, confirmar_venta,
--      crear_devolucion, revertir_movimiento, vincular_item_factura_compra.
--   4. D7: carga_inicial_editar_producto rechaza corregir la cantidad con la carga inicial cerrada
--      (error VKH02, "usá Ajustar stock"); nombre/marca/precio se siguen pudiendo editar. Pantalla:
--      packages/shared/src/components/cargaInicial/InventarioTotal.tsx (cantidad editable; fase 4).
--   5. D6: vista perfiles_historial (id + nombre, incluye inactivos).
--   6. D5: precio del alta reconstruido desde auditoria en productos_precios_historial (columna nueva
--      reconstruido = true); precios_cambiados (alerta docs/67) las ignora, así no cambia.
--   7. historial_producto(producto, desde, hasta, clases[]) y resumen_historial_producto(producto,
--      desde, hasta): SQL STABLE SECURITY INVOKER.
--
-- Compatibilidad: ninguna firma cambia; Local instalado (v0.11.x) sigue igual. Solo la corrección de
-- cantidad de la carga inicial cerrada pasa a dar error (es la decisión D7).

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios
-- ════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ─── 1. Índice: historial por producto en orden cronológico ─────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_movimientos_stock_producto_fecha
  ON public.movimientos_stock (producto_id, created_at, id);
DROP INDEX IF EXISTS public.idx_movimientos_stock_producto;

-- ─── 2. movimientos_stock.origen ─────────────────────────────────────────────────────────────
-- `tipo` tiene 4 valores y anulaciones, devoluciones, NC y ajustes manuales caen todos en
-- 'ajuste'. `origen` guarda qué fue cada movimiento. Las RPCs lo completan explícito; el trigger
-- trg_movimiento_stock_origen lo deduce solo si viene NULL (Local viejo no escribe esta tabla,
-- pero un script de datos o una RPC reemplazada por otra migración sí podrían).
ALTER TABLE public.movimientos_stock ADD COLUMN IF NOT EXISTS origen text;

-- Clasificación por tipo + a qué tabla apunta referencia_id + texto del motivo. Es la del
-- diagnóstico (§2.1); el motivo se compara sin acentos porque este trigger corre antes que
-- trg_sin_acentos (orden alfabético) y en el backfill ya están sin acentos.
CREATE OR REPLACE FUNCTION public.clasificar_movimiento_stock(
  p_tipo public.tipo_movimiento_stock, p_cantidad numeric, p_motivo text, p_referencia_id uuid
) RETURNS text
LANGUAGE sql STABLE
SET search_path TO 'public'
AS $$
  SELECT CASE
    WHEN p_tipo = 'venta' THEN 'venta'
    WHEN p_tipo = 'compra' AND quitar_acentos(COALESCE(p_motivo, '')) ILIKE 'Correccion factura%' THEN 'compra_correccion'
    WHEN p_tipo = 'compra' THEN 'compra'
    WHEN p_tipo = 'inicial' AND p_referencia_id IS NULL AND p_motivo IS NOT NULL THEN 'carga_inicial_correccion'
    WHEN p_tipo = 'inicial' THEN 'carga_inicial'
    -- ajuste
    WHEN p_referencia_id IS NOT NULL AND EXISTS (SELECT 1 FROM ventas WHERE id = p_referencia_id) THEN 'anulacion_venta'
    WHEN p_referencia_id IS NOT NULL AND EXISTS (SELECT 1 FROM devoluciones WHERE id = p_referencia_id) THEN
      CASE WHEN quitar_acentos(COALESCE(p_motivo, '')) ILIKE 'Anulacion de devolucion%' THEN 'anulacion_devolucion'
           WHEN p_cantidad > 0 THEN 'devolucion_cliente'
           ELSE 'cambio_entrega' END
    WHEN p_referencia_id IS NOT NULL AND EXISTS (SELECT 1 FROM facturas_compra WHERE id = p_referencia_id) THEN
      CASE WHEN quitar_acentos(COALESCE(p_motivo, '')) ILIKE 'Devolucion a proveedor%' THEN 'devolucion_proveedor'
           ELSE 'anulacion_compra' END
    WHEN quitar_acentos(COALESCE(p_motivo, '')) ILIKE 'Reversion de ajuste%' THEN 'reversion_ajuste'
    ELSE 'ajuste_manual'
  END;
$$;
REVOKE ALL ON FUNCTION public.clasificar_movimiento_stock(public.tipo_movimiento_stock, numeric, text, uuid) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public.clasificar_movimiento_stock(public.tipo_movimiento_stock, numeric, text, uuid) IS
  'docs/70: deduce movimientos_stock.origen (backfill y respaldo del trigger). Las RPCs lo escriben explícito.';

-- Backfill (re-corrible: solo filas sin origen; trg_sin_acentos no cambia nada en un motivo ya limpio).
UPDATE public.movimientos_stock
SET origen = public.clasificar_movimiento_stock(tipo, cantidad, motivo, referencia_id)
WHERE origen IS NULL;

DO $$
DECLARE v_nulos int;
BEGIN
  SELECT count(*) INTO v_nulos FROM public.movimientos_stock WHERE origen IS NULL;
  IF v_nulos > 0 THEN RAISE EXCEPTION 'docs/70: % movimientos sin origen tras el backfill', v_nulos; END IF;
END $$;

ALTER TABLE public.movimientos_stock ALTER COLUMN origen SET NOT NULL;
ALTER TABLE public.movimientos_stock DROP CONSTRAINT IF EXISTS chk_movimientos_stock_origen;
ALTER TABLE public.movimientos_stock ADD CONSTRAINT chk_movimientos_stock_origen CHECK (
     (tipo = 'venta'   AND origen = 'venta')
  OR (tipo = 'compra'  AND origen IN ('compra', 'compra_correccion'))
  OR (tipo = 'inicial' AND origen IN ('carga_inicial', 'carga_inicial_correccion'))
  OR (tipo = 'ajuste'  AND origen IN ('anulacion_venta', 'devolucion_cliente', 'cambio_entrega', 'anulacion_devolucion',
                                      'devolucion_proveedor', 'anulacion_compra', 'ajuste_manual', 'reversion_ajuste'))
);
COMMENT ON COLUMN public.movimientos_stock.origen IS
  'docs/70: qué fue el movimiento (venta, anulacion_venta, devolucion_cliente, cambio_entrega, anulacion_devolucion, compra, compra_correccion, devolucion_proveedor, anulacion_compra, ajuste_manual, reversion_ajuste, carga_inicial, carga_inicial_correccion). Coherente con tipo (CHECK).';

CREATE OR REPLACE FUNCTION public.fn_movimiento_stock_origen() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.origen IS NULL THEN
    NEW.origen := clasificar_movimiento_stock(NEW.tipo, NEW.cantidad, NEW.motivo, NEW.referencia_id);
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.fn_movimiento_stock_origen() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_movimiento_stock_origen ON public.movimientos_stock;
CREATE TRIGGER trg_movimiento_stock_origen BEFORE INSERT ON public.movimientos_stock
  FOR EACH ROW EXECUTE FUNCTION public.fn_movimiento_stock_origen();

-- ─── 2b. productos_precios_historial.reconstruido (D5, ver sección 5) ─────────────────────────
ALTER TABLE public.productos_precios_historial ADD COLUMN IF NOT EXISTS reconstruido boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.productos_precios_historial.reconstruido IS
  'docs/70: fila agregada después, desde auditoria (precio del alta de productos anteriores al trigger). La alerta de precios no la cuenta.';

-- ─── 3. RPCs que mueven stock: escriben origen ──────────────────────────────────────────────
-- Definiciones tomadas del backup virikyna_2026-11-06_pre-docs70-test (post docs/68 y 69). Único
-- cambio en cada una: columna origen en el INSERT de movimientos_stock (marcado "docs/70"), y en
-- carga_inicial_editar_producto el bloqueo de D7.

-- ─── ajustar_stock (sobrecarga 1) ───
CREATE OR REPLACE FUNCTION "public"."ajustar_stock"("p_producto_id" "uuid", "p_ubicacion" "public"."ubicacion_stock", "p_cantidad" numeric, "p_motivo" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF p_motivo IS NULL OR trim(p_motivo) = '' THEN
    RAISE EXCEPTION 'El motivo es obligatorio para un ajuste de stock';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede ajustar stock manualmente';
  END IF;

  INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, usuario_id, origen)  -- docs/70: origen
  VALUES (p_producto_id, p_ubicacion, 'ajuste', p_cantidad, p_motivo, auth.uid(), 'ajuste_manual');

  INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
  VALUES (p_producto_id, p_ubicacion, p_cantidad)
  ON CONFLICT (producto_id, ubicacion)
  DO UPDATE SET cantidad = stock_ubicaciones.cantidad + p_cantidad;
END;
$$;

-- ─── anular_devolucion (sobrecarga 1) ───
CREATE OR REPLACE FUNCTION "public"."anular_devolucion"("p_devolucion_id" "uuid", "p_motivo" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_dev devoluciones%ROWTYPE;
  v_item RECORD;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede anular una devolución';
  END IF;
  IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
    RAISE EXCEPTION 'El motivo es obligatorio para anular una devolución';
  END IF;

  SELECT * INTO v_dev FROM devoluciones WHERE id = p_devolucion_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Devolución no encontrada'; END IF;
  IF v_dev.estado = 'anulada' THEN RAISE EXCEPTION 'Esta devolución ya está anulada'; END IF;

  FOR v_item IN SELECT * FROM devolucion_items WHERE devolucion_id = p_devolucion_id LOOP
    -- devuelto que había reingresado → sale del stock; nuevo entregado → vuelve al stock.
    -- Un devuelto defectuoso (reingresa_stock = false) nunca tocó el stock: no hay nada que revertir.
    IF v_item.tipo = 'devuelto' AND NOT v_item.reingresa_stock THEN CONTINUE; END IF;

    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id, origen)  -- docs/70: origen
    VALUES (v_item.producto_id, 'local', 'ajuste',
            CASE WHEN v_item.tipo = 'devuelto' THEN -v_item.cantidad ELSE v_item.cantidad END,
            'Anulación de devolución #' || v_dev.numero || ': ' || p_motivo, p_devolucion_id, auth.uid(), 'anulacion_devolucion');
    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES (v_item.producto_id, 'local',
            CASE WHEN v_item.tipo = 'devuelto' THEN -v_item.cantidad ELSE v_item.cantidad END)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad
                            + CASE WHEN v_item.tipo = 'devuelto' THEN -v_item.cantidad ELSE v_item.cantidad END;
  END LOOP;

  UPDATE devoluciones
  SET estado = 'anulada', anulada_por = auth.uid(), anulada_at = now(), motivo_anulacion = p_motivo
  WHERE id = p_devolucion_id;

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, valores_nuevos, usuario_id, nota)
  VALUES ('devoluciones', p_devolucion_id, 'anulacion', to_jsonb(v_dev),
          jsonb_set(to_jsonb(v_dev), '{estado}', '"anulada"'), auth.uid(), p_motivo);
END;
$$;

-- ─── anular_factura_compra (sobrecarga 1) ───
CREATE OR REPLACE FUNCTION "public"."anular_factura_compra"("p_factura_id" "uuid", "p_motivo" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_mov RECORD;   -- docs/55
  v_ya_anulada BOOLEAN;
  v_forma_pago forma_pago_compra;  -- docs/57
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede anular una factura de compra';
  END IF;
  IF p_motivo IS NULL OR trim(p_motivo) = '' THEN
    RAISE EXCEPTION 'El motivo es obligatorio para anular una factura de compra';
  END IF;

  SELECT anulada, forma_pago INTO v_ya_anulada, v_forma_pago FROM facturas_compra WHERE id = p_factura_id FOR UPDATE;
  IF v_ya_anulada IS NULL THEN
    RAISE EXCEPTION 'Factura de compra no encontrada';
  END IF;
  IF v_ya_anulada THEN
    RAISE EXCEPTION 'Esta factura ya estaba anulada';
  END IF;
  -- docs/57: una factura de contado tiene su pago (y su egreso): se revierte desde el Historial.
  IF v_forma_pago = 'contado' AND EXISTS (
    SELECT 1 FROM pagos_proveedor_aplicaciones
    WHERE factura_compra_id = p_factura_id AND pago_proveedor_id IS NOT NULL AND revertida_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Es una factura de contado: revertí su pago desde el Historial';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pagos_proveedor_aplicaciones
    WHERE (factura_compra_id = p_factura_id OR nota_credito_id = p_factura_id)
      AND revertida_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Este comprobante tiene pagos o notas de crédito aplicadas — revertí esos pagos antes de anularlo';
  END IF;

  -- docs/55: lo que el comprobante movió de verdad (compra, ítem vinculado después, devolución de
  -- una NC), neto por producto y depósito. Antes se recorrían los ítems con producto: en una NC
  -- habría restado stock que nunca había sumado.
  FOR v_mov IN
    SELECT producto_id, ubicacion, SUM(cantidad) AS neto
    FROM movimientos_stock
    WHERE referencia_id = p_factura_id
    GROUP BY producto_id, ubicacion
    HAVING SUM(cantidad) <> 0
  LOOP
    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id, origen)  -- docs/70: origen
    VALUES (v_mov.producto_id, v_mov.ubicacion, 'ajuste', -1 * v_mov.neto,
            'Anulación de factura de compra: ' || p_motivo, p_factura_id, auth.uid(), 'anulacion_compra');

    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES (v_mov.producto_id, v_mov.ubicacion, -1 * v_mov.neto)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad + EXCLUDED.cantidad;
  END LOOP;

  UPDATE facturas_compra SET anulada = true WHERE id = p_factura_id;

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, nota, usuario_id)
  VALUES ('facturas_compra', p_factura_id, 'anulacion', p_motivo, auth.uid());
END;
$$;

-- ─── anular_venta (sobrecarga 1) ───
CREATE OR REPLACE FUNCTION "public"."anular_venta"("p_venta_id" "uuid", "p_motivo" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_venta ventas%ROWTYPE;
  v_item RECORD;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede anular una venta';
  END IF;
  IF p_motivo IS NULL OR trim(p_motivo) = '' THEN
    RAISE EXCEPTION 'El motivo es obligatorio para anular una venta';
  END IF;

  SELECT * INTO v_venta FROM ventas WHERE id = p_venta_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Venta no encontrada'; END IF;
  IF v_venta.estado = 'anulada' THEN RAISE EXCEPTION 'Esta venta ya está anulada'; END IF;
  IF EXISTS (SELECT 1 FROM facturas_c WHERE venta_id = p_venta_id) THEN
    RAISE EXCEPTION 'Esta venta ya tiene Factura C emitida — no es reversible desde el sistema (límite conocido de Fase 1, ver docs)';
  END IF;

  FOR v_item IN SELECT * FROM venta_items WHERE venta_id = p_venta_id LOOP
    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id, origen)  -- docs/70: origen
    VALUES (v_item.producto_id, 'local', 'ajuste', v_item.cantidad,
            'Reposición por anulación de venta: ' || p_motivo, p_venta_id, auth.uid(), 'anulacion_venta');

    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES (v_item.producto_id, 'local', v_item.cantidad)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad + v_item.cantidad;
  END LOOP;

  UPDATE ventas SET estado = 'anulada' WHERE id = p_venta_id;

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, valores_nuevos, usuario_id, nota)
  VALUES ('ventas', p_venta_id, 'anulacion', to_jsonb(v_venta),
          jsonb_set(to_jsonb(v_venta), '{estado}', '"anulada"'), auth.uid(), p_motivo);
END;
$$;

-- ─── carga_inicial_editar_producto (sobrecarga 1) ───
CREATE OR REPLACE FUNCTION "public"."carga_inicial_editar_producto"("p_client_id" "uuid", "p_producto_id" "uuid", "p_nombre" "text", "p_marca" "text", "p_descripcion" "text", "p_precio" numeric, "p_cantidad_local" numeric) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_nombre TEXT := NULLIF(btrim(COALESCE(p_nombre, '')), '');
  v_marca TEXT := NULLIF(btrim(COALESCE(p_marca, '')), '');
  v_descripcion TEXT := NULLIF(btrim(COALESCE(p_descripcion, '')), '');
  v_prod productos%ROWTYPE;
  v_precio_manual NUMERIC;
  v_actual NUMERIC;
  v_delta NUMERIC := 0;
  v_resultado JSONB;
BEGIN
  PERFORM carga_inicial_verificar_acceso();

  -- docs/34c: operación ya aplicada → lo que devolvió la primera vez.
  IF NOT carga_inicial_reclamar_operacion(p_client_id, 'editar_producto') THEN
    RETURN (SELECT resultado FROM carga_inicial_operaciones WHERE client_id = p_client_id);
  END IF;

  SELECT * INTO v_prod FROM productos WHERE id = p_producto_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Producto no encontrado';
  END IF;
  IF v_nombre IS NULL THEN
    RAISE EXCEPTION 'El nombre es obligatorio';
  END IF;
  IF p_precio IS NOT NULL AND p_precio <= 0 THEN
    RAISE EXCEPTION 'El precio tiene que ser mayor a 0';
  END IF;
  IF p_cantidad_local IS NOT NULL AND p_cantidad_local < 0 THEN
    RAISE EXCEPTION 'La cantidad no puede ser negativa';
  END IF;
  IF p_precio IS NOT NULL AND v_prod.costo IS NOT NULL AND p_precio <> v_prod.precio_venta THEN
    RAISE EXCEPTION 'Precio calculado por costo: este producto tiene costo cargado y su precio sale de la fórmula';
  END IF;

  v_precio_manual := CASE WHEN v_prod.costo IS NULL AND p_precio IS NOT NULL THEN p_precio ELSE v_prod.precio_manual END;

  IF v_nombre IS DISTINCT FROM v_prod.nombre OR v_marca IS DISTINCT FROM v_prod.marca
     OR v_descripcion IS DISTINCT FROM v_prod.descripcion OR v_precio_manual IS DISTINCT FROM v_prod.precio_manual THEN
    UPDATE productos
    SET nombre = v_nombre, marca = v_marca, descripcion = v_descripcion,
        precio_manual = v_precio_manual, updated_at = now()
    WHERE id = p_producto_id;
  END IF;

  IF p_cantidad_local IS NOT NULL THEN
    SELECT cantidad INTO v_actual FROM stock_ubicaciones
    WHERE producto_id = p_producto_id AND ubicacion = 'local' FOR UPDATE;
    v_actual := COALESCE(v_actual, 0);
    v_delta := p_cantidad_local - v_actual;

    IF v_delta <> 0 THEN
      -- docs/70 (D7): con la carga inicial cerrada, el stock no se corrige desde acá (fijaba la
      -- cantidad absoluta, pisando las ventas del medio, y sin motivo). Se usa "Ajustar stock".
      IF NOT COALESCE((SELECT carga_inicial_abierta FROM configuracion), false) THEN
        RAISE EXCEPTION 'La carga inicial está cerrada: para corregir el stock usá "Ajustar stock" en Inventario, con el motivo.'
          USING ERRCODE = 'VKH02';
      END IF;

      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, usuario_id, origen)  -- docs/70: origen
      VALUES (p_producto_id, 'local', 'inicial', v_delta,
              format('Carga inicial: corrección de cantidad (%s → %s)', v_actual, p_cantidad_local), auth.uid(), 'carga_inicial_correccion');

      INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
      VALUES (p_producto_id, 'local', p_cantidad_local)
      ON CONFLICT (producto_id, ubicacion) DO UPDATE SET cantidad = EXCLUDED.cantidad;
    END IF;
  END IF;

  v_resultado := jsonb_build_object(
    'producto_id', p_producto_id,
    'precio_venta', (SELECT precio_venta FROM productos WHERE id = p_producto_id),
    'cantidad_anterior', v_actual,
    'cantidad_nueva', p_cantidad_local,
    'delta', v_delta
  );

  UPDATE carga_inicial_operaciones SET item_id = p_producto_id, resultado = v_resultado  -- docs/34c
  WHERE client_id = p_client_id;

  RETURN v_resultado;
END;
$$;

-- ─── carga_inicial_finalizar (sobrecarga 1) ───
CREATE OR REPLACE FUNCTION "public"."carga_inicial_finalizar"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_item carga_inicial_items%ROWTYPE;
  v_producto_id UUID;
  v_codigo TEXT;
  v_generado BOOLEAN;
  v_creado BOOLEAN;
  v_costo NUMERIC;
  v_precio_venta NUMERIC;
  v_items INT := 0;
  v_creados INT := 0;
  v_reemplazados INT := 0;
  v_sumados INT := 0;
  v_fusionados INT := 0;
  v_precios_no_aplicados INT := 0;
  v_unidades NUMERIC := 0;
  v_codigos JSONB := '[]'::JSONB;
BEGIN
  PERFORM carga_inicial_verificar_acceso();

  FOR v_item IN
    SELECT * FROM carga_inicial_items WHERE usuario_id = auth.uid() ORDER BY created_at, id FOR UPDATE
  LOOP
    v_items := v_items + 1;
    v_producto_id := NULL;
    v_generado := false;
    v_creado := false;

    -- Producto: el que se resolvió al guardar el borrador, o el que tenga el código ahora.
    IF v_item.producto_id IS NOT NULL THEN
      SELECT id INTO v_producto_id FROM productos WHERE id = v_item.producto_id;
    END IF;
    IF v_producto_id IS NULL AND v_item.codigo_barras IS NOT NULL THEN
      v_producto_id := carga_inicial_producto_por_codigo(v_item.codigo_barras);
    END IF;

    IF v_producto_id IS NULL THEN
      -- Alta con mis datos. Si el borrador no tiene código, se genera uno.
      v_codigo := v_item.codigo_barras;
      IF v_codigo IS NULL THEN
        v_codigo := generar_codigo_interno();
        v_generado := true;
      END IF;

      INSERT INTO productos (nombre, marca, descripcion, codigo_barras, costo, precio_manual,
                             proveedor_id, margen_1, margen_2, iva_porcentaje, estado)
      VALUES (v_item.nombre, v_item.marca, v_item.descripcion, v_codigo, NULL, v_item.precio,
              NULL, 0, 0, 21, 'activo')
      ON CONFLICT (codigo_barras) DO NOTHING
      RETURNING id INTO v_producto_id;

      IF v_producto_id IS NOT NULL THEN
        v_creado := true;
        v_creados := v_creados + 1;
        IF v_generado THEN
          v_codigos := v_codigos || jsonb_build_object('producto_id', v_producto_id, 'nombre', v_item.nombre, 'codigo', v_codigo);
        END IF;
      ELSE
        -- Otro usuario lo dio de alta en el medio (el ON CONFLICT espera a que su transacción
        -- confirme): se sigue con ese producto según la acción.
        SELECT id INTO v_producto_id FROM productos WHERE codigo_barras = v_codigo;
      END IF;
    END IF;

    IF NOT v_creado THEN
      IF v_item.accion = 'reemplazar' THEN
        SELECT costo, precio_venta INTO v_costo, v_precio_venta FROM productos WHERE id = v_producto_id FOR UPDATE;
        UPDATE productos
        SET nombre = v_item.nombre,
            marca = v_item.marca,
            descripcion = v_item.descripcion,
            precio_manual = CASE WHEN v_costo IS NULL THEN v_item.precio ELSE precio_manual END,
            updated_at = now()
        WHERE id = v_producto_id;
        -- Con costo, el precio sale de la fórmula: no se pisa.
        IF v_costo IS NOT NULL AND v_item.precio <> v_precio_venta THEN
          v_precios_no_aplicados := v_precios_no_aplicados + 1;
        END IF;
        v_reemplazados := v_reemplazados + 1;
      ELSIF v_item.accion = 'nuevo' THEN
        -- Era nuevo al guardarlo, pero el código apareció después: se suma.
        v_fusionados := v_fusionados + 1;
      ELSE
        v_sumados := v_sumados + 1;
      END IF;
    END IF;

    -- Stock: siempre en 'local', sumando.
    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id, origen)  -- docs/70: origen
    VALUES (v_producto_id, 'local', 'inicial', v_item.cantidad, 'Carga inicial', v_item.id, auth.uid(), 'carga_inicial');

    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES (v_producto_id, 'local', v_item.cantidad)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad + EXCLUDED.cantidad;

    v_unidades := v_unidades + v_item.cantidad;
  END LOOP;

  DELETE FROM carga_inicial_items WHERE usuario_id = auth.uid();

  RETURN jsonb_build_object(
    'items', v_items,
    'productos_creados', v_creados,
    'productos_reemplazados', v_reemplazados,
    'stock_sumado', v_sumados,
    'fusionados', v_fusionados,
    'precios_no_aplicados', v_precios_no_aplicados,
    'unidades', v_unidades,
    'codigos_generados', v_codigos
  );
END;
$$;

-- ─── cargar_factura_compra (sobrecarga 1) ───
CREATE OR REPLACE FUNCTION "public"."cargar_factura_compra"("p_proveedor_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_forma_pago" "public"."forma_pago_compra", "p_items" "jsonb", "p_copiada_de_id" "uuid" DEFAULT NULL::"uuid", "p_iva_alicuota" numeric DEFAULT 21, "p_tipo_compra" "text" DEFAULT 'articulos'::"text", "p_borrador_id" "uuid" DEFAULT NULL::"uuid", "p_devuelve_mercaderia" boolean DEFAULT false) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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

  SELECT COALESCE(SUM((i->>'cantidad')::NUMERIC * (i->>'precio_unitario_sin_iva')::NUMERIC
           * (1 - COALESCE((i->>'descuento_porcentaje')::NUMERIC,0)/100.0)), 0)
  INTO v_total_sin_iva
  FROM jsonb_array_elements(p_items) AS i;

  v_iva := ROUND(v_total_sin_iva * p_iva_alicuota / 100, 2);  -- docs/45 (antes: × 0.21 fijo)
  v_total := v_total_sin_iva + v_iva;

  INSERT INTO facturas_compra (proveedor_id, tipo_comprobante, letra, punto_venta, numero_comprobante,
         fecha_comprobante, fecha_fiscal, forma_pago, total_sin_iva, iva, total, usuario_id, copiada_de_id,
         iva_alicuota,  -- docs/45
         tipo_compra,   -- docs/53
         devuelve_mercaderia)  -- docs/55
  VALUES (p_proveedor_id, p_tipo_comprobante, p_letra, p_punto_venta, p_numero_comprobante,
         p_fecha_comprobante, p_fecha_fiscal, p_forma_pago, v_total_sin_iva, v_iva, v_total, auth.uid(), p_copiada_de_id,
         p_iva_alicuota,
         p_tipo_compra,
         v_devuelve)
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

-- ─── confirmar_venta (sobrecarga 1) ───
CREATE OR REPLACE FUNCTION "public"."confirmar_venta"("p_cliente_id" "uuid", "p_forma_pago" "public"."forma_pago_venta", "p_items" "jsonb", "p_descuento_porcentaje" numeric DEFAULT 0, "p_nota" "text" DEFAULT NULL::"text", "p_recargo_porcentaje" numeric DEFAULT 0, "p_pagos" "jsonb" DEFAULT NULL::"jsonb", "p_precio_cobrado" numeric DEFAULT NULL::numeric, "p_client_id" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
  v_costo NUMERIC;       -- docs/68
  v_con_iva BOOLEAN;     -- docs/68
  v_interna BOOLEAN := false;  -- docs/68
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

  -- docs/68: cliente interno + cuenta corriente → venta interna pendiente (la revisa la dueña).
  IF v_forma_pago_final = 'cuenta_corriente' THEN
    SELECT tipo = 'interno' INTO v_interna FROM clientes WHERE id = p_cliente_id;
    v_interna := COALESCE(v_interna, false);
  END IF;

  INSERT INTO ventas (cliente_id, forma_pago, subtotal, descuento_porcentaje, recargo_porcentaje, total,
         precio_oficial, precio_cobrado, nota, usuario_id, client_id,
         estado_interno, total_original, descuento_global_original)
  VALUES (p_cliente_id, v_forma_pago_final, v_subtotal, COALESCE(p_descuento_porcentaje,0),
          COALESCE(p_recargo_porcentaje,0), v_precio_cobrado, v_precio_oficial, v_precio_cobrado, p_nota, auth.uid(),
          p_client_id,
          CASE WHEN v_interna THEN 'pendiente'::estado_venta_interna END,
          CASE WHEN v_interna THEN v_precio_cobrado END,
          CASE WHEN v_interna THEN COALESCE(p_descuento_porcentaje,0) END)
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

    -- docs/42: snapshot de nombre y marca. docs/68: + costo (sin IVA) y check de IVA.
    -- Si el producto no existe, la FK del INSERT lo frena igual.
    SELECT nombre, marca, costo, iva_porcentaje > 0 INTO v_nombre, v_marca, v_costo, v_con_iva
    FROM productos WHERE id = (v_item->>'producto_id')::UUID;

    INSERT INTO venta_items (venta_id, producto_id, cantidad, precio_unitario, descuento_porcentaje, importe,
                             producto_nombre, producto_marca, costo_unitario, producto_con_iva)
    VALUES (v_venta_id, (v_item->>'producto_id')::UUID, (v_item->>'cantidad')::NUMERIC,
            (v_item->>'precio_unitario')::NUMERIC, COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0), v_importe,
            v_nombre, v_marca, v_costo, v_con_iva);

    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, referencia_id, usuario_id, origen)  -- docs/70: origen
    VALUES ((v_item->>'producto_id')::UUID, 'local', 'venta', -1 * (v_item->>'cantidad')::NUMERIC, v_venta_id, auth.uid(), 'venta');

    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES ((v_item->>'producto_id')::UUID, 'local', -1 * (v_item->>'cantidad')::NUMERIC)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad - (v_item->>'cantidad')::NUMERIC;
  END LOOP;

  RETURN v_venta_id;
END;
$$;

-- ─── crear_devolucion (sobrecarga 1) ───
CREATE OR REPLACE FUNCTION "public"."crear_devolucion"("p_venta_id" "uuid", "p_motivo" "public"."motivo_devolucion", "p_motivo_detalle" "text", "p_observaciones" "text", "p_items_devueltos" "jsonb", "p_items_nuevos" "jsonb" DEFAULT NULL::"jsonb", "p_forma_pago" "public"."forma_pago_venta" DEFAULT NULL::"public"."forma_pago_venta", "p_pagos" "jsonb" DEFAULT NULL::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    SET "TimeZone" TO 'America/Argentina/Buenos_Aires'
    AS $$
DECLARE
  v_venta ventas%ROWTYPE;
  v_row RECORD;
  v_devolucion_id UUID;
  v_vendida NUMERIC;
  v_ya_devuelta NUMERIC;
  v_precio NUMERIC;
  v_total_devuelto NUMERIC := 0;
  v_total_nuevo NUMERIC := 0;
  v_diferencia NUMERIC;
  v_forma_final forma_pago_venta;
  v_suma_pagos NUMERIC;
  v_suma_asignada NUMERIC := 0;
  v_monto NUMERIC;
  v_pago JSONB;
  v_idx INT := 0;
  v_reingresa BOOLEAN;
  v_nombre TEXT;
  v_marca TEXT;  -- docs/42
  v_items_devueltos JSONB := '[]'::jsonb;
  v_items_nuevos JSONB := '[]'::jsonb;
  v_a_cuenta BOOLEAN := false;  -- docs/68
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  -- Bloquea la venta: dos devoluciones simultáneas sobre la misma venta se serializan, así la
  -- validación de cantidad disponible no se puede saltear con una carrera.
  SELECT * INTO v_venta FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Venta no encontrada'; END IF;
  IF v_venta.estado = 'anulada' THEN
    RAISE EXCEPTION 'No se puede hacer una devolución sobre una venta anulada';
  END IF;
  IF v_venta.estado_interno = 'finalizado' THEN
    RAISE EXCEPTION 'Es un consumo interno ya finalizado: pedile a un administrador que lo reabra antes de la devolución';
  END IF;

  -- Validación 1: plazo de 15 días
  IF v_venta.created_at::date < current_date - 15 THEN
    RAISE EXCEPTION 'Esta venta supera los 15 días permitidos para devolución/cambio';
  END IF;

  -- Validación 3: motivo obligatorio; "otro" exige detalle
  IF p_motivo IS NULL THEN RAISE EXCEPTION 'El motivo es obligatorio'; END IF;
  IF p_motivo = 'otro' AND (p_motivo_detalle IS NULL OR btrim(p_motivo_detalle) = '') THEN
    RAISE EXCEPTION 'Con motivo "otro" el detalle es obligatorio';
  END IF;

  IF p_items_devueltos IS NULL OR jsonb_typeof(p_items_devueltos) <> 'array' OR jsonb_array_length(p_items_devueltos) = 0 THEN
    RAISE EXCEPTION 'Elegí al menos un producto para devolver';
  END IF;

  v_reingresa := (p_motivo <> 'defectuoso');

  -- ---- Ítems devueltos (agrupados por producto por si el cliente manda repetidos) ----
  FOR v_row IN
    SELECT (i->>'producto_id')::UUID AS producto_id, SUM((i->>'cantidad')::NUMERIC) AS cantidad
    FROM jsonb_array_elements(p_items_devueltos) AS i
    GROUP BY 1
  LOOP
    IF v_row.cantidad IS NULL OR v_row.cantidad <= 0 THEN
      RAISE EXCEPTION 'La cantidad a devolver debe ser mayor a 0';
    END IF;

    SELECT COALESCE(SUM(cantidad), 0) INTO v_vendida
    FROM venta_items WHERE venta_id = p_venta_id AND producto_id = v_row.producto_id;

    SELECT nombre INTO v_nombre FROM productos WHERE id = v_row.producto_id;

    IF v_vendida = 0 THEN
      RAISE EXCEPTION 'El producto "%" no forma parte de esta venta', COALESCE(v_nombre, v_row.producto_id::text);
    END IF;

    -- Validación 2: no devolver más de lo vendido, descontando devoluciones activas previas
    SELECT COALESCE(SUM(di.cantidad), 0) INTO v_ya_devuelta
    FROM devolucion_items di
    JOIN devoluciones d ON d.id = di.devolucion_id
    WHERE d.venta_id = p_venta_id AND d.estado = 'activa'
      AND di.tipo = 'devuelto' AND di.producto_id = v_row.producto_id;

    IF v_row.cantidad > v_vendida - v_ya_devuelta THEN
      RAISE EXCEPTION 'No se puede devolver % de "%": solo quedan % disponibles (vendidas %, ya devueltas %)',
        v_row.cantidad, v_nombre, v_vendida - v_ya_devuelta, v_vendida, v_ya_devuelta;
    END IF;

    -- Precio efectivamente pagado por unidad (ver decisión 1 del encabezado)
    SELECT ROUND(
             (SUM(importe) / NULLIF(SUM(cantidad), 0))
             * (CASE WHEN v_venta.subtotal > 0 THEN v_venta.total / v_venta.subtotal ELSE 1 END), 2)
    INTO v_precio
    FROM venta_items WHERE venta_id = p_venta_id AND producto_id = v_row.producto_id;

    v_total_devuelto := v_total_devuelto + ROUND(v_row.cantidad * v_precio, 2);
    v_items_devueltos := v_items_devueltos || jsonb_build_object(
      'producto_id', v_row.producto_id, 'cantidad', v_row.cantidad, 'precio_unitario', v_precio);
  END LOOP;

  -- ---- Ítems nuevos (cambio), a precio actual de lista ----
  IF p_items_nuevos IS NOT NULL AND jsonb_typeof(p_items_nuevos) = 'array' AND jsonb_array_length(p_items_nuevos) > 0 THEN
    FOR v_row IN
      SELECT (i->>'producto_id')::UUID AS producto_id, SUM((i->>'cantidad')::NUMERIC) AS cantidad
      FROM jsonb_array_elements(p_items_nuevos) AS i
      GROUP BY 1
    LOOP
      IF v_row.cantidad IS NULL OR v_row.cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad del producto nuevo debe ser mayor a 0';
      END IF;
      SELECT nombre, precio_venta INTO v_nombre, v_precio
      FROM productos WHERE id = v_row.producto_id AND estado = 'activo';
      IF NOT FOUND THEN RAISE EXCEPTION 'Producto nuevo no encontrado o inactivo'; END IF;

      v_total_nuevo := v_total_nuevo + ROUND(v_row.cantidad * v_precio, 2);
      v_items_nuevos := v_items_nuevos || jsonb_build_object(
        'producto_id', v_row.producto_id, 'cantidad', v_row.cantidad, 'precio_unitario', v_precio);
    END LOOP;
  END IF;

  v_diferencia := ROUND(v_total_nuevo - v_total_devuelto, 2);

  -- docs/68 (D12): venta a cta. cte. → la diferencia va a la cuenta, no se devuelve plata.
  IF v_venta.forma_pago = 'cuenta_corriente'
     AND (v_diferencia <= 0 OR p_forma_pago = 'cuenta_corriente') THEN
    v_a_cuenta := true;
  END IF;

  -- ---- Forma de pago de la diferencia ----
  IF v_diferencia <> 0 AND NOT v_a_cuenta THEN
    IF p_pagos IS NOT NULL AND jsonb_typeof(p_pagos) = 'array' AND jsonb_array_length(p_pagos) > 0 THEN
      IF jsonb_array_length(p_pagos) > 2 THEN
        RAISE EXCEPTION 'Un pago combinado admite hasta 2 medios de pago';
      END IF;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_pagos) AS p
                 WHERE (p->>'forma_pago') IN ('cuenta_corriente', 'combinado')) THEN
        RAISE EXCEPTION 'La diferencia no se puede saldar con cuenta corriente';
      END IF;
      SELECT COALESCE(SUM((p->>'monto')::NUMERIC), 0) INTO v_suma_pagos FROM jsonb_array_elements(p_pagos) AS p;
      IF ABS(v_suma_pagos - ABS(v_diferencia)) > 0.01 THEN
        RAISE EXCEPTION 'La suma de los pagos (%) no coincide con la diferencia (%)', v_suma_pagos, ABS(v_diferencia);
      END IF;
      v_forma_final := CASE WHEN jsonb_array_length(p_pagos) = 1
        THEN (p_pagos->0->>'forma_pago')::forma_pago_venta
        ELSE 'combinado'::forma_pago_venta END;
    ELSE
      IF p_forma_pago IS NULL THEN
        RAISE EXCEPTION 'Elegí la forma de pago para saldar la diferencia';
      END IF;
      IF p_forma_pago IN ('cuenta_corriente', 'combinado') THEN
        RAISE EXCEPTION 'Forma de pago inválida para saldar la diferencia';
      END IF;
      v_forma_final := p_forma_pago;
    END IF;
  ELSE
    v_forma_final := NULL;
  END IF;

  -- ---- Insert de la devolución ----
  INSERT INTO devoluciones (venta_id, usuario_id, motivo, motivo_detalle, observaciones,
                            diferencia_monto, diferencia_forma_pago, a_cuenta_corriente)
  VALUES (p_venta_id, auth.uid(), p_motivo, NULLIF(btrim(p_motivo_detalle), ''), NULLIF(btrim(p_observaciones), ''),
          v_diferencia, v_forma_final, v_a_cuenta)
  RETURNING id INTO v_devolucion_id;

  -- Pagos de la diferencia (monto siempre positivo). La última parte absorbe el centavo de redondeo.
  IF v_diferencia <> 0 AND NOT v_a_cuenta THEN
    IF p_pagos IS NOT NULL AND jsonb_typeof(p_pagos) = 'array' AND jsonb_array_length(p_pagos) > 0 THEN
      FOR v_pago IN SELECT * FROM jsonb_array_elements(p_pagos)
      LOOP
        v_idx := v_idx + 1;
        IF v_idx = jsonb_array_length(p_pagos) THEN
          v_monto := ABS(v_diferencia) - v_suma_asignada;
        ELSE
          v_monto := ROUND((v_pago->>'monto')::NUMERIC, 2);
          v_suma_asignada := v_suma_asignada + v_monto;
        END IF;
        INSERT INTO devolucion_pagos (devolucion_id, forma_pago, monto)
        VALUES (v_devolucion_id, (v_pago->>'forma_pago')::forma_pago_venta, v_monto);
      END LOOP;
    ELSE
      INSERT INTO devolucion_pagos (devolucion_id, forma_pago, monto)
      VALUES (v_devolucion_id, v_forma_final, ABS(v_diferencia));
    END IF;
  END IF;

  -- Ítems devueltos: + stock local solo si reingresa (defectuoso queda separado, sin movimiento)
  FOR v_row IN SELECT (i->>'producto_id')::UUID AS producto_id, (i->>'cantidad')::NUMERIC AS cantidad,
                      (i->>'precio_unitario')::NUMERIC AS precio_unitario
               FROM jsonb_array_elements(v_items_devueltos) AS i
  LOOP
    SELECT nombre, marca INTO v_nombre, v_marca FROM productos WHERE id = v_row.producto_id;  -- docs/42

    INSERT INTO devolucion_items (devolucion_id, tipo, producto_id, cantidad, precio_unitario, reingresa_stock,
                                  producto_nombre, producto_marca)
    VALUES (v_devolucion_id, 'devuelto', v_row.producto_id, v_row.cantidad, v_row.precio_unitario, v_reingresa,
            v_nombre, v_marca);

    IF v_reingresa THEN
      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id, origen)  -- docs/70: origen
      VALUES (v_row.producto_id, 'local', 'ajuste', v_row.cantidad,
              'Devolución de venta #' || v_venta.numero || ' (' || p_motivo::text || ')', v_devolucion_id, auth.uid(), 'devolucion_cliente');
      INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
      VALUES (v_row.producto_id, 'local', v_row.cantidad)
      ON CONFLICT (producto_id, ubicacion)
      DO UPDATE SET cantidad = stock_ubicaciones.cantidad + v_row.cantidad;
    END IF;
  END LOOP;

  -- Ítems nuevos: − stock local
  FOR v_row IN SELECT (i->>'producto_id')::UUID AS producto_id, (i->>'cantidad')::NUMERIC AS cantidad,
                      (i->>'precio_unitario')::NUMERIC AS precio_unitario
               FROM jsonb_array_elements(v_items_nuevos) AS i
  LOOP
    SELECT nombre, marca INTO v_nombre, v_marca FROM productos WHERE id = v_row.producto_id;  -- docs/42

    INSERT INTO devolucion_items (devolucion_id, tipo, producto_id, cantidad, precio_unitario, reingresa_stock,
                                  producto_nombre, producto_marca)
    VALUES (v_devolucion_id, 'nuevo', v_row.producto_id, v_row.cantidad, v_row.precio_unitario, true,
            v_nombre, v_marca);

    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id, origen)  -- docs/70: origen
    VALUES (v_row.producto_id, 'local', 'ajuste', -1 * v_row.cantidad,
            'Cambio sobre venta #' || v_venta.numero, v_devolucion_id, auth.uid(), 'cambio_entrega');
    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES (v_row.producto_id, 'local', -1 * v_row.cantidad)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad - v_row.cantidad;
  END LOOP;

  RETURN v_devolucion_id;
END;
$$;

-- ─── revertir_movimiento (sobrecarga 1) ───
CREATE OR REPLACE FUNCTION "public"."revertir_movimiento"("p_auditoria_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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
      cheque_numero, cheque_fecha_salida, cheque_fecha_vencimiento, nota
    )
    VALUES (
      (v_row->>'proveedor_id')::UUID, NULLIF(v_row->>'factura_compra_id','')::UUID,
      -1 * v_monto, (v_row->>'forma_pago')::forma_pago_egreso, auth.uid(), v_pago_orig_id,
      v_row->>'cheque_numero', NULLIF(v_row->>'cheque_fecha_salida','')::DATE, NULLIF(v_row->>'cheque_fecha_vencimiento','')::DATE,
      'Reversión desde Historial'
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

    INSERT INTO pagos_cliente (cliente_id, venta_id, monto, forma_pago, usuario_id, revierte_pago_cliente_id, origen, nota)
    SELECT pc.cliente_id, pc.venta_id, -1 * pc.monto, pc.forma_pago, auth.uid(), pc.id, pc.origen, 'Reversion desde Historial'
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

-- ─── vincular_item_factura_compra (sobrecarga 1) ───
CREATE OR REPLACE FUNCTION "public"."vincular_item_factura_compra"("p_item_id" "uuid", "p_producto_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_item facturas_compra_items%ROWTYPE;
  v_anulada BOOLEAN;
  v_tipo_compra TEXT;  -- docs/53
  v_tipo_comprobante tipo_comprobante_compra;  -- docs/55
  v_nombre TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede vincular un ítem de una factura ya cargada';
  END IF;

  -- FOR UPDATE: dos vínculos simultáneos del mismo ítem sumarían el stock dos veces.
  SELECT * INTO v_item FROM facturas_compra_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Ítem de factura no encontrado';
  END IF;
  IF v_item.producto_id IS NOT NULL THEN
    RAISE EXCEPTION 'Este ítem ya está vinculado a un producto';
  END IF;

  SELECT anulada, tipo_compra, tipo_comprobante INTO v_anulada, v_tipo_compra, v_tipo_comprobante
  FROM facturas_compra WHERE id = v_item.factura_compra_id;
  IF v_anulada THEN
    RAISE EXCEPTION 'El comprobante está anulado: no se le suma stock';
  END IF;
  -- docs/53: un servicio no es mercadería, no se vincula ni suma stock.
  IF v_tipo_compra = 'servicios' THEN
    RAISE EXCEPTION 'Es una factura de servicios: sus ítems no se vinculan a productos';
  END IF;
  -- docs/55: vincular suma stock como una compra; en una nota de crédito no corresponde.
  IF v_tipo_comprobante = 'nota_credito' THEN
    RAISE EXCEPTION 'Es una nota de crédito: sus ítems no se vinculan a productos';
  END IF;

  SELECT nombre INTO v_nombre FROM productos WHERE id = p_producto_id AND estado = 'activo';
  IF v_nombre IS NULL THEN
    RAISE EXCEPTION 'El producto no existe o está inactivo';
  END IF;

  -- Igual que un ítem vinculado al cargar: la descripción es la copia del nombre del producto.
  UPDATE facturas_compra_items SET producto_id = p_producto_id, descripcion = v_nombre WHERE id = p_item_id;

  -- Mismo par de escrituras que cargar_factura_compra para un ítem vinculado.
  INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id, origen)  -- docs/70: origen
  VALUES (p_producto_id, v_item.ubicacion, 'compra', v_item.cantidad,
          'Ítem de factura vinculado después de cargada', v_item.factura_compra_id, auth.uid(), 'compra');

  INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
  VALUES (p_producto_id, v_item.ubicacion, v_item.cantidad)
  ON CONFLICT (producto_id, ubicacion)
  DO UPDATE SET cantidad = stock_ubicaciones.cantidad + EXCLUDED.cantidad;

  -- docs/56: costo, precio manual y proveedor/márgenes como al cargar, si es la compra más nueva.
  PERFORM aplicar_costo_vinculo_item(p_item_id, p_producto_id);
END;
$$;

-- ─── precios_cambiados (alerta docs/67): ignora las altas reconstruidas ───
CREATE OR REPLACE FUNCTION "public"."precios_cambiados"("p_solo_pendientes" boolean DEFAULT true, "p_desde" timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS TABLE("producto_id" "uuid", "nombre" "text", "marca" "text", "codigo_barras" "text", "codigo_interno" "text", "fecha_cambio" timestamp with time zone, "precio_anterior" numeric, "precio_actual" numeric, "variacion_porcentaje" numeric, "origen" "text", "pendiente" boolean, "marcado_por" "text", "marcado_at" timestamp with time zone)
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  WITH lim AS (SELECT COALESCE(p_desde, now() - interval '30 days') AS desde),
  base AS (
    SELECT p.id, p.nombre, p.marca, p.codigo_barras, p.codigo_interno, p.precio_venta, p.created_at,
           e.precio_etiquetado, e.marcado_por, e.marcado_at,
           (p.estado = 'activo' AND p.precio_venta IS NOT NULL
            AND p.precio_venta IS DISTINCT FROM e.precio_etiquetado) AS pendiente
    FROM productos p
    LEFT JOIN productos_etiqueta e ON e.producto_id = p.id
  ),
  ult AS (
    SELECT DISTINCT ON (h.producto_id) h.producto_id, h.created_at, h.origen
    FROM productos_precios_historial h CROSS JOIN lim
    WHERE (p_solo_pendientes OR h.created_at >= lim.desde)
      AND NOT h.reconstruido  -- docs/70: las altas reconstruidas no son cambios para la alerta
    ORDER BY h.producto_id, h.created_at DESC, h.id DESC
  ),
  pri AS (
    SELECT DISTINCT ON (h.producto_id) h.producto_id, h.precio_anterior
    FROM productos_precios_historial h CROSS JOIN lim
    WHERE NOT p_solo_pendientes AND h.created_at >= lim.desde
      AND NOT h.reconstruido  -- docs/70
    ORDER BY h.producto_id, h.created_at, h.id
  )
  SELECT b.id, b.nombre, b.marca, b.codigo_barras, b.codigo_interno,
         COALESCE(u.created_at, b.created_at),
         ant.precio,
         b.precio_venta,
         CASE WHEN ant.precio > 0 THEN round((b.precio_venta - ant.precio) / ant.precio * 100, 1) END,
         COALESCE(u.origen, 'alta'),
         b.pendiente,
         pp.nombre,
         b.marcado_at
  FROM base b
  LEFT JOIN ult u ON u.producto_id = b.id
  LEFT JOIN pri ON pri.producto_id = b.id
  LEFT JOIN perfiles_publico pp ON pp.id = b.marcado_por
  CROSS JOIN LATERAL (
    SELECT CASE WHEN p_solo_pendientes THEN b.precio_etiquetado ELSE pri.precio_anterior END AS precio
  ) ant
  WHERE CASE WHEN p_solo_pendientes THEN b.pendiente ELSE u.producto_id IS NOT NULL END
  ORDER BY 6 DESC, b.nombre;
$$;

-- ─── 4. Nombres de usuario para el historial, con los dados de baja (D6) ────────────────────
-- perfiles tiene RLS "solo el propio" y perfiles_publico filtra activo = true: un usuario dado de
-- baja quedaría sin nombre en el historial. Esta vista lo incluye y expone solo id + nombre.
-- No es security_invoker a propósito: con invoker la RLS de perfiles dejaría ver solo la fila
-- propia (mismo motivo que perfiles_publico). La propia vista exige un perfil activo que la lea.
CREATE OR REPLACE VIEW public.perfiles_historial WITH (security_barrier = true) AS
SELECT p.id, p.nombre
FROM public.perfiles p
WHERE EXISTS (SELECT 1 FROM public.perfiles yo WHERE yo.id = auth.uid() AND yo.activo);
REVOKE ALL ON public.perfiles_historial FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.perfiles_historial TO authenticated, service_role;
COMMENT ON VIEW public.perfiles_historial IS
  'docs/70 (D6): id + nombre de todos los usuarios (incluye inactivos), para mostrar quién hizo cada evento del historial. Solo para perfiles activos.';

-- ─── 5. Precio del alta reconstruido (D5) ────────────────────────────────────────────────────
-- 2164 productos se crearon antes del trigger de INSERT del historial de precios (docs/67) y no
-- tienen fila 'alta'. El precio, la fecha y el usuario reales están en auditoria (alta). Se marcan
-- reconstruido = true: precios_cambiados (alerta de etiquetas) las ignora, así esa pantalla no
-- cambia (si no, "Últimos 30 días" sumaba ~2164 altas del 13 al 19/10).
-- (columna reconstruido: creada en la sección 2b, antes de reemplazar precios_cambiados)

INSERT INTO public.productos_precios_historial (producto_id, precio_anterior, precio_nuevo, origen, usuario_id, created_at, reconstruido)
SELECT a.registro_id, NULL, (a.valores_nuevos ->> 'precio_venta')::numeric, 'alta', a.usuario_id, a.created_at, true
FROM public.auditoria a
JOIN public.productos p ON p.id = a.registro_id
WHERE a.tabla_afectada = 'productos' AND a.accion = 'alta'
  AND a.valores_nuevos ->> 'precio_venta' IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.productos_precios_historial h
                  WHERE h.producto_id = a.registro_id AND h.origen = 'alta');

-- ─── 6. historial_producto ───────────────────────────────────────────────────────────────────
-- Línea de tiempo del producto: movimientos de stock + cambios de precio + cambios de datos + alta
-- (+ "sin_registro" si algún día stock ≠ Σ movimientos). SECURITY INVOKER: cada tabla aplica su
-- RLS (un cajero recibe 0 filas de datos, porque auditoria es solo admin).
--
-- Reglas:
--   - stock_resultante = (stock actual − Σ movimientos) + Σ acumulada en orden (created_at, id), sobre
--     TODOS los movimientos y antes de filtrar: filtrar no cambia ninguna fila. La última fila da el
--     stock actual. Las filas sin cantidad toman el stock del último movimiento con fecha <= la suya
--     (el alta, el de antes: < ).
--   - Cambios de datos (D4): costo, margen_1, margen_2, iva_porcentaje, proveedor, nombre, marca,
--     codigo_barras, estado, stock_minimo. Sin cambio real en esos campos → no hay fila.
--     Hechos por una factura (mismo instante que una compra del producto) → van en la fila de la
--     compra (columna cambios). Ediciones masivas → no se muestran: mismo usuario y mismo instante en
--     >= 20 productos (en prod: IVA del 24/10, 445 y 57 productos; las facturas grandes, p. ej. 105
--     ítems, se agrupan con su compra antes de este filtro).
--   - Precio con origen factura en el mismo instante que una compra del producto: se le pone la
--     referencia a esa factura (misma transacción: now() es el mismo).
--   - El alta lleva el precio inicial (fila 'alta' del historial de precios) y su usuario.
--   - p_hasta es exclusivo. p_clases: valores de `clase` (origen del movimiento, o 'alta',
--     'precio', 'datos', 'sin_registro'); NULL = todas.
--   - `orden`: posición cronológica, estable con o sin filtro. Ordenar por orden DESC.
CREATE OR REPLACE FUNCTION public.historial_producto(
  p_producto_id uuid,
  p_desde timestamptz DEFAULT NULL,
  p_hasta timestamptz DEFAULT NULL,
  p_clases text[] DEFAULT NULL
) RETURNS TABLE (
  orden bigint,
  fecha timestamptz,
  clase text,
  detalle text,
  proveedor text,
  ubicacion public.ubicacion_stock,
  cantidad numeric,
  stock_resultante numeric,
  usuario_id uuid,
  usuario_nombre text,
  ref_tabla text,
  ref_id uuid,
  ref_numero text,
  precio_anterior numeric,
  precio_nuevo numeric,
  precio_origen text,
  cambios jsonb
)
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path TO 'public'
AS $$
WITH
prod AS (
  SELECT p.id, p.created_at FROM productos p WHERE p.id = p_producto_id
),
dif AS (
  SELECT COALESCE((SELECT sum(s.cantidad) FROM stock_ubicaciones s WHERE s.producto_id = p_producto_id), 0)
       - COALESCE((SELECT sum(m.cantidad) FROM movimientos_stock m WHERE m.producto_id = p_producto_id), 0) AS d
),
mov AS (
  SELECT m.id, m.created_at, m.origen, m.motivo, m.ubicacion, m.cantidad, m.usuario_id, m.referencia_id,
         (SELECT d FROM dif) + sum(m.cantidad) OVER (ORDER BY m.created_at, m.id) AS stock_resultante,
         row_number() OVER (ORDER BY m.created_at, m.id) AS n
  FROM movimientos_stock m
  WHERE m.producto_id = p_producto_id
),
mov_ref AS (
  SELECT mv.*,
         CASE WHEN v.id IS NOT NULL THEN 'venta' WHEN dv.id IS NOT NULL THEN 'devolucion'
              WHEN f.id IS NOT NULL THEN 'factura_compra' END AS ref_tabla,
         COALESCE(v.id, dv.id, f.id) AS ref_id,
         COALESCE(v.numero::text, dv.numero::text,
                  CASE WHEN f.id IS NOT NULL THEN
                    concat_ws(' ', upper(replace(f.tipo_comprobante::text, '_', ' ')), f.letra::text,
                              NULLIF(concat_ws('-', NULLIF(btrim(f.punto_venta), ''), NULLIF(btrim(f.numero_comprobante), '')), ''))
                  END) AS ref_numero,
         pr.razon_social AS proveedor
  FROM mov mv
  LEFT JOIN ventas v           ON v.id = mv.referencia_id
  LEFT JOIN devoluciones dv    ON dv.id = mv.referencia_id
  LEFT JOIN facturas_compra f  ON f.id = mv.referencia_id
  LEFT JOIN proveedores pr     ON pr.id = f.proveedor_id
),
-- La compra a la que se pegan los cambios de la misma factura (si el producto va en varias líneas,
-- la última).
compra_instante AS (
  SELECT DISTINCT ON (created_at) created_at, id AS mov_id
  FROM mov WHERE origen IN ('compra', 'compra_correccion')
  ORDER BY created_at, n DESC
),
aud AS (
  SELECT a.id, a.created_at, a.usuario_id, a.accion,
         (SELECT jsonb_object_agg(
                   CASE WHEN k.campo = 'proveedor_id' THEN 'proveedor' ELSE k.campo END,
                   CASE WHEN k.campo = 'proveedor_id' THEN
                     jsonb_build_object(
                       'antes',   (SELECT to_jsonb(x.razon_social) FROM proveedores x WHERE x.id = (a.valores_anteriores ->> 'proveedor_id')::uuid),
                       'despues', (SELECT to_jsonb(x.razon_social) FROM proveedores x WHERE x.id = (a.valores_nuevos ->> 'proveedor_id')::uuid))
                   ELSE jsonb_build_object('antes', a.valores_anteriores -> k.campo, 'despues', a.valores_nuevos -> k.campo)
                   END)
          FROM unnest(ARRAY['costo', 'margen_1', 'margen_2', 'iva_porcentaje', 'proveedor_id', 'nombre', 'marca',
                            'codigo_barras', 'estado', 'stock_minimo']) AS k(campo)
          WHERE a.valores_anteriores ? k.campo
            AND (a.valores_anteriores -> k.campo) IS DISTINCT FROM (a.valores_nuevos -> k.campo)) AS cambios
  FROM auditoria a
  WHERE a.tabla_afectada = 'productos' AND a.registro_id = p_producto_id AND a.accion IN ('edicion', 'reversion')
),
aud_util AS (
  SELECT aud.*, ci.mov_id AS compra_mov_id,
         (ci.mov_id IS NULL AND
          (SELECT count(*) FROM auditoria b
           WHERE b.tabla_afectada = 'productos' AND b.accion = 'edicion'
             AND b.created_at = aud.created_at AND b.usuario_id IS NOT DISTINCT FROM aud.usuario_id) >= 20) AS masiva
  FROM aud
  LEFT JOIN compra_instante ci ON ci.created_at = aud.created_at
  WHERE aud.cambios IS NOT NULL
),
cambios_compra AS (
  SELECT compra_mov_id AS mov_id, jsonb_object_agg(kv.key, kv.value ORDER BY au.id) AS cambios
  FROM aud_util au, jsonb_each(au.cambios) kv
  WHERE au.compra_mov_id IS NOT NULL
  GROUP BY compra_mov_id
),
precio_alta AS (
  SELECT DISTINCT ON (h.producto_id) h.precio_nuevo, h.usuario_id
  FROM productos_precios_historial h
  WHERE h.producto_id = p_producto_id AND h.origen = 'alta'
  ORDER BY h.producto_id, h.created_at, h.id
),
eventos AS (
  -- alta
  SELECT pr.created_at AS fecha, 0 AS prioridad, 0::bigint AS sub, 'alta'::text AS clase,
         NULL::text AS detalle, NULL::text AS proveedor, NULL::ubicacion_stock AS ubicacion, NULL::numeric AS cantidad,
         COALESCE((SELECT m.stock_resultante FROM mov m WHERE m.created_at < pr.created_at ORDER BY m.n DESC LIMIT 1),
                  (SELECT d FROM dif)) AS stock_resultante,
         COALESCE((SELECT a.usuario_id FROM auditoria a WHERE a.tabla_afectada = 'productos' AND a.registro_id = pr.id
                     AND a.accion = 'alta' ORDER BY a.created_at LIMIT 1),
                  (SELECT pa.usuario_id FROM precio_alta pa)) AS usuario_id,
         NULL::text AS ref_tabla, NULL::uuid AS ref_id, NULL::text AS ref_numero,
         NULL::numeric AS precio_anterior, (SELECT pa.precio_nuevo FROM precio_alta pa) AS precio_nuevo,
         NULL::text AS precio_origen, NULL::jsonb AS cambios
  FROM prod pr
  UNION ALL
  -- stock − Σ movimientos ≠ 0: la diferencia exacta, al principio, sin usuario
  SELECT pr.created_at, 1, 0, 'sin_registro', 'Diferencia entre el stock y los movimientos registrados', NULL, NULL,
         dif.d, dif.d, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
  FROM prod pr, dif WHERE dif.d <> 0
  UNION ALL
  -- movimientos de stock
  SELECT m.created_at, 2, m.n, m.origen, m.motivo, m.proveedor, m.ubicacion, m.cantidad, m.stock_resultante,
         m.usuario_id, m.ref_tabla, m.ref_id, m.ref_numero, NULL, NULL, NULL, cc.cambios
  FROM mov_ref m
  LEFT JOIN cambios_compra cc ON cc.mov_id = m.id
  UNION ALL
  -- cambios de precio (el del alta va en la fila del alta)
  SELECT h.created_at, 3, h.id, 'precio', NULL, mr.proveedor, NULL, NULL,
         COALESCE((SELECT m.stock_resultante FROM mov m WHERE m.created_at <= h.created_at ORDER BY m.n DESC LIMIT 1),
                  (SELECT d FROM dif)),
         h.usuario_id, mr.ref_tabla, mr.ref_id, mr.ref_numero, h.precio_anterior, h.precio_nuevo, h.origen, NULL
  FROM productos_precios_historial h
  LEFT JOIN compra_instante ci ON h.origen = 'factura' AND ci.created_at = h.created_at
  LEFT JOIN mov_ref mr ON mr.id = ci.mov_id
  WHERE h.producto_id = p_producto_id AND h.origen <> 'alta'
  UNION ALL
  -- cambios de datos sueltos (no de una factura, no masivos)
  SELECT au.created_at, 4, 0, 'datos', CASE WHEN au.accion = 'reversion' THEN 'reversion' END, NULL, NULL, NULL,
         COALESCE((SELECT m.stock_resultante FROM mov m WHERE m.created_at <= au.created_at ORDER BY m.n DESC LIMIT 1),
                  (SELECT d FROM dif)),
         au.usuario_id, NULL, NULL, NULL, NULL, NULL, NULL, au.cambios
  FROM aud_util au
  WHERE au.compra_mov_id IS NULL AND NOT au.masiva
),
ordenados AS (
  SELECT e.*, row_number() OVER (ORDER BY e.fecha, e.prioridad, e.sub) AS orden
  FROM eventos e
)
SELECT o.orden, o.fecha, o.clase, o.detalle, o.proveedor, o.ubicacion, o.cantidad, o.stock_resultante,
       o.usuario_id, ph.nombre, o.ref_tabla, o.ref_id, o.ref_numero,
       o.precio_anterior, o.precio_nuevo, o.precio_origen, o.cambios
FROM ordenados o
LEFT JOIN perfiles_historial ph ON ph.id = o.usuario_id
WHERE (p_desde IS NULL OR o.fecha >= p_desde)
  AND (p_hasta IS NULL OR o.fecha < p_hasta)
  AND (p_clases IS NULL OR o.clase = ANY (p_clases))
ORDER BY o.orden DESC;
$$;
REVOKE ALL ON FUNCTION public.historial_producto(uuid, timestamptz, timestamptz, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.historial_producto(uuid, timestamptz, timestamptz, text[]) TO authenticated, service_role;
COMMENT ON FUNCTION public.historial_producto(uuid, timestamptz, timestamptz, text[]) IS
  'docs/70: línea de tiempo del producto (stock con saldo por fila, precio, datos, alta). SECURITY INVOKER: la RLS decide qué ve cada rol.';

-- ─── 7. resumen_historial_producto (D3) ──────────────────────────────────────────────────────
-- stock_actual y ultimo_movimiento: siempre del producto entero (nunca del filtro). El resto, de los
-- movimientos del rango [p_desde, p_hasta).
--   stock_inicial = carga inicial + sus correcciones
--   entradas      = compras (+ correcciones de compra) + devoluciones de cliente + anulaciones de venta
--   salidas       = ventas + cambios entregados + devoluciones a proveedor + anulaciones de compra (en positivo)
--   ajustes       = ajustes manuales + reversiones (neto)
--   Una anulación de devolución resta de la columna del movimiento que anula: si saca stock (anula
--   un devuelto) baja entradas; si lo repone (anula un cambio) baja salidas.
--   diferencia_sin_registro = stock actual − Σ movimientos (hoy 0).
-- Sin filtro: stock_inicial + entradas − salidas + ajustes + diferencia_sin_registro = stock_actual.
CREATE OR REPLACE FUNCTION public.resumen_historial_producto(
  p_producto_id uuid,
  p_desde timestamptz DEFAULT NULL,
  p_hasta timestamptz DEFAULT NULL
) RETURNS TABLE (
  stock_actual numeric,
  stock_inicial numeric,
  entradas numeric,
  salidas numeric,
  ajustes numeric,
  diferencia_sin_registro numeric,
  ultimo_movimiento_fecha timestamptz,
  ultimo_movimiento_clase text
)
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path TO 'public'
AS $$
WITH
actual AS (
  SELECT COALESCE((SELECT sum(s.cantidad) FROM stock_ubicaciones s WHERE s.producto_id = p_producto_id), 0) AS stock,
         COALESCE((SELECT sum(m.cantidad) FROM movimientos_stock m WHERE m.producto_id = p_producto_id), 0) AS suma
),
m AS (
  SELECT x.origen, x.cantidad
  FROM movimientos_stock x
  WHERE x.producto_id = p_producto_id
    AND (p_desde IS NULL OR x.created_at >= p_desde)
    AND (p_hasta IS NULL OR x.created_at < p_hasta)
),
ult AS (
  SELECT x.created_at, x.origen FROM movimientos_stock x
  WHERE x.producto_id = p_producto_id ORDER BY x.created_at DESC, x.id DESC LIMIT 1
)
SELECT a.stock,
       COALESCE((SELECT sum(cantidad) FROM m WHERE origen IN ('carga_inicial', 'carga_inicial_correccion')), 0),
       COALESCE((SELECT sum(cantidad) FROM m WHERE origen IN ('compra', 'compra_correccion', 'devolucion_cliente', 'anulacion_venta')
                                                 OR (origen = 'anulacion_devolucion' AND cantidad < 0)), 0),
       -COALESCE((SELECT sum(cantidad) FROM m WHERE origen IN ('venta', 'cambio_entrega', 'devolucion_proveedor', 'anulacion_compra')
                                                  OR (origen = 'anulacion_devolucion' AND cantidad > 0)), 0),
       COALESCE((SELECT sum(cantidad) FROM m WHERE origen IN ('ajuste_manual', 'reversion_ajuste')), 0),
       a.stock - a.suma,
       (SELECT created_at FROM ult),
       (SELECT origen FROM ult)
FROM actual a;
$$;
REVOKE ALL ON FUNCTION public.resumen_historial_producto(uuid, timestamptz, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resumen_historial_producto(uuid, timestamptz, timestamptz) TO authenticated, service_role;
COMMENT ON FUNCTION public.resumen_historial_producto(uuid, timestamptz, timestamptz) IS
  'docs/70 (D3): totales del historial de un producto. Stock actual y último movimiento nunca dependen del filtro.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (solo lectura; corre en producción). Devuelve una sola fila JSON.
-- Esperado: sin_origen 0, origen_distinto 0, no_cuadran 0, ultimo_distinto 0, resumen_distinto 0,
-- datos_vacios 0, alta_faltante 0 (salvo productos sin precio_venta en su alta).
-- ════════════════════════════════════════════════════════════════════════════════════════════════
WITH h AS (
  SELECT p.id, x.*
  FROM productos p
  CROSS JOIN LATERAL public.historial_producto(p.id) x
),
ult AS (
  SELECT DISTINCT ON (id) id, stock_resultante FROM h ORDER BY id, orden DESC
),
st AS (
  SELECT p.id, COALESCE((SELECT sum(s.cantidad) FROM stock_ubicaciones s WHERE s.producto_id = p.id), 0) AS stock
  FROM productos p
),
res AS (
  SELECT p.id, r.* FROM productos p CROSS JOIN LATERAL public.resumen_historial_producto(p.id) r
)
SELECT jsonb_build_object(
  'movimientos', (SELECT count(*) FROM movimientos_stock),
  'por_origen', (SELECT jsonb_object_agg(origen, n) FROM (SELECT origen, count(*) n FROM movimientos_stock GROUP BY 1) x),
  'sin_origen', (SELECT count(*) FROM movimientos_stock WHERE origen IS NULL),
  'origen_distinto_de_clasificacion', (SELECT count(*) FROM movimientos_stock
      WHERE origen IS DISTINCT FROM public.clasificar_movimiento_stock(tipo, cantidad, motivo, referencia_id)),
  'no_cuadran', (SELECT count(*) FROM st WHERE st.stock <> COALESCE((SELECT sum(m.cantidad) FROM movimientos_stock m WHERE m.producto_id = st.id), 0)),
  'productos', (SELECT count(*) FROM productos),
  'ultimo_stock_distinto_de_actual', (SELECT count(*) FROM st JOIN ult USING (id) WHERE ult.stock_resultante IS DISTINCT FROM st.stock),
  'productos_sin_filas', (SELECT count(*) FROM productos p WHERE NOT EXISTS (SELECT 1 FROM h WHERE h.id = p.id)),
  'resumen_no_cierra', (SELECT count(*) FROM res
      WHERE stock_inicial + entradas - salidas + ajustes + diferencia_sin_registro <> stock_actual),
  'filas_por_clase', (SELECT jsonb_object_agg(clase, n) FROM (SELECT clase, count(*) n FROM h GROUP BY 1) x),
  'datos_vacios', (SELECT count(*) FROM h WHERE clase = 'datos' AND cambios IS NULL),
  'compras_con_cambios', (SELECT count(*) FROM h WHERE clase IN ('compra', 'compra_correccion') AND cambios IS NOT NULL),
  'precio_factura_con_ref', (SELECT count(*) FROM h WHERE clase = 'precio' AND precio_origen = 'factura' AND ref_id IS NOT NULL),
  'precio_factura_sin_ref', (SELECT count(*) FROM h WHERE clase = 'precio' AND precio_origen = 'factura' AND ref_id IS NULL),
  'alta_faltante', (SELECT count(*) FROM productos p WHERE NOT EXISTS (
      SELECT 1 FROM productos_precios_historial x WHERE x.producto_id = p.id AND x.origen = 'alta')),
  'precios_reconstruidos', (SELECT count(*) FROM productos_precios_historial WHERE reconstruido),
  'alerta_pendientes', (SELECT count(*) FROM public.precios_cambiados(true)),
  'alerta_ultimos30', (SELECT count(*) FROM public.precios_cambiados(false)),
  'max_filas_producto', (SELECT max(n) FROM (SELECT id, count(*) n FROM h GROUP BY 1) x),
  'figuritas', (SELECT jsonb_build_object('filas', count(*), 'stock_ultimo', max(stock_resultante) FILTER (WHERE orden = (SELECT max(orden) FROM h h2 WHERE h2.id = h.id)))
                FROM h WHERE h.id = (SELECT id FROM productos WHERE nombre = 'FIGURITAS MUNDIAL FIFA' LIMIT 1) GROUP BY h.id)
) AS r;

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (BEGIN … ROLLBACK). SOLO en la restauración local (restaurar-prueba.ps1): llama a
-- confirmar_venta / crear_devolucion, que consumen numeración aunque se haga ROLLBACK. Nunca en prod.
-- psql -v ON_ERROR_STOP=1: cualquier ASSERT que falle corta. Cada test imprime "OK Tn".
-- ════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- La restauración no trae privilegios (backup con --no-privileges): se replican los de Supabase para
-- `authenticated` (la RLS decide), solo dentro de esta transacción. Las internas de docs/70 quedan
-- revocadas como en producción: el trigger tiene que andar igual.
GRANT USAGE ON SCHEMA public, auth TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public, auth TO authenticated;
REVOKE ALL ON FUNCTION public.clasificar_movimiento_stock(public.tipo_movimiento_stock, numeric, text, uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.fn_movimiento_stock_origen() FROM authenticated;

CREATE TEMP TABLE t_ctx ON COMMIT DROP AS
SELECT (SELECT id FROM perfiles WHERE rol = 'admin' AND activo ORDER BY created_at LIMIT 1) AS admin_id,
       (SELECT id FROM perfiles WHERE rol = 'cajero' AND activo ORDER BY created_at LIMIT 1) AS cajero_id,
       (SELECT id FROM productos WHERE nombre = 'FIGURITAS MUNDIAL FIFA' LIMIT 1) AS figus_id,
       (SELECT id FROM proveedores ORDER BY razon_social LIMIT 1) AS prov_id,
       (SELECT count(*) FROM perfiles) AS n_perfiles,
       -- un producto del lote de IVA del 24/10 (edición masiva)
       (SELECT a.registro_id FROM auditoria a WHERE a.tabla_afectada = 'productos' AND a.created_at = '2026-10-24 01:22:44.987836+00' LIMIT 1) AS iva_lote_id;
CREATE TEMP TABLE t_ids (k text PRIMARY KEY, v uuid) ON COMMIT DROP;
GRANT SELECT ON t_ctx TO authenticated;
GRANT SELECT, INSERT, UPDATE ON t_ids TO authenticated;

-- T10 (superusuario): un INSERT sin origen (script de datos) queda clasificado por el trigger.
DO $$
DECLARE v_id uuid; v_o text;
BEGIN
  INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, usuario_id)
  SELECT figus_id, 'local', 'ajuste', 0.01, 'script de prueba', admin_id FROM t_ctx RETURNING id, origen INTO v_id, v_o;
  ASSERT v_o = 'ajuste_manual', 'T10 origen por trigger: ' || COALESCE(v_o, 'NULL');
  DELETE FROM movimientos_stock WHERE id = v_id;
  RAISE NOTICE 'OK T10 trigger de respaldo';
END $$;

-- ─── Como admin ───
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', admin_id, 'role', 'authenticated')::text, true) FROM t_ctx;

-- T1: filtrar no cambia el stock resultante de ninguna fila.
DO $$
DECLARE v_figus uuid := (SELECT figus_id FROM t_ctx); v_mal int; v_n int;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE f.stock_resultante IS DISTINCT FROM t.stock_resultante)
  INTO v_n, v_mal
  FROM historial_producto(v_figus, '2026-10-25', '2026-11-03', ARRAY['venta']) f
  JOIN historial_producto(v_figus) t USING (orden);
  ASSERT v_n > 0, 'T1 sin filas filtradas';
  ASSERT v_mal = 0, 'T1 filas con stock distinto al filtrar: ' || v_mal;
  ASSERT (SELECT bool_and(clase = 'venta') FROM historial_producto(v_figus, NULL, NULL, ARRAY['venta'])), 'T1 filtro por clase';
  RAISE NOTICE 'OK T1 filtro (% filas)', v_n;
END $$;

-- T2: ajuste manual → origen ajuste_manual; la fila de arriba da el stock actual.
DO $$
DECLARE v_figus uuid := (SELECT figus_id FROM t_ctx); v_o text; v_top record; v_stock numeric; v_mid uuid;
BEGIN
  PERFORM ajustar_stock(v_figus, 'local', 3, 'Prueba docs70');
  -- Todo el test es una transacción: created_at es el mismo para todo; se busca por motivo.
  SELECT id, origen INTO v_mid, v_o FROM movimientos_stock WHERE producto_id = v_figus AND motivo = 'Prueba docs70';
  ASSERT v_o = 'ajuste_manual', 'T2 origen ' || v_o;
  SELECT * INTO v_top FROM historial_producto(v_figus) LIMIT 1;
  SELECT sum(cantidad) INTO v_stock FROM stock_ubicaciones WHERE producto_id = v_figus;
  ASSERT v_top.clase = 'ajuste_manual' AND v_top.cantidad = 3 AND v_top.stock_resultante = v_stock,
    format('T2 fila de arriba %s %s %s (stock %s)', v_top.clase, v_top.cantidad, v_top.stock_resultante, v_stock);
  ASSERT v_top.usuario_nombre IS NOT NULL, 'T2 sin nombre de usuario';
  INSERT INTO t_ids VALUES ('ajuste_aud', (SELECT a.id FROM auditoria a WHERE a.tabla_afectada = 'movimientos_stock'
     AND a.registro_id = v_mid));
  RAISE NOTICE 'OK T2 ajuste manual';
END $$;

-- T3: reversión del ajuste → reversion_ajuste.
DO $$
DECLARE v_o text;
BEGIN
  PERFORM revertir_movimiento((SELECT v FROM t_ids WHERE k = 'ajuste_aud'));
  SELECT origen INTO v_o FROM movimientos_stock WHERE producto_id = (SELECT figus_id FROM t_ctx)
    AND cantidad = -3 AND motivo ILIKE 'Reversion de ajuste%' AND created_at = now();
  ASSERT v_o = 'reversion_ajuste', 'T3 origen ' || COALESCE(v_o, 'NULL');
  RAISE NOTICE 'OK T3 reversión';
END $$;

-- T4: factura de compra → compra; los cambios de costo/proveedor de la factura van en la fila de la
-- compra (sin fila 'datos' suelta) y el cambio de precio queda vinculado a la factura. Anulación → anulacion_compra.
-- (Cada DO es su propia sentencia: now() es el de la transacción, así que todo cae en el mismo
--  instante; se identifica la factura por su id.)
DO $$
DECLARE v_ctx t_ctx; v_fc uuid; v_o text; v_cambios jsonb; v_n_datos int; v_precio record; v_costo numeric;
BEGIN
  SELECT * INTO v_ctx FROM t_ctx;
  SELECT COALESCE(costo, 100) INTO v_costo FROM productos WHERE id = v_ctx.figus_id;
  v_fc := cargar_factura_compra(v_ctx.prov_id, 'factura', 'A', '0099', '70700001', current_date, current_date,
            'cuenta_corriente',
            jsonb_build_array(jsonb_build_object('producto_id', v_ctx.figus_id, 'descripcion', 'Prueba docs70',
                              'cantidad', 2, 'precio_unitario_sin_iva', round(v_costo * 1.37, 2))));
  INSERT INTO t_ids VALUES ('factura', v_fc);
  SELECT origen INTO v_o FROM movimientos_stock WHERE referencia_id = v_fc;
  ASSERT v_o = 'compra', 'T4 origen ' || v_o;
  SELECT cambios INTO v_cambios FROM historial_producto(v_ctx.figus_id) WHERE ref_id = v_fc AND clase = 'compra';
  ASSERT v_cambios ? 'costo', 'T4 la compra no lleva el cambio de costo: ' || COALESCE(v_cambios::text, 'NULL');
  SELECT count(*) INTO v_n_datos FROM historial_producto(v_ctx.figus_id) h
  WHERE h.clase = 'datos' AND h.fecha = (SELECT created_at FROM movimientos_stock WHERE referencia_id = v_fc);
  ASSERT v_n_datos = 0, 'T4 quedó una fila datos suelta en el instante de la compra';
  SELECT * INTO v_precio FROM historial_producto(v_ctx.figus_id, NULL, NULL, ARRAY['precio']) LIMIT 1;
  IF v_precio.precio_origen = 'factura' AND v_precio.fecha = (SELECT created_at FROM movimientos_stock WHERE referencia_id = v_fc) THEN
    ASSERT v_precio.ref_tabla = 'factura_compra' AND v_precio.ref_id = v_fc, 'T4 precio sin vínculo a la factura';
  END IF;
  PERFORM anular_factura_compra(v_fc, 'Prueba docs70');
  SELECT origen INTO v_o FROM movimientos_stock WHERE referencia_id = v_fc AND tipo = 'ajuste';
  ASSERT v_o = 'anulacion_compra', 'T4 anulación ' || COALESCE(v_o, 'NULL');
  ASSERT (SELECT ref_numero FROM historial_producto(v_ctx.figus_id) WHERE ref_id = v_fc LIMIT 1) = 'FACTURA A 0099-70700001',
    'T4 ref_numero ' || (SELECT ref_numero FROM historial_producto(v_ctx.figus_id) WHERE ref_id = v_fc LIMIT 1);
  RAISE NOTICE 'OK T4 compra (cambios: %), anulación', v_cambios;
END $$;

-- T5: venta → venta; anulación → anulacion_venta.
DO $$
DECLARE v_ctx t_ctx; v_v uuid; v_o text; v_precio numeric;
BEGIN
  SELECT * INTO v_ctx FROM t_ctx;
  SELECT precio_venta INTO v_precio FROM productos WHERE id = v_ctx.figus_id;
  v_v := confirmar_venta(NULL, 'efectivo', jsonb_build_array(jsonb_build_object('producto_id', v_ctx.figus_id,
            'cantidad', 1, 'precio_unitario', v_precio)));
  SELECT origen INTO v_o FROM movimientos_stock WHERE referencia_id = v_v;
  ASSERT v_o = 'venta', 'T5 origen ' || v_o;
  PERFORM anular_venta(v_v, 'Prueba docs70');
  SELECT origen INTO v_o FROM movimientos_stock WHERE referencia_id = v_v AND tipo = 'ajuste';
  ASSERT v_o = 'anulacion_venta', 'T5 anulación ' || COALESCE(v_o, 'NULL');
  RAISE NOTICE 'OK T5 venta y anulación';
END $$;

-- T6: devolución con cambio → devolucion_cliente + cambio_entrega; anulación → anulacion_devolucion.
DO $$
DECLARE v_ctx t_ctx; v_v uuid; v_d uuid; v_precio numeric; v_os text[];
BEGIN
  SELECT * INTO v_ctx FROM t_ctx;
  SELECT precio_venta INTO v_precio FROM productos WHERE id = v_ctx.figus_id;
  v_v := confirmar_venta(NULL, 'efectivo', jsonb_build_array(jsonb_build_object('producto_id', v_ctx.figus_id,
            'cantidad', 1, 'precio_unitario', v_precio)));
  v_d := crear_devolucion(v_v, 'arrepentimiento', NULL, NULL,
            jsonb_build_array(jsonb_build_object('producto_id', v_ctx.figus_id, 'cantidad', 1, 'precio_unitario', v_precio)),
            jsonb_build_array(jsonb_build_object('producto_id', v_ctx.figus_id, 'cantidad', 1, 'precio_unitario', v_precio)));
  SELECT array_agg(origen ORDER BY origen) INTO v_os FROM movimientos_stock WHERE referencia_id = v_d;
  ASSERT v_os = ARRAY['cambio_entrega', 'devolucion_cliente'], 'T6 origenes ' || v_os::text;
  PERFORM anular_devolucion(v_d, 'Prueba docs70');
  SELECT array_agg(DISTINCT origen) INTO v_os FROM movimientos_stock WHERE referencia_id = v_d AND origen NOT IN ('cambio_entrega', 'devolucion_cliente');
  ASSERT v_os = ARRAY['anulacion_devolucion'], 'T6 anulación ' || COALESCE(v_os::text, 'NULL');
  RAISE NOTICE 'OK T6 devolución, cambio y anulación';
END $$;

-- T7 (D7): con la carga inicial cerrada, corregir la cantidad se rechaza (VKH02); editar el nombre no.
DO $$
DECLARE v_ctx t_ctx; v_p productos; v_ok boolean := false;
BEGIN
  SELECT * INTO v_ctx FROM t_ctx;
  SELECT * INTO v_p FROM productos WHERE id = v_ctx.figus_id;
  ASSERT NOT (SELECT carga_inicial_abierta FROM configuracion), 'T7 la carga inicial debería estar cerrada';
  BEGIN
    PERFORM carga_inicial_editar_producto(gen_random_uuid(), v_p.id, v_p.nombre, v_p.marca, v_p.descripcion, NULL,
             (SELECT sum(cantidad) FROM stock_ubicaciones WHERE producto_id = v_p.id AND ubicacion = 'local') + 5);
  EXCEPTION WHEN SQLSTATE 'VKH02' THEN v_ok := true;
  END;
  ASSERT v_ok, 'T7 la corrección de cantidad no se rechazó';
  PERFORM carga_inicial_editar_producto(gen_random_uuid(), v_p.id, v_p.nombre, v_p.marca, v_p.descripcion, NULL, NULL);
  RAISE NOTICE 'OK T7 D7';
END $$;

-- T8: resumen e invariantes después de todo lo anterior (FIGURITAS).
DO $$
DECLARE v_figus uuid := (SELECT figus_id FROM t_ctx); r record; v_top numeric;
BEGIN
  SELECT * INTO r FROM resumen_historial_producto(v_figus);
  ASSERT r.stock_inicial + r.entradas - r.salidas + r.ajustes + r.diferencia_sin_registro = r.stock_actual, 'T8 resumen no cierra';
  SELECT stock_resultante INTO v_top FROM historial_producto(v_figus) LIMIT 1;
  ASSERT v_top = r.stock_actual, 'T8 la fila de arriba no da el stock actual';
  RAISE NOTICE 'OK T8 resumen % (inicial %, entradas %, salidas %, ajustes %)', r.stock_actual, r.stock_inicial, r.entradas, r.salidas, r.ajustes;
END $$;

-- T9 (D4): el lote masivo de IVA del 24/10 no aparece como fila de datos.
DO $$
DECLARE v_id uuid := (SELECT iva_lote_id FROM t_ctx); v_n int;
BEGIN
  ASSERT v_id IS NOT NULL, 'T9 sin producto del lote';
  SELECT count(*) INTO v_n FROM historial_producto(v_id) WHERE clase = 'datos' AND fecha = '2026-10-24 01:22:44.987836+00';
  ASSERT v_n = 0, 'T9 la edición masiva aparece';
  RAISE NOTICE 'OK T9 ediciones masivas ocultas';
END $$;

-- ─── Como cajero ───
SELECT set_config('request.jwt.claims', json_build_object('sub', cajero_id, 'role', 'authenticated')::text, true) FROM t_ctx;

-- T11: el cajero recibe movimientos y precios, 0 filas de datos, sin cambios en las compras, y nombres
-- (incluidos usuarios dados de baja).
DO $$
DECLARE v_figus uuid := (SELECT figus_id FROM t_ctx); v_mov int; v_precio int; v_datos int; v_cambios int; v_sin_nombre int; v_perfiles int;
BEGIN
  SELECT count(*) FILTER (WHERE cantidad IS NOT NULL), count(*) FILTER (WHERE clase = 'precio'),
         count(*) FILTER (WHERE clase = 'datos'), count(*) FILTER (WHERE cambios IS NOT NULL),
         count(*) FILTER (WHERE usuario_id IS NOT NULL AND usuario_nombre IS NULL)
  INTO v_mov, v_precio, v_datos, v_cambios, v_sin_nombre
  FROM historial_producto(v_figus);
  ASSERT v_mov > 0, 'T11 sin movimientos';
  ASSERT v_datos = 0 AND v_cambios = 0, format('T11 el cajero ve datos (%s filas, %s cambios)', v_datos, v_cambios);
  ASSERT v_sin_nombre = 0, 'T11 filas sin nombre: ' || v_sin_nombre;
  SELECT count(*) INTO v_perfiles FROM perfiles_historial;
  ASSERT v_perfiles = (SELECT n_perfiles FROM t_ctx), format('T11 perfiles_historial %s de %s', v_perfiles, (SELECT n_perfiles FROM t_ctx));
  RAISE NOTICE 'OK T11 cajero: % movimientos, % precios, 0 datos; perfiles_historial % filas', v_mov, v_precio, v_perfiles;
END $$;

RESET ROLE;
-- T12: perfiles_historial incluye inactivos (comparado como superusuario).
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM perfiles WHERE NOT activo) > 0, 'T12 no hay inactivos para probar';
  RAISE NOTICE 'OK T12 perfiles: % en total, % inactivos', (SELECT count(*) FROM perfiles), (SELECT count(*) FROM perfiles WHERE NOT activo);
END $$;

ROLLBACK;
