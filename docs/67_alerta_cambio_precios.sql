-- 67 — Alerta de cambios de precio: historial de precios y etiquetas pendientes
--
-- ⏳ PENDIENTE de aplicar en producción (esperando OK). Antes: backup con etiqueta (pre-docs67):
--    backup-virikyna.ps1 -Etiqueta pre-docs67   (docs/44; no seguir sin [OK] en la última línea)
-- Correr desde la raíz del repo con
-- `supabase db query --linked -f docs/67_alerta_cambio_precios.sql` (o en el SQL Editor del
-- proyecto ccpinvtleqlsukcqnili). La PARTE A es una sola transacción: el backfill y la
-- inicialización de etiquetas corren una sola vez (si productos_etiqueta ya tiene filas, se
-- saltean). La PARTE B solo lee. La PARTE C es un test (BEGIN … ROLLBACK, termina con
-- RAISE EXCEPTION 'RESULTADO: …' a propósito para que nada quede escrito).
--
-- Contexto (relevado contra la base real el 2026-10-27):
--   - No hay tabla de historial de precios. trg_auditoria_productos guarda la fila entera antes y
--     después en `auditoria` (precio_venta incluido: es GENERATED y el trigger es AFTER), pero sin
--     origen, con RLS solo-admin (el cajero no la lee) y ya pesa 23 MB.
--   - Desde el 13/10 (reset de datos): 188 cambios de precio en 139 productos. Origen inferido por
--     transacción (mismo now()): 141 factura de compra, 35 costo manual, 7 margen, 5 precio manual.
--   - 2321 altas en auditoría: 2164 son la carga inicial (13 al 18/10, cerrada el 19/10); unas 157
--     son altas normales desde el 20/10.
--   - Las funciones que cambian precio: cargar_factura_compra (también la llama
--     cargar_factura_compra_contado), aplicar_costo_vinculo_item (vincular un ítem de una factura ya
--     cargada a un producto: el "editar factura" que mueve costos; editar_factura_compra no toca
--     productos), actualizar_precios_masivo, revertir_edicion, fijar/marcar_iva_productos y las de
--     carga inicial. Las tres primeras se reemplazan acá con su definición de producción + una
--     línea; la guarda del punto 0 frena todo si alguna cambió desde el relevamiento.
--
-- Qué hace:
--   1. productos_precios_historial: una fila por cambio de precio_venta (y por alta), con origen
--      (manual | factura | masivo | margen | iva | reversion | alta), usuario y fecha.
--      Trigger AFTER UPDATE … WHEN (precio_venta distinto) + AFTER INSERT (origen alta). AFTER
--      porque precio_venta es GENERATED: en BEFORE todavía no está calculado. No respeta
--      virikyna.suppress_audit: un precio revertido también pide etiqueta nueva.
--      Origen: lo fija la RPC con set_config('virikyna.origen_precio', …, true) y lo vuelve a ''
--      al terminar el UPDATE; sin eso el trigger lo deduce (reversion si suppress_audit; iva si solo
--      cambió el IVA; margen si no cambiaron costo ni precio manual; si no, manual).
--      No queda registrado: un cambio de la función redondear_precio_venta (reescribe la columna
--      GENERATED sin pasar por UPDATE, no dispara triggers).
--   2. productos_etiqueta: una fila por producto con el precio que tiene la etiqueta en el local.
--      PENDIENTE = producto activo con precio y precio_venta distinto de precio_etiquetado (o sin
--      fila: alta nunca etiquetada). Así varios cambios dan una sola fila, el "anterior" es el
--      precio de la etiqueta, y si el precio vuelve al etiquetado sale solo de pendientes.
--      marcado_por/marcado_at NULL = fila de la inicialización de esta migración.
--   3. Backfill del historial desde `auditoria`: cambios de precio desde el 13/10 (origen inferido
--      por transacción, como en el relevamiento) + altas desde el cierre de la carga inicial.
--   4. Inicialización (decisión 2026-10-27): lo cambiado en los últimos 7 días queda pendiente
--      (precio_etiquetado = precio previo al primer cambio de ese tramo; un alta del tramo queda sin
--      fila → pendiente); el resto, etiquetado al precio actual.
--   5. RPCs (authenticated, sin anon):
--        alerta_precios_pendientes()              → contador para las cards de los Dashboards.
--        precios_cambiados(p_solo_pendientes, p_desde) → filas del modal (pendientes, o historial
--                                                     desde p_desde; default 30 días).
--        marcar_etiquetas(p_producto_ids, p_precios) → "Etiqueta actualizada"; admin y cajero.
--          p_precios (opcional) = precio que se vio en pantalla: si el precio cambió mientras
--          tanto, ese producto no se marca (devuelve cuántos marcó).

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ─── 0. Guarda: las funciones que se reemplazan son las relevadas el 2026-10-27 ──────────────
-- (o ya tienen el cambio de esta migración). Si no, regenerar desde pg_get_functiondef.
DO $$
DECLARE
  v_r record;
BEGIN
  FOR v_r IN
    SELECT p.proname, md5(pg_get_functiondef(p.oid)) AS md5, e.md5 AS esperado,
           pg_get_functiondef(p.oid) LIKE '%virikyna.origen_precio%' AS ya
    FROM pg_proc p
    JOIN (VALUES ('actualizar_precios_masivo', 'b87f9d2697c96f89289e86fb8abb7c02'),
                 ('aplicar_costo_vinculo_item', '169116cb98a56af8dcef5469559b39c4'),
                 ('cargar_factura_compra', '050e07eedaf509f7a139f06e3ff5ff3b')) AS e(proname, md5)
      ON e.proname = p.proname
    WHERE p.pronamespace = 'public'::regnamespace
  LOOP
    IF NOT v_r.ya AND v_r.md5 <> v_r.esperado THEN
      RAISE EXCEPTION 'docs/67: % cambió en producción desde el relevamiento — regenerar la migración', v_r.proname;
    END IF;
  END LOOP;
END;
$$;

-- ─── 1. Tablas ───────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.productos_precios_historial (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  producto_id uuid NOT NULL REFERENCES public.productos(id) ON DELETE CASCADE,
  precio_anterior numeric(12,2),  -- NULL en un alta
  precio_nuevo numeric(12,2),
  origen text NOT NULL CHECK (origen IN ('manual', 'factura', 'masivo', 'margen', 'iva', 'reversion', 'alta')),
  usuario_id uuid,                -- auth.uid(); NULL = SQL Editor / mantenimiento (como auditoria)
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_precios_historial_producto ON public.productos_precios_historial (producto_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_precios_historial_fecha ON public.productos_precios_historial (created_at DESC);

CREATE TABLE IF NOT EXISTS public.productos_etiqueta (
  producto_id uuid PRIMARY KEY REFERENCES public.productos(id) ON DELETE CASCADE,
  precio_etiquetado numeric(12,2) NOT NULL,
  marcado_por uuid REFERENCES public.perfiles(id),  -- NULL = inicialización de docs/67
  marcado_at timestamptz
);

-- Lectura para cualquier usuario activo (mismo criterio que productos_select). Escritura solo por
-- trigger / marcar_etiquetas (SECURITY DEFINER): sin policies de INSERT/UPDATE/DELETE.
ALTER TABLE public.productos_precios_historial ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.productos_etiqueta ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS productos_precios_historial_select ON public.productos_precios_historial;
CREATE POLICY productos_precios_historial_select ON public.productos_precios_historial FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));
DROP POLICY IF EXISTS productos_etiqueta_select ON public.productos_etiqueta;
CREATE POLICY productos_etiqueta_select ON public.productos_etiqueta FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));

REVOKE ALL ON public.productos_precios_historial, public.productos_etiqueta FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.productos_precios_historial, public.productos_etiqueta TO authenticated;
GRANT ALL ON public.productos_precios_historial, public.productos_etiqueta TO service_role;

-- ─── 2. Trigger de historial ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_productos_precio_historial() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_origen text := NULLIF(current_setting('virikyna.origen_precio', true), '');
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.precio_venta IS NOT NULL THEN
      INSERT INTO productos_precios_historial (producto_id, precio_anterior, precio_nuevo, origen, usuario_id)
      VALUES (NEW.id, NULL, NEW.precio_venta, 'alta', auth.uid());
    END IF;
    RETURN NULL;
  END IF;

  IF v_origen IS NULL THEN
    v_origen := CASE
      WHEN current_setting('virikyna.suppress_audit', true) = 'true' THEN 'reversion'
      WHEN NEW.costo IS NOT DISTINCT FROM OLD.costo AND NEW.precio_manual IS NOT DISTINCT FROM OLD.precio_manual
           AND NEW.margen_1 IS NOT DISTINCT FROM OLD.margen_1 AND NEW.margen_2 IS NOT DISTINCT FROM OLD.margen_2 THEN 'iva'
      WHEN NEW.costo IS NOT DISTINCT FROM OLD.costo AND NEW.precio_manual IS NOT DISTINCT FROM OLD.precio_manual THEN 'margen'
      ELSE 'manual'
    END;
  END IF;

  INSERT INTO productos_precios_historial (producto_id, precio_anterior, precio_nuevo, origen, usuario_id)
  VALUES (NEW.id, OLD.precio_venta, NEW.precio_venta, v_origen, auth.uid());
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.fn_productos_precio_historial() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_precio_historial_upd ON public.productos;
CREATE TRIGGER trg_precio_historial_upd AFTER UPDATE ON public.productos
  FOR EACH ROW WHEN (OLD.precio_venta IS DISTINCT FROM NEW.precio_venta)
  EXECUTE FUNCTION public.fn_productos_precio_historial();
DROP TRIGGER IF EXISTS trg_precio_historial_ins ON public.productos;
CREATE TRIGGER trg_precio_historial_ins AFTER INSERT ON public.productos
  FOR EACH ROW EXECUTE FUNCTION public.fn_productos_precio_historial();

-- ─── 3. Origen en las RPCs que cambian precio (definición de producción + set_config) ────────
CREATE OR REPLACE FUNCTION public.actualizar_precios_masivo(p_porcentaje numeric, p_proveedor_id uuid DEFAULT NULL::uuid, p_producto_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_count INTEGER;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF (p_proveedor_id IS NULL) = (p_producto_ids IS NULL) THEN
    RAISE EXCEPTION 'Especificá exactamente uno: proveedor_id o producto_ids';
  END IF;
  -- docs/34: un precio manual tiene que quedar > 0 (CHECK).
  IF p_porcentaje IS NULL OR p_porcentaje <= -100 THEN
    RAISE EXCEPTION 'El porcentaje tiene que ser mayor a -100';
  END IF;

  -- docs/34: con precio_manual, el % va sobre ese precio con el redondeo escalonado (si el
  -- redondeo da 0 —precio nuevo menor a $50—, queda el valor exacto). Sin precio_manual, sobre
  -- el costo, como antes.
  PERFORM set_config('virikyna.origen_precio', 'masivo', true);  -- docs/67
  UPDATE productos
  SET precio_manual = CASE
        WHEN precio_manual IS NULL THEN NULL
        WHEN redondear_precio_venta(precio_manual * (1 + p_porcentaje/100.0)) > 0
          THEN redondear_precio_venta(precio_manual * (1 + p_porcentaje/100.0))
        ELSE ROUND(precio_manual * (1 + p_porcentaje/100.0), 2)
      END,
      costo = CASE WHEN precio_manual IS NULL THEN ROUND(costo * (1 + p_porcentaje/100.0), 2) ELSE costo END
  WHERE (p_proveedor_id IS NOT NULL AND proveedor_id = p_proveedor_id)
     OR (p_producto_ids IS NOT NULL AND id = ANY(p_producto_ids));

  GET DIAGNOSTICS v_count = ROW_COUNT;
  PERFORM set_config('virikyna.origen_precio', '', true);  -- docs/67
  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.aplicar_costo_vinculo_item(p_item_id uuid, p_producto_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_plan jsonb;
  v_cambia_proveedor boolean;
BEGIN
  -- Lock antes del plan: una carga de factura simultánea del mismo producto espera.
  PERFORM 1 FROM productos WHERE id = p_producto_id FOR UPDATE;
  v_plan := plan_costo_vinculo_item(p_item_id, p_producto_id);
  IF v_plan IS NULL OR NOT (v_plan->>'aplica')::boolean THEN
    RETURN v_plan;
  END IF;

  v_cambia_proveedor := (v_plan->>'cambia_proveedor')::boolean;
  IF v_cambia_proveedor THEN
    PERFORM set_config('virikyna.margen_auto_herencia', 'true', true);
  END IF;

  PERFORM set_config('virikyna.origen_precio', 'factura', true);  -- docs/67
  UPDATE productos
  SET proveedor_id = (v_plan->>'proveedor_id_nuevo')::uuid,
      margen_1 = (v_plan->>'margen_1_nuevo')::numeric,
      margen_2 = (v_plan->>'margen_2_nuevo')::numeric,
      costo = (v_plan->>'costo_nuevo')::numeric,
      precio_manual = CASE WHEN (v_plan->>'pone_costo')::boolean THEN NULL ELSE precio_manual END,
      updated_at = now()
  WHERE id = p_producto_id;
  PERFORM set_config('virikyna.origen_precio', '', true);  -- docs/67

  IF v_cambia_proveedor THEN
    PERFORM set_config('virikyna.margen_auto_herencia', 'false', true);
  END IF;
  RETURN v_plan;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cargar_factura_compra(p_proveedor_id uuid, p_tipo_comprobante tipo_comprobante_compra, p_letra letra_comprobante_compra, p_punto_venta text, p_numero_comprobante text, p_fecha_comprobante date, p_fecha_fiscal date, p_forma_pago forma_pago_compra, p_items jsonb, p_copiada_de_id uuid DEFAULT NULL::uuid, p_iva_alicuota numeric DEFAULT 21, p_tipo_compra text DEFAULT 'articulos'::text, p_borrador_id uuid DEFAULT NULL::uuid, p_devuelve_mercaderia boolean DEFAULT false)
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
      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, referencia_id, usuario_id)
      VALUES (v_producto_id, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'),
             'compra', (v_item->>'cantidad')::NUMERIC, v_factura_id, auth.uid());

      INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
      VALUES (v_producto_id, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'), (v_item->>'cantidad')::NUMERIC)
      ON CONFLICT (producto_id, ubicacion)
      DO UPDATE SET cantidad = stock_ubicaciones.cantidad + (v_item->>'cantidad')::NUMERIC;
    ELSIF v_producto_id IS NOT NULL AND v_devuelve THEN
      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
      VALUES (v_producto_id, COALESCE((v_item->>'ubicacion')::ubicacion_stock,'local'), 'ajuste',
             -1 * (v_item->>'cantidad')::NUMERIC,
             'Devolucion a proveedor: NC ' || COALESCE(NULLIF(btrim(p_numero_comprobante), ''), 'sin numero'),
             v_factura_id, auth.uid());

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
$function$;

-- ─── 4. Backfill del historial y 5. inicialización de etiquetas (una sola vez) ───────────────
-- Los triggers ya existen y tienen tomada la tabla productos hasta el COMMIT: un cambio de precio
-- desde las apps espera y entra por el trigger; lo anterior ya está en auditoria.
DO $$
DECLARE
  v_cierre_carga timestamptz := (SELECT cerrada_at FROM configuracion WHERE fila_unica);
  v_corte timestamptz := now() - interval '7 days';
BEGIN
  IF EXISTS (SELECT 1 FROM productos_etiqueta) THEN
    RAISE NOTICE 'docs/67: backfill e inicialización ya hechos, se saltean';
    RETURN;
  END IF;

  INSERT INTO productos_precios_historial (producto_id, precio_anterior, precio_nuevo, origen, usuario_id, created_at)
  SELECT x.producto_id, x.precio_anterior, x.precio_nuevo, x.origen, x.usuario_id, x.created_at
  FROM (
    SELECT a.registro_id AS producto_id,
           (a.valores_anteriores->>'precio_venta')::numeric AS precio_anterior,
           (a.valores_nuevos->>'precio_venta')::numeric AS precio_nuevo,
           CASE
             WHEN a.accion = 'reversion' THEN 'reversion'
             -- Misma transacción que una factura de compra (alta o vínculo de un ítem).
             WHEN EXISTS (SELECT 1 FROM facturas_compra f WHERE f.created_at = a.created_at)
               OR EXISTS (SELECT 1 FROM auditoria x WHERE x.created_at = a.created_at AND x.tabla_afectada = 'facturas_compra') THEN 'factura'
             -- Varios productos en la misma transacción sin factura: aumento masivo.
             WHEN (SELECT count(*) FROM auditoria y WHERE y.created_at = a.created_at
                     AND y.tabla_afectada = 'productos' AND y.accion = 'edicion') > 1 THEN 'masivo'
             WHEN a.valores_anteriores->'costo' IS NOT DISTINCT FROM a.valores_nuevos->'costo'
              AND a.valores_anteriores->'precio_manual' IS NOT DISTINCT FROM a.valores_nuevos->'precio_manual'
              AND a.valores_anteriores->'margen_1' IS NOT DISTINCT FROM a.valores_nuevos->'margen_1'
              AND a.valores_anteriores->'margen_2' IS NOT DISTINCT FROM a.valores_nuevos->'margen_2' THEN 'iva'
             WHEN a.valores_anteriores->'costo' IS NOT DISTINCT FROM a.valores_nuevos->'costo'
              AND a.valores_anteriores->'precio_manual' IS NOT DISTINCT FROM a.valores_nuevos->'precio_manual' THEN 'margen'
             ELSE 'manual'
           END AS origen,
           a.usuario_id, a.created_at
    FROM auditoria a
    WHERE a.tabla_afectada = 'productos' AND a.accion IN ('edicion', 'reversion')
      AND a.created_at >= '2026-10-13'
      AND (a.valores_anteriores->>'precio_venta') IS DISTINCT FROM (a.valores_nuevos->>'precio_venta')
    UNION ALL
    SELECT a.registro_id, NULL, (a.valores_nuevos->>'precio_venta')::numeric, 'alta', a.usuario_id, a.created_at
    FROM auditoria a
    WHERE a.tabla_afectada = 'productos' AND a.accion = 'alta'
      AND a.created_at > COALESCE(v_cierre_carga, '2026-10-19')
      AND a.valores_nuevos->>'precio_venta' IS NOT NULL
  ) x
  WHERE EXISTS (SELECT 1 FROM productos p WHERE p.id = x.producto_id)
  ORDER BY x.created_at;

  -- Pendientes iniciales: lo cambiado (o dado de alta) en los últimos 7 días.
  INSERT INTO productos_etiqueta (producto_id, precio_etiquetado, marcado_por, marcado_at)
  SELECT p.id, COALESCE(pr.precio_anterior, p.precio_venta), NULL, NULL
  FROM productos p
  LEFT JOIN (
    SELECT DISTINCT ON (h.producto_id) h.producto_id, h.precio_anterior, h.origen
    FROM productos_precios_historial h
    WHERE h.created_at >= v_corte
    ORDER BY h.producto_id, h.created_at, h.id
  ) pr ON pr.producto_id = p.id
  WHERE p.precio_venta IS NOT NULL
    AND (pr.producto_id IS NULL OR pr.precio_anterior IS NOT NULL)  -- alta del tramo: sin fila = pendiente
  ON CONFLICT (producto_id) DO NOTHING;
END;
$$;

-- ─── 6. RPCs ─────────────────────────────────────────────────────────────────────────────────
-- Invoker: lee con la RLS de quien llama (productos, productos_etiqueta: usuarios activos).
CREATE OR REPLACE FUNCTION public.alerta_precios_pendientes() RETURNS integer
LANGUAGE sql STABLE SET search_path = public
AS $$
  SELECT count(*)::int
  FROM productos p
  LEFT JOIN productos_etiqueta e ON e.producto_id = p.id
  WHERE p.estado = 'activo' AND p.precio_venta IS NOT NULL
    AND p.precio_venta IS DISTINCT FROM e.precio_etiquetado;
$$;
REVOKE ALL ON FUNCTION public.alerta_precios_pendientes() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.alerta_precios_pendientes() TO authenticated, service_role;

-- Una fila por producto, del cambio más nuevo al más viejo.
--   Pendientes: anterior = precio de la etiqueta (NULL en un alta sin etiquetar).
--   Historial (p_solo_pendientes = false): productos con cambios desde p_desde (default 30 días);
--     anterior = precio antes del primer cambio del tramo.
--   fecha_cambio / origen: último cambio (del tramo, en historial). precio_actual: el de hoy.
CREATE OR REPLACE FUNCTION public.precios_cambiados(p_solo_pendientes boolean DEFAULT true, p_desde timestamptz DEFAULT NULL)
RETURNS TABLE (
  producto_id uuid,
  nombre text,
  marca text,
  codigo_barras text,
  codigo_interno text,
  fecha_cambio timestamptz,
  precio_anterior numeric,
  precio_actual numeric,
  variacion_porcentaje numeric,
  origen text,
  pendiente boolean,
  marcado_por text,
  marcado_at timestamptz
)
LANGUAGE sql STABLE SET search_path = public
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
    WHERE p_solo_pendientes OR h.created_at >= lim.desde
    ORDER BY h.producto_id, h.created_at DESC, h.id DESC
  ),
  pri AS (
    SELECT DISTINCT ON (h.producto_id) h.producto_id, h.precio_anterior
    FROM productos_precios_historial h CROSS JOIN lim
    WHERE NOT p_solo_pendientes AND h.created_at >= lim.desde
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
REVOKE ALL ON FUNCTION public.precios_cambiados(boolean, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.precios_cambiados(boolean, timestamptz) TO authenticated, service_role;

-- "Etiqueta actualizada": admin y cajero. Solo marca lo que está pendiente; con p_precios, además,
-- solo si el precio sigue siendo el que se vio en pantalla. Devuelve cuántos marcó.
CREATE OR REPLACE FUNCTION public.marcar_etiquetas(p_producto_ids uuid[], p_precios numeric[] DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_n integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF COALESCE(cardinality(p_producto_ids), 0) = 0 THEN
    RETURN 0;
  END IF;
  IF p_precios IS NOT NULL AND cardinality(p_precios) <> cardinality(p_producto_ids) THEN
    RAISE EXCEPTION 'Tiene que venir un precio por producto';
  END IF;

  INSERT INTO productos_etiqueta (producto_id, precio_etiquetado, marcado_por, marcado_at)
  SELECT DISTINCT ON (p.id) p.id, p.precio_venta, auth.uid(), now()
  FROM unnest(p_producto_ids, COALESCE(p_precios, array_fill(NULL::numeric, ARRAY[cardinality(p_producto_ids)]))) AS u(id, precio)
  JOIN productos p ON p.id = u.id
  LEFT JOIN productos_etiqueta e ON e.producto_id = p.id
  WHERE p.precio_venta IS NOT NULL
    AND p.precio_venta IS DISTINCT FROM e.precio_etiquetado
    AND (u.precio IS NULL OR u.precio = p.precio_venta)
  ORDER BY p.id
  ON CONFLICT (producto_id) DO UPDATE
    SET precio_etiquetado = EXCLUDED.precio_etiquetado,
        marcado_por = EXCLUDED.marcado_por,
        marcado_at = EXCLUDED.marcado_at;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.marcar_etiquetas(uuid[], numeric[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.marcar_etiquetas(uuid[], numeric[]) TO authenticated, service_role;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (solo lectura)
-- ════════════════════════════════════════════════════════════════════════════════════════════
SELECT json_build_object(
  'historial_por_origen', (SELECT json_object_agg(origen, n) FROM (SELECT origen, count(*) n FROM productos_precios_historial GROUP BY origen) x),
  'etiquetas', (SELECT count(*) FROM productos_etiqueta),
  'pendientes', (SELECT count(*) FROM precios_cambiados(true)),
  'rpcs', (SELECT json_agg(json_build_object('f', p.proname, 'definer', p.prosecdef,
             'anon', has_function_privilege('anon', p.oid, 'EXECUTE'),
             'authenticated', has_function_privilege('authenticated', p.oid, 'EXECUTE')))
           FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
             AND p.proname IN ('alerta_precios_pendientes', 'precios_cambiados', 'marcar_etiquetas')),
  'origen_en_rpcs', (SELECT json_object_agg(p.proname, pg_get_functiondef(p.oid) LIKE '%virikyna.origen_precio%')
           FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
             AND p.proname IN ('actualizar_precios_masivo', 'aplicar_costo_vinculo_item', 'cargar_factura_compra'))
) AS verificacion;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (BEGIN … ROLLBACK). Corre como `authenticated` con el JWT de un admin y de un
-- cajero reales (SET LOCAL ROLE + request.jwt.claims), así se prueban RLS y permisos de verdad.
-- Los cambios de precio, la factura y el producto de prueba se crean dentro de la transacción.
-- Siempre aborta: el resultado viene en el mensaje 'RESULTADO: …'.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TEMP TABLE t67 (orden int, caso text, ok boolean, detalle text) ON COMMIT DROP;
CREATE TEMP TABLE t67_ids (clave text PRIMARY KEY, id uuid) ON COMMIT DROP;
GRANT ALL ON t67, t67_ids TO authenticated;

-- Productos de prueba: activos, precio por fórmula (sin manual), con costo y proveedor, etiquetados
-- al precio de hoy (no pendientes).
CREATE TEMP TABLE t67_cand ON COMMIT DROP AS
  SELECT p.id, row_number() OVER (ORDER BY p.nombre) AS n
  FROM productos p JOIN productos_etiqueta e ON e.producto_id = p.id
  WHERE p.estado = 'activo' AND p.precio_manual IS NULL AND p.costo > 0 AND p.proveedor_id IS NOT NULL
    AND e.precio_etiquetado = p.precio_venta;

INSERT INTO t67_ids
SELECT 'cajero', (SELECT id FROM perfiles WHERE rol = 'cajero' AND activo ORDER BY created_at LIMIT 1)
UNION ALL SELECT 'admin', (SELECT id FROM perfiles WHERE rol = 'admin' AND activo ORDER BY created_at LIMIT 1)
UNION ALL SELECT 'prod1', (SELECT id FROM t67_cand WHERE n = 1)
UNION ALL SELECT 'prod2', (SELECT id FROM t67_cand WHERE n = 2)
UNION ALL SELECT 'prod3', (SELECT id FROM t67_cand WHERE n = 3);

-- ─── Como postgres: backfill e inicialización ────────────────────────────────────────────────
DO $$
DECLARE
  v_esperado int;
  v_n int;
  v_txt text;
BEGIN
  -- 1. Backfill = cambios de precio de auditoría desde el 13/10 + altas posteriores a la carga.
  SELECT count(*) INTO v_esperado
  FROM auditoria a
  WHERE a.tabla_afectada = 'productos' AND EXISTS (SELECT 1 FROM productos p WHERE p.id = a.registro_id)
    AND ((a.accion IN ('edicion', 'reversion') AND a.created_at >= '2026-10-13'
          AND (a.valores_anteriores->>'precio_venta') IS DISTINCT FROM (a.valores_nuevos->>'precio_venta'))
      OR (a.accion = 'alta' AND a.created_at > (SELECT cerrada_at FROM configuracion WHERE fila_unica)
          AND a.valores_nuevos->>'precio_venta' IS NOT NULL));
  SELECT count(*) INTO v_n FROM productos_precios_historial;
  SELECT string_agg(origen || '=' || n, ', ' ORDER BY n DESC) INTO v_txt
  FROM (SELECT origen, count(*) n FROM productos_precios_historial GROUP BY origen) x;
  INSERT INTO t67 VALUES (1, 'backfill = auditoría', v_n = v_esperado, format('%s filas (%s)', v_n, v_txt));

  -- 2. Todo producto con precio tiene etiqueta, salvo las altas de los últimos 7 días.
  SELECT count(*) INTO v_n FROM productos p
  WHERE p.precio_venta IS NOT NULL AND NOT EXISTS (SELECT 1 FROM productos_etiqueta e WHERE e.producto_id = p.id)
    AND NOT EXISTS (SELECT 1 FROM productos_precios_historial h WHERE h.producto_id = p.id AND h.origen = 'alta'
                    AND h.created_at >= now() - interval '7 days');
  INSERT INTO t67 VALUES (2, 'sin etiqueta solo altas de 7 días', v_n = 0, v_n || ' sin etiqueta fuera del tramo');

  -- 3. Un pendiente inicial siempre tiene un cambio o alta en los últimos 7 días.
  SELECT count(*) INTO v_n FROM precios_cambiados(true) c
  WHERE NOT EXISTS (SELECT 1 FROM productos_precios_historial h WHERE h.producto_id = c.producto_id
                    AND h.created_at >= now() - interval '7 days');
  INSERT INTO t67 VALUES (3, 'pendientes iniciales dentro del tramo', v_n = 0,
    format('pendientes iniciales: %s (altas sin etiqueta: %s, cambios: %s); fuera del tramo: %s',
      (SELECT count(*) FROM precios_cambiados(true)),
      (SELECT count(*) FROM precios_cambiados(true) WHERE precio_anterior IS NULL),
      (SELECT count(*) FROM precios_cambiados(true) WHERE precio_anterior IS NOT NULL), v_n));

  -- 4. Hay 3 productos de prueba.
  SELECT count(*) INTO v_n FROM t67_ids WHERE clave LIKE 'prod%' AND id IS NOT NULL;
  INSERT INTO t67 VALUES (4, 'productos de prueba', v_n = 3, v_n || ' de 3');
END;
$$;

-- ─── Como admin ──────────────────────────────────────────────────────────────────────────────
SELECT set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true) FROM t67_ids WHERE clave = 'admin';
SET LOCAL ROLE authenticated;

DO $$
DECLARE
  v_admin uuid := (SELECT id FROM t67_ids WHERE clave = 'admin');
  v_p1 uuid := (SELECT id FROM t67_ids WHERE clave = 'prod1');
  v_p2 uuid := (SELECT id FROM t67_ids WHERE clave = 'prod2');
  v_p3 uuid := (SELECT id FROM t67_ids WHERE clave = 'prod3');
  v_etiq numeric;
  v_precio numeric;
  v_costo numeric;
  v_prov uuid;
  v_h record;
  v_c record;
  v_n int;
  v_aud uuid;
  v_nuevo uuid;
BEGIN
  SELECT precio_venta INTO v_etiq FROM productos WHERE id = v_p1;

  -- 5. Cambio manual → pendiente, origen manual, usuario admin, anterior = etiqueta.
  UPDATE productos SET precio_manual = v_etiq + 100 WHERE id = v_p1;
  SELECT * INTO v_h FROM productos_precios_historial WHERE producto_id = v_p1 ORDER BY id DESC LIMIT 1;
  SELECT * INTO v_c FROM precios_cambiados(true) WHERE producto_id = v_p1;
  INSERT INTO t67 VALUES (5, 'manual → pendiente (manual, anterior = etiqueta)',
    v_h.origen = 'manual' AND v_h.usuario_id = v_admin AND v_c.pendiente AND v_c.precio_anterior = v_etiq
      AND v_c.precio_actual = v_etiq + 100 AND v_c.origen = 'manual',
    format('hist %s %s→%s · fila %s→%s %s%%', v_h.origen, v_h.precio_anterior, v_h.precio_nuevo, v_c.precio_anterior, v_c.precio_actual, v_c.variacion_porcentaje));

  -- 6. Segundo cambio del mismo producto → una sola fila, anterior sigue siendo la etiqueta.
  UPDATE productos SET precio_manual = v_etiq + 300 WHERE id = v_p1;
  SELECT count(*) INTO v_n FROM precios_cambiados(true) WHERE producto_id = v_p1;
  SELECT * INTO v_c FROM precios_cambiados(true) WHERE producto_id = v_p1;
  INSERT INTO t67 VALUES (6, 'varios cambios → 1 fila, anterior = etiqueta',
    v_n = 1 AND v_c.precio_anterior = v_etiq AND v_c.precio_actual = v_etiq + 300
      AND (SELECT count(*) FROM productos_precios_historial WHERE producto_id = v_p1 AND created_at = now()) = 2,
    format('%s fila(s), %s→%s', v_n, v_c.precio_anterior, v_c.precio_actual));

  -- 7. Vuelve al precio etiquetado → sale solo.
  UPDATE productos SET precio_manual = NULL WHERE id = v_p1;
  INSERT INTO t67 VALUES (7, 'vuelve al etiquetado → sale de pendientes',
    NOT EXISTS (SELECT 1 FROM precios_cambiados(true) WHERE producto_id = v_p1),
    format('precio %s, etiqueta %s', (SELECT precio_venta FROM productos WHERE id = v_p1), v_etiq));

  -- 8. Factura de compra que cambia el costo → origen factura.
  SELECT costo, proveedor_id INTO v_costo, v_prov FROM productos WHERE id = v_p2;
  PERFORM cargar_factura_compra(
    v_prov, 'factura', (SELECT letra FROM facturas_compra WHERE tipo_comprobante = 'factura' ORDER BY created_at DESC LIMIT 1),
    '9967', '99967001', current_date, current_date,
    (SELECT forma_pago FROM facturas_compra WHERE tipo_comprobante = 'factura' ORDER BY created_at DESC LIMIT 1),
    jsonb_build_array(jsonb_build_object('producto_id', v_p2, 'descripcion', 'PRUEBA 67', 'cantidad', 1,
      'precio_unitario_sin_iva', round(v_costo * 1.2, 2), 'ubicacion', 'local')));
  SELECT * INTO v_h FROM productos_precios_historial WHERE producto_id = v_p2 ORDER BY id DESC LIMIT 1;
  INSERT INTO t67 VALUES (8, 'factura de compra → origen factura',
    v_h.origen = 'factura' AND v_h.created_at = now() AND EXISTS (SELECT 1 FROM precios_cambiados(true) WHERE producto_id = v_p2 AND origen = 'factura'),
    format('%s %s→%s', v_h.origen, v_h.precio_anterior, v_h.precio_nuevo));

  -- 9. Después de la factura, en la misma transacción, un cambio manual es manual (GUC limpio).
  UPDATE productos SET precio_manual = (SELECT precio_venta FROM productos WHERE id = v_p3) + 50 WHERE id = v_p3;
  SELECT * INTO v_h FROM productos_precios_historial WHERE producto_id = v_p3 ORDER BY id DESC LIMIT 1;
  INSERT INTO t67 VALUES (9, 'origen se limpia después de la RPC', v_h.origen = 'manual', v_h.origen);

  -- 10. Aumento masivo → origen masivo (prod1 con precio por fórmula).
  PERFORM actualizar_precios_masivo(10, NULL, ARRAY[v_p1]);
  SELECT * INTO v_h FROM productos_precios_historial WHERE producto_id = v_p1 ORDER BY id DESC LIMIT 1;
  INSERT INTO t67 VALUES (10, 'aumento masivo → origen masivo', v_h.origen = 'masivo',
    format('%s %s→%s', v_h.origen, v_h.precio_anterior, v_h.precio_nuevo));

  -- 11. Revertir ese cambio desde el Historial → origen reversion (y vuelve al etiquetado).
  -- Las 4 ediciones de prod1 tienen el mismo created_at (misma transacción): se toma la del masivo.
  SELECT id INTO v_aud FROM auditoria WHERE tabla_afectada = 'productos' AND registro_id = v_p1 AND accion = 'edicion'
    AND (valores_nuevos->>'precio_venta')::numeric = (SELECT precio_venta FROM productos WHERE id = v_p1)
    AND (valores_anteriores->>'costo') IS DISTINCT FROM (valores_nuevos->>'costo');
  PERFORM revertir_edicion(v_aud);
  SELECT * INTO v_h FROM productos_precios_historial WHERE producto_id = v_p1 ORDER BY id DESC LIMIT 1;
  INSERT INTO t67 VALUES (11, 'reversión → origen reversion', v_h.origen = 'reversion' AND v_h.precio_nuevo = v_etiq,
    format('%s %s→%s', v_h.origen, v_h.precio_anterior, v_h.precio_nuevo));

  -- 12. Producto nuevo → pendiente con origen alta, sin precio anterior.
  INSERT INTO productos (nombre, precio_manual) VALUES ('PRUEBA 67 ALTA', 1234) RETURNING id INTO v_nuevo;
  INSERT INTO t67_ids VALUES ('nuevo', v_nuevo);
  SELECT * INTO v_c FROM precios_cambiados(true) WHERE producto_id = v_nuevo;
  INSERT INTO t67 VALUES (12, 'alta → pendiente (alta, sin anterior)',
    v_c.origen = 'alta' AND v_c.precio_anterior IS NULL AND v_c.precio_actual = 1234 AND v_c.variacion_porcentaje IS NULL,
    format('%s %s→%s', v_c.origen, v_c.precio_anterior, v_c.precio_actual));

  -- 13. Contador = filas del modal.
  INSERT INTO t67 VALUES (13, 'alerta_precios_pendientes = filas',
    alerta_precios_pendientes() = (SELECT count(*) FROM precios_cambiados(true)),
    alerta_precios_pendientes() || ' pendientes');

  -- 14. Historial 30 días: prod1 aparece con anterior = precio antes del primer cambio del tramo.
  SELECT * INTO v_c FROM precios_cambiados(false, now() - interval '1 minute') WHERE producto_id = v_p1;
  INSERT INTO t67 VALUES (14, 'historial: anterior = antes del primer cambio del tramo',
    v_c.precio_anterior = v_etiq AND v_c.origen = 'reversion' AND NOT v_c.pendiente,
    format('%s→%s %s pendiente=%s', v_c.precio_anterior, v_c.precio_actual, v_c.origen, v_c.pendiente));

  -- 15. Admin marca → sale, guarda quién.
  v_n := marcar_etiquetas(ARRAY[v_p3]);
  INSERT INTO t67 VALUES (15, 'admin marca',
    v_n = 1 AND NOT EXISTS (SELECT 1 FROM precios_cambiados(true) WHERE producto_id = v_p3)
      AND (SELECT marcado_por FROM productos_etiqueta WHERE producto_id = v_p3) = v_admin,
    v_n || ' marcado');
END;
$$;

-- ─── Como cajero ─────────────────────────────────────────────────────────────────────────────
RESET ROLE;
SELECT set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true) FROM t67_ids WHERE clave = 'cajero';
SET LOCAL ROLE authenticated;

DO $$
DECLARE
  v_cajero uuid := (SELECT id FROM t67_ids WHERE clave = 'cajero');
  v_p2 uuid := (SELECT id FROM t67_ids WHERE clave = 'prod2');
  v_nuevo uuid := (SELECT id FROM t67_ids WHERE clave = 'nuevo');
  v_n int;
  v_c record;
BEGIN
  -- 16. El cajero ve pendientes e historial.
  INSERT INTO t67 VALUES (16, 'cajero lee pendientes e historial',
    EXISTS (SELECT 1 FROM precios_cambiados(true) WHERE producto_id = v_p2)
      AND EXISTS (SELECT 1 FROM productos_precios_historial WHERE producto_id = v_p2),
    alerta_precios_pendientes() || ' pendientes');

  -- 17. Con un precio distinto al de hoy (cambió mientras miraba) no marca.
  v_n := marcar_etiquetas(ARRAY[v_p2], ARRAY[1::numeric]);
  INSERT INTO t67 VALUES (17, 'precio visto distinto → no marca',
    v_n = 0 AND EXISTS (SELECT 1 FROM precios_cambiados(true) WHERE producto_id = v_p2), v_n || ' marcados');

  -- 18. Marcar (repetido en el array + el alta) → salen, guarda cajero y hora.
  v_n := marcar_etiquetas(ARRAY[v_p2, v_p2, v_nuevo],
    ARRAY[(SELECT precio_venta FROM productos WHERE id = v_p2), (SELECT precio_venta FROM productos WHERE id = v_p2), 1234]);
  SELECT * INTO v_c FROM precios_cambiados(false, now() - interval '1 minute') WHERE producto_id = v_p2;
  INSERT INTO t67 VALUES (18, 'cajero marca (repetidos ok) → sale, quién/cuándo',
    v_n = 2 AND NOT EXISTS (SELECT 1 FROM precios_cambiados(true) WHERE producto_id IN (v_p2, v_nuevo))
      AND (SELECT marcado_por FROM productos_etiqueta WHERE producto_id = v_p2) = v_cajero
      AND v_c.marcado_at = now() AND v_c.marcado_por IS NOT NULL,
    format('%s marcados, por %s', v_n, v_c.marcado_por));

  -- 19. Marcar algo que no está pendiente no hace nada.
  v_n := marcar_etiquetas(ARRAY[v_p2]);
  INSERT INTO t67 VALUES (19, 'marcar no pendiente → 0', v_n = 0, v_n || ' marcados');

  -- 20. El cajero no escribe las tablas directo.
  BEGIN
    INSERT INTO productos_etiqueta (producto_id, precio_etiquetado) VALUES (v_p2, 1);
    INSERT INTO t67 VALUES (20, 'cajero no escribe productos_etiqueta', false, 'se insertó');
  EXCEPTION WHEN insufficient_privilege THEN
    INSERT INTO t67 VALUES (20, 'cajero no escribe productos_etiqueta', true, SQLERRM);
  END;
  BEGIN
    DELETE FROM productos_precios_historial WHERE producto_id = v_p2;
    INSERT INTO t67 VALUES (21, 'cajero no borra historial', false, 'se borró');
  EXCEPTION WHEN insufficient_privilege THEN
    INSERT INTO t67 VALUES (21, 'cajero no borra historial', true, SQLERRM);
  END;
END;
$$;

RESET ROLE;

-- ─── Permisos (como postgres) y resultado ────────────────────────────────────────────────────
DO $$
DECLARE
  v_ok int;
  v_total int;
  v_fallas text;
  v_detalle text;
BEGIN
  INSERT INTO t67 VALUES (22, 'anon sin RPCs ni tablas',
    NOT has_function_privilege('anon', 'public.alerta_precios_pendientes()', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'public.precios_cambiados(boolean, timestamptz)', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'public.marcar_etiquetas(uuid[], numeric[])', 'EXECUTE')
      AND NOT has_table_privilege('anon', 'public.productos_precios_historial', 'SELECT')
      AND NOT has_table_privilege('anon', 'public.productos_etiqueta', 'SELECT')
      AND has_function_privilege('authenticated', 'public.marcar_etiquetas(uuid[], numeric[])', 'EXECUTE'),
    '');

  SELECT count(*) FILTER (WHERE ok), count(*),
         string_agg(format('[%s %s: %s]', orden, caso, detalle), ' ' ORDER BY orden) FILTER (WHERE NOT ok OR ok IS NULL),
         string_agg(format('%s) %s', orden, detalle), ' | ' ORDER BY orden) FILTER (WHERE orden IN (1, 3, 13))
  INTO v_ok, v_total, v_fallas, v_detalle
  FROM t67;
  RAISE EXCEPTION 'RESULTADO: % de % ok%. %', v_ok, v_total,
    CASE WHEN v_fallas IS NULL THEN '' ELSE ' — FALLAS: ' || v_fallas END, v_detalle;
END;
$$;

ROLLBACK;
