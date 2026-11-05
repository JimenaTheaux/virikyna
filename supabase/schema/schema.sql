


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."categoria_egreso" AS ENUM (
    'pago_proveedor',
    'sueldo',
    'servicio',
    'otro',
    'agua',
    'descartables',
    'super'
);


ALTER TYPE "public"."categoria_egreso" OWNER TO "postgres";


CREATE TYPE "public"."condicion_iva_cliente" AS ENUM (
    'consumidor_final',
    'responsable_inscripto',
    'monotributista',
    'exento',
    'no_categorizado'
);


ALTER TYPE "public"."condicion_iva_cliente" OWNER TO "postgres";


CREATE TYPE "public"."estado_cierre_z" AS ENUM (
    'pendiente_validacion',
    'validado'
);


ALTER TYPE "public"."estado_cierre_z" OWNER TO "postgres";


CREATE TYPE "public"."estado_comprobante" AS ENUM (
    'sin_facturar',
    'facturado',
    'anulada'
);


ALTER TYPE "public"."estado_comprobante" OWNER TO "postgres";


CREATE TYPE "public"."estado_devolucion" AS ENUM (
    'activa',
    'anulada'
);


ALTER TYPE "public"."estado_devolucion" OWNER TO "postgres";


CREATE TYPE "public"."estado_producto" AS ENUM (
    'activo',
    'inactivo'
);


ALTER TYPE "public"."estado_producto" OWNER TO "postgres";


CREATE TYPE "public"."estado_venta_interna" AS ENUM (
    'pendiente',
    'finalizado'
);


ALTER TYPE "public"."estado_venta_interna" OWNER TO "postgres";


CREATE TYPE "public"."forma_pago_compra" AS ENUM (
    'contado',
    'cuenta_corriente'
);


ALTER TYPE "public"."forma_pago_compra" OWNER TO "postgres";


CREATE TYPE "public"."forma_pago_egreso" AS ENUM (
    'efectivo',
    'transferencia',
    'cheque',
    'echeq',
    'mixto'
);


ALTER TYPE "public"."forma_pago_egreso" OWNER TO "postgres";


CREATE TYPE "public"."forma_pago_venta" AS ENUM (
    'efectivo',
    'transferencia',
    'qr',
    'tarjeta_debito',
    'tarjeta_credito',
    'cuenta_corriente',
    'combinado'
);


ALTER TYPE "public"."forma_pago_venta" OWNER TO "postgres";


CREATE TYPE "public"."letra_comprobante_compra" AS ENUM (
    'A',
    'B',
    'R',
    'X'
);


ALTER TYPE "public"."letra_comprobante_compra" OWNER TO "postgres";


CREATE TYPE "public"."motivo_devolucion" AS ENUM (
    'regalo',
    'defectuoso',
    'arrepentimiento',
    'otro'
);


ALTER TYPE "public"."motivo_devolucion" OWNER TO "postgres";


CREATE TYPE "public"."origen_egreso" AS ENUM (
    'turno',
    'general'
);


ALTER TYPE "public"."origen_egreso" OWNER TO "postgres";


CREATE TYPE "public"."rol_usuario" AS ENUM (
    'admin',
    'cajero'
);


ALTER TYPE "public"."rol_usuario" OWNER TO "postgres";


CREATE TYPE "public"."tipo_accion_auditoria" AS ENUM (
    'alta',
    'edicion',
    'eliminacion',
    'anulacion',
    'reversion',
    'nota_correccion'
);


ALTER TYPE "public"."tipo_accion_auditoria" OWNER TO "postgres";


CREATE TYPE "public"."tipo_cierre" AS ENUM (
    'x',
    'z'
);


ALTER TYPE "public"."tipo_cierre" OWNER TO "postgres";


CREATE TYPE "public"."tipo_cliente" AS ENUM (
    'externo',
    'interno'
);


ALTER TYPE "public"."tipo_cliente" OWNER TO "postgres";


CREATE TYPE "public"."tipo_comprobante_compra" AS ENUM (
    'factura',
    'remito',
    'cupon',
    'nota_credito',
    'nota_debito',
    'presupuesto'
);


ALTER TYPE "public"."tipo_comprobante_compra" OWNER TO "postgres";


CREATE TYPE "public"."tipo_item_devolucion" AS ENUM (
    'devuelto',
    'nuevo'
);


ALTER TYPE "public"."tipo_item_devolucion" OWNER TO "postgres";


CREATE TYPE "public"."tipo_movimiento_cuenta" AS ENUM (
    'saldo_inicial',
    'venta',
    'pago_cliente',
    'pago_proveedor',
    'egreso',
    'ingreso_manual',
    'cierre_z',
    'transferencia_interna',
    'retiro'
);


ALTER TYPE "public"."tipo_movimiento_cuenta" OWNER TO "postgres";


CREATE TYPE "public"."tipo_movimiento_stock" AS ENUM (
    'venta',
    'compra',
    'ajuste',
    'inicial'
);


ALTER TYPE "public"."tipo_movimiento_stock" OWNER TO "postgres";


CREATE TYPE "public"."ubicacion_stock" AS ENUM (
    'local',
    'deposito'
);


ALTER TYPE "public"."ubicacion_stock" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."abrir_caja"("p_monto_real" numeric) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_apertura_id UUID;
  v_ultimo_z cierres_caja%ROWTYPE;
  v_monto_esperado NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF p_monto_real IS NULL OR p_monto_real < 0 THEN
    RAISE EXCEPTION 'El monto de apertura debe ser mayor o igual a 0';
  END IF;
  IF EXISTS (SELECT 1 FROM aperturas_caja WHERE cierre_z_id IS NULL) THEN
    RAISE EXCEPTION 'Ya hay una caja abierta — no se puede abrir de nuevo hasta el próximo Cierre Z';
  END IF;

  SELECT * INTO v_ultimo_z FROM cierres_caja WHERE tipo = 'z' ORDER BY created_at DESC LIMIT 1;
  v_monto_esperado := COALESCE(v_ultimo_z.efectivo_contado, 0);

  INSERT INTO aperturas_caja (cierre_z_previo_id, monto_esperado, monto_real, diferencia, usuario_id)
  VALUES (v_ultimo_z.id, v_monto_esperado, p_monto_real, p_monto_real - v_monto_esperado, auth.uid())
  RETURNING id INTO v_apertura_id;

  RETURN v_apertura_id;
END;
$$;


ALTER FUNCTION "public"."abrir_caja"("p_monto_real" numeric) OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."configuracion" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "fila_unica" boolean DEFAULT true NOT NULL,
    "carga_inicial_abierta" boolean DEFAULT false NOT NULL,
    "abierta_at" timestamp with time zone,
    "abierta_por" "uuid",
    "cerrada_at" timestamp with time zone,
    "cerrada_por" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "datos_reset_at" timestamp with time zone,
    CONSTRAINT "configuracion_fila_unica_check" CHECK ("fila_unica")
);


ALTER TABLE "public"."configuracion" OWNER TO "postgres";


COMMENT ON COLUMN "public"."configuracion"."datos_reset_at" IS 'Último vaciado de datos. Lo pone el script de reset; las pantallas descartan lo guardado en el navegador con una marca anterior.';



CREATE OR REPLACE FUNCTION "public"."abrir_carga_inicial"() RETURNS "public"."configuracion"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_fila configuracion;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede abrir la carga inicial';
  END IF;
  IF (SELECT carga_inicial_abierta FROM configuracion) THEN
    RAISE EXCEPTION 'La carga inicial ya está abierta';
  END IF;

  UPDATE configuracion
  SET carga_inicial_abierta = true, abierta_at = now(), abierta_por = auth.uid(),
      cerrada_at = NULL, cerrada_por = NULL, updated_at = now()
  WHERE fila_unica  -- docs/34d: safeupdate exige WHERE
  RETURNING * INTO v_fila;
  RETURN v_fila;
END;
$$;


ALTER FUNCTION "public"."abrir_carga_inicial"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."actualizar_precios_masivo"("p_porcentaje" numeric, "p_proveedor_id" "uuid" DEFAULT NULL::"uuid", "p_producto_ids" "uuid"[] DEFAULT NULL::"uuid"[]) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
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
$_$;


ALTER FUNCTION "public"."actualizar_precios_masivo"("p_porcentaje" numeric, "p_proveedor_id" "uuid", "p_producto_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."agregar_nota_correccion"("p_cierre_id" "uuid", "p_nota" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede agregar una nota de corrección';
  END IF;
  IF p_nota IS NULL OR trim(p_nota) = '' THEN
    RAISE EXCEPTION 'La nota no puede estar vacía';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cierres_caja WHERE id = p_cierre_id AND tipo = 'z') THEN
    RAISE EXCEPTION 'Cierre Z no encontrado';
  END IF;

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, nota, usuario_id)
  VALUES ('cierres_caja', p_cierre_id, 'nota_correccion', trim(p_nota), auth.uid());
END;
$$;


ALTER FUNCTION "public"."agregar_nota_correccion"("p_cierre_id" "uuid", "p_nota" "text") OWNER TO "postgres";


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

  INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, usuario_id)
  VALUES (p_producto_id, p_ubicacion, 'ajuste', p_cantidad, p_motivo, auth.uid());

  INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
  VALUES (p_producto_id, p_ubicacion, p_cantidad)
  ON CONFLICT (producto_id, ubicacion)
  DO UPDATE SET cantidad = stock_ubicaciones.cantidad + p_cantidad;
END;
$$;


ALTER FUNCTION "public"."ajustar_stock"("p_producto_id" "uuid", "p_ubicacion" "public"."ubicacion_stock", "p_cantidad" numeric, "p_motivo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."alerta_precios_pendientes"() RETURNS integer
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  SELECT count(*)::int
  FROM productos p
  LEFT JOIN productos_etiqueta e ON e.producto_id = p.id
  WHERE p.estado = 'activo' AND p.precio_venta IS NOT NULL
    AND p.precio_venta IS DISTINCT FROM e.precio_etiquetado;
$$;


ALTER FUNCTION "public"."alerta_precios_pendientes"() OWNER TO "postgres";


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

    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
    VALUES (v_item.producto_id, 'local', 'ajuste',
            CASE WHEN v_item.tipo = 'devuelto' THEN -v_item.cantidad ELSE v_item.cantidad END,
            'Anulación de devolución #' || v_dev.numero || ': ' || p_motivo, p_devolucion_id, auth.uid());
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


ALTER FUNCTION "public"."anular_devolucion"("p_devolucion_id" "uuid", "p_motivo" "text") OWNER TO "postgres";


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
    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
    VALUES (v_mov.producto_id, v_mov.ubicacion, 'ajuste', -1 * v_mov.neto,
            'Anulación de factura de compra: ' || p_motivo, p_factura_id, auth.uid());

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


ALTER FUNCTION "public"."anular_factura_compra"("p_factura_id" "uuid", "p_motivo" "text") OWNER TO "postgres";


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
    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
    VALUES (v_item.producto_id, 'local', 'ajuste', v_item.cantidad,
            'Reposición por anulación de venta: ' || p_motivo, p_venta_id, auth.uid());

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


ALTER FUNCTION "public"."anular_venta"("p_venta_id" "uuid", "p_motivo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."aperturas_con_diferencia_pendientes"() RETURNS TABLE("id" "uuid", "monto_esperado" numeric, "monto_real" numeric, "diferencia" numeric, "usuario_id" "uuid", "usuario_nombre" "text", "abierta_at" timestamp with time zone)
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  SELECT a.id, a.monto_esperado, a.monto_real, a.diferencia, a.usuario_id,
         pp.nombre::text AS usuario_nombre, a.abierta_at
  FROM aperturas_caja a
  LEFT JOIN perfiles_publico pp ON pp.id = a.usuario_id
  WHERE a.diferencia <> 0
    AND a.revisada_at IS NULL
  ORDER BY a.abierta_at DESC;
$$;


ALTER FUNCTION "public"."aperturas_con_diferencia_pendientes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."aplicar_cobros_a_cuenta"("p_cliente_id" "uuid", "p_venta_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_pago_ids" "uuid"[] DEFAULT NULL::"uuid"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_venta_ids UUID[];
  v_pago_ids UUID[];
  v_mal RECORD;
  v_doc_ids UUID[] := '{}';
  v_doc_saldos NUMERIC[] := '{}';
  v_pag_ids UUID[] := '{}';
  v_pag_disp NUMERIC[] := '{}';
  i INT := 1;
  j INT := 1;
  v_aplicar NUMERIC;
  v_total NUMERIC := 0;
  v_ids UUID[] := '{}';
  v_id UUID;
BEGIN
  -- Mismo permiso que cobrar: cualquier perfil activo. No mueve plata.
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  SELECT array_agg(DISTINCT x) INTO v_venta_ids FROM unnest(p_venta_ids) AS x WHERE x IS NOT NULL;
  SELECT array_agg(DISTINCT x) INTO v_pago_ids FROM unnest(p_pago_ids) AS x WHERE x IS NOT NULL;

  PERFORM 1 FROM clientes WHERE id = p_cliente_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Cliente no encontrado'; END IF;

  IF v_venta_ids IS NOT NULL THEN
    IF (SELECT count(*) FROM ventas WHERE id = ANY(v_venta_ids)) <> cardinality(v_venta_ids) THEN
      RAISE EXCEPTION 'Alguna de las ventas elegidas no existe';
    END IF;
    SELECT numero INTO v_mal FROM ventas WHERE id = ANY(v_venta_ids) AND cliente_id IS DISTINCT FROM p_cliente_id LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'La venta N° % no es de este cliente', v_mal.numero; END IF;
    SELECT numero INTO v_mal FROM ventas WHERE id = ANY(v_venta_ids)
      AND (forma_pago <> 'cuenta_corriente' OR estado = 'anulada' OR estado_interno IS NOT NULL) LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'A la venta N° % no se le aplican cobros', v_mal.numero; END IF;
  END IF;
  IF v_pago_ids IS NOT NULL THEN
    IF (SELECT count(*) FROM pagos_cliente WHERE id = ANY(v_pago_ids)) <> cardinality(v_pago_ids) THEN
      RAISE EXCEPTION 'Alguno de los cobros elegidos no existe';
    END IF;
    SELECT * INTO v_mal FROM pagos_cliente_a_cuenta WHERE id = ANY(v_pago_ids) AND cliente_id <> p_cliente_id LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'El cobro del % no es de este cliente', to_char(v_mal.fecha, 'DD/MM/YYYY'); END IF;
    SELECT * INTO v_mal FROM pagos_cliente_a_cuenta WHERE id = ANY(v_pago_ids) AND NOT vigente LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'El cobro del % no está vigente (fue revertido o es una reversión)', to_char(v_mal.fecha, 'DD/MM/YYYY'); END IF;
  END IF;

  SELECT COALESCE(array_agg(s.id ORDER BY s.created_at, s.id), '{}'),
         COALESCE(array_agg(s.saldo_pendiente ORDER BY s.created_at, s.id), '{}')
  INTO v_doc_ids, v_doc_saldos
  FROM ventas_cuenta_corriente_saldo s
  WHERE s.cliente_id = p_cliente_id AND s.estado <> 'anulada' AND s.estado_interno IS NULL
    AND s.saldo_pendiente > 0 AND (v_venta_ids IS NULL OR s.id = ANY(v_venta_ids));
  IF cardinality(v_doc_ids) = 0 THEN
    RAISE EXCEPTION 'No hay saldo pendiente en las ventas al que aplicar el cobro a cuenta';
  END IF;

  SELECT COALESCE(array_agg(p.id ORDER BY p.fecha, p.created_at, p.id), '{}'),
         COALESCE(array_agg(p.a_cuenta ORDER BY p.fecha, p.created_at, p.id), '{}')
  INTO v_pag_ids, v_pag_disp
  FROM pagos_cliente_a_cuenta p
  WHERE p.cliente_id = p_cliente_id AND p.a_cuenta > 0 AND (v_pago_ids IS NULL OR p.id = ANY(v_pago_ids));
  IF cardinality(v_pag_ids) = 0 THEN
    RAISE EXCEPTION 'Este cliente no tiene cobros a cuenta para aplicar';
  END IF;

  WHILE i <= cardinality(v_doc_ids) AND j <= cardinality(v_pag_ids) LOOP
    v_aplicar := LEAST(v_doc_saldos[i], v_pag_disp[j]);
    INSERT INTO pagos_cliente_aplicaciones (pago_cliente_id, venta_id, monto, operacion_id, usuario_id)
    VALUES (v_pag_ids[j], v_doc_ids[i], v_aplicar, v_pag_ids[j], auth.uid())
    RETURNING id INTO v_id;
    v_ids := array_append(v_ids, v_id);
    v_total := v_total + v_aplicar;
    v_doc_saldos[i] := v_doc_saldos[i] - v_aplicar;
    v_pag_disp[j] := v_pag_disp[j] - v_aplicar;
    IF v_doc_saldos[i] <= 0 THEN i := i + 1; END IF;
    IF v_pag_disp[j] <= 0 THEN j := j + 1; END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'aplicado', v_total,
    'a_cuenta_restante', (SELECT COALESCE(SUM(a_cuenta), 0) FROM pagos_cliente_a_cuenta WHERE cliente_id = p_cliente_id),
    'aplicaciones', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', a.id, 'pago_cliente_id', a.pago_cliente_id, 'venta_id', a.venta_id, 'monto', a.monto)
                       ORDER BY array_position(v_ids, a.id))
      FROM pagos_cliente_aplicaciones a WHERE a.id = ANY(v_ids)
    ), '[]'::jsonb)
  );
END;
$$;


ALTER FUNCTION "public"."aplicar_cobros_a_cuenta"("p_cliente_id" "uuid", "p_venta_ids" "uuid"[], "p_pago_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."aplicar_costo_vinculo_item"("p_item_id" "uuid", "p_producto_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
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
$$;


ALTER FUNCTION "public"."aplicar_costo_vinculo_item"("p_item_id" "uuid", "p_producto_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."aplicar_costo_vinculo_item"("p_item_id" "uuid", "p_producto_id" "uuid") IS 'Interna: aplica plan_costo_vinculo_item al producto (mismo UPDATE que cargar_factura_compra). docs/56.';



CREATE OR REPLACE FUNCTION "public"."aplicar_pagos_a_cuenta"("p_proveedor_id" "uuid", "p_factura_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_pago_ids" "uuid"[] DEFAULT NULL::"uuid"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_factura_ids UUID[];
  v_pago_ids UUID[];
  v_mal facturas_compra%ROWTYPE;
  v_pago_mal RECORD;
  v_doc_ids UUID[] := '{}';
  v_doc_saldos NUMERIC[] := '{}';
  v_pag_ids UUID[] := '{}';
  v_pag_disp NUMERIC[] := '{}';
  v_n INT;
  v_m INT;
  i INT := 1;
  j INT := 1;
  v_aplicar NUMERIC;
  v_total NUMERIC := 0;
  v_ids UUID[] := '{}';
  v_id UUID;
BEGIN
  -- Mismo permiso que registrar_pago_proveedor_v2: cualquier perfil activo. No mueve plata.
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  SELECT array_agg(DISTINCT x) INTO v_factura_ids FROM unnest(p_factura_ids) AS x WHERE x IS NOT NULL;
  SELECT array_agg(DISTINCT x) INTO v_pago_ids FROM unnest(p_pago_ids) AS x WHERE x IS NOT NULL;

  -- Mismo lock que v2: serializa pagos, aplicaciones y quitas del mismo proveedor.
  PERFORM 1 FROM proveedores WHERE id = p_proveedor_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Proveedor no encontrado';
  END IF;

  -- ── Comprobantes elegidos: mismas reglas que v2 ──
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
      RAISE EXCEPTION 'El comprobante % está anulado, no se le aplican pagos', COALESCE(v_mal.numero_comprobante, 'sin número');
    END IF;
    SELECT * INTO v_mal FROM facturas_compra WHERE id = ANY(v_factura_ids) AND tipo_comprobante = 'nota_credito' LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El comprobante % es una nota de crédito: no se le aplican pagos', COALESCE(v_mal.numero_comprobante, 'sin número');
    END IF;
  END IF;

  -- ── Pagos elegidos: del proveedor y vigentes ──
  IF v_pago_ids IS NOT NULL THEN
    IF (SELECT count(*) FROM pagos_proveedor WHERE id = ANY(v_pago_ids)) <> cardinality(v_pago_ids) THEN
      RAISE EXCEPTION 'Alguno de los pagos elegidos no existe';
    END IF;
    SELECT * INTO v_pago_mal FROM pagos_proveedor_a_cuenta WHERE id = ANY(v_pago_ids) AND proveedor_id <> p_proveedor_id LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El pago del % no es de este proveedor', to_char(v_pago_mal.fecha, 'DD/MM/YYYY');
    END IF;
    SELECT * INTO v_pago_mal FROM pagos_proveedor_a_cuenta WHERE id = ANY(v_pago_ids) AND NOT vigente LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El pago del % no está vigente (fue revertido o es una reversión)', to_char(v_pago_mal.fecha, 'DD/MM/YYYY');
    END IF;
  END IF;

  -- ── Comprobantes a cancelar, más viejos primero (mismo orden y saldo que v2) ──
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

  IF v_n = 0 THEN
    RAISE EXCEPTION 'No hay saldo pendiente en los comprobantes al que aplicar el pago a cuenta';
  END IF;

  -- ── Pagos con saldo a cuenta, más viejos primero ──
  SELECT COALESCE(array_agg(p.id ORDER BY p.fecha, p.created_at, p.id), '{}'),
         COALESCE(array_agg(p.a_cuenta ORDER BY p.fecha, p.created_at, p.id), '{}')
  INTO v_pag_ids, v_pag_disp
  FROM pagos_proveedor_a_cuenta p
  WHERE p.proveedor_id = p_proveedor_id
    AND p.a_cuenta > 0
    AND (v_pago_ids IS NULL OR p.id = ANY(v_pago_ids));
  v_m := cardinality(v_pag_ids);

  IF v_m = 0 THEN
    RAISE EXCEPTION 'Este proveedor no tiene pagos a cuenta para aplicar';
  END IF;

  -- ── Reparto: pago más viejo contra comprobante más viejo ──
  WHILE i <= v_n AND j <= v_m LOOP
    v_aplicar := LEAST(v_doc_saldos[i], v_pag_disp[j]);
    INSERT INTO pagos_proveedor_aplicaciones
      (factura_compra_id, monto, pago_proveedor_id, nota_credito_id, operacion_id, usuario_id)
    VALUES (v_doc_ids[i], v_aplicar, v_pag_ids[j], NULL, v_pag_ids[j], auth.uid())
    RETURNING id INTO v_id;
    v_ids := array_append(v_ids, v_id);
    v_total := v_total + v_aplicar;
    v_doc_saldos[i] := v_doc_saldos[i] - v_aplicar;
    v_pag_disp[j] := v_pag_disp[j] - v_aplicar;
    IF v_doc_saldos[i] <= 0 THEN i := i + 1; END IF;
    IF v_pag_disp[j] <= 0 THEN j := j + 1; END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'aplicado', v_total,
    'a_cuenta_restante', (SELECT COALESCE(SUM(a_cuenta), 0) FROM pagos_proveedor_a_cuenta WHERE proveedor_id = p_proveedor_id),
    'aplicaciones', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', a.id,
               'pago_proveedor_id', a.pago_proveedor_id,
               'factura_compra_id', a.factura_compra_id,
               'monto', a.monto
             -- En el orden en que se aplicaron: created_at es el mismo para toda la transacción.
             ) ORDER BY array_position(v_ids, a.id))
      FROM pagos_proveedor_aplicaciones a
      WHERE a.id = ANY(v_ids)
    ), '[]'::jsonb)
  );
END;
$$;


ALTER FUNCTION "public"."aplicar_pagos_a_cuenta"("p_proveedor_id" "uuid", "p_factura_ids" "uuid"[], "p_pago_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."app_cliente"() RETURNS "text"
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  SELECT NULLIF(current_setting('request.headers', true), '')::json ->> 'x-virikyna-app'
$$;


ALTER FUNCTION "public"."app_cliente"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."app_cliente"() IS 'Header x-virikyna-app de la llamada (local | gestion | inventario), o NULL fuera de las apps. Chequeo blando de borradores, no es seguridad. docs/54.';



CREATE OR REPLACE FUNCTION "public"."archivar_nota"("p_nota_id" "uuid", "p_archivar" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_nota notas_internas%ROWTYPE;
BEGIN
  IF p_archivar IS NULL THEN RAISE EXCEPTION 'Falta indicar si se archiva o se desarchiva'; END IF;
  SELECT * INTO v_nota FROM notas_internas WHERE id = p_nota_id FOR UPDATE;
  IF NOT FOUND OR NOT nota_visible_para_mi(v_nota.origen) THEN RAISE EXCEPTION 'Nota no encontrada'; END IF;
  IF v_nota.parent_id IS NOT NULL THEN
    RAISE EXCEPTION 'Una respuesta no se archiva sola: se archiva la nota principal con todo su hilo';
  END IF;
  -- archivada_at/archivada_por y el resto del hilo: triggers de notas_internas.
  UPDATE notas_internas SET archivada = p_archivar WHERE id = p_nota_id AND archivada IS DISTINCT FROM p_archivar;
END;
$$;


ALTER FUNCTION "public"."archivar_nota"("p_nota_id" "uuid", "p_archivar" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."borradores_mantener"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."borradores_mantener"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."borradores_mantener"() IS 'Trigger (borradores): autor, fechas y version los pone la base; id, tipo, sistema, autor y alta no cambian. docs/54.';



CREATE OR REPLACE FUNCTION "public"."carga_inicial_buscar_codigo"("p_codigo" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_codigo TEXT := regexp_replace(COALESCE(p_codigo, ''), '\s+', '', 'g');
  v_producto_id UUID;
  v_producto JSONB;
  v_mio JSONB;
  v_otros JSONB;
BEGIN
  PERFORM carga_inicial_verificar_acceso();
  IF v_codigo = '' THEN
    RAISE EXCEPTION 'Ingresá un código';
  END IF;

  v_producto_id := carga_inicial_producto_por_codigo(v_codigo);

  IF v_producto_id IS NOT NULL THEN
    SELECT jsonb_build_object(
             'id', p.id, 'nombre', p.nombre, 'marca', p.marca, 'descripcion', p.descripcion,
             'codigo_barras', p.codigo_barras, 'estado', p.estado,
             'precio_venta', p.precio_venta, 'precio_manual', p.precio_manual,
             'tiene_costo', p.costo IS NOT NULL,
             'stock_local', COALESCE((SELECT s.cantidad FROM stock_ubicaciones s
                                      WHERE s.producto_id = p.id AND s.ubicacion = 'local'), 0))
    INTO v_producto
    FROM productos p WHERE p.id = v_producto_id;
  END IF;

  SELECT to_jsonb(i) INTO v_mio
  FROM carga_inicial_items i
  WHERE i.usuario_id = auth.uid() AND i.codigo_barras = ANY(codigo_barras_variantes(v_codigo))
  LIMIT 1;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', i.id, 'usuario_id', i.usuario_id, 'usuario_nombre', u.nombre,
           'nombre', i.nombre, 'marca', i.marca, 'precio', i.precio, 'cantidad', i.cantidad,
           'accion', i.accion, 'updated_at', i.updated_at) ORDER BY i.updated_at), '[]'::JSONB)
  INTO v_otros
  FROM carga_inicial_items i
  JOIN perfiles u ON u.id = i.usuario_id
  WHERE i.usuario_id <> auth.uid() AND i.codigo_barras = ANY(codigo_barras_variantes(v_codigo));

  RETURN jsonb_build_object('codigo', v_codigo, 'producto', v_producto,
                            'mi_borrador', v_mio, 'borradores_otros', v_otros);
END;
$$;


ALTER FUNCTION "public"."carga_inicial_buscar_codigo"("p_codigo" "text") OWNER TO "postgres";


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
      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, usuario_id)
      VALUES (p_producto_id, 'local', 'inicial', v_delta,
              format('Carga inicial: corrección de cantidad (%s → %s)', v_actual, p_cantidad_local), auth.uid());

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


ALTER FUNCTION "public"."carga_inicial_editar_producto"("p_client_id" "uuid", "p_producto_id" "uuid", "p_nombre" "text", "p_marca" "text", "p_descripcion" "text", "p_precio" numeric, "p_cantidad_local" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."carga_inicial_eliminar_item"("p_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  PERFORM carga_inicial_verificar_acceso();
  DELETE FROM carga_inicial_items WHERE id = p_id AND usuario_id = auth.uid();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Borrador no encontrado';
  END IF;
END;
$$;


ALTER FUNCTION "public"."carga_inicial_eliminar_item"("p_id" "uuid") OWNER TO "postgres";


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
    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
    VALUES (v_producto_id, 'local', 'inicial', v_item.cantidad, 'Carga inicial', v_item.id, auth.uid());

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


ALTER FUNCTION "public"."carga_inicial_finalizar"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."carga_inicial_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "usuario_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "codigo_barras" "text",
    "nombre" "text" NOT NULL,
    "marca" "text",
    "descripcion" "text",
    "precio" numeric(12,2) NOT NULL,
    "cantidad" numeric(10,2) NOT NULL,
    "accion" "text" DEFAULT 'nuevo'::"text" NOT NULL,
    "producto_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "carga_inicial_items_accion_check" CHECK (("accion" = ANY (ARRAY['nuevo'::"text", 'sumar'::"text", 'reemplazar'::"text"]))),
    CONSTRAINT "carga_inicial_items_cantidad_check" CHECK (("cantidad" > (0)::numeric)),
    CONSTRAINT "carga_inicial_items_codigo_barras_check" CHECK ((("codigo_barras" IS NULL) OR ("btrim"("codigo_barras") <> ''::"text"))),
    CONSTRAINT "carga_inicial_items_nombre_check" CHECK (("btrim"("nombre") <> ''::"text")),
    CONSTRAINT "carga_inicial_items_precio_check" CHECK (("precio" > (0)::numeric))
);


ALTER TABLE "public"."carga_inicial_items" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."carga_inicial_guardar_item"("p_client_id" "uuid", "p_codigo_barras" "text", "p_nombre" "text", "p_marca" "text", "p_descripcion" "text", "p_precio" numeric, "p_cantidad" numeric, "p_accion" "text" DEFAULT 'nuevo'::"text", "p_id" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."carga_inicial_items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_codigo TEXT := NULLIF(regexp_replace(COALESCE(p_codigo_barras, ''), '\s+', '', 'g'), '');
  v_nombre TEXT := NULLIF(btrim(COALESCE(p_nombre, '')), '');
  v_marca TEXT := NULLIF(btrim(COALESCE(p_marca, '')), '');
  v_descripcion TEXT := NULLIF(btrim(COALESCE(p_descripcion, '')), '');
  v_producto_id UUID;
  v_costo NUMERIC;
  v_precio_venta NUMERIC;
  v_fila carga_inicial_items;
BEGIN
  PERFORM carga_inicial_verificar_acceso();

  -- docs/34c: operación ya aplicada → la fila como está ahora (o solo su id si ya no existe).
  IF NOT carga_inicial_reclamar_operacion(p_client_id, 'guardar_item') THEN
    SELECT i.* INTO v_fila
    FROM carga_inicial_operaciones o JOIN carga_inicial_items i ON i.id = o.item_id
    WHERE o.client_id = p_client_id;
    IF v_fila.id IS NULL THEN
      v_fila.id := (SELECT item_id FROM carga_inicial_operaciones WHERE client_id = p_client_id);
    END IF;
    RETURN v_fila;
  END IF;

  IF p_accion IS NULL OR p_accion NOT IN ('nuevo', 'sumar', 'reemplazar') THEN
    RAISE EXCEPTION 'Acción inválida: tiene que ser nuevo, sumar o reemplazar';
  END IF;
  IF v_nombre IS NULL THEN
    RAISE EXCEPTION 'El nombre es obligatorio';
  END IF;
  IF p_precio IS NULL OR p_precio <= 0 THEN
    RAISE EXCEPTION 'El precio tiene que ser mayor a 0';
  END IF;
  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RAISE EXCEPTION 'La cantidad tiene que ser mayor a 0';
  END IF;

  IF v_codigo IS NOT NULL THEN
    v_producto_id := carga_inicial_producto_por_codigo(v_codigo);
  END IF;

  IF p_accion = 'nuevo' AND v_producto_id IS NOT NULL THEN
    RAISE EXCEPTION 'Ya existe un producto con el código %: elegí sumar stock o reemplazar sus datos', v_codigo;
  END IF;
  IF p_accion = 'sumar' AND v_producto_id IS NULL THEN
    RAISE EXCEPTION 'No hay ningún producto con ese código para sumar';
  END IF;
  IF p_accion = 'reemplazar' AND v_codigo IS NULL THEN
    RAISE EXCEPTION 'Para reemplazar datos hace falta el código';
  END IF;
  IF p_accion = 'reemplazar' AND v_producto_id IS NOT NULL THEN
    SELECT costo, precio_venta INTO v_costo, v_precio_venta FROM productos WHERE id = v_producto_id;
    IF v_costo IS NOT NULL AND p_precio <> v_precio_venta THEN
      RAISE EXCEPTION 'Precio calculado por costo: este producto tiene costo cargado y su precio sale de la fórmula. Dejá el precio actual (%) o usá sumar.', v_precio_venta;
    END IF;
  END IF;

  IF p_id IS NOT NULL THEN
    -- Edición: FIJA los valores (no suma).
    BEGIN
      UPDATE carga_inicial_items
      SET codigo_barras = v_codigo, nombre = v_nombre, marca = v_marca, descripcion = v_descripcion,
          precio = p_precio, cantidad = p_cantidad, accion = p_accion, producto_id = v_producto_id,
          updated_at = now()
      WHERE id = p_id AND usuario_id = auth.uid()
      RETURNING * INTO v_fila;
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'Ya tenés otro borrador con el código %', v_codigo;
    END;
    IF v_fila.id IS NULL THEN
      RAISE EXCEPTION 'Borrador no encontrado';
    END IF;
  ELSIF v_codigo IS NOT NULL THEN
    -- Alta: si el código ya está en mis borradores, suma la cantidad.
    INSERT INTO carga_inicial_items (usuario_id, codigo_barras, nombre, marca, descripcion, precio, cantidad, accion, producto_id)
    VALUES (auth.uid(), v_codigo, v_nombre, v_marca, v_descripcion, p_precio, p_cantidad, p_accion, v_producto_id)
    ON CONFLICT (usuario_id, codigo_barras) WHERE codigo_barras IS NOT NULL
    DO UPDATE SET cantidad = carga_inicial_items.cantidad + EXCLUDED.cantidad,
                  nombre = EXCLUDED.nombre, marca = EXCLUDED.marca, descripcion = EXCLUDED.descripcion,
                  precio = EXCLUDED.precio, accion = EXCLUDED.accion, producto_id = EXCLUDED.producto_id,
                  updated_at = now()
    RETURNING * INTO v_fila;
  ELSE
    INSERT INTO carga_inicial_items (usuario_id, codigo_barras, nombre, marca, descripcion, precio, cantidad, accion, producto_id)
    VALUES (auth.uid(), NULL, v_nombre, v_marca, v_descripcion, p_precio, p_cantidad, p_accion, NULL)
    RETURNING * INTO v_fila;
  END IF;

  UPDATE carga_inicial_operaciones SET item_id = v_fila.id WHERE client_id = p_client_id;  -- docs/34c

  RETURN v_fila;
END;
$$;


ALTER FUNCTION "public"."carga_inicial_guardar_item"("p_client_id" "uuid", "p_codigo_barras" "text", "p_nombre" "text", "p_marca" "text", "p_descripcion" "text", "p_precio" numeric, "p_cantidad" numeric, "p_accion" "text", "p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."carga_inicial_producto_por_codigo"("p_codigo" "text") RETURNS "uuid"
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  SELECT p.id FROM productos p
  WHERE p.codigo_barras = ANY(codigo_barras_variantes(p_codigo)) OR p.codigo_interno = p_codigo
  ORDER BY (p.codigo_barras = p_codigo) DESC NULLS LAST, p.created_at
  LIMIT 1;
$$;


ALTER FUNCTION "public"."carga_inicial_producto_por_codigo"("p_codigo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."carga_inicial_reclamar_operacion"("p_client_id" "uuid", "p_operacion" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_op carga_inicial_operaciones%ROWTYPE;
BEGIN
  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'Falta el identificador de la operación (p_client_id)';
  END IF;

  INSERT INTO carga_inicial_operaciones (client_id, usuario_id, operacion)
  VALUES (p_client_id, auth.uid(), p_operacion)
  ON CONFLICT (client_id) DO NOTHING;
  IF FOUND THEN
    RETURN true;
  END IF;

  SELECT * INTO v_op FROM carga_inicial_operaciones WHERE client_id = p_client_id;
  IF v_op.usuario_id IS DISTINCT FROM auth.uid() OR v_op.operacion <> p_operacion THEN
    RAISE EXCEPTION 'Identificador de operación inválido';
  END IF;
  RETURN false;
END;
$$;


ALTER FUNCTION "public"."carga_inicial_reclamar_operacion"("p_client_id" "uuid", "p_operacion" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."carga_inicial_resumen"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_resultado JSONB;
BEGIN
  PERFORM carga_inicial_verificar_acceso();

  -- Movimientos 'inicial' por usuario y producto, valuados al precio de venta actual.
  WITH mov AS (
    SELECT m.usuario_id, m.producto_id, sum(m.cantidad) AS unidades
    FROM movimientos_stock m WHERE m.tipo = 'inicial'
    GROUP BY m.usuario_id, m.producto_id
  ),
  aplicado AS (
    SELECT mov.usuario_id, count(DISTINCT mov.producto_id) AS productos,
           COALESCE(sum(mov.unidades), 0) AS unidades,
           COALESCE(sum(mov.unidades * p.precio_venta), 0) AS valor
    FROM mov JOIN productos p ON p.id = mov.producto_id
    GROUP BY mov.usuario_id
  ),
  pendiente AS (
    SELECT usuario_id, count(*) AS borradores, COALESCE(sum(cantidad), 0) AS unidades
    FROM carga_inicial_items GROUP BY usuario_id
  ),
  por_usuario AS (
    SELECT COALESCE(a.usuario_id, p.usuario_id) AS usuario_id,
           COALESCE(a.productos, 0) AS productos, COALESCE(a.unidades, 0) AS unidades,
           COALESCE(a.valor, 0) AS valor,
           COALESCE(p.borradores, 0) AS borradores, COALESCE(p.unidades, 0) AS unidades_borradores
    FROM aplicado a FULL JOIN pendiente p ON p.usuario_id = a.usuario_id
  )
  SELECT jsonb_build_object(
    'abierta', c.carga_inicial_abierta,
    'abierta_at', c.abierta_at,
    'abierta_por_nombre', (SELECT nombre FROM perfiles WHERE id = c.abierta_por),
    'cerrada_at', c.cerrada_at,
    'cerrada_por_nombre', (SELECT nombre FROM perfiles WHERE id = c.cerrada_por),
    'productos', (SELECT count(DISTINCT producto_id) FROM movimientos_stock WHERE tipo = 'inicial'),
    'unidades', (SELECT COALESCE(sum(cantidad), 0) FROM movimientos_stock WHERE tipo = 'inicial'),
    'valor', (SELECT COALESCE(sum(mov.unidades * p.precio_venta), 0) FROM mov JOIN productos p ON p.id = mov.producto_id),
    'borradores', (SELECT count(*) FROM carga_inicial_items),
    'unidades_borradores', (SELECT COALESCE(sum(cantidad), 0) FROM carga_inicial_items),
    'por_usuario', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'usuario_id', pu.usuario_id, 'nombre', u.nombre,
               'productos', pu.productos, 'unidades', pu.unidades, 'valor', pu.valor,
               'borradores', pu.borradores, 'unidades_borradores', pu.unidades_borradores)
             ORDER BY u.nombre)
      FROM por_usuario pu JOIN perfiles u ON u.id = pu.usuario_id), '[]'::JSONB)
  )
  INTO v_resultado
  FROM configuracion c;

  RETURN v_resultado;
END;
$$;


ALTER FUNCTION "public"."carga_inicial_resumen"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."carga_inicial_verificar_acceso"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_rol rol_usuario;
BEGIN
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid() AND activo = true;
  IF v_rol IS NULL THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF v_rol = 'admin' THEN
    RETURN;
  END IF;
  IF NOT COALESCE((SELECT carga_inicial_abierta FROM configuracion), false) THEN
    RAISE EXCEPTION 'La carga inicial está cerrada. Solo un administrador puede usarla.';
  END IF;
END;
$$;


ALTER FUNCTION "public"."carga_inicial_verificar_acceso"() OWNER TO "postgres";


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
$$;


ALTER FUNCTION "public"."cargar_factura_compra"("p_proveedor_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_forma_pago" "public"."forma_pago_compra", "p_items" "jsonb", "p_copiada_de_id" "uuid", "p_iva_alicuota" numeric, "p_tipo_compra" "text", "p_borrador_id" "uuid", "p_devuelve_mercaderia" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cargar_factura_compra_contado"("p_proveedor_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_items" "jsonb", "p_origen" "public"."origen_egreso", "p_copiada_de_id" "uuid" DEFAULT NULL::"uuid", "p_iva_alicuota" numeric DEFAULT 21, "p_tipo_compra" "text" DEFAULT 'articulos'::"text", "p_borrador_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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
    p_iva_alicuota => p_iva_alicuota, p_tipo_compra => p_tipo_compra, p_borrador_id => p_borrador_id);

  -- El monto es el total que calculó cargar_factura_compra, no uno que mande la pantalla.
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


ALTER FUNCTION "public"."cargar_factura_compra_contado"("p_proveedor_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_items" "jsonb", "p_origen" "public"."origen_egreso", "p_copiada_de_id" "uuid", "p_iva_alicuota" numeric, "p_tipo_compra" "text", "p_borrador_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."cargar_factura_compra_contado"("p_proveedor_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_items" "jsonb", "p_origen" "public"."origen_egreso", "p_copiada_de_id" "uuid", "p_iva_alicuota" numeric, "p_tipo_compra" "text", "p_borrador_id" "uuid") IS 'docs/57: carga una factura de compra de contado y registra su pago en efectivo (total del servidor) en la misma transacción. turno = caja de Local (exige caja abierta); general = Caja Gestión (admin).';



CREATE OR REPLACE FUNCTION "public"."cargar_saldos_iniciales"("p_saldos_cuentas" "jsonb", "p_saldos_proveedores" "jsonb", "p_saldos_clientes" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_item JSONB;
  v_saldo_actual NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede cargar los saldos iniciales';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_saldos_cuentas) LOOP
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, usuario_id)
    VALUES ((v_item->>'cuenta_id')::UUID, 'saldo_inicial', (v_item->>'monto')::NUMERIC, 'Carga inicial del sistema', auth.uid());
  END LOOP;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_saldos_proveedores) LOOP
    SELECT saldo_inicial INTO v_saldo_actual FROM proveedores WHERE id = (v_item->>'proveedor_id')::UUID;
    IF v_saldo_actual IS DISTINCT FROM 0 THEN
      RAISE EXCEPTION 'El proveedor % ya tiene un saldo inicial cargado (%) — la carga inicial no se repite, corregilo por separado si hace falta', (v_item->>'proveedor_id'), v_saldo_actual;
    END IF;
    UPDATE proveedores SET saldo_inicial = (v_item->>'monto')::NUMERIC WHERE id = (v_item->>'proveedor_id')::UUID;
  END LOOP;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_saldos_clientes) LOOP
    SELECT saldo_inicial INTO v_saldo_actual FROM clientes WHERE id = (v_item->>'cliente_id')::UUID;
    IF v_saldo_actual IS DISTINCT FROM 0 THEN
      RAISE EXCEPTION 'El cliente % ya tiene un saldo inicial cargado (%) — la carga inicial no se repite, corregilo por separado si hace falta', (v_item->>'cliente_id'), v_saldo_actual;
    END IF;
    UPDATE clientes SET saldo_inicial = (v_item->>'monto')::NUMERIC WHERE id = (v_item->>'cliente_id')::UUID;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."cargar_saldos_iniciales"("p_saldos_cuentas" "jsonb", "p_saldos_proveedores" "jsonb", "p_saldos_clientes" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cerrar_caja"("p_tipo" "public"."tipo_cierre", "p_efectivo_contado" numeric DEFAULT NULL::numeric) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    SET "TimeZone" TO 'America/Argentina/Buenos_Aires'
    AS $$
DECLARE
  v_cierre_id UUID;
  v_apertura aperturas_caja%ROWTYPE;
  v_monto_base NUMERIC;
  v_total_efectivo NUMERIC;
  v_total_transferencia NUMERIC;
  v_total_qr NUMERIC;
  v_total_tarjeta NUMERIC;
  v_total_cuenta_corriente NUMERIC;
  v_total_egresos NUMERIC;
  v_total_egresos_efectivo NUMERIC;
  v_total_retiros NUMERIC;
  v_dev_efectivo NUMERIC;
  v_dev_transferencia NUMERIC;
  v_dev_qr NUMERIC;
  v_dev_tarjeta NUMERIC;
  v_cant_devoluciones INT;
  v_cob_efectivo NUMERIC;       -- docs/68
  v_cob_transferencia NUMERIC;  -- docs/68
  v_cob_qr NUMERIC;             -- docs/68
  v_cob_tarjeta NUMERIC;        -- docs/68
  v_cant_cobros INT;            -- docs/68
  v_efectivo_esperado NUMERIC;
  v_diferencia NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  SELECT * INTO v_apertura FROM aperturas_caja WHERE cierre_z_id IS NULL ORDER BY abierta_at DESC LIMIT 1;
  v_monto_base := COALESCE(v_apertura.monto_real, 0);

  SELECT COALESCE(SUM(vp.monto) FILTER (WHERE vp.forma_pago = 'efectivo'), 0),
         COALESCE(SUM(vp.monto) FILTER (WHERE vp.forma_pago = 'transferencia'), 0),
         COALESCE(SUM(vp.monto) FILTER (WHERE vp.forma_pago = 'qr'), 0),
         COALESCE(SUM(vp.monto) FILTER (WHERE vp.forma_pago IN ('tarjeta_debito','tarjeta_credito')), 0)
  INTO v_total_efectivo, v_total_transferencia, v_total_qr, v_total_tarjeta
  FROM venta_pagos vp
  JOIN ventas v ON v.id = vp.venta_id
  WHERE v.created_at::date = current_date AND v.estado <> 'anulada';

  SELECT COALESCE(SUM(precio_cobrado), 0) INTO v_total_cuenta_corriente
  FROM ventas
  WHERE created_at::date = current_date AND estado <> 'anulada' AND forma_pago = 'cuenta_corriente';

  -- Devoluciones/cambios de hoy: neto con signo por medio (+ el comercio cobró / − devolvió plata)
  SELECT COALESCE(SUM(CASE WHEN d.diferencia_monto >= 0 THEN dp.monto ELSE -dp.monto END)
                    FILTER (WHERE dp.forma_pago = 'efectivo'), 0),
         COALESCE(SUM(CASE WHEN d.diferencia_monto >= 0 THEN dp.monto ELSE -dp.monto END)
                    FILTER (WHERE dp.forma_pago = 'transferencia'), 0),
         COALESCE(SUM(CASE WHEN d.diferencia_monto >= 0 THEN dp.monto ELSE -dp.monto END)
                    FILTER (WHERE dp.forma_pago = 'qr'), 0),
         COALESCE(SUM(CASE WHEN d.diferencia_monto >= 0 THEN dp.monto ELSE -dp.monto END)
                    FILTER (WHERE dp.forma_pago IN ('tarjeta_debito','tarjeta_credito')), 0)
  INTO v_dev_efectivo, v_dev_transferencia, v_dev_qr, v_dev_tarjeta
  FROM devolucion_pagos dp
  JOIN devoluciones d ON d.id = dp.devolucion_id
  WHERE d.fecha = current_date AND d.estado = 'activa';

  SELECT COUNT(*) INTO v_cant_devoluciones
  FROM devoluciones WHERE fecha = current_date AND estado = 'activa';

  -- docs/68 (D13): cobros de cuenta corriente hechos en la caja de Local hoy (las reversiones,
  -- con medios negativos, restan el día en que se hacen, igual que los egresos).
  SELECT COALESCE(SUM(m.monto) FILTER (WHERE m.forma_pago = 'efectivo'), 0),
         COALESCE(SUM(m.monto) FILTER (WHERE m.forma_pago = 'transferencia'), 0),
         COALESCE(SUM(m.monto) FILTER (WHERE m.forma_pago = 'qr'), 0),
         COALESCE(SUM(m.monto) FILTER (WHERE m.forma_pago IN ('tarjeta_debito','tarjeta_credito')), 0),
         COUNT(DISTINCT pc.id) FILTER (WHERE pc.revierte_pago_cliente_id IS NULL)
  INTO v_cob_efectivo, v_cob_transferencia, v_cob_qr, v_cob_tarjeta, v_cant_cobros
  FROM pagos_cliente pc
  JOIN pagos_cliente_medios m ON m.pago_cliente_id = pc.id
  WHERE pc.origen = 'turno' AND pc.created_at::date = current_date;

  -- docs/31: solo egresos de la caja de Local (origen 'turno'); los de Gestión ('general') no.
  SELECT COALESCE(SUM(monto), 0) INTO v_total_egresos
  FROM egresos WHERE created_at::date = current_date AND origen = 'turno';

  SELECT COALESCE(SUM(monto), 0) INTO v_total_egresos_efectivo
  FROM egresos WHERE created_at::date = current_date AND origen = 'turno' AND forma_pago = 'efectivo';

  SELECT COALESCE(SUM(monto), 0) INTO v_total_retiros
  FROM retiros_caja WHERE fecha = current_date;

  v_efectivo_esperado := v_monto_base + v_total_efectivo + v_dev_efectivo + v_cob_efectivo
                         - v_total_egresos_efectivo - v_total_retiros;
  v_diferencia := CASE WHEN p_efectivo_contado IS NOT NULL THEN p_efectivo_contado - v_efectivo_esperado ELSE NULL END;

  INSERT INTO cierres_caja (tipo, turno_fecha, total_efectivo, total_transferencia, total_qr, total_tarjeta,
         total_cuenta_corriente, total_egresos, total_retiros, efectivo_esperado, efectivo_contado, diferencia,
         estado_validacion, usuario_id, apertura_id,
         cantidad_devoluciones, total_devoluciones_efectivo, total_devoluciones_transferencia,
         total_devoluciones_qr, total_devoluciones_tarjeta,
         cantidad_cobros, total_cobros_efectivo, total_cobros_transferencia, total_cobros_qr, total_cobros_tarjeta)
  VALUES (p_tipo, current_date, v_total_efectivo, v_total_transferencia, v_total_qr, v_total_tarjeta,
         v_total_cuenta_corriente, v_total_egresos, v_total_retiros, v_efectivo_esperado, p_efectivo_contado, v_diferencia,
         CASE WHEN p_tipo = 'z' THEN 'pendiente_validacion'::estado_cierre_z ELSE NULL END, auth.uid(), v_apertura.id,
         v_cant_devoluciones, v_dev_efectivo, v_dev_transferencia, v_dev_qr, v_dev_tarjeta,
         v_cant_cobros, v_cob_efectivo, v_cob_transferencia, v_cob_qr, v_cob_tarjeta)
  RETURNING id INTO v_cierre_id;

  IF p_tipo = 'z' AND v_apertura.id IS NOT NULL THEN
    UPDATE aperturas_caja SET cierre_z_id = v_cierre_id WHERE id = v_apertura.id;
  END IF;

  RETURN v_cierre_id;
END;
$$;


ALTER FUNCTION "public"."cerrar_caja"("p_tipo" "public"."tipo_cierre", "p_efectivo_contado" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cerrar_carga_inicial"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_fila configuracion;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede cerrar la carga inicial';
  END IF;
  IF NOT (SELECT carga_inicial_abierta FROM configuracion) THEN
    RAISE EXCEPTION 'La carga inicial ya está cerrada';
  END IF;

  UPDATE configuracion
  SET carga_inicial_abierta = false, cerrada_at = now(), cerrada_por = auth.uid(), updated_at = now()
  WHERE fila_unica  -- docs/34d: safeupdate exige WHERE
  RETURNING * INTO v_fila;

  RETURN jsonb_build_object(
    'configuracion', to_jsonb(v_fila),
    'borradores_pendientes', (SELECT count(*) FROM carga_inicial_items),
    'usuarios_con_borradores', (SELECT count(DISTINCT usuario_id) FROM carga_inicial_items)
  );
END;
$$;


ALTER FUNCTION "public"."cerrar_carga_inicial"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."codigo_barras_variantes"("p_codigo" "text") RETURNS "text"[]
    LANGUAGE "sql" IMMUTABLE STRICT PARALLEL SAFE
    SET "search_path" TO 'public'
    AS $_$
  WITH c AS (SELECT regexp_replace(p_codigo, '\s+', '', 'g') AS v)
  SELECT CASE
    WHEN v = '' THEN ARRAY[]::TEXT[]
    WHEN v ~ '^\d{12}$' THEN ARRAY[v, '0' || v]
    WHEN v ~ '^0\d{12}$' THEN ARRAY[v, substr(v, 2)]
    ELSE ARRAY[v]
  END FROM c;
$_$;


ALTER FUNCTION "public"."codigo_barras_variantes"("p_codigo" "text") OWNER TO "postgres";


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

    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, referencia_id, usuario_id)
    VALUES ((v_item->>'producto_id')::UUID, 'local', 'venta', -1 * (v_item->>'cantidad')::NUMERIC, v_venta_id, auth.uid());

    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES ((v_item->>'producto_id')::UUID, 'local', -1 * (v_item->>'cantidad')::NUMERIC)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad - (v_item->>'cantidad')::NUMERIC;
  END LOOP;

  RETURN v_venta_id;
END;
$$;


ALTER FUNCTION "public"."confirmar_venta"("p_cliente_id" "uuid", "p_forma_pago" "public"."forma_pago_venta", "p_items" "jsonb", "p_descuento_porcentaje" numeric, "p_nota" "text", "p_recargo_porcentaje" numeric, "p_pagos" "jsonb", "p_precio_cobrado" numeric, "p_client_id" "text") OWNER TO "postgres";


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
      INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
      VALUES (v_row.producto_id, 'local', 'ajuste', v_row.cantidad,
              'Devolución de venta #' || v_venta.numero || ' (' || p_motivo::text || ')', v_devolucion_id, auth.uid());
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

    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
    VALUES (v_row.producto_id, 'local', 'ajuste', -1 * v_row.cantidad,
            'Cambio sobre venta #' || v_venta.numero, v_devolucion_id, auth.uid());
    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES (v_row.producto_id, 'local', -1 * v_row.cantidad)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad - v_row.cantidad;
  END LOOP;

  RETURN v_devolucion_id;
END;
$$;


ALTER FUNCTION "public"."crear_devolucion"("p_venta_id" "uuid", "p_motivo" "public"."motivo_devolucion", "p_motivo_detalle" "text", "p_observaciones" "text", "p_items_devueltos" "jsonb", "p_items_nuevos" "jsonb", "p_forma_pago" "public"."forma_pago_venta", "p_pagos" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."credito_devoluciones_venta"("p_venta_id" "uuid") RETURNS numeric
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  SELECT COALESCE(SUM(
           CASE WHEN di.tipo = 'devuelto' THEN ROUND(di.cantidad * COALESCE(pu.precio, di.precio_unitario), 2)
                ELSE -ROUND(di.cantidad * di.precio_unitario, 2) END), 0)
  FROM devoluciones d
  JOIN devolucion_items di ON di.devolucion_id = d.id
  JOIN ventas v ON v.id = d.venta_id
  LEFT JOIN LATERAL (
    SELECT ROUND((SUM(vi.importe) / NULLIF(SUM(vi.cantidad), 0))
                 * (CASE WHEN v.subtotal > 0 THEN v.total / v.subtotal ELSE 1 END), 2) AS precio
    FROM venta_items vi
    WHERE vi.venta_id = d.venta_id AND vi.producto_id = di.producto_id
  ) pu ON di.tipo = 'devuelto'
  WHERE d.venta_id = p_venta_id AND d.estado = 'activa' AND d.a_cuenta_corriente;
$$;


ALTER FUNCTION "public"."credito_devoluciones_venta"("p_venta_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dashboard_consumo_interno"("p_desde" "date", "p_hasta" "date") RETURNS TABLE("fecha" "date", "cliente_id" "uuid", "cliente_nombre" "text", "producto_id" "uuid", "nombre" "text", "marca" "text", "estado_interno" "public"."estado_venta_interna", "unidades" numeric, "importe" numeric)
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  WITH vendidos AS (
    SELECT (v.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS dia,
           v.cliente_id, vi.producto_id, vi.producto_nombre AS nombre, vi.producto_marca AS marca,
           v.estado_interno, vi.cantidad,
           COALESCE(vi.importe * v.precio_cobrado / NULLIF(SUM(vi.importe) OVER (PARTITION BY v.id), 0), 0) AS importe
    FROM ventas v
    JOIN venta_items vi ON vi.venta_id = v.id
    WHERE v.estado <> 'anulada' AND v.estado_interno IS NOT NULL
      AND v.created_at >= (p_desde::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires')
      AND v.created_at <  ((p_hasta + 1)::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires')
  ),
  devueltos AS (
    SELECT d.fecha AS dia, v.cliente_id, di.producto_id, di.producto_nombre, di.producto_marca, v.estado_interno,
           CASE WHEN di.tipo = 'devuelto' THEN -di.cantidad ELSE di.cantidad END,
           CASE WHEN di.tipo = 'devuelto'
                THEN -ROUND(di.cantidad * COALESCE(pu.precio, di.precio_unitario), 2)
                ELSE ROUND(di.cantidad * di.precio_unitario, 2) END
    FROM devoluciones d
    JOIN devolucion_items di ON di.devolucion_id = d.id
    JOIN ventas v ON v.id = d.venta_id
    LEFT JOIN LATERAL (
      SELECT ROUND((SUM(vi.importe) / NULLIF(SUM(vi.cantidad), 0))
                   * (CASE WHEN v.subtotal > 0 THEN v.total / v.subtotal ELSE 1 END), 2) AS precio
      FROM venta_items vi WHERE vi.venta_id = d.venta_id AND vi.producto_id = di.producto_id
    ) pu ON di.tipo = 'devuelto'
    WHERE d.estado = 'activa' AND v.estado <> 'anulada' AND v.estado_interno IS NOT NULL
      AND d.fecha BETWEEN p_desde AND p_hasta
  ),
  movs AS (SELECT * FROM vendidos UNION ALL SELECT * FROM devueltos)
  SELECT m.dia, m.cliente_id, COALESCE(c.razon_social, c.nombre_fantasia), m.producto_id,
         MAX(m.nombre), MAX(m.marca), m.estado_interno,
         SUM(m.cantidad), round(SUM(m.importe), 2)
  FROM movs m
  JOIN clientes c ON c.id = m.cliente_id
  GROUP BY m.dia, m.cliente_id, COALESCE(c.razon_social, c.nombre_fantasia), m.producto_id, m.estado_interno
  ORDER BY m.dia, 3, 5;
$$;


ALTER FUNCTION "public"."dashboard_consumo_interno"("p_desde" "date", "p_hasta" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dashboard_ventas_por_dia"("p_desde" "date", "p_hasta" "date") RETURNS TABLE("fecha" "date", "total" numeric, "cantidad" integer)
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  WITH ventas_rango AS (
    SELECT (v.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS dia,
           v.precio_cobrado
    FROM ventas v
    WHERE v.estado <> 'anulada'
      AND v.estado_interno IS NULL  -- docs/68 (D8)
      AND v.created_at >= (p_desde::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires')
      AND v.created_at <  ((p_hasta + 1)::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires')
  )
  SELECT g.dia::date,
         COALESCE(SUM(vr.precio_cobrado), 0)::numeric,
         COUNT(vr.dia)::int
  FROM generate_series(p_desde::timestamp, p_hasta::timestamp, interval '1 day') AS g(dia)
  LEFT JOIN ventas_rango vr ON vr.dia = g.dia::date
  GROUP BY g.dia
  ORDER BY g.dia;
$$;


ALTER FUNCTION "public"."dashboard_ventas_por_dia"("p_desde" "date", "p_hasta" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dashboard_ventas_por_producto"("p_desde" "date", "p_hasta" "date", "p_ant_desde" "date" DEFAULT NULL::"date", "p_ant_hasta" "date" DEFAULT NULL::"date") RETURNS TABLE("producto_id" "uuid", "nombre" "text", "marca" "text", "unidades" numeric, "importe" numeric, "stock_actual" numeric, "stock_minimo" numeric, "unidades_periodo_anterior" numeric, "importe_periodo_anterior" numeric)
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  WITH lim AS (
    SELECT p_desde AS d1, p_hasta AS h1,
           COALESCE(p_ant_desde, p_desde - (p_hasta - p_desde + 1)) AS d0,
           COALESCE(p_ant_hasta, p_desde - 1) AS h0
  ),
  rango AS (SELECT LEAST(d0, d1) AS desde, GREATEST(h0, h1) AS hasta FROM lim),
  vendidos AS (
    SELECT vi.producto_id,
           (v.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS dia,
           vi.cantidad,
           -- Prorrateo: la venta se cobró precio_cobrado (con descuento/recargo); cada ítem se lleva
           -- su parte según su importe de lista.
           COALESCE(vi.importe * v.precio_cobrado / NULLIF(SUM(vi.importe) OVER (PARTITION BY v.id), 0), 0) AS importe
    FROM ventas v
    JOIN venta_items vi ON vi.venta_id = v.id
    CROSS JOIN rango r
    WHERE v.estado <> 'anulada'
      AND v.estado_interno IS NULL  -- docs/68 (D8)
      AND v.created_at >= (r.desde::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires')
      AND v.created_at <  ((r.hasta + 1)::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires')
  ),
  devueltos AS (
    SELECT di.producto_id,
           d.fecha AS dia,
           CASE WHEN di.tipo = 'devuelto' THEN -di.cantidad ELSE di.cantidad END AS cantidad,
           CASE WHEN di.tipo = 'devuelto' THEN -1 ELSE 1 END * di.cantidad * di.precio_unitario AS importe
    FROM devoluciones d
    JOIN devolucion_items di ON di.devolucion_id = d.id
    JOIN ventas vd ON vd.id = d.venta_id
    CROSS JOIN rango r
    WHERE d.estado = 'activa' AND d.fecha BETWEEN r.desde AND r.hasta
      AND vd.estado_interno IS NULL  -- docs/68 (D8)
  ),
  movs AS (SELECT * FROM vendidos UNION ALL SELECT * FROM devueltos),
  por_producto AS (
    SELECT m.producto_id,
           SUM(m.cantidad) FILTER (WHERE m.dia BETWEEN l.d1 AND l.h1) AS unidades,
           SUM(m.importe)  FILTER (WHERE m.dia BETWEEN l.d1 AND l.h1) AS importe,
           SUM(m.cantidad) FILTER (WHERE m.dia BETWEEN l.d0 AND l.h0) AS unidades_ant,
           SUM(m.importe)  FILTER (WHERE m.dia BETWEEN l.d0 AND l.h0) AS importe_ant,
           bool_or(m.dia BETWEEN l.d1 AND l.h1) AS en_periodo
    FROM movs m CROSS JOIN lim l
    GROUP BY m.producto_id
  )
  SELECT pp.producto_id, p.nombre, p.marca,
         COALESCE(pp.unidades, 0), round(COALESCE(pp.importe, 0), 2),
         COALESCE((SELECT SUM(s.cantidad) FROM stock_ubicaciones s WHERE s.producto_id = pp.producto_id), 0),
         p.stock_minimo,
         COALESCE(pp.unidades_ant, 0), round(COALESCE(pp.importe_ant, 0), 2)
  FROM por_producto pp
  JOIN productos p ON p.id = pp.producto_id
  WHERE pp.en_periodo
  ORDER BY 5 DESC, 4 DESC, p.nombre;
$$;


ALTER FUNCTION "public"."dashboard_ventas_por_producto"("p_desde" "date", "p_hasta" "date", "p_ant_desde" "date", "p_ant_hasta" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."desaplicar_cobro"("p_aplicacion_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_apl pagos_cliente_aplicaciones%ROWTYPE;
  v_cliente_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede quitar una aplicación de cobro';
  END IF;
  SELECT pc.cliente_id INTO v_cliente_id
  FROM pagos_cliente_aplicaciones a JOIN pagos_cliente pc ON pc.id = a.pago_cliente_id
  WHERE a.id = p_aplicacion_id;
  IF v_cliente_id IS NULL THEN RAISE EXCEPTION 'Aplicación no encontrada'; END IF;

  PERFORM 1 FROM clientes WHERE id = v_cliente_id FOR UPDATE;
  SELECT * INTO v_apl FROM pagos_cliente_aplicaciones WHERE id = p_aplicacion_id FOR UPDATE;
  IF v_apl.revertida_at IS NOT NULL THEN RAISE EXCEPTION 'Esta aplicación ya se había quitado'; END IF;

  UPDATE pagos_cliente_aplicaciones SET revertida_at = now(), revertida_por = auth.uid()
  WHERE id = p_aplicacion_id AND revertida_at IS NULL;

  RETURN jsonb_build_object('id', v_apl.id, 'venta_id', v_apl.venta_id, 'monto', v_apl.monto,
                            'pago_cliente_id', v_apl.pago_cliente_id);
END;
$$;


ALTER FUNCTION "public"."desaplicar_cobro"("p_aplicacion_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."desaplicar_pago"("p_aplicacion_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_apl pagos_proveedor_aplicaciones%ROWTYPE;
  v_proveedor_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede quitar una aplicación de pago';
  END IF;

  SELECT fc.proveedor_id INTO v_proveedor_id
  FROM pagos_proveedor_aplicaciones a JOIN facturas_compra fc ON fc.id = a.factura_compra_id
  WHERE a.id = p_aplicacion_id;
  IF v_proveedor_id IS NULL THEN
    RAISE EXCEPTION 'Aplicación no encontrada';
  END IF;

  -- Mismo lock que v2 y aplicar_pagos_a_cuenta.
  PERFORM 1 FROM proveedores WHERE id = v_proveedor_id FOR UPDATE;

  SELECT * INTO v_apl FROM pagos_proveedor_aplicaciones WHERE id = p_aplicacion_id FOR UPDATE;
  IF v_apl.revertida_at IS NOT NULL THEN
    RAISE EXCEPTION 'Esta aplicación ya se había quitado';
  END IF;

  UPDATE pagos_proveedor_aplicaciones
  SET revertida_at = now(), revertida_por = auth.uid()
  WHERE id = p_aplicacion_id AND revertida_at IS NULL;

  RETURN jsonb_build_object(
    'id', v_apl.id,
    'factura_compra_id', v_apl.factura_compra_id,
    'monto', v_apl.monto,
    'fuente', CASE WHEN v_apl.nota_credito_id IS NULL THEN 'pago' ELSE 'nota_credito' END,
    'pago_proveedor_id', v_apl.pago_proveedor_id,
    'nota_credito_id', v_apl.nota_credito_id
  );
END;
$$;


ALTER FUNCTION "public"."desaplicar_pago"("p_aplicacion_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."desbloquear_emision_factura_c"("p_venta_id" "uuid", "p_nota" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_res emisiones_factura_c_en_curso%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true AND rol = 'admin') THEN
    RAISE EXCEPTION 'Solo un administrador puede desbloquear la emisión';
  END IF;
  IF coalesce(trim(p_nota), '') = '' THEN
    RAISE EXCEPTION 'Falta la nota de qué se revisó';
  END IF;

  DELETE FROM emisiones_factura_c_en_curso
  WHERE venta_id = p_venta_id AND revisar_at IS NOT NULL
  RETURNING * INTO v_res;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Esta venta no está bloqueada para revisar';
  END IF;

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, usuario_id, nota)
  VALUES ('emisiones_factura_c_en_curso', p_venta_id, 'eliminacion', to_jsonb(v_res), auth.uid(),
          'Emisión de Factura C desbloqueada: ' || trim(p_nota));
END;
$$;


ALTER FUNCTION "public"."desbloquear_emision_factura_c"("p_venta_id" "uuid", "p_nota" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ean13_digito_verificador"("p_doce" "text") RETURNS integer
    LANGUAGE "sql" IMMUTABLE STRICT PARALLEL SAFE
    SET "search_path" TO 'public'
    AS $$
  SELECT (10 - (SUM(substr(p_doce, i, 1)::INT * CASE WHEN i % 2 = 0 THEN 3 ELSE 1 END) % 10)::INT) % 10
  FROM generate_series(1, 12) AS i;
$$;


ALTER FUNCTION "public"."ean13_digito_verificador"("p_doce" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."editar_factura_compra"("p_factura_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra" DEFAULT NULL::"public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra" DEFAULT NULL::"public"."letra_comprobante_compra", "p_punto_venta" "text" DEFAULT NULL::"text", "p_numero_comprobante" "text" DEFAULT NULL::"text", "p_fecha_comprobante" "date" DEFAULT NULL::"date", "p_fecha_fiscal" "date" DEFAULT NULL::"date", "p_forma_pago" "public"."forma_pago_compra" DEFAULT NULL::"public"."forma_pago_compra", "p_iva_alicuota" numeric DEFAULT NULL::numeric) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_tipo_actual tipo_comprobante_compra;
  v_alicuota_actual NUMERIC;    -- docs/45
  v_forma_pago_actual forma_pago_compra;  -- docs/57
  v_tipo_nuevo tipo_comprobante_compra;
  v_alicuota_nueva NUMERIC;
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

  SELECT tipo_comprobante, iva_alicuota, forma_pago INTO v_tipo_actual, v_alicuota_actual, v_forma_pago_actual
  FROM facturas_compra WHERE id = p_factura_id FOR UPDATE;

  -- docs/45: tipo y alícuota definen el total (y, de/a NC, si suma o resta deuda). Con pagos o NC
  -- aplicados vigentes no se tocan: cambiaría lo que ya se imputó. Mandar el mismo valor no cuenta
  -- como cambio (la UI manda todos los campos siempre).
  v_tipo_nuevo := COALESCE(p_tipo_comprobante, v_tipo_actual);
  v_alicuota_nueva := COALESCE(p_iva_alicuota, v_alicuota_actual);
  v_cambia_importes := v_tipo_nuevo IS DISTINCT FROM v_tipo_actual
                       OR v_alicuota_nueva IS DISTINCT FROM v_alicuota_actual;
  v_tiene_aplicaciones := EXISTS (
    SELECT 1 FROM pagos_proveedor_aplicaciones
    WHERE (factura_compra_id = p_factura_id OR nota_credito_id = p_factura_id)
      AND revertida_at IS NULL);

  IF v_cambia_importes AND v_tiene_aplicaciones THEN
    RAISE EXCEPTION 'Este comprobante ya tiene pagos o notas de crédito aplicados: no se puede cambiar el tipo ni el IVA. Revertí esos pagos primero';
  END IF;
  -- docs/57: la forma de pago es una etiqueta (cambiarla no crea ni borra pagos). Con pagos aplicados
  -- queda fija, para que una factura pagada de contado no pase a figurar en cuenta corriente.
  IF p_forma_pago IS NOT NULL AND p_forma_pago IS DISTINCT FROM v_forma_pago_actual AND v_tiene_aplicaciones THEN
    RAISE EXCEPTION 'Este comprobante ya tiene pagos aplicados: no se puede cambiar la forma de pago. Revertí esos pagos primero';
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
    iva_alicuota = v_alicuota_nueva,
    iva = CASE WHEN v_cambia_importes THEN ROUND(total_sin_iva * v_alicuota_nueva / 100, 2) ELSE iva END,
    total = CASE WHEN v_cambia_importes THEN total_sin_iva + ROUND(total_sin_iva * v_alicuota_nueva / 100, 2) ELSE total END
  WHERE id = p_factura_id;
END;
$$;


ALTER FUNCTION "public"."editar_factura_compra"("p_factura_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_forma_pago" "public"."forma_pago_compra", "p_iva_alicuota" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."editar_movimiento_cuenta"("p_movimiento_id" "uuid", "p_monto_nuevo" numeric, "p_descripcion_nueva" "text", "p_motivo" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE v_original movimientos_cuenta%ROWTYPE; v_nuevo_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede editar un movimiento de cuenta';
  END IF;
  IF p_motivo IS NULL OR trim(p_motivo) = '' THEN
    RAISE EXCEPTION 'El motivo es obligatorio para editar un movimiento';
  END IF;
  SELECT * INTO v_original FROM movimientos_cuenta WHERE id = p_movimiento_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Movimiento no encontrado'; END IF;
  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, revierte_movimiento_id, usuario_id)
  VALUES (v_original.cuenta_id, v_original.tipo, -1 * v_original.monto, 'Corrección: ' || p_motivo, p_movimiento_id, auth.uid());
  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, revierte_movimiento_id, usuario_id)
  VALUES (v_original.cuenta_id, v_original.tipo, p_monto_nuevo, COALESCE(p_descripcion_nueva, v_original.descripcion), p_movimiento_id, auth.uid())
  RETURNING id INTO v_nuevo_id;
  RETURN v_nuevo_id;
END;
$$;


ALTER FUNCTION "public"."editar_movimiento_cuenta"("p_movimiento_id" "uuid", "p_monto_nuevo" numeric, "p_descripcion_nueva" "text", "p_motivo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."editar_nota"("p_nota_id" "uuid", "p_mensaje" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_nota notas_internas%ROWTYPE;
  v_mensaje text := btrim(coalesce(p_mensaje, ''));
BEGIN
  IF v_mensaje = '' THEN RAISE EXCEPTION 'La nota no puede quedar vacía'; END IF;
  SELECT * INTO v_nota FROM notas_internas WHERE id = p_nota_id FOR UPDATE;
  IF NOT FOUND OR NOT nota_visible_para_mi(v_nota.origen) THEN RAISE EXCEPTION 'Nota no encontrada'; END IF;
  IF v_nota.autor_id <> auth.uid() THEN RAISE EXCEPTION 'Solo quien escribió la nota puede editarla'; END IF;
  -- editada_at lo marca trg_notas_internas_guardia solo si el texto cambió.
  UPDATE notas_internas SET mensaje = v_mensaje WHERE id = p_nota_id;
END;
$$;


ALTER FUNCTION "public"."editar_nota"("p_nota_id" "uuid", "p_mensaje" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."editar_usuario"("p_user_id" "uuid", "p_nombre" "text", "p_rol" "public"."rol_usuario") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede editar usuarios';
  END IF;
  IF p_nombre IS NULL OR trim(p_nombre) = '' THEN
    RAISE EXCEPTION 'El nombre es obligatorio';
  END IF;

  UPDATE perfiles SET nombre = trim(p_nombre), rol = p_rol WHERE id = p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Usuario no encontrado'; END IF;
END;
$$;


ALTER FUNCTION "public"."editar_usuario"("p_user_id" "uuid", "p_nombre" "text", "p_rol" "public"."rol_usuario") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."editar_venta_interna"("p_venta_id" "uuid", "p_items" "jsonb", "p_version" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_venta ventas%ROWTYPE;
  v_elem jsonb;
  v_item_id UUID;
  v_desc NUMERIC;
  v_ids UUID[] := '{}';
  v_subtotal NUMERIC;
  v_total NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede editar un comprobante interno';
  END IF;

  SELECT * INTO v_venta FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Venta no encontrada'; END IF;
  IF v_venta.estado_interno IS NULL THEN
    RAISE EXCEPTION 'Solo se editan comprobantes de clientes internos';
  END IF;
  IF v_venta.estado_interno = 'finalizado' THEN
    RAISE EXCEPTION 'El comprobante está finalizado: reabrilo para editarlo';
  END IF;
  IF v_venta.estado <> 'sin_facturar' THEN
    RAISE EXCEPTION 'El comprobante está %: no se puede editar', CASE WHEN v_venta.estado = 'anulada' THEN 'anulado' ELSE 'facturado' END;
  END IF;
  IF p_version IS NULL OR p_version <> v_venta.version THEN
    RAISE EXCEPTION 'El comprobante cambió mientras lo editabas: volvé a abrirlo';
  END IF;
  IF EXISTS (SELECT 1 FROM pagos_cliente_aplicaciones WHERE venta_id = p_venta_id AND revertida_at IS NULL) THEN
    RAISE EXCEPTION 'El comprobante tiene cobros aplicados: no se puede editar';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'Faltan los ítems a editar';
  END IF;
  FOR v_elem IN SELECT e FROM jsonb_array_elements(p_items) AS e LOOP
    BEGIN
      v_item_id := (v_elem->>'item_id')::uuid;
      v_desc := round((v_elem->>'descuento_porcentaje')::numeric, 2);
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'Ítem o descuento inválido';
    END;
    IF v_item_id IS NULL OR v_desc IS NULL THEN RAISE EXCEPTION 'Ítem o descuento inválido'; END IF;
    IF v_desc < 0 OR v_desc > 100 THEN
      RAISE EXCEPTION 'El descuento tiene que estar entre 0 y 100 %%';
    END IF;
    IF v_item_id = ANY(v_ids) THEN RAISE EXCEPTION 'Un ítem vino repetido'; END IF;
    IF NOT EXISTS (SELECT 1 FROM venta_items WHERE id = v_item_id AND venta_id = p_venta_id) THEN
      RAISE EXCEPTION 'Un ítem no es de este comprobante';
    END IF;
    v_ids := array_append(v_ids, v_item_id);

    UPDATE venta_items
    SET precio_unitario_original = COALESCE(precio_unitario_original, precio_unitario),
        descuento_porcentaje_original = COALESCE(descuento_porcentaje_original, descuento_porcentaje),
        descuento_porcentaje = v_desc,
        importe = ROUND(cantidad * precio_unitario * (1 - v_desc / 100.0), 2)
    WHERE id = v_item_id AND venta_id = p_venta_id;
  END LOOP;
  IF (SELECT count(*) FROM venta_items WHERE venta_id = p_venta_id) <> cardinality(v_ids) THEN
    RAISE EXCEPTION 'Mandá el descuento de todos los ítems del comprobante';
  END IF;

  SELECT COALESCE(SUM(importe), 0) INTO v_subtotal FROM venta_items WHERE venta_id = p_venta_id;
  v_total := ROUND(v_subtotal * (1 + COALESCE(v_venta.recargo_porcentaje, 0) / 100.0), 2);

  UPDATE ventas
  SET subtotal = v_subtotal, descuento_porcentaje = 0,
      precio_oficial = v_total, precio_cobrado = v_total, total = v_total,
      editada_at = now(), editada_por = auth.uid(), version = version + 1
  WHERE id = p_venta_id;

  RETURN jsonb_build_object('venta_id', p_venta_id, 'subtotal', v_subtotal, 'total', v_total,
                            'total_original', v_venta.total_original, 'version', v_venta.version + 1);
END;
$$;


ALTER FUNCTION "public"."editar_venta_interna"("p_venta_id" "uuid", "p_items" "jsonb", "p_version" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."eliminar_movimiento_cuenta"("p_movimiento_id" "uuid", "p_motivo" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE v_original movimientos_cuenta%ROWTYPE; v_nuevo_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede eliminar un movimiento de cuenta';
  END IF;
  IF p_motivo IS NULL OR trim(p_motivo) = '' THEN
    RAISE EXCEPTION 'El motivo es obligatorio para eliminar un movimiento';
  END IF;
  SELECT * INTO v_original FROM movimientos_cuenta WHERE id = p_movimiento_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Movimiento no encontrado'; END IF;
  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, revierte_movimiento_id, usuario_id)
  VALUES (v_original.cuenta_id, v_original.tipo, -1 * v_original.monto, 'Eliminación: ' || p_motivo, p_movimiento_id, auth.uid())
  RETURNING id INTO v_nuevo_id;
  RETURN v_nuevo_id;
END;
$$;


ALTER FUNCTION "public"."eliminar_movimiento_cuenta"("p_movimiento_id" "uuid", "p_motivo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."eliminar_producto"("p_producto_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_n int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede eliminar un producto';
  END IF;

  -- La fila bloqueada serializa contra una venta/compra simultánea (sus FK toman KEY SHARE sobre
  -- este producto): o la otra transacción termina antes y la vemos abajo, o espera y falla por FK.
  PERFORM 1 FROM productos WHERE id = p_producto_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El producto no existe (puede que ya se haya eliminado)';
  END IF;

  IF EXISTS (SELECT 1 FROM venta_items WHERE producto_id = p_producto_id)
     OR EXISTS (SELECT 1 FROM devolucion_items WHERE producto_id = p_producto_id)
     OR EXISTS (SELECT 1 FROM facturas_compra_items WHERE producto_id = p_producto_id)
     OR EXISTS (SELECT 1 FROM movimientos_stock WHERE producto_id = p_producto_id AND tipo <> 'inicial') THEN
    RAISE EXCEPTION 'Tiene movimientos registrados. No se puede eliminar.'
      USING ERRCODE = 'VKH01',
            HINT = 'Tiene ventas, devoluciones, compras o movimientos de stock: se puede inactivar.';
  END IF;

  DELETE FROM movimientos_stock WHERE producto_id = p_producto_id AND tipo = 'inicial';
  DELETE FROM stock_ubicaciones WHERE producto_id = p_producto_id;
  DELETE FROM productos WHERE id = p_producto_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'No se pudo eliminar el producto';
  END IF;
END;
$$;


ALTER FUNCTION "public"."eliminar_producto"("p_producto_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."eliminar_producto"("p_producto_id" "uuid") IS 'Elimina un producto sin historial (solo admin activo). Con ventas, devoluciones, compras o movimientos que no sean de carga inicial: error VKH01 y la UI ofrece inactivar. docs/48.';



CREATE OR REPLACE FUNCTION "public"."eliminar_proveedor"("p_proveedor_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede eliminar un proveedor';
  END IF;
  IF EXISTS (SELECT 1 FROM facturas_compra WHERE proveedor_id = p_proveedor_id)
     OR EXISTS (SELECT 1 FROM pagos_proveedor WHERE proveedor_id = p_proveedor_id) THEN
    RAISE EXCEPTION 'Este proveedor tiene historial — no se puede eliminar';
  END IF;

  DELETE FROM proveedores WHERE id = p_proveedor_id;
END;
$$;


ALTER FUNCTION "public"."eliminar_proveedor"("p_proveedor_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."emitir_factura_c"("p_venta_id" "uuid", "p_cae" "text", "p_numero_factura" "text", "p_punto_venta" "text", "p_ambiente" "text" DEFAULT 'homologacion'::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_factura_id UUID;
  v_existente facturas_c%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  PERFORM 1 FROM ventas WHERE id = p_venta_id FOR UPDATE;

  -- Desde docs/66 la Edge Function guarda el CAE apenas ARCA lo da; las apps instaladas lo vuelven a
  -- mandar después. Mismo CAE = mismo comprobante: se devuelve el que ya está, sin error.
  SELECT * INTO v_existente FROM facturas_c WHERE venta_id = p_venta_id;
  IF FOUND THEN
    IF v_existente.cae IS NOT DISTINCT FROM p_cae THEN
      RETURN v_existente.id;
    END IF;
    RAISE EXCEPTION 'Esta venta ya tiene una Factura C emitida';
  END IF;
  IF EXISTS (SELECT 1 FROM ventas WHERE id = p_venta_id AND estado = 'facturado') THEN
    RAISE EXCEPTION 'Esta venta ya tiene una Factura C emitida';
  END IF;

  INSERT INTO facturas_c (venta_id, cae, numero_factura, punto_venta, fecha_emision, usuario_id, ambiente)
  VALUES (p_venta_id, p_cae, p_numero_factura, p_punto_venta, now(), auth.uid(), p_ambiente)
  RETURNING id INTO v_factura_id;

  UPDATE ventas SET estado = 'facturado' WHERE id = p_venta_id;
  -- También una marcada para revisar: con la factura guardada ya no hay nada que revisar.
  DELETE FROM emisiones_factura_c_en_curso WHERE venta_id = p_venta_id;

  RETURN v_factura_id;
END;
$$;


ALTER FUNCTION "public"."emitir_factura_c"("p_venta_id" "uuid", "p_cae" "text", "p_numero_factura" "text", "p_punto_venta" "text", "p_ambiente" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."existe_comprobante_compra"("p_proveedor_id" "uuid", "p_tipo" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero" "text") RETURNS TABLE("id" "uuid", "fecha_comprobante" "date", "total" numeric, "anulada" boolean)
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."existe_comprobante_compra"("p_proveedor_id" "uuid", "p_tipo" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fijar_iva_productos"("p_sin_iva" "uuid"[], "p_con_iva" "uuid"[]) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sin uuid[] := COALESCE(p_sin_iva, '{}');
  v_con uuid[] := COALESCE(p_con_iva, '{}');
  v_count INTEGER;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede cambiar el IVA de los productos';
  END IF;
  IF cardinality(v_sin) = 0 AND cardinality(v_con) = 0 THEN
    RAISE EXCEPTION 'Elegí al menos un producto';
  END IF;
  IF v_sin && v_con THEN
    RAISE EXCEPTION 'Un producto no puede quedar con y sin IVA a la vez';
  END IF;

  -- Solo los que cambian (auditoría sin ediciones vacías; el WHERE también cumple con safeupdate).
  UPDATE productos
  SET iva_porcentaje = CASE WHEN id = ANY(v_sin) THEN 0 ELSE 21 END,
      updated_at = now()
  WHERE (id = ANY(v_sin) AND iva_porcentaje <> 0)
     OR (id = ANY(v_con) AND iva_porcentaje <> 21);

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;


ALTER FUNCTION "public"."fijar_iva_productos"("p_sin_iva" "uuid"[], "p_con_iva" "uuid"[]) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."fijar_iva_productos"("p_sin_iva" "uuid"[], "p_con_iva" "uuid"[]) IS 'IVA de productos como estado (docs/62): admin activo; pone 0 en p_sin_iva y 21 en p_con_iva (solo los que cambian) y devuelve cuántos cambió.';



CREATE OR REPLACE FUNCTION "public"."finalizar_venta_interna"("p_venta_id" "uuid", "p_version" integer DEFAULT NULL::integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_venta ventas%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede finalizar un comprobante interno';
  END IF;
  SELECT * INTO v_venta FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Venta no encontrada'; END IF;
  IF v_venta.estado_interno IS NULL THEN RAISE EXCEPTION 'Solo se finalizan comprobantes de clientes internos'; END IF;
  IF v_venta.estado_interno = 'finalizado' THEN RAISE EXCEPTION 'El comprobante ya está finalizado'; END IF;
  IF v_venta.estado <> 'sin_facturar' THEN RAISE EXCEPTION 'El comprobante está anulado: no se finaliza'; END IF;
  IF p_version IS NOT NULL AND p_version <> v_venta.version THEN
    RAISE EXCEPTION 'El comprobante cambió mientras lo revisabas: volvé a abrirlo';
  END IF;

  -- Sin pagos_cliente, movimientos_cuenta ni venta_pagos: se cierra sin cobro (D1).
  UPDATE ventas
  SET estado_interno = 'finalizado', finalizada_at = now(), finalizada_por = auth.uid(), version = version + 1
  WHERE id = p_venta_id;

  RETURN jsonb_build_object('venta_id', p_venta_id, 'total', v_venta.total, 'version', v_venta.version + 1);
END;
$$;


ALTER FUNCTION "public"."finalizar_venta_interna"("p_venta_id" "uuid", "p_version" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_auditoria_generica"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF current_setting('virikyna.suppress_audit', true) = 'true' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF TG_OP = 'INSERT' THEN
    INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_nuevos, usuario_id)
    VALUES (TG_TABLE_NAME, NEW.id, 'alta', to_jsonb(NEW), auth.uid());
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, valores_nuevos, usuario_id)
    VALUES (TG_TABLE_NAME, NEW.id, 'edicion', to_jsonb(OLD), to_jsonb(NEW), auth.uid());
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, usuario_id)
    VALUES (TG_TABLE_NAME, OLD.id, 'eliminacion', to_jsonb(OLD), auth.uid());
    RETURN OLD;
  END IF;
END;
$$;


ALTER FUNCTION "public"."fn_auditoria_generica"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_productos_precio_historial"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."fn_productos_precio_historial"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_proteger_alta_producto"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_m1 NUMERIC;
  v_m2 NUMERIC;
BEGIN
  IF EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RETURN NEW;
  END IF;
  -- Defaults: los del proveedor elegido; sin proveedor, 0/0 (como el formulario y la carga inicial).
  SELECT margen_1_default, margen_2_default INTO v_m1, v_m2 FROM proveedores WHERE id = NEW.proveedor_id;
  IF NEW.margen_1 IS DISTINCT FROM COALESCE(v_m1, 0)
     OR NEW.margen_2 IS DISTINCT FROM COALESCE(v_m2, 0)
     OR NEW.iva_porcentaje IS DISTINCT FROM 21 THEN
    RAISE EXCEPTION 'Solo un administrador puede dar de alta un producto con márgenes o IVA distintos de los del proveedor';
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."fn_proteger_alta_producto"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_proteger_eliminacion_cliente"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM ventas WHERE cliente_id = OLD.id)
     OR EXISTS (SELECT 1 FROM pagos_cliente WHERE cliente_id = OLD.id) THEN
    RAISE EXCEPTION 'Este cliente tiene historial — no se puede eliminar, solo inactivar';
  END IF;
  RETURN OLD;
END;
$$;


ALTER FUNCTION "public"."fn_proteger_eliminacion_cliente"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_proteger_eliminacion_proveedor"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM facturas_compra WHERE proveedor_id = OLD.id)
     OR EXISTS (SELECT 1 FROM pagos_proveedor WHERE proveedor_id = OLD.id) THEN
    RAISE EXCEPTION 'Este proveedor tiene historial — no se puede eliminar';
  END IF;
  RETURN OLD;
END;
$$;


ALTER FUNCTION "public"."fn_proteger_eliminacion_proveedor"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_proteger_margen_producto"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF (NEW.margen_1 IS DISTINCT FROM OLD.margen_1) OR (NEW.margen_2 IS DISTINCT FROM OLD.margen_2) THEN
    IF current_setting('virikyna.margen_auto_herencia', true) = 'true' THEN
      NULL;  -- docs/47: antes RETURN NEW; ahora sigue para revisar el IVA (que no se hereda)
    ELSIF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
      RAISE EXCEPTION 'Solo un administrador puede modificar el margen de un producto';
    END IF;
  END IF;
  -- docs/47: el IVA define el precio igual que los márgenes → misma regla, solo admin.
  IF NEW.iva_porcentaje IS DISTINCT FROM OLD.iva_porcentaje
     AND NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede modificar el IVA de un producto';
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."fn_proteger_margen_producto"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_proteger_margen_proveedor"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF (NEW.margen_1_default IS DISTINCT FROM OLD.margen_1_default) OR (NEW.margen_2_default IS DISTINCT FROM OLD.margen_2_default) THEN
    IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
      RAISE EXCEPTION 'Solo un administrador puede modificar el margen por defecto de un proveedor';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."fn_proteger_margen_proveedor"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_proteger_tipo_cliente"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF auth.uid() IS NULL OR EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.tipo <> 'externo' OR NEW.perfil_id IS NOT NULL THEN
      RAISE EXCEPTION 'Solo un administrador puede dar de alta un cliente interno';
    END IF;
  ELSIF NEW.tipo IS DISTINCT FROM OLD.tipo OR NEW.perfil_id IS DISTINCT FROM OLD.perfil_id THEN
    RAISE EXCEPTION 'Solo un administrador puede cambiar si un cliente es interno';
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."fn_proteger_tipo_cliente"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_sin_acentos"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_fila JSONB := to_jsonb(NEW);
  v_cambios JSONB := '{}'::JSONB;
  v_col TEXT;
  v_valor TEXT;
BEGIN
  FOREACH v_col IN ARRAY TG_ARGV LOOP
    v_valor := v_fila->>v_col;
    IF v_valor IS NOT NULL AND v_valor <> quitar_acentos(v_valor) THEN
      v_cambios := v_cambios || jsonb_build_object(v_col, quitar_acentos(v_valor));
    END IF;
  END LOOP;
  IF v_cambios <> '{}'::JSONB THEN
    NEW := jsonb_populate_record(NEW, v_cambios);
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."fn_sin_acentos"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generar_codigo_interno"() RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_base TEXT;
  v_codigo TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  LOOP
    v_base := '20' || lpad(nextval('codigo_interno_seq')::TEXT, 10, '0');
    v_codigo := v_base || ean13_digito_verificador(v_base);
    EXIT WHEN NOT EXISTS (SELECT 1 FROM productos WHERE codigo_barras = v_codigo OR codigo_interno = v_codigo)
          AND NOT EXISTS (SELECT 1 FROM carga_inicial_items WHERE codigo_barras = v_codigo);
  END LOOP;

  RETURN v_codigo;
END;
$$;


ALTER FUNCTION "public"."generar_codigo_interno"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."generar_codigo_interno"() IS 'Código numérico de 13 dígitos (20 + secuencia + verificador EAN-13) para productos sin código. Lo usan carga_inicial_finalizar y los formularios de producto de las 3 apps (docs/49).';



CREATE OR REPLACE FUNCTION "public"."liberar_emision_factura_c"("p_venta_id" "uuid", "p_token" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  DELETE FROM emisiones_factura_c_en_curso
  WHERE venta_id = p_venta_id AND token = p_token AND revisar_at IS NULL;
  RETURN FOUND;
END;
$$;


ALTER FUNCTION "public"."liberar_emision_factura_c"("p_venta_id" "uuid", "p_token" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."listar_admins"() RETURNS TABLE("id" "uuid", "nombre" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles p WHERE p.id = auth.uid() AND p.activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  RETURN QUERY
  SELECT p.id, p.nombre FROM perfiles p WHERE p.rol = 'admin' AND p.activo = true ORDER BY p.nombre;
END;
$$;


ALTER FUNCTION "public"."listar_admins"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."listar_emisiones_factura_c_a_revisar"() RETURNS TABLE("venta_id" "uuid", "venta_numero" bigint, "venta_total" numeric, "venta_fecha" timestamp with time zone, "ambiente" "text", "registrado_at" timestamp with time zone, "registrado_por_nombre" "text", "ultimo_arca" integer, "ultimo_arca_actual" integer, "revisar_at" timestamp with time zone, "revisar_detectado_por_nombre" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  RETURN QUERY
  SELECT e.venta_id, v.numero, v.total, v.created_at, e.ambiente, e.registrado_at, pr.nombre,
         e.ultimo_arca, e.ultimo_arca_actual, e.revisar_at, pd.nombre
  FROM emisiones_factura_c_en_curso e
  JOIN ventas v ON v.id = e.venta_id
  LEFT JOIN perfiles pr ON pr.id = e.registrado_por
  LEFT JOIN perfiles pd ON pd.id = e.revisar_detectado_por
  WHERE e.revisar_at IS NOT NULL
  ORDER BY e.revisar_at;
END;
$$;


ALTER FUNCTION "public"."listar_emisiones_factura_c_a_revisar"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."perfiles" (
    "id" "uuid" NOT NULL,
    "nombre" "text" NOT NULL,
    "rol" "public"."rol_usuario" NOT NULL,
    "activo" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."perfiles" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."listar_usuarios"() RETURNS SETOF "public"."perfiles"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede ver el listado de usuarios';
  END IF;

  RETURN QUERY SELECT * FROM perfiles ORDER BY nombre;
END;
$$;


ALTER FUNCTION "public"."listar_usuarios"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."marcar_apertura_revisada"("p_apertura_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_apertura aperturas_caja%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede marcar una apertura como revisada';
  END IF;

  -- FOR UPDATE: si dos admins la marcan a la vez, el segundo espera y ve que ya está revisada.
  SELECT * INTO v_apertura FROM aperturas_caja WHERE id = p_apertura_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Apertura de caja no encontrada'; END IF;
  IF v_apertura.diferencia = 0 THEN RAISE EXCEPTION 'Esta apertura no tiene diferencia para revisar'; END IF;
  IF v_apertura.revisada_at IS NOT NULL THEN RAISE EXCEPTION 'Esta apertura ya fue marcada como revisada'; END IF;

  UPDATE aperturas_caja SET revisada_por = auth.uid(), revisada_at = now()
  WHERE id = p_apertura_id;
END;
$$;


ALTER FUNCTION "public"."marcar_apertura_revisada"("p_apertura_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."marcar_etiquetas"("p_producto_ids" "uuid"[], "p_precios" numeric[] DEFAULT NULL::numeric[]) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."marcar_etiquetas"("p_producto_ids" "uuid"[], "p_precios" numeric[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."marcar_iva_productos"("p_ids" "uuid"[], "p_lleva_iva" boolean) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_iva NUMERIC;
  v_count INTEGER;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede cambiar el IVA de los productos';
  END IF;
  IF p_ids IS NULL OR cardinality(p_ids) = 0 THEN
    RAISE EXCEPTION 'Elegí al menos un producto';
  END IF;
  IF p_lleva_iva IS NULL THEN
    RAISE EXCEPTION 'Indicá si los productos llevan IVA o no';
  END IF;

  v_iva := CASE WHEN p_lleva_iva THEN 21 ELSE 0 END;

  -- Solo los que cambian: así la auditoría no se llena de ediciones vacías y la cantidad devuelta
  -- es la de productos realmente modificados. El WHERE también cumple con safeupdate.
  UPDATE productos
  SET iva_porcentaje = v_iva,
      updated_at = now()
  WHERE id = ANY(p_ids) AND iva_porcentaje <> v_iva;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;


ALTER FUNCTION "public"."marcar_iva_productos"("p_ids" "uuid"[], "p_lleva_iva" boolean) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."marcar_iva_productos"("p_ids" "uuid"[], "p_lleva_iva" boolean) IS 'Acción masiva "Lleva IVA" (docs/47): admin activo; pone iva_porcentaje 21 o 0 en los productos que no lo tienen y devuelve cuántos cambió.';



CREATE OR REPLACE FUNCTION "public"."marcar_revisar_emision_factura_c"("p_venta_id" "uuid", "p_token" "uuid", "p_ultimo_actual" integer) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  UPDATE emisiones_factura_c_en_curso
  SET revisar_at = now(), revisar_detectado_por = auth.uid(), ultimo_arca_actual = p_ultimo_actual
  WHERE venta_id = p_venta_id AND token = p_token AND revisar_at IS NULL;
  RETURN FOUND;
END;
$$;


ALTER FUNCTION "public"."marcar_revisar_emision_factura_c"("p_venta_id" "uuid", "p_token" "uuid", "p_ultimo_actual" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalizar_descripcion_item_libre"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NEW.producto_id IS NULL THEN
    NEW.descripcion := upper(btrim(NEW.descripcion));
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."normalizar_descripcion_item_libre"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."normalizar_descripcion_item_libre"() IS 'Trigger (facturas_compra_items): descripcion en MAYÚSCULAS solo en ítems libres (producto_id null). docs/42.';



CREATE OR REPLACE FUNCTION "public"."normalizar_texto_producto"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_descripcion TEXT := NULLIF(btrim(NEW.descripcion), '');
BEGIN
  -- nombre es NOT NULL en las dos tablas: se deja que el constraint avise si viene null.
  NEW.nombre := upper(btrim(NEW.nombre));
  NEW.marca := NULLIF(upper(btrim(NEW.marca)), '');
  NEW.descripcion := upper(left(v_descripcion, 1)) || lower(substr(v_descripcion, 2));
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."normalizar_texto_producto"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."normalizar_texto_producto"() IS 'Trigger (productos, carga_inicial_items): nombre y marca en MAYÚSCULAS, descripcion con solo la primera letra en mayúscula. No toca los códigos. docs/42.';



CREATE OR REPLACE FUNCTION "public"."nota_visible_para_mi"("p_origen" "text") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
     AND (p_origen = 'local' OR EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin'));
$$;


ALTER FUNCTION "public"."nota_visible_para_mi"("p_origen" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notas_internas_archivar_hilo"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  UPDATE notas_internas SET archivada = NEW.archivada
  WHERE parent_id = NEW.id AND archivada IS DISTINCT FROM NEW.archivada;
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."notas_internas_archivar_hilo"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notas_internas_guardia"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_padre notas_internas%ROWTYPE;
  v_ancestro uuid;
  v_vueltas int := 0;
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.editada_at := NULL;
    NEW.archivada_por := CASE WHEN NEW.archivada THEN auth.uid() END;
  ELSE
    IF NEW.autor_id IS DISTINCT FROM OLD.autor_id OR NEW.origen IS DISTINCT FROM OLD.origen
       OR NEW.parent_id IS DISTINCT FROM OLD.parent_id OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
      RAISE EXCEPTION 'No se puede cambiar el autor, el origen, la nota respondida ni la fecha de una nota';
    END IF;
    IF NEW.mensaje IS DISTINCT FROM OLD.mensaje THEN
      IF auth.uid() IS NOT NULL AND auth.uid() <> OLD.autor_id THEN
        RAISE EXCEPTION 'Solo quien escribió la nota puede editarla';
      END IF;
      NEW.editada_at := now();
    ELSE
      NEW.editada_at := OLD.editada_at;
    END IF;
    IF NEW.archivada IS DISTINCT FROM OLD.archivada THEN
      NEW.archivada_at := CASE WHEN NEW.archivada THEN now() END;
      NEW.archivada_por := CASE WHEN NEW.archivada THEN auth.uid() END;
    ELSE
      NEW.archivada_por := OLD.archivada_por;
    END IF;
  END IF;

  -- Validación del padre: solo en el INSERT (en un UPDATE parent_id no cambia, ver arriba).
  IF TG_OP = 'INSERT' AND NEW.parent_id IS NOT NULL THEN
    SELECT * INTO v_padre FROM notas_internas WHERE id = NEW.parent_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'La nota que querés responder no existe'; END IF;
    IF v_padre.origen <> NEW.origen THEN
      RAISE EXCEPTION 'Una respuesta tiene que ser del mismo origen (Local / Gestión) que la nota';
    END IF;
    IF v_padre.archivada THEN RAISE EXCEPTION 'No se puede responder una nota archivada'; END IF;
    -- Sin ciclos: subiendo desde el padre nunca se llega a la nota nueva.
    v_ancestro := NEW.parent_id;
    WHILE v_ancestro IS NOT NULL LOOP
      IF v_ancestro = NEW.id THEN RAISE EXCEPTION 'Una nota no puede responderse a sí misma'; END IF;
      v_vueltas := v_vueltas + 1;
      IF v_vueltas > 1000 THEN RAISE EXCEPTION 'Hilo de notas demasiado profundo'; END IF;
      SELECT parent_id INTO v_ancestro FROM notas_internas WHERE id = v_ancestro;
    END LOOP;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."notas_internas_guardia"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."plan_costo_vinculo_item"("p_item_id" "uuid", "p_producto_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_item facturas_compra_items%ROWTYPE;
  v_fc facturas_compra%ROWTYPE;
  v_prod productos%ROWTYPE;
  v_prov proveedores%ROWTYPE;
  v_post RECORD;
  v_costo_linea numeric;
  v_pone_costo boolean;
  v_cambia_proveedor boolean;
  v_costo_nuevo numeric;
  v_m1 numeric;
  v_m2 numeric;
  v_manual_nuevo numeric;
  v_cambia boolean;
BEGIN
  SELECT * INTO v_item FROM facturas_compra_items WHERE id = p_item_id;
  SELECT * INTO v_fc FROM facturas_compra WHERE id = v_item.factura_compra_id;
  SELECT * INTO v_prod FROM productos WHERE id = p_producto_id;
  IF v_item.id IS NULL OR v_fc.id IS NULL OR v_prod.id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_prov FROM proveedores WHERE id = v_fc.proveedor_id;

  -- Compra posterior del mismo producto: si existe, ese comprobante ya definió el costo.
  SELECT f2.id, f2.fecha_comprobante, f2.tipo_comprobante, f2.letra, f2.punto_venta, f2.numero_comprobante
  INTO v_post
  FROM facturas_compra f2
  JOIN facturas_compra_items i2 ON i2.factura_compra_id = f2.id
  WHERE i2.producto_id = p_producto_id
    AND f2.id <> v_fc.id
    AND NOT f2.anulada
    AND f2.tipo_comprobante <> 'nota_credito'
    AND (f2.fecha_comprobante, f2.created_at) > (v_fc.fecha_comprobante, v_fc.created_at)
  ORDER BY f2.fecha_comprobante DESC, f2.created_at DESC
  LIMIT 1;

  -- Mismas reglas que cargar_factura_compra (docs/13, docs/34, docs/45).
  v_costo_linea := ROUND(v_item.precio_unitario_sin_iva * (1 - v_item.descuento_porcentaje / 100.0), 2);
  v_pone_costo := v_fc.tipo_comprobante NOT IN ('nota_credito', 'nota_debito') AND v_costo_linea > 0;
  v_cambia_proveedor := v_prod.proveedor_id IS DISTINCT FROM v_fc.proveedor_id;
  v_costo_nuevo := CASE WHEN v_pone_costo THEN v_costo_linea ELSE v_prod.costo END;
  v_m1 := CASE WHEN v_cambia_proveedor THEN v_prov.margen_1_default ELSE v_prod.margen_1 END;
  v_m2 := CASE WHEN v_cambia_proveedor THEN v_prov.margen_2_default ELSE v_prod.margen_2 END;
  v_manual_nuevo := CASE WHEN v_pone_costo THEN NULL ELSE v_prod.precio_manual END;
  v_cambia := v_cambia_proveedor OR v_costo_nuevo IS DISTINCT FROM v_prod.costo
              OR (v_pone_costo AND v_prod.precio_manual IS NOT NULL);

  RETURN jsonb_build_object(
    'aplica', v_post.id IS NULL AND v_cambia,
    'compra_posterior', CASE WHEN v_post.id IS NULL THEN NULL ELSE jsonb_build_object(
        'fecha_comprobante', v_post.fecha_comprobante, 'tipo_comprobante', v_post.tipo_comprobante,
        'letra', v_post.letra, 'punto_venta', v_post.punto_venta, 'numero_comprobante', v_post.numero_comprobante) END,
    'pone_costo', v_pone_costo,
    'costo_antes', v_prod.costo,
    'costo_nuevo', v_costo_nuevo,
    'precio_antes', v_prod.precio_venta,
    'precio_manual_antes', v_prod.precio_manual,
    -- Misma expresión que la columna generada productos.precio_venta.
    'precio_nuevo', COALESCE(v_manual_nuevo, redondear_precio_venta(
        v_costo_nuevo * (1 + v_m1 / 100.0) * (1 + v_m2 / 100.0) * (1 + v_prod.iva_porcentaje / 100.0))),
    'cambia_proveedor', v_cambia_proveedor,
    'proveedor_id_nuevo', v_fc.proveedor_id,
    'proveedor_nuevo', v_prov.razon_social,
    'margen_1_nuevo', v_m1,
    'margen_2_nuevo', v_m2);
END;
$$;


ALTER FUNCTION "public"."plan_costo_vinculo_item"("p_item_id" "uuid", "p_producto_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."plan_costo_vinculo_item"("p_item_id" "uuid", "p_producto_id" "uuid") IS 'Interna: qué le hace al producto vincularle un ítem de factura (costo, precio manual, proveedor/márgenes), si es la compra más nueva. docs/56.';



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


ALTER FUNCTION "public"."precios_cambiados"("p_solo_pendientes" boolean, "p_desde" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."productos_stock_bajo"("p_limite" integer DEFAULT NULL::integer) RETURNS TABLE("id" "uuid", "nombre" "text", "marca" "text", "stock_total" numeric, "stock_minimo" numeric, "total_count" integer)
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  WITH stock AS (
    SELECT p.id, p.nombre, p.marca, p.stock_minimo,
           COALESCE(SUM(s.cantidad), 0) AS stock_total
    FROM productos p
    LEFT JOIN stock_ubicaciones s ON s.producto_id = p.id
    WHERE p.estado = 'activo'
      AND p.stock_minimo > 0  -- docs/64: mínimo 0 = sin definir, no alerta
    GROUP BY p.id, p.nombre, p.marca, p.stock_minimo
  )
  SELECT st.id, st.nombre, st.marca, st.stock_total, st.stock_minimo,
         (COUNT(*) OVER ())::int AS total_count
  FROM stock st
  WHERE st.stock_total <= st.stock_minimo
  ORDER BY st.stock_total - st.stock_minimo, st.nombre
  LIMIT p_limite;
$$;


ALTER FUNCTION "public"."productos_stock_bajo"("p_limite" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."proteger_tipo_compra"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RAISE EXCEPTION 'El tipo de compra (artículos/servicios) no se cambia: anulá el comprobante y volvé a cargarlo';
END;
$$;


ALTER FUNCTION "public"."proteger_tipo_compra"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."proteger_tipo_compra"() IS 'Trigger (facturas_compra): tipo_compra no cambia después de cargada. docs/53.';



CREATE OR REPLACE FUNCTION "public"."quitar_acentos"("p_texto" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO 'public'
    AS $$
  -- 20 minúsculas + 20 mayúsculas, en el mismo orden. Ñ/ñ no están: se conservan.
  SELECT translate(p_texto,
    'áéíóúüàèìòùäëïöâêîôûÁÉÍÓÚÜÀÈÌÒÙÄËÏÖÂÊÎÔÛ',
    'aeiouuaeiouaeioaeiouAEIOUUAEIOUAEIOAEIOU');
$$;


ALTER FUNCTION "public"."quitar_acentos"("p_texto" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."quitar_acentos"("p_texto" "text") IS 'Quita tildes, diéresis y acentos graves/circunflejos; conserva la Ñ. docs/51.';



CREATE OR REPLACE FUNCTION "public"."reabrir_venta_interna"("p_venta_id" "uuid", "p_motivo" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_venta ventas%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede reabrir un comprobante interno';
  END IF;
  IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
    RAISE EXCEPTION 'El motivo es obligatorio para reabrir un comprobante';
  END IF;
  SELECT * INTO v_venta FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Venta no encontrada'; END IF;
  IF v_venta.estado_interno IS DISTINCT FROM 'finalizado' THEN
    RAISE EXCEPTION 'Solo se reabre un comprobante interno finalizado';
  END IF;
  IF v_venta.estado <> 'sin_facturar' THEN RAISE EXCEPTION 'El comprobante está anulado: no se reabre'; END IF;

  -- La auditoría (trg_auditoria_ventas) guarda el antes/después con el motivo y quién reabrió.
  UPDATE ventas
  SET estado_interno = 'pendiente', finalizada_at = NULL, finalizada_por = NULL,
      reabierta_at = now(), reabierta_por = auth.uid(), reabierta_motivo = btrim(p_motivo),
      version = version + 1
  WHERE id = p_venta_id;

  RETURN jsonb_build_object('venta_id', p_venta_id, 'version', v_venta.version + 1);
END;
$$;


ALTER FUNCTION "public"."reabrir_venta_interna"("p_venta_id" "uuid", "p_motivo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."redondear_precio_venta"("p_precio" numeric) RETURNS numeric
    LANGUAGE "plpgsql" IMMUTABLE STRICT PARALLEL SAFE
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_base NUMERIC := ROUND(p_precio, 2);  -- = precio_calculado
  v_resto NUMERIC;
BEGIN
  IF v_base < 500 THEN
    RETURN ROUND(v_base, -2);
  ELSIF v_base < 10000 THEN
    v_resto := mod(v_base, 500);
    RETURN CASE WHEN v_resto <= 200 THEN v_base - v_resto ELSE v_base - v_resto + 500 END;
  ELSE
    RETURN ROUND(v_base, -3);
  END IF;
END;
$$;


ALTER FUNCTION "public"."redondear_precio_venta"("p_precio" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reemitir_factura_c_produccion"("p_venta_id" "uuid", "p_cae" "text", "p_numero_factura" "text", "p_punto_venta" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
DECLARE
  v_anterior facturas_c%ROWTYPE;
  v_nueva facturas_c%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true AND rol = 'admin') THEN
    RAISE EXCEPTION 'Solo un administrador puede re-emitir una Factura C';
  END IF;
  IF p_cae IS NULL OR p_cae !~ '^\d{14}$' THEN
    RAISE EXCEPTION 'CAE inválido: %', p_cae;
  END IF;

  SELECT * INTO v_anterior FROM facturas_c WHERE venta_id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Esta venta no tiene Factura C para re-emitir';
  END IF;
  IF v_anterior.ambiente <> 'homologacion' THEN
    RAISE EXCEPTION 'Esta Factura C ya es de producción, no se re-emite';
  END IF;

  UPDATE facturas_c SET
    cae = p_cae,
    numero_factura = p_numero_factura,
    punto_venta = p_punto_venta,
    ambiente = 'produccion',
    fecha_emision = now()
  WHERE id = v_anterior.id
  RETURNING * INTO v_nueva;

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, valores_nuevos, usuario_id, nota)
  VALUES ('facturas_c', v_anterior.id, 'edicion', to_jsonb(v_anterior), to_jsonb(v_nueva), auth.uid(),
          'Re-emisión en ARCA producción: el CAE ' || coalesce(v_anterior.cae, '—')
          || ' era de homologación (sin validez fiscal)');

  RETURN v_anterior.id;
END;
$_$;


ALTER FUNCTION "public"."reemitir_factura_c_produccion"("p_venta_id" "uuid", "p_cae" "text", "p_numero_factura" "text", "p_punto_venta" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_cobro_cliente"("p_cliente_id" "uuid", "p_medios" "jsonb", "p_venta_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_origen" "public"."origen_egreso" DEFAULT 'turno'::"public"."origen_egreso", "p_fecha" "date" DEFAULT NULL::"date", "p_nota" "text" DEFAULT NULL::"text", "p_monto" numeric DEFAULT NULL::numeric) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_hoy DATE := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_fecha DATE;
  v_nota TEXT := NULLIF(btrim(p_nota), '');
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

  IF p_origen = 'turno' THEN
    -- El cobro de Local entra al Cierre del día: tiene que haber caja abierta y es de hoy.
    IF NOT EXISTS (SELECT 1 FROM aperturas_caja WHERE cierre_z_id IS NULL) THEN
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
  IF p_medios IS NULL OR jsonb_typeof(p_medios) <> 'array' OR jsonb_array_length(p_medios) = 0 THEN
    RAISE EXCEPTION 'Agregá al menos un medio de cobro';
  END IF;
  FOR v_elem IN SELECT e FROM jsonb_array_elements(p_medios) AS e LOOP
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
  SELECT saldo_cobrable INTO v_cobrable FROM clientes_saldo WHERE id = p_cliente_id;
  IF COALESCE(v_cobrable, 0) <= 0 THEN
    RAISE EXCEPTION 'Este cliente no tiene saldo a cobrar';
  END IF;
  IF v_monto > v_cobrable THEN
    RAISE EXCEPTION 'El cobro (%) supera lo que debe el cliente (%)', v_monto, v_cobrable;
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

  v_rest := v_monto;
  i := 1;
  WHILE i <= cardinality(v_doc_ids) AND v_rest > 0 LOOP
    v_aplicar := LEAST(v_doc_saldos[i], v_rest);
    v_plan_doc := array_append(v_plan_doc, v_doc_ids[i]);
    v_plan_monto := array_append(v_plan_monto, v_aplicar);
    v_rest := v_rest - v_aplicar;
    i := i + 1;
  END LOOP;

  -- ── Escritura ──
  INSERT INTO pagos_cliente (cliente_id, venta_id, monto, forma_pago, usuario_id, origen, fecha, nota)
  VALUES (p_cliente_id,
          CASE WHEN cardinality(v_plan_doc) = 1 AND v_rest = 0 THEN v_plan_doc[1] END,  -- deprecated
          v_monto,
          CASE WHEN v_cant = 1 THEN v_m_forma[1] ELSE 'combinado'::forma_pago_venta END,
          auth.uid(), p_origen, v_fecha, v_nota)
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
    'aplicado', v_monto - v_rest,
    'a_cuenta', v_rest,
    'aplicaciones', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', a.id, 'venta_id', a.venta_id, 'monto', a.monto)
                       ORDER BY array_position(v_plan_doc, a.venta_id))
      FROM pagos_cliente_aplicaciones a WHERE a.operacion_id = v_pago_id
    ), '[]'::jsonb)
  );
END;
$$;


ALTER FUNCTION "public"."registrar_cobro_cliente"("p_cliente_id" "uuid", "p_medios" "jsonb", "p_venta_ids" "uuid"[], "p_origen" "public"."origen_egreso", "p_fecha" "date", "p_nota" "text", "p_monto" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_egreso_general"("p_categoria" "public"."categoria_egreso", "p_monto" numeric, "p_descripcion" "text", "p_forma_pago" "public"."forma_pago_egreso", "p_origen" "public"."origen_egreso" DEFAULT 'general'::"public"."origen_egreso", "p_cierre_caja_id" "uuid" DEFAULT NULL::"uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_egreso_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF p_origen = 'general' AND NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede registrar un egreso de origen general';
  END IF;
  IF p_categoria = 'pago_proveedor' THEN
    RAISE EXCEPTION 'Para pagos a proveedor usá registrar_pago_proveedor, no esta función';
  END IF;
  IF p_descripcion IS NULL OR trim(p_descripcion) = '' THEN
    RAISE EXCEPTION 'La descripción es obligatoria';
  END IF;

  INSERT INTO egresos (cierre_caja_id, origen, categoria, monto, descripcion, forma_pago, usuario_id)
  VALUES (p_cierre_caja_id, p_origen, p_categoria, p_monto, p_descripcion, p_forma_pago, auth.uid())
  RETURNING id INTO v_egreso_id;

  -- docs/58: el efectivo de Local (origen 'turno') no sale de la cuenta Efectivo de Caja Gestión.
  IF p_forma_pago = 'transferencia' OR (p_forma_pago = 'efectivo' AND p_origen = 'general') THEN
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
    SELECT cuenta_id, 'egreso', -abs(p_monto), v_egreso_id, auth.uid()
    FROM cuenta_forma_pago WHERE forma_pago = p_forma_pago::text::forma_pago_venta;
  END IF;

  RETURN v_egreso_id;
END;
$$;


ALTER FUNCTION "public"."registrar_egreso_general"("p_categoria" "public"."categoria_egreso", "p_monto" numeric, "p_descripcion" "text", "p_forma_pago" "public"."forma_pago_egreso", "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_egreso_general"("p_categoria" "public"."categoria_egreso", "p_monto" numeric, "p_descripcion" "text", "p_forma_pago" "public"."forma_pago_egreso", "p_origen" "public"."origen_egreso" DEFAULT 'general'::"public"."origen_egreso", "p_cierre_caja_id" "uuid" DEFAULT NULL::"uuid", "p_fecha" "date" DEFAULT CURRENT_DATE) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_egreso_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF p_origen = 'general' AND NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede registrar un egreso de origen general';
  END IF;
  IF p_categoria = 'pago_proveedor' THEN
    RAISE EXCEPTION 'Para pagos a proveedor usá registrar_pago_proveedor, no esta función';
  END IF;
  IF p_descripcion IS NULL OR trim(p_descripcion) = '' THEN
    RAISE EXCEPTION 'La descripción es obligatoria';
  END IF;
  IF p_fecha IS NULL THEN
    RAISE EXCEPTION 'La fecha del egreso es obligatoria';
  END IF;

  INSERT INTO egresos (cierre_caja_id, origen, categoria, monto, descripcion, forma_pago, usuario_id, fecha)
  VALUES (p_cierre_caja_id, p_origen, p_categoria, p_monto, p_descripcion, p_forma_pago, auth.uid(), p_fecha)
  RETURNING id INTO v_egreso_id;

  -- docs/58: el efectivo de Local (origen 'turno') no sale de la cuenta Efectivo de Caja Gestión.
  IF p_forma_pago = 'transferencia' OR (p_forma_pago = 'efectivo' AND p_origen = 'general') THEN
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
    SELECT cuenta_id, 'egreso', -abs(p_monto), v_egreso_id, auth.uid()
    FROM cuenta_forma_pago WHERE forma_pago = p_forma_pago::text::forma_pago_venta;
  END IF;

  RETURN v_egreso_id;
END;
$$;


ALTER FUNCTION "public"."registrar_egreso_general"("p_categoria" "public"."categoria_egreso", "p_monto" numeric, "p_descripcion" "text", "p_forma_pago" "public"."forma_pago_egreso", "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid", "p_fecha" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_movimiento_caja_general"("p_cuenta_id" "uuid", "p_monto" numeric, "p_tipo" "public"."tipo_movimiento_cuenta", "p_descripcion" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_id UUID;
BEGIN
  IF p_tipo NOT IN ('ingreso_manual', 'egreso') THEN
    RAISE EXCEPTION 'Este RPC es solo para movimientos manuales (ingreso_manual o egreso)';
  END IF;
  IF p_descripcion IS NULL OR trim(p_descripcion) = '' THEN
    RAISE EXCEPTION 'La descripción es obligatoria para un movimiento manual de caja';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede registrar movimientos manuales de caja';
  END IF;

  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, usuario_id)
  VALUES (p_cuenta_id, p_tipo, CASE WHEN p_tipo = 'egreso' THEN -abs(p_monto) ELSE abs(p_monto) END, p_descripcion, auth.uid())
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;


ALTER FUNCTION "public"."registrar_movimiento_caja_general"("p_cuenta_id" "uuid", "p_monto" numeric, "p_tipo" "public"."tipo_movimiento_cuenta", "p_descripcion" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_pago_cliente"("p_cliente_id" "uuid", "p_venta_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_venta") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_pago_id UUID;
  v_origen origen_egreso := CASE WHEN app_cliente() = 'local' THEN 'turno'::origen_egreso ELSE 'general'::origen_egreso END;
  v_saldo NUMERIC;
  v_monto NUMERIC := round(p_monto, 2);
BEGIN
  IF p_forma_pago = 'cuenta_corriente' THEN
    RAISE EXCEPTION 'La forma de pago no puede ser cuenta_corriente para saldar una cuenta corriente';
  END IF;
  IF p_forma_pago = 'combinado' THEN
    RAISE EXCEPTION 'Elegí un solo medio de cobro';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF v_monto IS NULL OR v_monto <= 0 THEN
    RAISE EXCEPTION 'Ingresá un monto mayor a cero';
  END IF;

  PERFORM 1 FROM clientes WHERE id = p_cliente_id FOR UPDATE;

  IF p_venta_id IS NOT NULL THEN
    SELECT s.saldo_pendiente INTO v_saldo
    FROM ventas_cuenta_corriente_saldo s
    WHERE s.id = p_venta_id AND s.cliente_id = p_cliente_id
      AND s.estado <> 'anulada' AND s.estado_interno IS NULL;
  END IF;

  INSERT INTO pagos_cliente (cliente_id, venta_id, monto, forma_pago, usuario_id, origen)
  VALUES (p_cliente_id, p_venta_id, v_monto, p_forma_pago, auth.uid(), v_origen)
  RETURNING id INTO v_pago_id;

  INSERT INTO pagos_cliente_medios (pago_cliente_id, forma_pago, monto, orden)
  VALUES (v_pago_id, p_forma_pago, v_monto, 1);

  IF COALESCE(v_saldo, 0) > 0 THEN
    INSERT INTO pagos_cliente_aplicaciones (pago_cliente_id, venta_id, monto, operacion_id, usuario_id)
    VALUES (v_pago_id, p_venta_id, LEAST(v_saldo, v_monto), v_pago_id, auth.uid());
  END IF;

  IF v_origen = 'general' THEN
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
    SELECT cuenta_id, 'pago_cliente', v_monto, v_pago_id, auth.uid()
    FROM cuenta_forma_pago WHERE forma_pago = p_forma_pago;
  END IF;
  RETURN v_pago_id;
END;
$$;


ALTER FUNCTION "public"."registrar_pago_cliente"("p_cliente_id" "uuid", "p_venta_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_venta") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_pago_proveedor"("p_proveedor_id" "uuid", "p_factura_compra_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_egreso", "p_origen" "public"."origen_egreso" DEFAULT 'turno'::"public"."origen_egreso", "p_cierre_caja_id" "uuid" DEFAULT NULL::"uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_res JSONB;
BEGIN
  IF p_factura_compra_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM facturas_compra WHERE id = p_factura_compra_id AND anulada) THEN
    RAISE EXCEPTION 'Esta factura está anulada, no se le registran pagos';
  END IF;

  v_res := registrar_pago_proveedor_v2(
    p_proveedor_id := p_proveedor_id,
    p_monto := p_monto,
    p_forma_pago := p_forma_pago,
    p_factura_ids := CASE WHEN p_factura_compra_id IS NULL THEN NULL ELSE ARRAY[p_factura_compra_id] END,
    p_origen := p_origen,
    p_cierre_caja_id := p_cierre_caja_id
  );
  RETURN (v_res->>'pago_id')::UUID;
END;
$$;


ALTER FUNCTION "public"."registrar_pago_proveedor"("p_proveedor_id" "uuid", "p_factura_compra_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_egreso", "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_pago_proveedor"("p_proveedor_id" "uuid", "p_factura_compra_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_egreso", "p_origen" "public"."origen_egreso" DEFAULT 'turno'::"public"."origen_egreso", "p_cierre_caja_id" "uuid" DEFAULT NULL::"uuid", "p_cheque_numero" "text" DEFAULT NULL::"text", "p_cheque_fecha_salida" "date" DEFAULT NULL::"date", "p_cheque_fecha_vencimiento" "date" DEFAULT NULL::"date") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_res JSONB;
BEGIN
  IF p_factura_compra_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM facturas_compra WHERE id = p_factura_compra_id AND anulada) THEN
    RAISE EXCEPTION 'Esta factura está anulada, no se le registran pagos';
  END IF;

  v_res := registrar_pago_proveedor_v2(
    p_proveedor_id := p_proveedor_id,
    p_monto := p_monto,
    p_forma_pago := p_forma_pago,
    p_factura_ids := CASE WHEN p_factura_compra_id IS NULL THEN NULL ELSE ARRAY[p_factura_compra_id] END,
    p_nota_credito_ids := NULL,
    p_origen := p_origen,
    p_cierre_caja_id := p_cierre_caja_id,
    p_fecha := NULL,
    p_nota := NULL,
    p_cheque_numero := p_cheque_numero,
    p_cheque_fecha_salida := p_cheque_fecha_salida,
    p_cheque_fecha_vencimiento := p_cheque_fecha_vencimiento
  );
  RETURN (v_res->>'pago_id')::UUID;
END;
$$;


ALTER FUNCTION "public"."registrar_pago_proveedor"("p_proveedor_id" "uuid", "p_factura_compra_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_egreso", "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid", "p_cheque_numero" "text", "p_cheque_fecha_salida" "date", "p_cheque_fecha_vencimiento" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_pago_proveedor_v2"("p_proveedor_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_egreso", "p_factura_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_nota_credito_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_origen" "public"."origen_egreso" DEFAULT 'turno'::"public"."origen_egreso", "p_cierre_caja_id" "uuid" DEFAULT NULL::"uuid", "p_fecha" "date" DEFAULT NULL::"date", "p_nota" "text" DEFAULT NULL::"text", "p_cheque_numero" "text" DEFAULT NULL::"text", "p_cheque_fecha_salida" "date" DEFAULT NULL::"date", "p_cheque_fecha_vencimiento" "date" DEFAULT NULL::"date") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_monto NUMERIC := round(p_monto, 2);
  v_es_cheque BOOLEAN := p_forma_pago IN ('cheque', 'echeq');
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF p_forma_pago IS NULL THEN
    RAISE EXCEPTION 'La forma de pago es obligatoria';
  END IF;
  IF p_forma_pago = 'mixto' THEN
    RAISE EXCEPTION 'Un pago con varios medios se registra con registrar_pago_proveedor_v3';
  END IF;
  IF v_monto IS NULL OR v_monto < 0 THEN
    RAISE EXCEPTION 'El monto no puede ser negativo';
  END IF;
  IF v_monto = 0 AND v_es_cheque THEN
    RAISE EXCEPTION 'Un pago sin monto (solo aplicación de notas de crédito) no puede ser con cheque';
  END IF;
  IF v_es_cheque AND v_monto > 0 THEN
    IF p_cheque_numero IS NULL OR trim(p_cheque_numero) = '' THEN
      RAISE EXCEPTION 'El número de cheque es obligatorio';
    END IF;
    IF p_cheque_fecha_salida IS NULL THEN
      RAISE EXCEPTION 'La fecha de salida del cheque es obligatoria';
    END IF;
    IF p_cheque_fecha_vencimiento IS NULL THEN
      RAISE EXCEPTION 'La fecha de vencimiento del cheque es obligatoria';
    END IF;
  END IF;

  RETURN registrar_pago_proveedor_v3(
    p_proveedor_id => p_proveedor_id,
    p_medios => CASE WHEN v_monto > 0 THEN jsonb_build_array(jsonb_build_object(
                  'medio', p_forma_pago, 'monto', v_monto,
                  'numero', CASE WHEN v_es_cheque THEN p_cheque_numero END,
                  'fecha_salida', CASE WHEN v_es_cheque THEN p_cheque_fecha_salida END,
                  'fecha_pago', CASE WHEN v_es_cheque THEN p_cheque_fecha_vencimiento END))
                ELSE '[]'::jsonb END,
    p_factura_ids => p_factura_ids,
    p_nota_credito_ids => p_nota_credito_ids,
    p_origen => p_origen,
    p_cierre_caja_id => p_cierre_caja_id,
    p_fecha => p_fecha,
    p_nota => p_nota,
    p_monto => v_monto);
END;
$$;


ALTER FUNCTION "public"."registrar_pago_proveedor_v2"("p_proveedor_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_egreso", "p_factura_ids" "uuid"[], "p_nota_credito_ids" "uuid"[], "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid", "p_fecha" "date", "p_nota" "text", "p_cheque_numero" "text", "p_cheque_fecha_salida" "date", "p_cheque_fecha_vencimiento" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_pago_proveedor_v3"("p_proveedor_id" "uuid", "p_medios" "jsonb", "p_factura_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_nota_credito_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_origen" "public"."origen_egreso" DEFAULT 'turno'::"public"."origen_egreso", "p_cierre_caja_id" "uuid" DEFAULT NULL::"uuid", "p_fecha" "date" DEFAULT NULL::"date", "p_nota" "text" DEFAULT NULL::"text", "p_monto" numeric DEFAULT NULL::numeric) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_fecha DATE := COALESCE(p_fecha, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);
  v_nota TEXT := NULLIF(trim(p_nota), '');
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

  IF v_monto = 0 AND v_nc_ids IS NULL THEN
    RAISE EXCEPTION 'Ingresá un monto mayor a cero o elegí una nota de crédito para aplicar';
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

  IF v_monto = 0 AND v_total_nc = 0 THEN
    RAISE EXCEPTION 'No hay saldo pendiente al que aplicar la nota de crédito';
  END IF;

  -- ── Paso 2: repartir el pago (suma de los medios), más viejos primero. Lo que sobra queda a cuenta ──
  v_rest := v_monto;
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

  -- ── Escritura ──
  -- Sin medios (solo NC) la cabecera queda en efectivo, como hacía v2 con monto 0.
  v_forma_cabecera := CASE WHEN v_cant = 0 THEN 'efectivo'::forma_pago_egreso
                           WHEN v_cant = 1 THEN v_m_medio[1]
                           ELSE 'mixto'::forma_pago_egreso END;

  INSERT INTO pagos_proveedor (
    proveedor_id, factura_compra_id, monto, forma_pago, usuario_id, fecha, nota,
    cheque_numero, cheque_fecha_salida, cheque_fecha_vencimiento
  )
  VALUES (
    p_proveedor_id,
    -- deprecated: solo si todo el pago cancela una única factura (compatibilidad con las pantallas actuales)
    CASE WHEN cardinality(v_pago_docs) = 1 AND v_rest = 0 THEN v_pago_docs[1] END,
    v_monto, v_forma_cabecera, auth.uid(), v_fecha, v_nota,
    -- Con un solo cheque, también en la cabecera: lo leen las apps que no conocen los medios.
    CASE WHEN v_cant = 1 AND v_m_medio[1] IN ('cheque', 'echeq') THEN v_m_numero[1] END,
    CASE WHEN v_cant = 1 AND v_m_medio[1] IN ('cheque', 'echeq') THEN v_m_salida[1] END,
    CASE WHEN v_cant = 1 AND v_m_medio[1] IN ('cheque', 'echeq') THEN v_m_pago[1] END
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
    'aplicado_pago', v_monto - v_rest,
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


ALTER FUNCTION "public"."registrar_pago_proveedor_v3"("p_proveedor_id" "uuid", "p_medios" "jsonb", "p_factura_ids" "uuid"[], "p_nota_credito_ids" "uuid"[], "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid", "p_fecha" "date", "p_nota" "text", "p_monto" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_retiro_caja"("p_monto" numeric, "p_admin_id" "uuid", "p_cajero_id" "uuid", "p_fecha" "date" DEFAULT CURRENT_DATE) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_cuenta_id UUID;
  v_movimiento_id UUID;
  v_retiro_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF p_monto IS NULL OR p_monto <= 0 THEN
    RAISE EXCEPTION 'El importe del retiro debe ser mayor a 0';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = p_admin_id AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'El admin receptor seleccionado no es válido';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = p_cajero_id AND activo = true) THEN
    RAISE EXCEPTION 'El cajero seleccionado no es válido';
  END IF;

  SELECT id INTO v_cuenta_id FROM cuentas WHERE nombre = 'Efectivo';
  IF v_cuenta_id IS NULL THEN
    RAISE EXCEPTION 'No existe la cuenta Efectivo';
  END IF;

  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, usuario_id)
  VALUES (v_cuenta_id, 'retiro', abs(p_monto), 'Retiro de efectivo recibido por admin', auth.uid())
  RETURNING id INTO v_movimiento_id;

  INSERT INTO retiros_caja (fecha, monto, admin_receptor_id, cajero_id, movimiento_cuenta_id, usuario_id)
  VALUES (p_fecha, abs(p_monto), p_admin_id, p_cajero_id, v_movimiento_id, auth.uid())
  RETURNING id INTO v_retiro_id;

  RETURN v_retiro_id;
END;
$$;


ALTER FUNCTION "public"."registrar_retiro_caja"("p_monto" numeric, "p_admin_id" "uuid", "p_cajero_id" "uuid", "p_fecha" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_ultimo_arca_emision_factura_c"("p_venta_id" "uuid", "p_token" "uuid", "p_ambiente" "text", "p_ultimo" integer) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  UPDATE emisiones_factura_c_en_curso
  SET ambiente = p_ambiente, ultimo_arca = p_ultimo, registrado_at = now(), registrado_por = auth.uid()
  WHERE venta_id = p_venta_id AND token = p_token AND revisar_at IS NULL;
  RETURN FOUND;
END;
$$;


ALTER FUNCTION "public"."registrar_ultimo_arca_emision_factura_c"("p_venta_id" "uuid", "p_token" "uuid", "p_ambiente" "text", "p_ultimo" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reservar_emision_factura_c"("p_venta_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_estado estado_comprobante;
  v_interno estado_venta_interna;  -- docs/68
  v_res emisiones_factura_c_en_curso%ROWTYPE;
  v_token uuid := gen_random_uuid();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  -- El lock de la venta serializa reservas y el guardado de la factura (emitir_factura_c).
  SELECT estado, estado_interno INTO v_estado, v_interno FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('resultado', 'no_encontrada');
  END IF;
  -- docs/68 (D5): antes de cualquier reserva, así nunca se llega a pedirle un CAE a ARCA.
  IF v_interno IS NOT NULL THEN
    RAISE EXCEPTION 'Es un consumo interno (cliente interno): no lleva Factura C';
  END IF;
  IF v_estado <> 'sin_facturar' OR EXISTS (SELECT 1 FROM facturas_c WHERE venta_id = p_venta_id) THEN
    RETURN jsonb_build_object('resultado', 'ya_facturada');
  END IF;

  SELECT * INTO v_res FROM emisiones_factura_c_en_curso WHERE venta_id = p_venta_id;
  IF NOT FOUND THEN
    INSERT INTO emisiones_factura_c_en_curso (venta_id, token, tomada_at, tomada_por)
    VALUES (p_venta_id, v_token, now(), auth.uid());
    RETURN jsonb_build_object('resultado', 'reservada', 'token', v_token);
  END IF;

  IF v_res.revisar_at IS NOT NULL THEN
    RETURN jsonb_build_object('resultado', 'revisar');
  END IF;
  IF v_res.tomada_at > now() - interval '5 minutes' THEN
    RETURN jsonb_build_object('resultado', 'en_curso');
  END IF;

  -- Vencida: se toma de nuevo sin borrar ultimo_arca/ambiente. Si esta función también muere antes de
  -- registrar un número nuevo, el próximo sigue teniendo contra qué comparar.
  UPDATE emisiones_factura_c_en_curso
  SET token = v_token, tomada_at = now(), tomada_por = auth.uid()
  WHERE venta_id = p_venta_id;

  RETURN jsonb_build_object(
    'resultado', 'reservada',
    'token', v_token,
    'pendiente_ultimo_arca', v_res.ultimo_arca,
    'pendiente_ambiente', v_res.ambiente
  );
END;
$$;


ALTER FUNCTION "public"."reservar_emision_factura_c"("p_venta_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resumen_stock_inventario"() RETURNS TABLE("activos" integer, "sin_stock" integer, "negativo" integer, "bajo" integer, "sin_minimo" integer)
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  WITH stock AS (
    SELECT p.stock_minimo, COALESCE(SUM(s.cantidad), 0) AS stock_total
    FROM productos p
    LEFT JOIN stock_ubicaciones s ON s.producto_id = p.id
    WHERE p.estado = 'activo'
    GROUP BY p.id, p.stock_minimo
  )
  SELECT count(*)::int,
         (count(*) FILTER (WHERE stock_total <= 0))::int,
         (count(*) FILTER (WHERE stock_total < 0))::int,
         (count(*) FILTER (WHERE stock_minimo > 0 AND stock_total > 0 AND stock_total <= stock_minimo))::int,
         (count(*) FILTER (WHERE stock_minimo <= 0))::int
  FROM stock;
$$;


ALTER FUNCTION "public"."resumen_stock_inventario"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."revertir_alta"("p_auditoria_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_auditoria auditoria%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede revertir acciones';
  END IF;

  SELECT * INTO v_auditoria FROM auditoria WHERE id = p_auditoria_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Acción no encontrada'; END IF;
  IF v_auditoria.accion <> 'alta' THEN RAISE EXCEPTION 'Esta acción no es un alta reversible'; END IF;
  IF v_auditoria.tabla_afectada NOT IN ('productos', 'clientes', 'proveedores') THEN
    RAISE EXCEPTION 'Este tipo de alta no se revierte automáticamente';
  END IF;
  IF EXISTS (SELECT 1 FROM auditoria WHERE revierte_auditoria_id = p_auditoria_id) THEN
    RAISE EXCEPTION 'Esta acción ya fue revertida';
  END IF;

  PERFORM set_config('virikyna.suppress_audit', 'true', true);

  IF v_auditoria.tabla_afectada = 'productos' THEN
    UPDATE productos SET estado = 'inactivo', updated_at = now() WHERE id = v_auditoria.registro_id;
  ELSIF v_auditoria.tabla_afectada = 'clientes' THEN
    UPDATE clientes SET activo = false WHERE id = v_auditoria.registro_id;
  ELSIF v_auditoria.tabla_afectada = 'proveedores' THEN
    DELETE FROM proveedores WHERE id = v_auditoria.registro_id;
  END IF;

  PERFORM set_config('virikyna.suppress_audit', 'false', true);

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, usuario_id, revierte_auditoria_id)
  VALUES (v_auditoria.tabla_afectada, v_auditoria.registro_id, 'reversion', v_auditoria.valores_nuevos, auth.uid(), p_auditoria_id);
END;
$$;


ALTER FUNCTION "public"."revertir_alta"("p_auditoria_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."revertir_edicion"("p_auditoria_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_auditoria auditoria%ROWTYPE;
  v_set_clause TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede revertir acciones';
  END IF;

  SELECT * INTO v_auditoria FROM auditoria WHERE id = p_auditoria_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Acción no encontrada'; END IF;
  IF v_auditoria.accion <> 'edicion' THEN RAISE EXCEPTION 'Esta acción no es una edición reversible'; END IF;
  IF v_auditoria.tabla_afectada NOT IN ('productos', 'proveedores', 'clientes') THEN
    RAISE EXCEPTION 'Este cambio no se revierte con revertir_edicion — usá la función específica de ese tipo';
  END IF;
  IF EXISTS (SELECT 1 FROM auditoria WHERE revierte_auditoria_id = p_auditoria_id) THEN
    RAISE EXCEPTION 'Esta acción ya fue revertida';
  END IF;

  SELECT string_agg(format('%I = %L', kv.key, kv.value), ', ')
  INTO v_set_clause
  FROM jsonb_each_text(v_auditoria.valores_anteriores) AS kv(key, value)
  WHERE kv.key NOT IN ('id', 'created_at', 'updated_at', 'precio_venta', 'precio_calculado');

  IF v_set_clause IS NULL THEN RAISE EXCEPTION 'No hay valores anteriores para restaurar'; END IF;

  PERFORM set_config('virikyna.suppress_audit', 'true', true);
  EXECUTE format('UPDATE %I SET %s WHERE id = %L', v_auditoria.tabla_afectada, v_set_clause, v_auditoria.registro_id);
  IF v_auditoria.tabla_afectada = 'productos' THEN
    EXECUTE format('UPDATE productos SET updated_at = now() WHERE id = %L', v_auditoria.registro_id);
  END IF;
  PERFORM set_config('virikyna.suppress_audit', 'false', true);

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, valores_nuevos, usuario_id, revierte_auditoria_id)
  VALUES (v_auditoria.tabla_afectada, v_auditoria.registro_id, 'reversion',
          v_auditoria.valores_nuevos, v_auditoria.valores_anteriores, auth.uid(), p_auditoria_id);
END;
$$;


ALTER FUNCTION "public"."revertir_edicion"("p_auditoria_id" "uuid") OWNER TO "postgres";


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


ALTER FUNCTION "public"."revertir_movimiento"("p_auditoria_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_usuario_activo"("p_user_id" "uuid", "p_activo" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede desactivar o reactivar usuarios';
  END IF;
  IF p_user_id = auth.uid() AND p_activo = false THEN
    RAISE EXCEPTION 'No podés desactivar tu propio usuario';
  END IF;

  UPDATE perfiles SET activo = p_activo WHERE id = p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Usuario no encontrado'; END IF;
END;
$$;


ALTER FUNCTION "public"."set_usuario_activo"("p_user_id" "uuid", "p_activo" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."transferir_entre_cuentas"("p_cuenta_origen_id" "uuid", "p_cuenta_destino_id" "uuid", "p_monto" numeric, "p_descripcion" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE v_referencia UUID := gen_random_uuid();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede transferir entre cuentas';
  END IF;
  IF p_cuenta_origen_id = p_cuenta_destino_id THEN
    RAISE EXCEPTION 'La cuenta de origen y destino no pueden ser la misma';
  END IF;
  IF p_monto <= 0 THEN
    RAISE EXCEPTION 'El monto de la transferencia debe ser positivo';
  END IF;
  IF p_descripcion IS NULL OR trim(p_descripcion) = '' THEN
    RAISE EXCEPTION 'La descripción es obligatoria para una transferencia entre cuentas';
  END IF;
  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, referencia_id, usuario_id)
  VALUES (p_cuenta_origen_id, 'transferencia_interna', -abs(p_monto), p_descripcion, v_referencia, auth.uid());
  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, descripcion, referencia_id, usuario_id)
  VALUES (p_cuenta_destino_id, 'transferencia_interna', abs(p_monto), p_descripcion, v_referencia, auth.uid());
  RETURN v_referencia;
END;
$$;


ALTER FUNCTION "public"."transferir_entre_cuentas"("p_cuenta_origen_id" "uuid", "p_cuenta_destino_id" "uuid", "p_monto" numeric, "p_descripcion" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validar_cierre_z"("p_cierre_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_cierre cierres_caja%ROWTYPE;
  v_monto_tarjeta NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede validar un Cierre Z';
  END IF;

  SELECT * INTO v_cierre FROM cierres_caja WHERE id = p_cierre_id AND tipo = 'z';
  IF NOT FOUND THEN RAISE EXCEPTION 'Cierre Z no encontrado'; END IF;
  IF v_cierre.estado_validacion = 'validado' THEN RAISE EXCEPTION 'Este Cierre Z ya fue validado'; END IF;

  UPDATE cierres_caja SET estado_validacion = 'validado', validado_por = auth.uid(), validado_at = now()
  WHERE id = p_cierre_id;

  -- docs/68: + cobros de cuenta corriente del turno (lo no-efectivo va a su cuenta, como las ventas).
  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
  SELECT cfp.cuenta_id, 'cierre_z', v.monto, p_cierre_id, auth.uid()
  FROM (VALUES
    ('transferencia'::forma_pago_venta, v_cierre.total_transferencia + v_cierre.total_devoluciones_transferencia + v_cierre.total_cobros_transferencia),
    ('qr'::forma_pago_venta, v_cierre.total_qr + v_cierre.total_devoluciones_qr + v_cierre.total_cobros_qr)
  ) AS v(forma_pago, monto)
  JOIN cuenta_forma_pago cfp ON cfp.forma_pago = v.forma_pago
  WHERE v.monto <> 0;

  -- Tarjeta (débito+crédito) va a la misma cuenta que QR (Galicia)
  v_monto_tarjeta := v_cierre.total_tarjeta + v_cierre.total_devoluciones_tarjeta + v_cierre.total_cobros_tarjeta;
  IF v_monto_tarjeta <> 0 THEN
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
    SELECT cuenta_id, 'cierre_z', v_monto_tarjeta, p_cierre_id, auth.uid()
    FROM cuenta_forma_pago WHERE forma_pago = 'qr';
  END IF;
END;
$$;


ALTER FUNCTION "public"."validar_cierre_z"("p_cierre_id" "uuid") OWNER TO "postgres";


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
  INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
  VALUES (p_producto_id, v_item.ubicacion, 'compra', v_item.cantidad,
          'Ítem de factura vinculado después de cargada', v_item.factura_compra_id, auth.uid());

  INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
  VALUES (p_producto_id, v_item.ubicacion, v_item.cantidad)
  ON CONFLICT (producto_id, ubicacion)
  DO UPDATE SET cantidad = stock_ubicaciones.cantidad + EXCLUDED.cantidad;

  -- docs/56: costo, precio manual y proveedor/márgenes como al cargar, si es la compra más nueva.
  PERFORM aplicar_costo_vinculo_item(p_item_id, p_producto_id);
END;
$$;


ALTER FUNCTION "public"."vincular_item_factura_compra"("p_item_id" "uuid", "p_producto_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."vista_previa_vincular_item_factura_compra"("p_item_id" "uuid", "p_producto_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede vincular un ítem de una factura ya cargada';
  END IF;
  RETURN plan_costo_vinculo_item(p_item_id, p_producto_id);
END;
$$;


ALTER FUNCTION "public"."vista_previa_vincular_item_factura_compra"("p_item_id" "uuid", "p_producto_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."vista_previa_vincular_item_factura_compra"("p_item_id" "uuid", "p_producto_id" "uuid") IS 'Solo admin, solo lectura: cómo quedan costo y precio del producto si se le vincula el ítem. docs/56.';



CREATE TABLE IF NOT EXISTS "public"."aperturas_caja" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "cierre_z_previo_id" "uuid",
    "monto_esperado" numeric(12,2) DEFAULT 0 NOT NULL,
    "monto_real" numeric(12,2) NOT NULL,
    "diferencia" numeric(12,2) DEFAULT 0 NOT NULL,
    "cierre_z_id" "uuid",
    "usuario_id" "uuid" NOT NULL,
    "abierta_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "revisada_por" "uuid",
    "revisada_at" timestamp with time zone
);


ALTER TABLE "public"."aperturas_caja" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."arca_wsaa_tokens" (
    "servicio" "text" NOT NULL,
    "cuit" "text" NOT NULL,
    "token" "text" NOT NULL,
    "sign" "text" NOT NULL,
    "expiration_time" timestamp with time zone NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ambiente" "text" DEFAULT 'homologacion'::"text" NOT NULL
);


ALTER TABLE "public"."arca_wsaa_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."auditoria" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tabla_afectada" "text" NOT NULL,
    "registro_id" "uuid" NOT NULL,
    "accion" "public"."tipo_accion_auditoria" NOT NULL,
    "valores_anteriores" "jsonb",
    "valores_nuevos" "jsonb",
    "usuario_id" "uuid",
    "revierte_auditoria_id" "uuid",
    "nota" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."auditoria" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."borradores" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tipo" "text" NOT NULL,
    "sistema" "text" NOT NULL,
    "payload" "jsonb" NOT NULL,
    "resumen" "text",
    "usuario_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "actualizado_por" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    CONSTRAINT "borradores_payload_check" CHECK ((("jsonb_typeof"("payload") = 'object'::"text") AND ("octet_length"(("payload")::"text") <= 500000))),
    CONSTRAINT "borradores_sistema_check" CHECK (("sistema" = ANY (ARRAY['local'::"text", 'gestion'::"text", 'inventario'::"text"]))),
    CONSTRAINT "borradores_tipo_check" CHECK (("tipo" = 'factura_compra'::"text"))
);


ALTER TABLE "public"."borradores" OWNER TO "postgres";


COMMENT ON TABLE "public"."borradores" IS 'Formularios a medio cargar (docs/54). No modifican nada del negocio: se aplican recién al confirmar. Sin auditoría a propósito.';



CREATE TABLE IF NOT EXISTS "public"."carga_inicial_operaciones" (
    "client_id" "uuid" NOT NULL,
    "usuario_id" "uuid" NOT NULL,
    "operacion" "text" NOT NULL,
    "item_id" "uuid",
    "resultado" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "carga_inicial_operaciones_operacion_check" CHECK (("operacion" = ANY (ARRAY['guardar_item'::"text", 'editar_producto'::"text"])))
);


ALTER TABLE "public"."carga_inicial_operaciones" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pagos_proveedor" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "proveedor_id" "uuid" NOT NULL,
    "factura_compra_id" "uuid",
    "monto" numeric(12,2) NOT NULL,
    "forma_pago" "public"."forma_pago_egreso" NOT NULL,
    "usuario_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "revierte_pago_proveedor_id" "uuid",
    "cheque_numero" "text",
    "cheque_fecha_salida" "date",
    "cheque_fecha_vencimiento" "date",
    "fecha" "date" DEFAULT (("now"() AT TIME ZONE 'America/Argentina/Buenos_Aires'::"text"))::"date" NOT NULL,
    "nota" "text"
);


ALTER TABLE "public"."pagos_proveedor" OWNER TO "postgres";


COMMENT ON COLUMN "public"."pagos_proveedor"."factura_compra_id" IS 'DEPRECATED (docs/31): la imputación vive en pagos_proveedor_aplicaciones. Se sigue completando solo cuando todo el pago cancela una única factura, para que las pantallas actuales sigan mostrando el pago en el detalle de esa factura. No usar para calcular saldos.';



CREATE TABLE IF NOT EXISTS "public"."pagos_proveedor_medios" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "pago_proveedor_id" "uuid" NOT NULL,
    "medio" "public"."forma_pago_egreso" NOT NULL,
    "monto" numeric(12,2) NOT NULL,
    "numero" "text",
    "banco" "text",
    "fecha_salida" "date",
    "fecha_pago" "date",
    "propio" boolean DEFAULT true NOT NULL,
    "orden" integer NOT NULL,
    "revierte_medio_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "pagos_proveedor_medios_cheque" CHECK (
CASE
    WHEN ("medio" = ANY (ARRAY['cheque'::"public"."forma_pago_egreso", 'echeq'::"public"."forma_pago_egreso"])) THEN (("numero" IS NOT NULL) AND ("btrim"("numero") <> ''::"text") AND ("fecha_pago" IS NOT NULL))
    ELSE (("numero" IS NULL) AND ("banco" IS NULL) AND ("fecha_salida" IS NULL) AND ("fecha_pago" IS NULL))
END),
    CONSTRAINT "pagos_proveedor_medios_monto" CHECK (("monto" <> (0)::numeric)),
    CONSTRAINT "pagos_proveedor_medios_no_mixto" CHECK (("medio" <> 'mixto'::"public"."forma_pago_egreso"))
);


ALTER TABLE "public"."pagos_proveedor_medios" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."proveedores" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "razon_social" "text" NOT NULL,
    "cuit" "text",
    "direccion" "text",
    "telefono" "text",
    "mail" "text",
    "contacto" "text",
    "margen_1_default" numeric(6,2) DEFAULT 0 NOT NULL,
    "margen_2_default" numeric(6,2) DEFAULT 0 NOT NULL,
    "saldo_inicial" numeric(12,2) DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "observaciones" "text"
);


ALTER TABLE "public"."proveedores" OWNER TO "postgres";


COMMENT ON COLUMN "public"."proveedores"."observaciones" IS 'Notas internas libres sobre el proveedor (ayuda memoria). Null si no hay. Se muestran al cargar una compra y en su cuenta corriente.';



CREATE OR REPLACE VIEW "public"."cartera_cheques_emitidos" WITH ("security_invoker"='true') AS
 SELECT "m"."id",
    "m"."pago_proveedor_id",
    "pp"."proveedor_id",
    "pr"."razon_social" AS "proveedor",
    "m"."medio",
    "m"."monto",
    "m"."numero",
    "m"."banco",
    "m"."fecha_salida",
    "m"."fecha_pago",
    "m"."propio",
    "pp"."fecha" AS "fecha_pago_proveedor",
    ("m"."revierte_medio_id" IS NOT NULL) AS "es_reversion",
    (EXISTS ( SELECT 1
           FROM "public"."pagos_proveedor_medios" "r"
          WHERE ("r"."revierte_medio_id" = "m"."id"))) AS "revertido"
   FROM (("public"."pagos_proveedor_medios" "m"
     JOIN "public"."pagos_proveedor" "pp" ON (("pp"."id" = "m"."pago_proveedor_id")))
     JOIN "public"."proveedores" "pr" ON (("pr"."id" = "pp"."proveedor_id")))
  WHERE ("m"."medio" = ANY (ARRAY['cheque'::"public"."forma_pago_egreso", 'echeq'::"public"."forma_pago_egreso"]));


ALTER VIEW "public"."cartera_cheques_emitidos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cierres_caja" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tipo" "public"."tipo_cierre" NOT NULL,
    "turno_fecha" "date" NOT NULL,
    "total_efectivo" numeric(12,2) DEFAULT 0 NOT NULL,
    "total_transferencia" numeric(12,2) DEFAULT 0 NOT NULL,
    "total_qr" numeric(12,2) DEFAULT 0 NOT NULL,
    "total_tarjeta" numeric(12,2) DEFAULT 0 NOT NULL,
    "total_cuenta_corriente" numeric(12,2) DEFAULT 0 NOT NULL,
    "total_egresos" numeric(12,2) DEFAULT 0 NOT NULL,
    "efectivo_esperado" numeric(12,2) DEFAULT 0 NOT NULL,
    "efectivo_contado" numeric(12,2),
    "diferencia" numeric(12,2),
    "estado_validacion" "public"."estado_cierre_z",
    "validado_por" "uuid",
    "validado_at" timestamp with time zone,
    "usuario_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "total_retiros" numeric(12,2) DEFAULT 0 NOT NULL,
    "apertura_id" "uuid",
    "cantidad_devoluciones" integer DEFAULT 0 NOT NULL,
    "total_devoluciones_efectivo" numeric(12,2) DEFAULT 0 NOT NULL,
    "total_devoluciones_transferencia" numeric(12,2) DEFAULT 0 NOT NULL,
    "total_devoluciones_qr" numeric(12,2) DEFAULT 0 NOT NULL,
    "total_devoluciones_tarjeta" numeric(12,2) DEFAULT 0 NOT NULL,
    "cantidad_cobros" integer DEFAULT 0 NOT NULL,
    "total_cobros_efectivo" numeric(12,2) DEFAULT 0 NOT NULL,
    "total_cobros_transferencia" numeric(12,2) DEFAULT 0 NOT NULL,
    "total_cobros_qr" numeric(12,2) DEFAULT 0 NOT NULL,
    "total_cobros_tarjeta" numeric(12,2) DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."cierres_caja" OWNER TO "postgres";


COMMENT ON COLUMN "public"."cierres_caja"."total_cobros_efectivo" IS 'docs/68: cobros de cuenta corriente en efectivo hechos en la caja de Local ese día (ya incluidos en efectivo_esperado).';



CREATE TABLE IF NOT EXISTS "public"."clientes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "razon_social" "text",
    "nombre_fantasia" "text",
    "cuit" "text",
    "domicilio" "text",
    "mail" "text",
    "celular" "text",
    "activo" boolean DEFAULT true NOT NULL,
    "saldo_inicial" numeric(12,2) DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "condicion_iva" "public"."condicion_iva_cliente" DEFAULT 'consumidor_final'::"public"."condicion_iva_cliente" NOT NULL,
    "tipo" "public"."tipo_cliente" DEFAULT 'externo'::"public"."tipo_cliente" NOT NULL,
    "perfil_id" "uuid",
    CONSTRAINT "chk_cliente_perfil_solo_interno" CHECK ((("perfil_id" IS NULL) OR ("tipo" = 'interno'::"public"."tipo_cliente")))
);


ALTER TABLE "public"."clientes" OWNER TO "postgres";


COMMENT ON COLUMN "public"."clientes"."tipo" IS 'docs/68: interno = dueña o empleado (sus ventas a cta. cte. las edita y finaliza un admin, sin cobro). Solo un admin lo cambia.';



COMMENT ON COLUMN "public"."clientes"."perfil_id" IS 'docs/68: usuario del sistema que es este cliente interno (opcional).';



CREATE TABLE IF NOT EXISTS "public"."pagos_cliente" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "cliente_id" "uuid" NOT NULL,
    "venta_id" "uuid",
    "monto" numeric(12,2) NOT NULL,
    "usuario_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "forma_pago" "public"."forma_pago_venta" NOT NULL,
    "revierte_pago_cliente_id" "uuid",
    "origen" "public"."origen_egreso" DEFAULT 'general'::"public"."origen_egreso" NOT NULL,
    "fecha" "date" DEFAULT (("now"() AT TIME ZONE 'America/Argentina/Buenos_Aires'::"text"))::"date" NOT NULL,
    "nota" "text",
    CONSTRAINT "chk_pago_cliente_forma_pago" CHECK (("forma_pago" <> 'cuenta_corriente'::"public"."forma_pago_venta"))
);


ALTER TABLE "public"."pagos_cliente" OWNER TO "postgres";


COMMENT ON COLUMN "public"."pagos_cliente"."venta_id" IS 'DEPRECATED (docs/68): la imputación vive en pagos_cliente_aplicaciones. Se completa solo cuando todo el cobro cancela una única venta. No usar para calcular saldos.';



COMMENT ON COLUMN "public"."pagos_cliente"."forma_pago" IS 'docs/68: medio del cobro, o combinado si tiene varios (detalle en pagos_cliente_medios).';



COMMENT ON COLUMN "public"."pagos_cliente"."origen" IS 'docs/68: turno = cobrado en la caja de Local (entra al Cierre); general = Gestión (impacta la cuenta mapeada).';



CREATE TABLE IF NOT EXISTS "public"."pagos_cliente_aplicaciones" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "pago_cliente_id" "uuid" NOT NULL,
    "venta_id" "uuid" NOT NULL,
    "monto" numeric(12,2) NOT NULL,
    "operacion_id" "uuid" NOT NULL,
    "usuario_id" "uuid" NOT NULL,
    "revertida_at" timestamp with time zone,
    "revertida_por" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "pagos_cliente_aplicaciones_monto_check" CHECK (("monto" > (0)::numeric))
);


ALTER TABLE "public"."pagos_cliente_aplicaciones" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."pagos_cliente_a_cuenta" WITH ("security_invoker"='on') AS
 SELECT "pc"."id",
    "pc"."cliente_id",
    "pc"."fecha",
    "pc"."created_at",
    "pc"."monto",
    "pc"."origen",
    "ap"."aplicado",
    "v"."vigente",
        CASE
            WHEN "v"."vigente" THEN ("pc"."monto" - "ap"."aplicado")
            ELSE (0)::numeric
        END AS "a_cuenta"
   FROM (("public"."pagos_cliente" "pc"
     CROSS JOIN LATERAL ( SELECT COALESCE("sum"("a"."monto"), (0)::numeric) AS "aplicado"
           FROM "public"."pagos_cliente_aplicaciones" "a"
          WHERE (("a"."pago_cliente_id" = "pc"."id") AND ("a"."revertida_at" IS NULL))) "ap")
     CROSS JOIN LATERAL ( SELECT (("pc"."monto" > (0)::numeric) AND ("pc"."revierte_pago_cliente_id" IS NULL) AND (NOT (EXISTS ( SELECT 1
                   FROM "public"."pagos_cliente" "r"
                  WHERE ("r"."revierte_pago_cliente_id" = "pc"."id"))))) AS "vigente") "v");


ALTER VIEW "public"."pagos_cliente_a_cuenta" OWNER TO "postgres";


COMMENT ON VIEW "public"."pagos_cliente_a_cuenta" IS 'docs/68: por cobro, lo aplicado vigente y lo que queda a cuenta (0 en reversiones y revertidos).';



CREATE TABLE IF NOT EXISTS "public"."ventas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "numero" bigint NOT NULL,
    "cliente_id" "uuid",
    "forma_pago" "public"."forma_pago_venta" NOT NULL,
    "subtotal" numeric(12,2) NOT NULL,
    "descuento_porcentaje" numeric(5,2) DEFAULT 0 NOT NULL,
    "total" numeric(12,2) NOT NULL,
    "estado" "public"."estado_comprobante" DEFAULT 'sin_facturar'::"public"."estado_comprobante" NOT NULL,
    "nota" "text",
    "terminal_id" "text" DEFAULT 'POS001'::"text" NOT NULL,
    "usuario_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "recargo_porcentaje" numeric(5,2) DEFAULT 0 NOT NULL,
    "precio_oficial" numeric(12,2) NOT NULL,
    "precio_cobrado" numeric(12,2) NOT NULL,
    "client_id" "text",
    "estado_interno" "public"."estado_venta_interna",
    "total_original" numeric(12,2),
    "descuento_global_original" numeric(5,2),
    "finalizada_at" timestamp with time zone,
    "finalizada_por" "uuid",
    "editada_at" timestamp with time zone,
    "editada_por" "uuid",
    "reabierta_at" timestamp with time zone,
    "reabierta_por" "uuid",
    "reabierta_motivo" "text",
    "version" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "chk_venta_cta_cte_requiere_cliente" CHECK ((NOT (("forma_pago" = 'cuenta_corriente'::"public"."forma_pago_venta") AND ("cliente_id" IS NULL)))),
    CONSTRAINT "chk_ventas_interna_cta_cte" CHECK ((("estado_interno" IS NULL) OR ("forma_pago" = 'cuenta_corriente'::"public"."forma_pago_venta"))),
    CONSTRAINT "chk_ventas_precio_cobrado_positivo" CHECK ((("precio_cobrado" > (0)::numeric) OR (("estado_interno" IS NOT NULL) AND ("precio_cobrado" >= (0)::numeric)))),
    CONSTRAINT "ventas_client_id_largo" CHECK (("char_length"("client_id") <= 100))
);


ALTER TABLE "public"."ventas" OWNER TO "postgres";


COMMENT ON COLUMN "public"."ventas"."client_id" IS 'Id del intento de cobro generado por Virikyna Local (<ticket>:<intento>). Único: un reintento con el mismo id devuelve la venta ya creada. docs/43.';



COMMENT ON COLUMN "public"."ventas"."estado_interno" IS 'docs/68: venta a cta. cte. de un cliente interno. pendiente = la dueña la revisa/edita; finalizado = cerrada sin cobro (se descuenta del sueldo fuera del sistema). null = no es interna.';



COMMENT ON COLUMN "public"."ventas"."total_original" IS 'docs/68: precio_cobrado que registró el cajero (solo ventas internas).';



COMMENT ON COLUMN "public"."ventas"."descuento_global_original" IS 'docs/68: descuento global que registró el cajero (solo ventas internas). Al editar, el global queda en 0.';



COMMENT ON COLUMN "public"."ventas"."version" IS 'docs/68: sube con cada edición/finalización/reapertura de una venta interna (control de edición concurrente).';



CREATE OR REPLACE VIEW "public"."ventas_cuenta_corriente_saldo" WITH ("security_invoker"='on') AS
 SELECT "v"."id",
    "v"."numero",
    "v"."cliente_id",
    "v"."created_at",
    "v"."usuario_id",
    "v"."estado",
    "v"."estado_interno",
    "v"."nota",
    "v"."subtotal",
    "v"."descuento_porcentaje",
    "v"."recargo_porcentaje",
    "v"."total",
    "v"."total_original",
    "v"."descuento_global_original",
    "v"."finalizada_at",
    "v"."finalizada_por",
    "v"."editada_at",
    "v"."editada_por",
    "v"."reabierta_at",
    "v"."reabierta_por",
    "v"."reabierta_motivo",
    "v"."version",
    "x"."aplicado" AS "total_aplicado",
    "x"."devuelto" AS "total_devuelto",
        CASE
            WHEN ("v"."estado" = 'anulada'::"public"."estado_comprobante") THEN (0)::numeric
            ELSE GREATEST((("v"."total" - "x"."aplicado") - "x"."devuelto"), (0)::numeric)
        END AS "saldo_pendiente",
        CASE
            WHEN ("v"."estado" = 'anulada'::"public"."estado_comprobante") THEN (0)::numeric
            ELSE GREATEST((("x"."aplicado" + "x"."devuelto") - "v"."total"), (0)::numeric)
        END AS "credito",
        CASE
            WHEN ("v"."estado" = 'anulada'::"public"."estado_comprobante") THEN 'anulada'::"text"
            WHEN ("v"."estado_interno" = 'pendiente'::"public"."estado_venta_interna") THEN 'a_revisar'::"text"
            WHEN ("v"."estado_interno" = 'finalizado'::"public"."estado_venta_interna") THEN 'finalizado'::"text"
            WHEN ((("v"."total" - "x"."aplicado") - "x"."devuelto") <= (0)::numeric) THEN 'pagada'::"text"
            WHEN (("x"."aplicado" + "x"."devuelto") > (0)::numeric) THEN 'parcial'::"text"
            ELSE 'pendiente'::"text"
        END AS "estado_cuenta"
   FROM ("public"."ventas" "v"
     CROSS JOIN LATERAL ( SELECT COALESCE(( SELECT "sum"("a"."monto") AS "sum"
                   FROM "public"."pagos_cliente_aplicaciones" "a"
                  WHERE (("a"."venta_id" = "v"."id") AND ("a"."revertida_at" IS NULL))), (0)::numeric) AS "aplicado",
            "public"."credito_devoluciones_venta"("v"."id") AS "devuelto") "x")
  WHERE ("v"."forma_pago" = 'cuenta_corriente'::"public"."forma_pago_venta");


ALTER VIEW "public"."ventas_cuenta_corriente_saldo" OWNER TO "postgres";


COMMENT ON VIEW "public"."ventas_cuenta_corriente_saldo" IS 'docs/68: saldo por venta a cta. cte. (cobros aplicados vigentes, devoluciones imputadas). estado_cuenta: a_revisar | finalizado | pendiente | parcial | pagada | anulada.';



CREATE OR REPLACE VIEW "public"."clientes_saldo" WITH ("security_invoker"='on') AS
 SELECT "c"."id",
    "c"."razon_social",
    "c"."nombre_fantasia",
    "c"."cuit",
    "c"."domicilio",
    "c"."mail",
    "c"."celular",
    "c"."activo",
    "c"."saldo_inicial",
    "c"."created_at",
    (("c"."saldo_inicial" + COALESCE("vt"."neto", (0)::numeric)) - COALESCE("pg"."total_pagado", (0)::numeric)) AS "saldo_actual",
    "c"."condicion_iva",
    "c"."tipo",
    "c"."perfil_id",
    COALESCE("vt"."deuda_comprobantes", (0)::numeric) AS "deuda_comprobantes",
    COALESCE("vt"."interno_pendiente", (0)::numeric) AS "consumo_interno_pendiente",
    COALESCE("ac"."a_cuenta", (0)::numeric) AS "a_cuenta",
    ((("c"."saldo_inicial" + COALESCE("vt"."neto", (0)::numeric)) - COALESCE("vt"."interno_pendiente", (0)::numeric)) - COALESCE("pg"."total_pagado", (0)::numeric)) AS "saldo_cobrable",
    COALESCE("vt"."comprobantes_abiertos", (0)::bigint) AS "comprobantes_abiertos"
   FROM ((("public"."clientes" "c"
     LEFT JOIN ( SELECT "s"."cliente_id",
            "sum"(("s"."total" - "s"."total_devuelto")) FILTER (WHERE ("s"."estado_interno" IS DISTINCT FROM 'finalizado'::"public"."estado_venta_interna")) AS "neto",
            "sum"("s"."saldo_pendiente") FILTER (WHERE ("s"."estado_interno" IS NULL)) AS "deuda_comprobantes",
            "sum"(("s"."total" - "s"."total_devuelto")) FILTER (WHERE ("s"."estado_interno" = 'pendiente'::"public"."estado_venta_interna")) AS "interno_pendiente",
            "count"(*) FILTER (WHERE ("s"."estado_cuenta" = ANY (ARRAY['pendiente'::"text", 'parcial'::"text", 'a_revisar'::"text"]))) AS "comprobantes_abiertos"
           FROM "public"."ventas_cuenta_corriente_saldo" "s"
          WHERE ("s"."estado" <> 'anulada'::"public"."estado_comprobante")
          GROUP BY "s"."cliente_id") "vt" ON (("vt"."cliente_id" = "c"."id")))
     LEFT JOIN ( SELECT "pagos_cliente"."cliente_id",
            "sum"("pagos_cliente"."monto") AS "total_pagado"
           FROM "public"."pagos_cliente"
          GROUP BY "pagos_cliente"."cliente_id") "pg" ON (("pg"."cliente_id" = "c"."id")))
     LEFT JOIN ( SELECT "pagos_cliente_a_cuenta"."cliente_id",
            "sum"("pagos_cliente_a_cuenta"."a_cuenta") AS "a_cuenta"
           FROM "public"."pagos_cliente_a_cuenta"
          GROUP BY "pagos_cliente_a_cuenta"."cliente_id") "ac" ON (("ac"."cliente_id" = "c"."id")));


ALTER VIEW "public"."clientes_saldo" OWNER TO "postgres";


COMMENT ON VIEW "public"."clientes_saldo" IS 'docs/68: saldo de cuenta corriente por cliente. saldo_actual excluye internas finalizadas y descuenta devoluciones imputadas; saldo_cobrable además excluye internas pendientes (no se cobran, se finalizan).';



CREATE SEQUENCE IF NOT EXISTS "public"."codigo_interno_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    MAXVALUE 9999999999
    CACHE 1;


ALTER SEQUENCE "public"."codigo_interno_seq" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."consumo_interno_mensual" WITH ("security_invoker"='on') AS
 SELECT "s"."cliente_id",
    COALESCE("c"."razon_social", "c"."nombre_fantasia") AS "cliente_nombre",
    ("date_trunc"('month'::"text", ("s"."finalizada_at" AT TIME ZONE 'America/Argentina/Buenos_Aires'::"text")))::"date" AS "mes",
    ("count"(*))::integer AS "cantidad_comprobantes",
    "sum"(("s"."total" - "s"."total_devuelto")) AS "total",
    "sum"(COALESCE("s"."total_original", "s"."total")) AS "total_original"
   FROM ("public"."ventas_cuenta_corriente_saldo" "s"
     JOIN "public"."clientes" "c" ON (("c"."id" = "s"."cliente_id")))
  WHERE (("s"."estado_interno" = 'finalizado'::"public"."estado_venta_interna") AND ("s"."estado" <> 'anulada'::"public"."estado_comprobante"))
  GROUP BY "s"."cliente_id", COALESCE("c"."razon_social", "c"."nombre_fantasia"), (("date_trunc"('month'::"text", ("s"."finalizada_at" AT TIME ZONE 'America/Argentina/Buenos_Aires'::"text")))::"date");


ALTER VIEW "public"."consumo_interno_mensual" OWNER TO "postgres";


COMMENT ON VIEW "public"."consumo_interno_mensual" IS 'docs/68 (D11): consumo interno finalizado por cliente y mes de finalización (total neto de devoluciones).';



CREATE TABLE IF NOT EXISTS "public"."cuenta_forma_pago" (
    "forma_pago" "public"."forma_pago_venta" NOT NULL,
    "cuenta_id" "uuid" NOT NULL
);


ALTER TABLE "public"."cuenta_forma_pago" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cuentas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nombre" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."cuentas" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."cuentas_saldo" AS
SELECT
    NULL::"uuid" AS "id",
    NULL::"text" AS "nombre",
    NULL::timestamp with time zone AS "created_at",
    NULL::numeric AS "saldo_actual";


ALTER VIEW "public"."cuentas_saldo" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."devolucion_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "devolucion_id" "uuid" NOT NULL,
    "tipo" "public"."tipo_item_devolucion" NOT NULL,
    "producto_id" "uuid" NOT NULL,
    "cantidad" numeric(10,2) NOT NULL,
    "precio_unitario" numeric(12,2) NOT NULL,
    "reingresa_stock" boolean DEFAULT true NOT NULL,
    "producto_nombre" "text",
    "producto_marca" "text",
    CONSTRAINT "devolucion_items_cantidad_check" CHECK (("cantidad" > (0)::numeric)),
    CONSTRAINT "devolucion_items_precio_unitario_check" CHECK (("precio_unitario" >= (0)::numeric))
);


ALTER TABLE "public"."devolucion_items" OWNER TO "postgres";


COMMENT ON COLUMN "public"."devolucion_items"."producto_nombre" IS 'Nombre del producto al momento de la devolución/cambio (snapshot, lo copia crear_devolucion). docs/42.';



COMMENT ON COLUMN "public"."devolucion_items"."producto_marca" IS 'Marca del producto al momento de la devolución/cambio (snapshot, null si no tenía). docs/42.';



CREATE TABLE IF NOT EXISTS "public"."devolucion_pagos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "devolucion_id" "uuid" NOT NULL,
    "forma_pago" "public"."forma_pago_venta" NOT NULL,
    "monto" numeric(12,2) NOT NULL,
    CONSTRAINT "chk_devolucion_pagos_forma" CHECK (("forma_pago" <> ALL (ARRAY['cuenta_corriente'::"public"."forma_pago_venta", 'combinado'::"public"."forma_pago_venta"]))),
    CONSTRAINT "devolucion_pagos_monto_check" CHECK (("monto" > (0)::numeric))
);


ALTER TABLE "public"."devolucion_pagos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."devoluciones" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "numero" bigint NOT NULL,
    "venta_id" "uuid" NOT NULL,
    "fecha" "date" DEFAULT (("now"() AT TIME ZONE 'America/Argentina/Buenos_Aires'::"text"))::"date" NOT NULL,
    "usuario_id" "uuid" NOT NULL,
    "motivo" "public"."motivo_devolucion" NOT NULL,
    "motivo_detalle" "text",
    "observaciones" "text",
    "diferencia_monto" numeric(12,2) DEFAULT 0 NOT NULL,
    "diferencia_forma_pago" "public"."forma_pago_venta",
    "estado" "public"."estado_devolucion" DEFAULT 'activa'::"public"."estado_devolucion" NOT NULL,
    "anulada_por" "uuid",
    "anulada_at" timestamp with time zone,
    "motivo_anulacion" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "a_cuenta_corriente" boolean DEFAULT false NOT NULL,
    CONSTRAINT "chk_devolucion_forma_pago_coherente" CHECK ((((("diferencia_monto" = (0)::numeric) OR "a_cuenta_corriente") AND ("diferencia_forma_pago" IS NULL)) OR (("diferencia_monto" <> (0)::numeric) AND (NOT "a_cuenta_corriente") AND ("diferencia_forma_pago" IS NOT NULL)))),
    CONSTRAINT "chk_devolucion_forma_pago_sin_cta_cte" CHECK ((("diferencia_forma_pago" IS NULL) OR ("diferencia_forma_pago" <> 'cuenta_corriente'::"public"."forma_pago_venta"))),
    CONSTRAINT "chk_devolucion_motivo_otro" CHECK ((("motivo" <> 'otro'::"public"."motivo_devolucion") OR (("motivo_detalle" IS NOT NULL) AND ("btrim"("motivo_detalle") <> ''::"text"))))
);


ALTER TABLE "public"."devoluciones" OWNER TO "postgres";


COMMENT ON COLUMN "public"."devoluciones"."a_cuenta_corriente" IS 'docs/68 (D12): la diferencia va a la cuenta corriente del cliente (baja o sube la deuda), sin plata. Solo en ventas a cta. cte.';



ALTER TABLE "public"."devoluciones" ALTER COLUMN "numero" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."devoluciones_numero_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."egresos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "cierre_caja_id" "uuid",
    "origen" "public"."origen_egreso" NOT NULL,
    "categoria" "public"."categoria_egreso" NOT NULL,
    "monto" numeric(12,2) NOT NULL,
    "descripcion" "text",
    "forma_pago" "public"."forma_pago_egreso" NOT NULL,
    "usuario_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "revierte_egreso_id" "uuid",
    "fecha" "date" DEFAULT (("now"() AT TIME ZONE 'America/Argentina/Buenos_Aires'::"text"))::"date" NOT NULL,
    "pago_proveedor_id" "uuid",
    "pago_proveedor_medio_id" "uuid"
);


ALTER TABLE "public"."egresos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."emisiones_factura_c_en_curso" (
    "venta_id" "uuid" NOT NULL,
    "token" "uuid" NOT NULL,
    "tomada_at" timestamp with time zone NOT NULL,
    "tomada_por" "uuid" NOT NULL,
    "ambiente" "text",
    "ultimo_arca" integer,
    "registrado_at" timestamp with time zone,
    "registrado_por" "uuid",
    "revisar_at" timestamp with time zone,
    "revisar_detectado_por" "uuid",
    "ultimo_arca_actual" integer,
    CONSTRAINT "emisiones_factura_c_en_curso_ambiente_check" CHECK (("ambiente" = ANY (ARRAY['homologacion'::"text", 'produccion'::"text"]))),
    CONSTRAINT "emisiones_factura_c_en_curso_check" CHECK ((("ultimo_arca" IS NULL) = ("ambiente" IS NULL)))
);


ALTER TABLE "public"."emisiones_factura_c_en_curso" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."facturas_c" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "venta_id" "uuid" NOT NULL,
    "cae" "text",
    "numero_factura" "text",
    "punto_venta" "text",
    "fecha_emision" timestamp with time zone,
    "pdf_url" "text",
    "enviado_a" "text",
    "usuario_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ambiente" "text" NOT NULL,
    CONSTRAINT "facturas_c_ambiente_check" CHECK (("ambiente" = ANY (ARRAY['homologacion'::"text", 'produccion'::"text"])))
);


ALTER TABLE "public"."facturas_c" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."facturas_compra" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "proveedor_id" "uuid" NOT NULL,
    "tipo_comprobante" "public"."tipo_comprobante_compra" NOT NULL,
    "letra" "public"."letra_comprobante_compra",
    "punto_venta" "text",
    "numero_comprobante" "text",
    "fecha_comprobante" "date" NOT NULL,
    "fecha_fiscal" "date",
    "forma_pago" "public"."forma_pago_compra" NOT NULL,
    "total_sin_iva" numeric(12,2) NOT NULL,
    "iva" numeric(12,2) NOT NULL,
    "total" numeric(12,2) NOT NULL,
    "usuario_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "anulada" boolean DEFAULT false NOT NULL,
    "copiada_de_id" "uuid",
    "iva_alicuota" numeric(5,2) DEFAULT 21 NOT NULL,
    "tipo_compra" "text" DEFAULT 'articulos'::"text" NOT NULL,
    "devuelve_mercaderia" boolean DEFAULT false NOT NULL,
    CONSTRAINT "facturas_compra_devolucion_solo_nc" CHECK (((NOT "devuelve_mercaderia") OR (("tipo_comprobante" = 'nota_credito'::"public"."tipo_comprobante_compra") AND ("tipo_compra" = 'articulos'::"text")))),
    CONSTRAINT "facturas_compra_iva_alicuota_valida" CHECK (("iva_alicuota" = ANY (ARRAY[(0)::numeric, (21)::numeric]))),
    CONSTRAINT "facturas_compra_tipo_compra_valido" CHECK (("tipo_compra" = ANY (ARRAY['articulos'::"text", 'servicios'::"text"])))
);


ALTER TABLE "public"."facturas_compra" OWNER TO "postgres";


COMMENT ON COLUMN "public"."facturas_compra"."iva_alicuota" IS 'Alícuota de IVA del comprobante completo: 21 o 0 (exento). iva = ROUND(total_sin_iva × alícuota / 100, 2). No afecta el costo ni el IVA del producto. docs/45.';



COMMENT ON COLUMN "public"."facturas_compra"."tipo_compra" IS 'articulos (default) o servicios. Servicios: ítems sin producto y cantidad 1, no mueven stock ni costo. No se cambia después de cargada. docs/53.';



COMMENT ON COLUMN "public"."facturas_compra"."devuelve_mercaderia" IS 'NC de artículos con devolución de mercadería: restó stock al cargarse (anularla lo vuelve a sumar). Sin marcar, una NC no toca el stock. docs/55.';



CREATE TABLE IF NOT EXISTS "public"."facturas_compra_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "factura_compra_id" "uuid" NOT NULL,
    "producto_id" "uuid",
    "descripcion" "text" NOT NULL,
    "cantidad" numeric(10,2) NOT NULL,
    "precio_unitario_sin_iva" numeric(12,2) NOT NULL,
    "descuento_porcentaje" numeric(5,2) DEFAULT 0 NOT NULL,
    "precio_total_sin_iva" numeric(12,2) NOT NULL,
    "ubicacion" "public"."ubicacion_stock" DEFAULT 'local'::"public"."ubicacion_stock" NOT NULL
);


ALTER TABLE "public"."facturas_compra_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pagos_proveedor_aplicaciones" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "factura_compra_id" "uuid" NOT NULL,
    "monto" numeric(12,2) NOT NULL,
    "pago_proveedor_id" "uuid",
    "nota_credito_id" "uuid",
    "operacion_id" "uuid" NOT NULL,
    "usuario_id" "uuid" NOT NULL,
    "revertida_at" timestamp with time zone,
    "revertida_por" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_aplicacion_nc_distinta" CHECK ((("nota_credito_id" IS NULL) OR ("nota_credito_id" <> "factura_compra_id"))),
    CONSTRAINT "chk_aplicacion_una_fuente" CHECK ((("pago_proveedor_id" IS NULL) <> ("nota_credito_id" IS NULL))),
    CONSTRAINT "pagos_proveedor_aplicaciones_monto_check" CHECK (("monto" > (0)::numeric))
);


ALTER TABLE "public"."pagos_proveedor_aplicaciones" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."facturas_compra_saldo" WITH ("security_invoker"='on') AS
 SELECT "fc"."id",
    "fc"."proveedor_id",
    "fc"."tipo_comprobante",
    "fc"."letra",
    "fc"."punto_venta",
    "fc"."numero_comprobante",
    "fc"."fecha_comprobante",
    "fc"."fecha_fiscal",
    "fc"."forma_pago",
    "fc"."total_sin_iva",
    "fc"."iva",
    "fc"."total",
    "fc"."usuario_id",
    "fc"."created_at",
    "fc"."anulada",
    "x"."aplicado" AS "total_pagado",
        CASE
            WHEN ("fc"."anulada" OR ("fc"."tipo_comprobante" = 'nota_credito'::"public"."tipo_comprobante_compra")) THEN (0)::numeric
            ELSE ("fc"."total" - "x"."aplicado")
        END AS "saldo_pendiente",
    "x"."aplicado" AS "total_aplicado",
        CASE
            WHEN (("fc"."tipo_comprobante" = 'nota_credito'::"public"."tipo_comprobante_compra") AND (NOT "fc"."anulada")) THEN ("fc"."total" - "x"."aplicado")
            ELSE (0)::numeric
        END AS "credito_disponible",
        CASE
            WHEN "fc"."anulada" THEN 'anulada'::"text"
            WHEN (("fc"."total" - "x"."aplicado") <= (0)::numeric) THEN 'pagada'::"text"
            WHEN ("x"."aplicado" > (0)::numeric) THEN 'parcial'::"text"
            ELSE 'pendiente'::"text"
        END AS "estado",
    "fc"."copiada_de_id",
    "fc"."iva_alicuota",
    "fc"."tipo_compra",
    "fc"."devuelve_mercaderia"
   FROM ("public"."facturas_compra" "fc"
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN ("fc"."tipo_comprobante" = 'nota_credito'::"public"."tipo_comprobante_compra") THEN ( SELECT COALESCE("sum"("a"."monto"), (0)::numeric) AS "coalesce"
                       FROM "public"."pagos_proveedor_aplicaciones" "a"
                      WHERE (("a"."nota_credito_id" = "fc"."id") AND ("a"."revertida_at" IS NULL)))
                    ELSE ( SELECT COALESCE("sum"("a"."monto"), (0)::numeric) AS "coalesce"
                       FROM "public"."pagos_proveedor_aplicaciones" "a"
                      WHERE (("a"."factura_compra_id" = "fc"."id") AND ("a"."revertida_at" IS NULL)))
                END AS "aplicado") "x");


ALTER VIEW "public"."facturas_compra_saldo" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."movimientos_cuenta" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "cuenta_id" "uuid" NOT NULL,
    "tipo" "public"."tipo_movimiento_cuenta" NOT NULL,
    "monto" numeric(12,2) NOT NULL,
    "descripcion" "text",
    "referencia_id" "uuid",
    "usuario_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "revierte_movimiento_id" "uuid"
);


ALTER TABLE "public"."movimientos_cuenta" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."movimientos_stock" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "producto_id" "uuid" NOT NULL,
    "ubicacion" "public"."ubicacion_stock" NOT NULL,
    "tipo" "public"."tipo_movimiento_stock" NOT NULL,
    "cantidad" numeric(10,2) NOT NULL,
    "motivo" "text",
    "referencia_id" "uuid",
    "usuario_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."movimientos_stock" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notas_internas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "mensaje" "text" NOT NULL,
    "autor_id" "uuid" NOT NULL,
    "archivada" boolean DEFAULT false NOT NULL,
    "archivada_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "origen" "text" DEFAULT 'local'::"text" NOT NULL,
    "parent_id" "uuid",
    "editada_at" timestamp with time zone,
    "archivada_por" "uuid",
    CONSTRAINT "notas_internas_origen_check" CHECK (("origen" = ANY (ARRAY['local'::"text", 'gestion'::"text"])))
);


ALTER TABLE "public"."notas_internas" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."notas_internas_con_autor" WITH ("security_barrier"='true') AS
 SELECT "n"."id",
    "n"."mensaje",
    "n"."autor_id",
    "n"."origen",
    "n"."parent_id",
    "n"."archivada",
    "n"."archivada_at",
    "n"."archivada_por",
    "n"."editada_at",
    "n"."created_at",
    "p"."nombre" AS "autor_nombre"
   FROM ("public"."notas_internas" "n"
     JOIN "public"."perfiles" "p" ON (("p"."id" = "n"."autor_id")))
  WHERE ((EXISTS ( SELECT 1
           FROM "public"."perfiles" "yo"
          WHERE (("yo"."id" = "auth"."uid"()) AND ("yo"."activo" = true)))) AND (("n"."origen" = 'local'::"text") OR (EXISTS ( SELECT 1
           FROM "public"."perfiles" "yo"
          WHERE (("yo"."id" = "auth"."uid"()) AND ("yo"."rol" = 'admin'::"public"."rol_usuario"))))));


ALTER VIEW "public"."notas_internas_con_autor" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pagos_cliente_medios" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "pago_cliente_id" "uuid" NOT NULL,
    "forma_pago" "public"."forma_pago_venta" NOT NULL,
    "monto" numeric(12,2) NOT NULL,
    "orden" integer NOT NULL,
    "revierte_medio_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "pagos_cliente_medios_forma" CHECK (("forma_pago" <> ALL (ARRAY['cuenta_corriente'::"public"."forma_pago_venta", 'combinado'::"public"."forma_pago_venta"]))),
    CONSTRAINT "pagos_cliente_medios_monto" CHECK (("monto" <> (0)::numeric))
);


ALTER TABLE "public"."pagos_cliente_medios" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."pagos_proveedor_a_cuenta" WITH ("security_invoker"='on') AS
 SELECT "pp"."id",
    "pp"."proveedor_id",
    "pp"."fecha",
    "pp"."created_at",
    "pp"."monto",
    "ap"."aplicado",
    "v"."vigente",
        CASE
            WHEN "v"."vigente" THEN ("pp"."monto" - "ap"."aplicado")
            ELSE (0)::numeric
        END AS "a_cuenta"
   FROM (("public"."pagos_proveedor" "pp"
     CROSS JOIN LATERAL ( SELECT COALESCE("sum"("a"."monto"), (0)::numeric) AS "aplicado"
           FROM "public"."pagos_proveedor_aplicaciones" "a"
          WHERE (("a"."pago_proveedor_id" = "pp"."id") AND ("a"."revertida_at" IS NULL))) "ap")
     CROSS JOIN LATERAL ( SELECT (("pp"."monto" > (0)::numeric) AND ("pp"."revierte_pago_proveedor_id" IS NULL) AND (NOT (EXISTS ( SELECT 1
                   FROM "public"."pagos_proveedor" "r"
                  WHERE ("r"."revierte_pago_proveedor_id" = "pp"."id"))))) AS "vigente") "v");


ALTER VIEW "public"."pagos_proveedor_a_cuenta" OWNER TO "postgres";


COMMENT ON VIEW "public"."pagos_proveedor_a_cuenta" IS 'docs/52: por pago, lo aplicado vigente y lo que queda a cuenta (0 en reversiones, revertidos y operaciones solo de NC).';



CREATE OR REPLACE VIEW "public"."perfiles_publico" AS
 SELECT "id",
    "nombre"
   FROM "public"."perfiles"
  WHERE ("activo" = true);


ALTER VIEW "public"."perfiles_publico" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."productos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nombre" "text" NOT NULL,
    "descripcion" "text",
    "codigo_barras" "text",
    "codigo_interno" "text",
    "proveedor_id" "uuid",
    "marca" "text",
    "costo" numeric(12,2),
    "margen_1" numeric(6,2) DEFAULT 0 NOT NULL,
    "margen_2" numeric(6,2) DEFAULT 0 NOT NULL,
    "iva_porcentaje" numeric(5,2) DEFAULT 21 NOT NULL,
    "precio_venta" numeric(12,2) GENERATED ALWAYS AS (COALESCE("precio_manual", "public"."redondear_precio_venta"(((("costo" * ((1)::numeric + ("margen_1" / 100.0))) * ((1)::numeric + ("margen_2" / 100.0))) * ((1)::numeric + ("iva_porcentaje" / 100.0)))))) STORED,
    "stock_minimo" numeric(10,2) DEFAULT 0 NOT NULL,
    "estado" "public"."estado_producto" DEFAULT 'activo'::"public"."estado_producto" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "precio_calculado" numeric(12,2) GENERATED ALWAYS AS ("round"(((("costo" * ((1)::numeric + ("margen_1" / 100.0))) * ((1)::numeric + ("margen_2" / 100.0))) * ((1)::numeric + ("iva_porcentaje" / 100.0))), 2)) STORED,
    "precio_manual" numeric(12,2),
    CONSTRAINT "productos_costo_o_precio_manual" CHECK ((("costo" IS NOT NULL) OR ("precio_manual" IS NOT NULL))),
    CONSTRAINT "productos_iva_porcentaje_valido" CHECK (("iva_porcentaje" = ANY (ARRAY[(0)::numeric, (21)::numeric]))),
    CONSTRAINT "productos_precio_manual_positivo" CHECK ((("precio_manual" IS NULL) OR ("precio_manual" > (0)::numeric)))
);


ALTER TABLE "public"."productos" OWNER TO "postgres";


COMMENT ON COLUMN "public"."productos"."iva_porcentaje" IS 'IVA del producto para el precio de venta: 21 (lleva IVA) o 0 (sin IVA). Solo admin lo cambia (fn_proteger_margen_producto). No afecta un precio manual. docs/47.';



COMMENT ON COLUMN "public"."productos"."precio_manual" IS 'Precio de venta cargado a mano (carga inicial, sin costo). Exacto, sin redondeo. Tiene prioridad sobre la fórmula; cargar_factura_compra lo borra al ponerle costo al producto.';



CREATE TABLE IF NOT EXISTS "public"."productos_etiqueta" (
    "producto_id" "uuid" NOT NULL,
    "precio_etiquetado" numeric(12,2) NOT NULL,
    "marcado_por" "uuid",
    "marcado_at" timestamp with time zone
);


ALTER TABLE "public"."productos_etiqueta" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."productos_precios_historial" (
    "id" bigint NOT NULL,
    "producto_id" "uuid" NOT NULL,
    "precio_anterior" numeric(12,2),
    "precio_nuevo" numeric(12,2),
    "origen" "text" NOT NULL,
    "usuario_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "productos_precios_historial_origen_check" CHECK (("origen" = ANY (ARRAY['manual'::"text", 'factura'::"text", 'masivo'::"text", 'margen'::"text", 'iva'::"text", 'reversion'::"text", 'alta'::"text"])))
);


ALTER TABLE "public"."productos_precios_historial" OWNER TO "postgres";


ALTER TABLE "public"."productos_precios_historial" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."productos_precios_historial_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE OR REPLACE VIEW "public"."proveedores_a_cuenta" WITH ("security_invoker"='on') AS
 SELECT "proveedor_id",
    "sum"("a_cuenta") AS "a_cuenta",
    "count"(*) FILTER (WHERE ("a_cuenta" > (0)::numeric)) AS "pagos_con_saldo"
   FROM "public"."pagos_proveedor_a_cuenta"
  GROUP BY "proveedor_id";


ALTER VIEW "public"."proveedores_a_cuenta" OWNER TO "postgres";


COMMENT ON VIEW "public"."proveedores_a_cuenta" IS 'docs/52: total a cuenta (pagos sin aplicar) por proveedor.';



CREATE OR REPLACE VIEW "public"."proveedores_saldo" WITH ("security_invoker"='on') AS
 SELECT "p"."id",
    "p"."razon_social",
    "p"."cuit",
    "p"."direccion",
    "p"."telefono",
    "p"."mail",
    "p"."contacto",
    "p"."margen_1_default",
    "p"."margen_2_default",
    "p"."saldo_inicial",
    "p"."created_at",
    (("p"."saldo_inicial" + COALESCE("facturado"."total_facturado", (0)::numeric)) - COALESCE("pagado"."total_pagado", (0)::numeric)) AS "saldo_actual",
    "p"."observaciones"
   FROM (("public"."proveedores" "p"
     LEFT JOIN ( SELECT "facturas_compra"."proveedor_id",
            "sum"(
                CASE
                    WHEN ("facturas_compra"."tipo_comprobante" = 'nota_credito'::"public"."tipo_comprobante_compra") THEN (- "facturas_compra"."total")
                    ELSE "facturas_compra"."total"
                END) AS "total_facturado"
           FROM "public"."facturas_compra"
          WHERE ("facturas_compra"."anulada" = false)
          GROUP BY "facturas_compra"."proveedor_id") "facturado" ON (("facturado"."proveedor_id" = "p"."id")))
     LEFT JOIN ( SELECT "pagos_proveedor"."proveedor_id",
            "sum"("pagos_proveedor"."monto") AS "total_pagado"
           FROM "public"."pagos_proveedor"
          GROUP BY "pagos_proveedor"."proveedor_id") "pagado" ON (("pagado"."proveedor_id" = "p"."id")));


ALTER VIEW "public"."proveedores_saldo" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."retiros_caja" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "fecha" "date" DEFAULT (("now"() AT TIME ZONE 'America/Argentina/Buenos_Aires'::"text"))::"date" NOT NULL,
    "monto" numeric(12,2) NOT NULL,
    "admin_receptor_id" "uuid" NOT NULL,
    "cajero_id" "uuid" NOT NULL,
    "movimiento_cuenta_id" "uuid" NOT NULL,
    "usuario_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "retiros_caja_monto_check" CHECK (("monto" > (0)::numeric))
);


ALTER TABLE "public"."retiros_caja" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."stock_ubicaciones" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "producto_id" "uuid" NOT NULL,
    "ubicacion" "public"."ubicacion_stock" NOT NULL,
    "cantidad" numeric(10,2) DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."stock_ubicaciones" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."venta_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "venta_id" "uuid" NOT NULL,
    "producto_id" "uuid" NOT NULL,
    "cantidad" numeric(10,2) NOT NULL,
    "precio_unitario" numeric(12,2) NOT NULL,
    "descuento_porcentaje" numeric(5,2) DEFAULT 0 NOT NULL,
    "importe" numeric(12,2) NOT NULL,
    "producto_nombre" "text",
    "producto_marca" "text",
    "costo_unitario" numeric(12,2),
    "producto_con_iva" boolean,
    "precio_unitario_original" numeric(12,2),
    "descuento_porcentaje_original" numeric(5,2),
    CONSTRAINT "chk_venta_items_descuento_rango" CHECK ((("descuento_porcentaje" >= (0)::numeric) AND ("descuento_porcentaje" <= (100)::numeric)))
);


ALTER TABLE "public"."venta_items" OWNER TO "postgres";


COMMENT ON COLUMN "public"."venta_items"."producto_nombre" IS 'Nombre del producto al momento de la venta (snapshot, lo copia confirmar_venta). docs/42.';



COMMENT ON COLUMN "public"."venta_items"."producto_marca" IS 'Marca del producto al momento de la venta (snapshot, null si no tenía). docs/42.';



COMMENT ON COLUMN "public"."venta_items"."costo_unitario" IS 'docs/68: productos.costo al vender (sin IVA). null = venta anterior a docs/68 o producto con precio manual sin costo.';



COMMENT ON COLUMN "public"."venta_items"."producto_con_iva" IS 'docs/68: check "lleva IVA" del producto al vender (iva_porcentaje > 0). Costo comparable = costo × 1,21 si true.';



COMMENT ON COLUMN "public"."venta_items"."precio_unitario_original" IS 'docs/68: precio unitario antes de la primera edición de la dueña (null = nunca se editó).';



COMMENT ON COLUMN "public"."venta_items"."descuento_porcentaje_original" IS 'docs/68: descuento del ítem antes de la primera edición (null = nunca se editó).';



CREATE TABLE IF NOT EXISTS "public"."venta_pagos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "venta_id" "uuid" NOT NULL,
    "forma_pago" "public"."forma_pago_venta" NOT NULL,
    "monto" numeric(12,2) NOT NULL,
    "usuario_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_venta_pagos_monto_positivo" CHECK (("monto" > (0)::numeric)),
    CONSTRAINT "chk_venta_pagos_no_cta_cte" CHECK (("forma_pago" <> ALL (ARRAY['cuenta_corriente'::"public"."forma_pago_venta", 'combinado'::"public"."forma_pago_venta"])))
);


ALTER TABLE "public"."venta_pagos" OWNER TO "postgres";


ALTER TABLE "public"."ventas" ALTER COLUMN "numero" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."ventas_numero_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE ONLY "public"."aperturas_caja"
    ADD CONSTRAINT "aperturas_caja_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."arca_wsaa_tokens"
    ADD CONSTRAINT "arca_wsaa_tokens_pkey" PRIMARY KEY ("servicio", "cuit", "ambiente");



ALTER TABLE ONLY "public"."auditoria"
    ADD CONSTRAINT "auditoria_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."borradores"
    ADD CONSTRAINT "borradores_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."carga_inicial_items"
    ADD CONSTRAINT "carga_inicial_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."carga_inicial_operaciones"
    ADD CONSTRAINT "carga_inicial_operaciones_pkey" PRIMARY KEY ("client_id");



ALTER TABLE ONLY "public"."cierres_caja"
    ADD CONSTRAINT "cierres_caja_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."clientes"
    ADD CONSTRAINT "clientes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."configuracion"
    ADD CONSTRAINT "configuracion_fila_unica_key" UNIQUE ("fila_unica");



ALTER TABLE ONLY "public"."configuracion"
    ADD CONSTRAINT "configuracion_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cuenta_forma_pago"
    ADD CONSTRAINT "cuenta_forma_pago_pkey" PRIMARY KEY ("forma_pago");



ALTER TABLE ONLY "public"."cuentas"
    ADD CONSTRAINT "cuentas_nombre_key" UNIQUE ("nombre");



ALTER TABLE ONLY "public"."cuentas"
    ADD CONSTRAINT "cuentas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."devolucion_items"
    ADD CONSTRAINT "devolucion_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."devolucion_pagos"
    ADD CONSTRAINT "devolucion_pagos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."devoluciones"
    ADD CONSTRAINT "devoluciones_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."egresos"
    ADD CONSTRAINT "egresos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."emisiones_factura_c_en_curso"
    ADD CONSTRAINT "emisiones_factura_c_en_curso_pkey" PRIMARY KEY ("venta_id");



ALTER TABLE ONLY "public"."facturas_c"
    ADD CONSTRAINT "facturas_c_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."facturas_c"
    ADD CONSTRAINT "facturas_c_venta_id_key" UNIQUE ("venta_id");



ALTER TABLE ONLY "public"."facturas_compra_items"
    ADD CONSTRAINT "facturas_compra_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."facturas_compra"
    ADD CONSTRAINT "facturas_compra_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."movimientos_cuenta"
    ADD CONSTRAINT "movimientos_cuenta_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."movimientos_stock"
    ADD CONSTRAINT "movimientos_stock_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notas_internas"
    ADD CONSTRAINT "notas_internas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pagos_cliente_aplicaciones"
    ADD CONSTRAINT "pagos_cliente_aplicaciones_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pagos_cliente_medios"
    ADD CONSTRAINT "pagos_cliente_medios_orden" UNIQUE ("pago_cliente_id", "orden");



ALTER TABLE ONLY "public"."pagos_cliente_medios"
    ADD CONSTRAINT "pagos_cliente_medios_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pagos_cliente"
    ADD CONSTRAINT "pagos_cliente_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pagos_proveedor_aplicaciones"
    ADD CONSTRAINT "pagos_proveedor_aplicaciones_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pagos_proveedor_medios"
    ADD CONSTRAINT "pagos_proveedor_medios_orden" UNIQUE ("pago_proveedor_id", "orden");



ALTER TABLE ONLY "public"."pagos_proveedor_medios"
    ADD CONSTRAINT "pagos_proveedor_medios_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pagos_proveedor"
    ADD CONSTRAINT "pagos_proveedor_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."perfiles"
    ADD CONSTRAINT "perfiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."productos"
    ADD CONSTRAINT "productos_codigo_barras_key" UNIQUE ("codigo_barras");



ALTER TABLE ONLY "public"."productos"
    ADD CONSTRAINT "productos_codigo_interno_key" UNIQUE ("codigo_interno");



ALTER TABLE ONLY "public"."productos_etiqueta"
    ADD CONSTRAINT "productos_etiqueta_pkey" PRIMARY KEY ("producto_id");



ALTER TABLE ONLY "public"."productos"
    ADD CONSTRAINT "productos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."productos_precios_historial"
    ADD CONSTRAINT "productos_precios_historial_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."proveedores"
    ADD CONSTRAINT "proveedores_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."retiros_caja"
    ADD CONSTRAINT "retiros_caja_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."stock_ubicaciones"
    ADD CONSTRAINT "stock_ubicaciones_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."stock_ubicaciones"
    ADD CONSTRAINT "stock_ubicaciones_producto_id_ubicacion_key" UNIQUE ("producto_id", "ubicacion");



ALTER TABLE ONLY "public"."venta_items"
    ADD CONSTRAINT "venta_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."venta_pagos"
    ADD CONSTRAINT "venta_pagos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ventas"
    ADD CONSTRAINT "ventas_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_aperturas_caja_abierta_at" ON "public"."aperturas_caja" USING "btree" ("abierta_at" DESC);



CREATE INDEX "idx_auditoria_created_at" ON "public"."auditoria" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_auditoria_tabla_registro" ON "public"."auditoria" USING "btree" ("tabla_afectada", "registro_id");



CREATE INDEX "idx_auditoria_usuario" ON "public"."auditoria" USING "btree" ("usuario_id");



CREATE INDEX "idx_borradores_tipo_updated" ON "public"."borradores" USING "btree" ("tipo", "updated_at" DESC);



CREATE INDEX "idx_carga_inicial_items_codigo" ON "public"."carga_inicial_items" USING "btree" ("codigo_barras") WHERE ("codigo_barras" IS NOT NULL);



CREATE INDEX "idx_carga_inicial_items_usuario" ON "public"."carga_inicial_items" USING "btree" ("usuario_id");



CREATE INDEX "idx_carga_inicial_operaciones_usuario" ON "public"."carga_inicial_operaciones" USING "btree" ("usuario_id");



CREATE INDEX "idx_cierres_caja_fecha" ON "public"."cierres_caja" USING "btree" ("turno_fecha", "tipo");



CREATE INDEX "idx_devolucion_items_defectuosos" ON "public"."devolucion_items" USING "btree" ("devolucion_id") WHERE ("reingresa_stock" = false);



CREATE INDEX "idx_devolucion_items_devolucion" ON "public"."devolucion_items" USING "btree" ("devolucion_id");



CREATE INDEX "idx_devolucion_items_producto" ON "public"."devolucion_items" USING "btree" ("producto_id");



CREATE INDEX "idx_devolucion_pagos_devolucion" ON "public"."devolucion_pagos" USING "btree" ("devolucion_id");



CREATE INDEX "idx_devoluciones_fecha" ON "public"."devoluciones" USING "btree" ("fecha");



CREATE INDEX "idx_devoluciones_venta" ON "public"."devoluciones" USING "btree" ("venta_id");



CREATE INDEX "idx_egresos_pago_proveedor" ON "public"."egresos" USING "btree" ("pago_proveedor_id") WHERE ("pago_proveedor_id" IS NOT NULL);



CREATE INDEX "idx_facturas_compra_copiada_de" ON "public"."facturas_compra" USING "btree" ("copiada_de_id") WHERE ("copiada_de_id" IS NOT NULL);



CREATE INDEX "idx_facturas_compra_proveedor" ON "public"."facturas_compra" USING "btree" ("proveedor_id");



CREATE INDEX "idx_movimientos_cuenta_cuenta" ON "public"."movimientos_cuenta" USING "btree" ("cuenta_id");



CREATE INDEX "idx_movimientos_stock_producto" ON "public"."movimientos_stock" USING "btree" ("producto_id");



CREATE INDEX "idx_notas_internas_parent" ON "public"."notas_internas" USING "btree" ("parent_id");



CREATE INDEX "idx_pagos_cliente_aplicaciones_pago" ON "public"."pagos_cliente_aplicaciones" USING "btree" ("pago_cliente_id");



CREATE INDEX "idx_pagos_cliente_aplicaciones_venta" ON "public"."pagos_cliente_aplicaciones" USING "btree" ("venta_id");



CREATE INDEX "idx_pagos_cliente_cliente" ON "public"."pagos_cliente" USING "btree" ("cliente_id");



CREATE INDEX "idx_pagos_cliente_medios_pago" ON "public"."pagos_cliente_medios" USING "btree" ("pago_cliente_id");



CREATE INDEX "idx_pagos_proveedor_cheque_vencimiento" ON "public"."pagos_proveedor" USING "btree" ("cheque_fecha_vencimiento") WHERE ("forma_pago" = ANY (ARRAY['cheque'::"public"."forma_pago_egreso", 'echeq'::"public"."forma_pago_egreso"]));



CREATE INDEX "idx_pagos_proveedor_medios_cheques" ON "public"."pagos_proveedor_medios" USING "btree" ("fecha_pago") WHERE ("medio" = ANY (ARRAY['cheque'::"public"."forma_pago_egreso", 'echeq'::"public"."forma_pago_egreso"]));



CREATE INDEX "idx_pagos_proveedor_medios_pago" ON "public"."pagos_proveedor_medios" USING "btree" ("pago_proveedor_id");



CREATE INDEX "idx_ppa_factura" ON "public"."pagos_proveedor_aplicaciones" USING "btree" ("factura_compra_id");



CREATE INDEX "idx_ppa_nota_credito" ON "public"."pagos_proveedor_aplicaciones" USING "btree" ("nota_credito_id");



CREATE INDEX "idx_ppa_operacion" ON "public"."pagos_proveedor_aplicaciones" USING "btree" ("operacion_id");



CREATE INDEX "idx_ppa_pago" ON "public"."pagos_proveedor_aplicaciones" USING "btree" ("pago_proveedor_id");



CREATE INDEX "idx_precios_historial_fecha" ON "public"."productos_precios_historial" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_precios_historial_producto" ON "public"."productos_precios_historial" USING "btree" ("producto_id", "created_at" DESC);



CREATE INDEX "idx_productos_estado" ON "public"."productos" USING "btree" ("estado");



CREATE INDEX "idx_productos_proveedor" ON "public"."productos" USING "btree" ("proveedor_id");



CREATE INDEX "idx_retiros_caja_fecha" ON "public"."retiros_caja" USING "btree" ("fecha");



CREATE INDEX "idx_venta_items_producto" ON "public"."venta_items" USING "btree" ("producto_id");



CREATE INDEX "idx_venta_items_venta" ON "public"."venta_items" USING "btree" ("venta_id");



CREATE INDEX "idx_venta_pagos_venta" ON "public"."venta_pagos" USING "btree" ("venta_id");



CREATE INDEX "idx_ventas_cliente" ON "public"."ventas" USING "btree" ("cliente_id");



CREATE INDEX "idx_ventas_created_at" ON "public"."ventas" USING "btree" ("created_at");



CREATE INDEX "idx_ventas_estado" ON "public"."ventas" USING "btree" ("estado");



CREATE INDEX "idx_ventas_estado_interno" ON "public"."ventas" USING "btree" ("estado_interno") WHERE ("estado_interno" IS NOT NULL);



CREATE UNIQUE INDEX "uq_carga_inicial_items_usuario_codigo" ON "public"."carga_inicial_items" USING "btree" ("usuario_id", "codigo_barras") WHERE ("codigo_barras" IS NOT NULL);



CREATE UNIQUE INDEX "ux_aperturas_caja_abierta" ON "public"."aperturas_caja" USING "btree" ((true)) WHERE ("cierre_z_id" IS NULL);



CREATE UNIQUE INDEX "ux_cierres_caja_z_unico_por_dia" ON "public"."cierres_caja" USING "btree" ("turno_fecha") WHERE ("tipo" = 'z'::"public"."tipo_cierre");



CREATE UNIQUE INDEX "ux_clientes_perfil" ON "public"."clientes" USING "btree" ("perfil_id") WHERE ("perfil_id" IS NOT NULL);



CREATE UNIQUE INDEX "ux_egresos_pago_proveedor_medio" ON "public"."egresos" USING "btree" ("pago_proveedor_medio_id") WHERE (("pago_proveedor_medio_id" IS NOT NULL) AND ("revierte_egreso_id" IS NULL));



CREATE UNIQUE INDEX "ux_egresos_pago_proveedor_sin_medio" ON "public"."egresos" USING "btree" ("pago_proveedor_id") WHERE (("pago_proveedor_id" IS NOT NULL) AND ("pago_proveedor_medio_id" IS NULL) AND ("revierte_egreso_id" IS NULL));



CREATE UNIQUE INDEX "ux_movimientos_cuenta_saldo_inicial_por_cuenta" ON "public"."movimientos_cuenta" USING "btree" ("cuenta_id") WHERE ("tipo" = 'saldo_inicial'::"public"."tipo_movimiento_cuenta");



CREATE UNIQUE INDEX "ventas_client_id_unico" ON "public"."ventas" USING "btree" ("client_id") WHERE ("client_id" IS NOT NULL);



CREATE OR REPLACE VIEW "public"."cuentas_saldo" WITH ("security_invoker"='on') AS
 SELECT "c"."id",
    "c"."nombre",
    "c"."created_at",
    COALESCE("sum"("mc"."monto"), (0)::numeric) AS "saldo_actual"
   FROM ("public"."cuentas" "c"
     LEFT JOIN "public"."movimientos_cuenta" "mc" ON (("mc"."cuenta_id" = "c"."id")))
  GROUP BY "c"."id";



CREATE OR REPLACE TRIGGER "trg_auditoria_aperturas_caja" AFTER INSERT OR UPDATE ON "public"."aperturas_caja" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_carga_inicial_items" AFTER INSERT OR DELETE OR UPDATE ON "public"."carga_inicial_items" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_cierres_caja" AFTER UPDATE ON "public"."cierres_caja" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_clientes" AFTER INSERT OR DELETE OR UPDATE ON "public"."clientes" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_configuracion" AFTER INSERT OR UPDATE ON "public"."configuracion" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_devoluciones" AFTER INSERT ON "public"."devoluciones" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_egresos" AFTER INSERT OR DELETE OR UPDATE ON "public"."egresos" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_facturas_compra" AFTER INSERT OR UPDATE ON "public"."facturas_compra" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_movimientos_cuenta" AFTER INSERT ON "public"."movimientos_cuenta" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_movimientos_stock" AFTER INSERT ON "public"."movimientos_stock" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_pagos_cliente" AFTER INSERT OR DELETE OR UPDATE ON "public"."pagos_cliente" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_pagos_cliente_aplicaciones" AFTER INSERT OR UPDATE ON "public"."pagos_cliente_aplicaciones" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_pagos_proveedor" AFTER INSERT OR DELETE OR UPDATE ON "public"."pagos_proveedor" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_pagos_proveedor_aplicaciones" AFTER INSERT OR UPDATE ON "public"."pagos_proveedor_aplicaciones" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_productos" AFTER INSERT OR DELETE OR UPDATE ON "public"."productos" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_proveedores" AFTER INSERT OR DELETE OR UPDATE ON "public"."proveedores" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_retiros_caja" AFTER INSERT ON "public"."retiros_caja" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_stock_ubicaciones" AFTER UPDATE ON "public"."stock_ubicaciones" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_venta_items" AFTER DELETE OR UPDATE ON "public"."venta_items" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_ventas" AFTER INSERT OR DELETE OR UPDATE ON "public"."ventas" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_borradores_mantener" BEFORE INSERT OR UPDATE ON "public"."borradores" FOR EACH ROW EXECUTE FUNCTION "public"."borradores_mantener"();



CREATE OR REPLACE TRIGGER "trg_normalizar_descripcion_item_libre" BEFORE INSERT OR UPDATE ON "public"."facturas_compra_items" FOR EACH ROW EXECUTE FUNCTION "public"."normalizar_descripcion_item_libre"();



CREATE OR REPLACE TRIGGER "trg_normalizar_texto_carga_inicial" BEFORE INSERT OR UPDATE ON "public"."carga_inicial_items" FOR EACH ROW EXECUTE FUNCTION "public"."normalizar_texto_producto"();



CREATE OR REPLACE TRIGGER "trg_normalizar_texto_producto" BEFORE INSERT OR UPDATE ON "public"."productos" FOR EACH ROW EXECUTE FUNCTION "public"."normalizar_texto_producto"();



CREATE OR REPLACE TRIGGER "trg_notas_internas_archivar_hilo" AFTER UPDATE OF "archivada" ON "public"."notas_internas" FOR EACH ROW WHEN (("old"."archivada" IS DISTINCT FROM "new"."archivada")) EXECUTE FUNCTION "public"."notas_internas_archivar_hilo"();



CREATE OR REPLACE TRIGGER "trg_notas_internas_guardia" BEFORE INSERT OR UPDATE ON "public"."notas_internas" FOR EACH ROW EXECUTE FUNCTION "public"."notas_internas_guardia"();



CREATE OR REPLACE TRIGGER "trg_precio_historial_ins" AFTER INSERT ON "public"."productos" FOR EACH ROW EXECUTE FUNCTION "public"."fn_productos_precio_historial"();



CREATE OR REPLACE TRIGGER "trg_precio_historial_upd" AFTER UPDATE ON "public"."productos" FOR EACH ROW WHEN (("old"."precio_venta" IS DISTINCT FROM "new"."precio_venta")) EXECUTE FUNCTION "public"."fn_productos_precio_historial"();



CREATE OR REPLACE TRIGGER "trg_proteger_alta_producto" BEFORE INSERT ON "public"."productos" FOR EACH ROW EXECUTE FUNCTION "public"."fn_proteger_alta_producto"();



CREATE OR REPLACE TRIGGER "trg_proteger_eliminacion_cliente" BEFORE DELETE ON "public"."clientes" FOR EACH ROW EXECUTE FUNCTION "public"."fn_proteger_eliminacion_cliente"();



CREATE OR REPLACE TRIGGER "trg_proteger_eliminacion_proveedor" BEFORE DELETE ON "public"."proveedores" FOR EACH ROW EXECUTE FUNCTION "public"."fn_proteger_eliminacion_proveedor"();



CREATE OR REPLACE TRIGGER "trg_proteger_margen_producto" BEFORE UPDATE ON "public"."productos" FOR EACH ROW EXECUTE FUNCTION "public"."fn_proteger_margen_producto"();



CREATE OR REPLACE TRIGGER "trg_proteger_margen_proveedor" BEFORE UPDATE ON "public"."proveedores" FOR EACH ROW EXECUTE FUNCTION "public"."fn_proteger_margen_proveedor"();



CREATE OR REPLACE TRIGGER "trg_proteger_tipo_cliente" BEFORE INSERT OR UPDATE ON "public"."clientes" FOR EACH ROW EXECUTE FUNCTION "public"."fn_proteger_tipo_cliente"();



CREATE OR REPLACE TRIGGER "trg_proteger_tipo_compra" BEFORE UPDATE OF "tipo_compra" ON "public"."facturas_compra" FOR EACH ROW WHEN (("old"."tipo_compra" IS DISTINCT FROM "new"."tipo_compra")) EXECUTE FUNCTION "public"."proteger_tipo_compra"();



CREATE OR REPLACE TRIGGER "trg_sin_acentos" BEFORE INSERT OR UPDATE ON "public"."carga_inicial_items" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sin_acentos"('nombre', 'marca', 'descripcion');



CREATE OR REPLACE TRIGGER "trg_sin_acentos" BEFORE INSERT OR UPDATE ON "public"."clientes" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sin_acentos"('razon_social', 'nombre_fantasia', 'domicilio');



CREATE OR REPLACE TRIGGER "trg_sin_acentos" BEFORE INSERT OR UPDATE ON "public"."cuentas" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sin_acentos"('nombre');



CREATE OR REPLACE TRIGGER "trg_sin_acentos" BEFORE INSERT OR UPDATE ON "public"."devolucion_items" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sin_acentos"('producto_nombre', 'producto_marca');



CREATE OR REPLACE TRIGGER "trg_sin_acentos" BEFORE INSERT OR UPDATE ON "public"."devoluciones" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sin_acentos"('motivo_detalle', 'observaciones', 'motivo_anulacion');



CREATE OR REPLACE TRIGGER "trg_sin_acentos" BEFORE INSERT OR UPDATE ON "public"."egresos" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sin_acentos"('descripcion');



CREATE OR REPLACE TRIGGER "trg_sin_acentos" BEFORE INSERT OR UPDATE ON "public"."facturas_compra_items" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sin_acentos"('descripcion');



CREATE OR REPLACE TRIGGER "trg_sin_acentos" BEFORE INSERT OR UPDATE ON "public"."movimientos_cuenta" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sin_acentos"('descripcion');



CREATE OR REPLACE TRIGGER "trg_sin_acentos" BEFORE INSERT OR UPDATE ON "public"."movimientos_stock" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sin_acentos"('motivo');



CREATE OR REPLACE TRIGGER "trg_sin_acentos" BEFORE INSERT OR UPDATE ON "public"."notas_internas" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sin_acentos"('mensaje');



CREATE OR REPLACE TRIGGER "trg_sin_acentos" BEFORE INSERT OR UPDATE ON "public"."pagos_cliente" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sin_acentos"('nota');



CREATE OR REPLACE TRIGGER "trg_sin_acentos" BEFORE INSERT OR UPDATE ON "public"."pagos_proveedor" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sin_acentos"('nota');



CREATE OR REPLACE TRIGGER "trg_sin_acentos" BEFORE INSERT OR UPDATE ON "public"."pagos_proveedor_medios" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sin_acentos"('banco');



CREATE OR REPLACE TRIGGER "trg_sin_acentos" BEFORE INSERT OR UPDATE ON "public"."perfiles" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sin_acentos"('nombre');



CREATE OR REPLACE TRIGGER "trg_sin_acentos" BEFORE INSERT OR UPDATE ON "public"."productos" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sin_acentos"('nombre', 'marca', 'descripcion');



CREATE OR REPLACE TRIGGER "trg_sin_acentos" BEFORE INSERT OR UPDATE ON "public"."proveedores" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sin_acentos"('razon_social', 'contacto', 'direccion', 'observaciones');



CREATE OR REPLACE TRIGGER "trg_sin_acentos" BEFORE INSERT OR UPDATE ON "public"."venta_items" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sin_acentos"('producto_nombre', 'producto_marca');



CREATE OR REPLACE TRIGGER "trg_sin_acentos" BEFORE INSERT OR UPDATE ON "public"."ventas" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sin_acentos"('nota', 'reabierta_motivo');



ALTER TABLE ONLY "public"."aperturas_caja"
    ADD CONSTRAINT "aperturas_caja_cierre_z_id_fkey" FOREIGN KEY ("cierre_z_id") REFERENCES "public"."cierres_caja"("id");



ALTER TABLE ONLY "public"."aperturas_caja"
    ADD CONSTRAINT "aperturas_caja_cierre_z_previo_id_fkey" FOREIGN KEY ("cierre_z_previo_id") REFERENCES "public"."cierres_caja"("id");



ALTER TABLE ONLY "public"."aperturas_caja"
    ADD CONSTRAINT "aperturas_caja_revisada_por_fkey" FOREIGN KEY ("revisada_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."aperturas_caja"
    ADD CONSTRAINT "aperturas_caja_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."auditoria"
    ADD CONSTRAINT "auditoria_revierte_auditoria_id_fkey" FOREIGN KEY ("revierte_auditoria_id") REFERENCES "public"."auditoria"("id");



ALTER TABLE ONLY "public"."auditoria"
    ADD CONSTRAINT "auditoria_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."borradores"
    ADD CONSTRAINT "borradores_actualizado_por_fkey" FOREIGN KEY ("actualizado_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."borradores"
    ADD CONSTRAINT "borradores_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."carga_inicial_items"
    ADD CONSTRAINT "carga_inicial_items_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."carga_inicial_items"
    ADD CONSTRAINT "carga_inicial_items_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."carga_inicial_operaciones"
    ADD CONSTRAINT "carga_inicial_operaciones_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."cierres_caja"
    ADD CONSTRAINT "cierres_caja_apertura_id_fkey" FOREIGN KEY ("apertura_id") REFERENCES "public"."aperturas_caja"("id");



ALTER TABLE ONLY "public"."cierres_caja"
    ADD CONSTRAINT "cierres_caja_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."cierres_caja"
    ADD CONSTRAINT "cierres_caja_validado_por_fkey" FOREIGN KEY ("validado_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."clientes"
    ADD CONSTRAINT "clientes_perfil_id_fkey" FOREIGN KEY ("perfil_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."configuracion"
    ADD CONSTRAINT "configuracion_abierta_por_fkey" FOREIGN KEY ("abierta_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."configuracion"
    ADD CONSTRAINT "configuracion_cerrada_por_fkey" FOREIGN KEY ("cerrada_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."cuenta_forma_pago"
    ADD CONSTRAINT "cuenta_forma_pago_cuenta_id_fkey" FOREIGN KEY ("cuenta_id") REFERENCES "public"."cuentas"("id");



ALTER TABLE ONLY "public"."devolucion_items"
    ADD CONSTRAINT "devolucion_items_devolucion_id_fkey" FOREIGN KEY ("devolucion_id") REFERENCES "public"."devoluciones"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."devolucion_items"
    ADD CONSTRAINT "devolucion_items_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id");



ALTER TABLE ONLY "public"."devolucion_pagos"
    ADD CONSTRAINT "devolucion_pagos_devolucion_id_fkey" FOREIGN KEY ("devolucion_id") REFERENCES "public"."devoluciones"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."devoluciones"
    ADD CONSTRAINT "devoluciones_anulada_por_fkey" FOREIGN KEY ("anulada_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."devoluciones"
    ADD CONSTRAINT "devoluciones_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."devoluciones"
    ADD CONSTRAINT "devoluciones_venta_id_fkey" FOREIGN KEY ("venta_id") REFERENCES "public"."ventas"("id");



ALTER TABLE ONLY "public"."egresos"
    ADD CONSTRAINT "egresos_cierre_caja_id_fkey" FOREIGN KEY ("cierre_caja_id") REFERENCES "public"."cierres_caja"("id");



ALTER TABLE ONLY "public"."egresos"
    ADD CONSTRAINT "egresos_pago_proveedor_id_fkey" FOREIGN KEY ("pago_proveedor_id") REFERENCES "public"."pagos_proveedor"("id");



ALTER TABLE ONLY "public"."egresos"
    ADD CONSTRAINT "egresos_pago_proveedor_medio_id_fkey" FOREIGN KEY ("pago_proveedor_medio_id") REFERENCES "public"."pagos_proveedor_medios"("id");



ALTER TABLE ONLY "public"."egresos"
    ADD CONSTRAINT "egresos_revierte_egreso_id_fkey" FOREIGN KEY ("revierte_egreso_id") REFERENCES "public"."egresos"("id");



ALTER TABLE ONLY "public"."egresos"
    ADD CONSTRAINT "egresos_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."emisiones_factura_c_en_curso"
    ADD CONSTRAINT "emisiones_factura_c_en_curso_registrado_por_fkey" FOREIGN KEY ("registrado_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."emisiones_factura_c_en_curso"
    ADD CONSTRAINT "emisiones_factura_c_en_curso_revisar_detectado_por_fkey" FOREIGN KEY ("revisar_detectado_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."emisiones_factura_c_en_curso"
    ADD CONSTRAINT "emisiones_factura_c_en_curso_tomada_por_fkey" FOREIGN KEY ("tomada_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."emisiones_factura_c_en_curso"
    ADD CONSTRAINT "emisiones_factura_c_en_curso_venta_id_fkey" FOREIGN KEY ("venta_id") REFERENCES "public"."ventas"("id");



ALTER TABLE ONLY "public"."facturas_c"
    ADD CONSTRAINT "facturas_c_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."facturas_c"
    ADD CONSTRAINT "facturas_c_venta_id_fkey" FOREIGN KEY ("venta_id") REFERENCES "public"."ventas"("id");



ALTER TABLE ONLY "public"."facturas_compra"
    ADD CONSTRAINT "facturas_compra_copiada_de_id_fkey" FOREIGN KEY ("copiada_de_id") REFERENCES "public"."facturas_compra"("id");



ALTER TABLE ONLY "public"."facturas_compra_items"
    ADD CONSTRAINT "facturas_compra_items_factura_compra_id_fkey" FOREIGN KEY ("factura_compra_id") REFERENCES "public"."facturas_compra"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."facturas_compra_items"
    ADD CONSTRAINT "facturas_compra_items_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id");



ALTER TABLE ONLY "public"."facturas_compra"
    ADD CONSTRAINT "facturas_compra_proveedor_id_fkey" FOREIGN KEY ("proveedor_id") REFERENCES "public"."proveedores"("id");



ALTER TABLE ONLY "public"."facturas_compra"
    ADD CONSTRAINT "facturas_compra_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."movimientos_cuenta"
    ADD CONSTRAINT "movimientos_cuenta_cuenta_id_fkey" FOREIGN KEY ("cuenta_id") REFERENCES "public"."cuentas"("id");



ALTER TABLE ONLY "public"."movimientos_cuenta"
    ADD CONSTRAINT "movimientos_cuenta_revierte_movimiento_id_fkey" FOREIGN KEY ("revierte_movimiento_id") REFERENCES "public"."movimientos_cuenta"("id");



ALTER TABLE ONLY "public"."movimientos_cuenta"
    ADD CONSTRAINT "movimientos_cuenta_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."movimientos_stock"
    ADD CONSTRAINT "movimientos_stock_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id");



ALTER TABLE ONLY "public"."movimientos_stock"
    ADD CONSTRAINT "movimientos_stock_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."notas_internas"
    ADD CONSTRAINT "notas_internas_archivada_por_fkey" FOREIGN KEY ("archivada_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."notas_internas"
    ADD CONSTRAINT "notas_internas_autor_id_fkey" FOREIGN KEY ("autor_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."notas_internas"
    ADD CONSTRAINT "notas_internas_parent_id_fkey" FOREIGN KEY ("parent_id") REFERENCES "public"."notas_internas"("id");



ALTER TABLE ONLY "public"."pagos_cliente_aplicaciones"
    ADD CONSTRAINT "pagos_cliente_aplicaciones_pago_cliente_id_fkey" FOREIGN KEY ("pago_cliente_id") REFERENCES "public"."pagos_cliente"("id");



ALTER TABLE ONLY "public"."pagos_cliente_aplicaciones"
    ADD CONSTRAINT "pagos_cliente_aplicaciones_revertida_por_fkey" FOREIGN KEY ("revertida_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."pagos_cliente_aplicaciones"
    ADD CONSTRAINT "pagos_cliente_aplicaciones_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."pagos_cliente_aplicaciones"
    ADD CONSTRAINT "pagos_cliente_aplicaciones_venta_id_fkey" FOREIGN KEY ("venta_id") REFERENCES "public"."ventas"("id");



ALTER TABLE ONLY "public"."pagos_cliente"
    ADD CONSTRAINT "pagos_cliente_cliente_id_fkey" FOREIGN KEY ("cliente_id") REFERENCES "public"."clientes"("id");



ALTER TABLE ONLY "public"."pagos_cliente_medios"
    ADD CONSTRAINT "pagos_cliente_medios_pago_cliente_id_fkey" FOREIGN KEY ("pago_cliente_id") REFERENCES "public"."pagos_cliente"("id");



ALTER TABLE ONLY "public"."pagos_cliente_medios"
    ADD CONSTRAINT "pagos_cliente_medios_revierte_medio_id_fkey" FOREIGN KEY ("revierte_medio_id") REFERENCES "public"."pagos_cliente_medios"("id");



ALTER TABLE ONLY "public"."pagos_cliente"
    ADD CONSTRAINT "pagos_cliente_revierte_pago_cliente_id_fkey" FOREIGN KEY ("revierte_pago_cliente_id") REFERENCES "public"."pagos_cliente"("id");



ALTER TABLE ONLY "public"."pagos_cliente"
    ADD CONSTRAINT "pagos_cliente_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."pagos_cliente"
    ADD CONSTRAINT "pagos_cliente_venta_id_fkey" FOREIGN KEY ("venta_id") REFERENCES "public"."ventas"("id");



ALTER TABLE ONLY "public"."pagos_proveedor_aplicaciones"
    ADD CONSTRAINT "pagos_proveedor_aplicaciones_factura_compra_id_fkey" FOREIGN KEY ("factura_compra_id") REFERENCES "public"."facturas_compra"("id");



ALTER TABLE ONLY "public"."pagos_proveedor_aplicaciones"
    ADD CONSTRAINT "pagos_proveedor_aplicaciones_nota_credito_id_fkey" FOREIGN KEY ("nota_credito_id") REFERENCES "public"."facturas_compra"("id");



ALTER TABLE ONLY "public"."pagos_proveedor_aplicaciones"
    ADD CONSTRAINT "pagos_proveedor_aplicaciones_operacion_id_fkey" FOREIGN KEY ("operacion_id") REFERENCES "public"."pagos_proveedor"("id");



ALTER TABLE ONLY "public"."pagos_proveedor_aplicaciones"
    ADD CONSTRAINT "pagos_proveedor_aplicaciones_pago_proveedor_id_fkey" FOREIGN KEY ("pago_proveedor_id") REFERENCES "public"."pagos_proveedor"("id");



ALTER TABLE ONLY "public"."pagos_proveedor_aplicaciones"
    ADD CONSTRAINT "pagos_proveedor_aplicaciones_revertida_por_fkey" FOREIGN KEY ("revertida_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."pagos_proveedor_aplicaciones"
    ADD CONSTRAINT "pagos_proveedor_aplicaciones_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."pagos_proveedor"
    ADD CONSTRAINT "pagos_proveedor_factura_compra_id_fkey" FOREIGN KEY ("factura_compra_id") REFERENCES "public"."facturas_compra"("id");



ALTER TABLE ONLY "public"."pagos_proveedor_medios"
    ADD CONSTRAINT "pagos_proveedor_medios_pago_proveedor_id_fkey" FOREIGN KEY ("pago_proveedor_id") REFERENCES "public"."pagos_proveedor"("id");



ALTER TABLE ONLY "public"."pagos_proveedor_medios"
    ADD CONSTRAINT "pagos_proveedor_medios_revierte_medio_id_fkey" FOREIGN KEY ("revierte_medio_id") REFERENCES "public"."pagos_proveedor_medios"("id");



ALTER TABLE ONLY "public"."pagos_proveedor"
    ADD CONSTRAINT "pagos_proveedor_proveedor_id_fkey" FOREIGN KEY ("proveedor_id") REFERENCES "public"."proveedores"("id");



ALTER TABLE ONLY "public"."pagos_proveedor"
    ADD CONSTRAINT "pagos_proveedor_revierte_pago_proveedor_id_fkey" FOREIGN KEY ("revierte_pago_proveedor_id") REFERENCES "public"."pagos_proveedor"("id");



ALTER TABLE ONLY "public"."pagos_proveedor"
    ADD CONSTRAINT "pagos_proveedor_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."perfiles"
    ADD CONSTRAINT "perfiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."productos_etiqueta"
    ADD CONSTRAINT "productos_etiqueta_marcado_por_fkey" FOREIGN KEY ("marcado_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."productos_etiqueta"
    ADD CONSTRAINT "productos_etiqueta_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."productos_precios_historial"
    ADD CONSTRAINT "productos_precios_historial_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."productos"
    ADD CONSTRAINT "productos_proveedor_id_fkey" FOREIGN KEY ("proveedor_id") REFERENCES "public"."proveedores"("id");



ALTER TABLE ONLY "public"."retiros_caja"
    ADD CONSTRAINT "retiros_caja_admin_receptor_id_fkey" FOREIGN KEY ("admin_receptor_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."retiros_caja"
    ADD CONSTRAINT "retiros_caja_cajero_id_fkey" FOREIGN KEY ("cajero_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."retiros_caja"
    ADD CONSTRAINT "retiros_caja_movimiento_cuenta_id_fkey" FOREIGN KEY ("movimiento_cuenta_id") REFERENCES "public"."movimientos_cuenta"("id");



ALTER TABLE ONLY "public"."retiros_caja"
    ADD CONSTRAINT "retiros_caja_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."stock_ubicaciones"
    ADD CONSTRAINT "stock_ubicaciones_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."venta_items"
    ADD CONSTRAINT "venta_items_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id");



ALTER TABLE ONLY "public"."venta_items"
    ADD CONSTRAINT "venta_items_venta_id_fkey" FOREIGN KEY ("venta_id") REFERENCES "public"."ventas"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."venta_pagos"
    ADD CONSTRAINT "venta_pagos_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."venta_pagos"
    ADD CONSTRAINT "venta_pagos_venta_id_fkey" FOREIGN KEY ("venta_id") REFERENCES "public"."ventas"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ventas"
    ADD CONSTRAINT "ventas_cliente_id_fkey" FOREIGN KEY ("cliente_id") REFERENCES "public"."clientes"("id");



ALTER TABLE ONLY "public"."ventas"
    ADD CONSTRAINT "ventas_editada_por_fkey" FOREIGN KEY ("editada_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."ventas"
    ADD CONSTRAINT "ventas_finalizada_por_fkey" FOREIGN KEY ("finalizada_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."ventas"
    ADD CONSTRAINT "ventas_reabierta_por_fkey" FOREIGN KEY ("reabierta_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."ventas"
    ADD CONSTRAINT "ventas_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE "public"."aperturas_caja" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "aperturas_ver_todos" ON "public"."aperturas_caja" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."arca_wsaa_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."auditoria" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "auditoria_select_solo_admin" ON "public"."auditoria" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'admin'::"public"."rol_usuario")))));



ALTER TABLE "public"."borradores" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "borradores_delete" ON "public"."borradores" FOR DELETE USING (((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("perfiles"."activo" = true)))) AND (("public"."app_cliente"() IS NULL) OR ("public"."app_cliente"() = "sistema"))));



CREATE POLICY "borradores_insert" ON "public"."borradores" FOR INSERT WITH CHECK (((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("perfiles"."activo" = true)))) AND ("usuario_id" = ( SELECT "auth"."uid"() AS "uid")) AND (("public"."app_cliente"() IS NULL) OR ("public"."app_cliente"() = "sistema"))));



CREATE POLICY "borradores_select" ON "public"."borradores" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("perfiles"."activo" = true)))));



CREATE POLICY "borradores_update" ON "public"."borradores" FOR UPDATE USING (((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("perfiles"."activo" = true)))) AND (("public"."app_cliente"() IS NULL) OR ("public"."app_cliente"() = "sistema")))) WITH CHECK (((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("perfiles"."activo" = true)))) AND (("public"."app_cliente"() IS NULL) OR ("public"."app_cliente"() = "sistema"))));



ALTER TABLE "public"."carga_inicial_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "carga_inicial_items_propios" ON "public"."carga_inicial_items" USING ((("usuario_id" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))))) WITH CHECK ((("usuario_id" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true))))));



ALTER TABLE "public"."carga_inicial_operaciones" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "carga_inicial_operaciones_propias" ON "public"."carga_inicial_operaciones" FOR SELECT USING (("usuario_id" = "auth"."uid"()));



ALTER TABLE "public"."cierres_caja" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cierres_validar_solo_admin" ON "public"."cierres_caja" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'admin'::"public"."rol_usuario")))));



CREATE POLICY "cierres_ver_todos" ON "public"."cierres_caja" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."clientes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "clientes_todos" ON "public"."clientes" USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."configuracion" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "configuracion_select" ON "public"."configuracion" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."cuenta_forma_pago" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cuenta_forma_pago_solo_admin" ON "public"."cuenta_forma_pago" USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'admin'::"public"."rol_usuario")))));



ALTER TABLE "public"."cuentas" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cuentas_solo_admin" ON "public"."cuentas" USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'admin'::"public"."rol_usuario")))));



ALTER TABLE "public"."devolucion_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "devolucion_items_ver_todos" ON "public"."devolucion_items" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."devolucion_pagos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "devolucion_pagos_ver_todos" ON "public"."devolucion_pagos" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."devoluciones" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "devoluciones_ver_todos" ON "public"."devoluciones" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."egresos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "egresos_select" ON "public"."egresos" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."emisiones_factura_c_en_curso" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "emisiones_factura_c_en_curso_select" ON "public"."emisiones_factura_c_en_curso" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."facturas_c" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "facturas_c_select" ON "public"."facturas_c" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."facturas_compra" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."facturas_compra_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "facturas_compra_items_select" ON "public"."facturas_compra_items" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



CREATE POLICY "facturas_compra_select" ON "public"."facturas_compra" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."movimientos_cuenta" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "movimientos_cuenta_select_admin" ON "public"."movimientos_cuenta" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'admin'::"public"."rol_usuario")))));



ALTER TABLE "public"."movimientos_stock" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "movimientos_stock_select" ON "public"."movimientos_stock" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."notas_internas" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "notas_internas_insert" ON "public"."notas_internas" FOR INSERT WITH CHECK ((("autor_id" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))) AND (("origen" = 'local'::"text") OR (EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'admin'::"public"."rol_usuario")))))));



CREATE POLICY "notas_internas_select" ON "public"."notas_internas" FOR SELECT USING (((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))) AND (("origen" = 'local'::"text") OR (EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'admin'::"public"."rol_usuario")))))));



CREATE POLICY "notas_internas_update" ON "public"."notas_internas" FOR UPDATE USING (((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))) AND (("origen" = 'local'::"text") OR (EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'admin'::"public"."rol_usuario"))))))) WITH CHECK (((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))) AND (("origen" = 'local'::"text") OR (EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'admin'::"public"."rol_usuario")))))));



ALTER TABLE "public"."pagos_cliente" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pagos_cliente_aplicaciones" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "pagos_cliente_aplicaciones_select" ON "public"."pagos_cliente_aplicaciones" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."pagos_cliente_medios" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "pagos_cliente_medios_select" ON "public"."pagos_cliente_medios" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



CREATE POLICY "pagos_cliente_select" ON "public"."pagos_cliente" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."pagos_proveedor" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pagos_proveedor_aplicaciones" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "pagos_proveedor_aplicaciones_select" ON "public"."pagos_proveedor_aplicaciones" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."pagos_proveedor_medios" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "pagos_proveedor_medios_select" ON "public"."pagos_proveedor_medios" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



CREATE POLICY "pagos_proveedor_select" ON "public"."pagos_proveedor" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



CREATE POLICY "perfil_propio" ON "public"."perfiles" FOR SELECT USING (("auth"."uid"() = "id"));



ALTER TABLE "public"."perfiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."productos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."productos_etiqueta" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "productos_etiqueta_select" ON "public"."productos_etiqueta" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



CREATE POLICY "productos_insert" ON "public"."productos" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."productos_precios_historial" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "productos_precios_historial_select" ON "public"."productos_precios_historial" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



CREATE POLICY "productos_select" ON "public"."productos" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



CREATE POLICY "productos_update" ON "public"."productos" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."proveedores" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "proveedores_delete_solo_admin" ON "public"."proveedores" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'admin'::"public"."rol_usuario") AND ("perfiles"."activo" = true)))));



CREATE POLICY "proveedores_insert" ON "public"."proveedores" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



CREATE POLICY "proveedores_select" ON "public"."proveedores" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



CREATE POLICY "proveedores_update" ON "public"."proveedores" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."retiros_caja" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "retiros_caja_select" ON "public"."retiros_caja" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."stock_ubicaciones" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "stock_ubicaciones_select" ON "public"."stock_ubicaciones" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."venta_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "venta_items_select" ON "public"."venta_items" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."venta_pagos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "venta_pagos_select" ON "public"."venta_pagos" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."ventas" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ventas_select" ON "public"."ventas" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






















































































































































REVOKE ALL ON FUNCTION "public"."abrir_caja"("p_monto_real" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."abrir_caja"("p_monto_real" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."abrir_caja"("p_monto_real" numeric) TO "service_role";



GRANT ALL ON TABLE "public"."configuracion" TO "authenticated";
GRANT ALL ON TABLE "public"."configuracion" TO "service_role";



REVOKE ALL ON FUNCTION "public"."abrir_carga_inicial"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."abrir_carga_inicial"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."abrir_carga_inicial"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."actualizar_precios_masivo"("p_porcentaje" numeric, "p_proveedor_id" "uuid", "p_producto_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."actualizar_precios_masivo"("p_porcentaje" numeric, "p_proveedor_id" "uuid", "p_producto_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."actualizar_precios_masivo"("p_porcentaje" numeric, "p_proveedor_id" "uuid", "p_producto_ids" "uuid"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."agregar_nota_correccion"("p_cierre_id" "uuid", "p_nota" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."agregar_nota_correccion"("p_cierre_id" "uuid", "p_nota" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."agregar_nota_correccion"("p_cierre_id" "uuid", "p_nota" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."ajustar_stock"("p_producto_id" "uuid", "p_ubicacion" "public"."ubicacion_stock", "p_cantidad" numeric, "p_motivo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ajustar_stock"("p_producto_id" "uuid", "p_ubicacion" "public"."ubicacion_stock", "p_cantidad" numeric, "p_motivo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ajustar_stock"("p_producto_id" "uuid", "p_ubicacion" "public"."ubicacion_stock", "p_cantidad" numeric, "p_motivo" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."alerta_precios_pendientes"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."alerta_precios_pendientes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."alerta_precios_pendientes"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."anular_devolucion"("p_devolucion_id" "uuid", "p_motivo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."anular_devolucion"("p_devolucion_id" "uuid", "p_motivo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."anular_devolucion"("p_devolucion_id" "uuid", "p_motivo" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."anular_factura_compra"("p_factura_id" "uuid", "p_motivo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."anular_factura_compra"("p_factura_id" "uuid", "p_motivo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."anular_factura_compra"("p_factura_id" "uuid", "p_motivo" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."anular_venta"("p_venta_id" "uuid", "p_motivo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."anular_venta"("p_venta_id" "uuid", "p_motivo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."anular_venta"("p_venta_id" "uuid", "p_motivo" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."aperturas_con_diferencia_pendientes"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."aperturas_con_diferencia_pendientes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."aperturas_con_diferencia_pendientes"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."aplicar_cobros_a_cuenta"("p_cliente_id" "uuid", "p_venta_ids" "uuid"[], "p_pago_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."aplicar_cobros_a_cuenta"("p_cliente_id" "uuid", "p_venta_ids" "uuid"[], "p_pago_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."aplicar_cobros_a_cuenta"("p_cliente_id" "uuid", "p_venta_ids" "uuid"[], "p_pago_ids" "uuid"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."aplicar_costo_vinculo_item"("p_item_id" "uuid", "p_producto_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."aplicar_costo_vinculo_item"("p_item_id" "uuid", "p_producto_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."aplicar_pagos_a_cuenta"("p_proveedor_id" "uuid", "p_factura_ids" "uuid"[], "p_pago_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."aplicar_pagos_a_cuenta"("p_proveedor_id" "uuid", "p_factura_ids" "uuid"[], "p_pago_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."aplicar_pagos_a_cuenta"("p_proveedor_id" "uuid", "p_factura_ids" "uuid"[], "p_pago_ids" "uuid"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."app_cliente"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."app_cliente"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."app_cliente"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."archivar_nota"("p_nota_id" "uuid", "p_archivar" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."archivar_nota"("p_nota_id" "uuid", "p_archivar" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."archivar_nota"("p_nota_id" "uuid", "p_archivar" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."borradores_mantener"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."borradores_mantener"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."carga_inicial_buscar_codigo"("p_codigo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."carga_inicial_buscar_codigo"("p_codigo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."carga_inicial_buscar_codigo"("p_codigo" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."carga_inicial_editar_producto"("p_client_id" "uuid", "p_producto_id" "uuid", "p_nombre" "text", "p_marca" "text", "p_descripcion" "text", "p_precio" numeric, "p_cantidad_local" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."carga_inicial_editar_producto"("p_client_id" "uuid", "p_producto_id" "uuid", "p_nombre" "text", "p_marca" "text", "p_descripcion" "text", "p_precio" numeric, "p_cantidad_local" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."carga_inicial_editar_producto"("p_client_id" "uuid", "p_producto_id" "uuid", "p_nombre" "text", "p_marca" "text", "p_descripcion" "text", "p_precio" numeric, "p_cantidad_local" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "public"."carga_inicial_eliminar_item"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."carga_inicial_eliminar_item"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."carga_inicial_eliminar_item"("p_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."carga_inicial_finalizar"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."carga_inicial_finalizar"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."carga_inicial_finalizar"() TO "service_role";



GRANT ALL ON TABLE "public"."carga_inicial_items" TO "authenticated";
GRANT ALL ON TABLE "public"."carga_inicial_items" TO "service_role";



REVOKE ALL ON FUNCTION "public"."carga_inicial_guardar_item"("p_client_id" "uuid", "p_codigo_barras" "text", "p_nombre" "text", "p_marca" "text", "p_descripcion" "text", "p_precio" numeric, "p_cantidad" numeric, "p_accion" "text", "p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."carga_inicial_guardar_item"("p_client_id" "uuid", "p_codigo_barras" "text", "p_nombre" "text", "p_marca" "text", "p_descripcion" "text", "p_precio" numeric, "p_cantidad" numeric, "p_accion" "text", "p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."carga_inicial_guardar_item"("p_client_id" "uuid", "p_codigo_barras" "text", "p_nombre" "text", "p_marca" "text", "p_descripcion" "text", "p_precio" numeric, "p_cantidad" numeric, "p_accion" "text", "p_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."carga_inicial_producto_por_codigo"("p_codigo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."carga_inicial_producto_por_codigo"("p_codigo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."carga_inicial_producto_por_codigo"("p_codigo" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."carga_inicial_reclamar_operacion"("p_client_id" "uuid", "p_operacion" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."carga_inicial_reclamar_operacion"("p_client_id" "uuid", "p_operacion" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."carga_inicial_resumen"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."carga_inicial_resumen"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."carga_inicial_resumen"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."carga_inicial_verificar_acceso"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."carga_inicial_verificar_acceso"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."cargar_factura_compra"("p_proveedor_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_forma_pago" "public"."forma_pago_compra", "p_items" "jsonb", "p_copiada_de_id" "uuid", "p_iva_alicuota" numeric, "p_tipo_compra" "text", "p_borrador_id" "uuid", "p_devuelve_mercaderia" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cargar_factura_compra"("p_proveedor_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_forma_pago" "public"."forma_pago_compra", "p_items" "jsonb", "p_copiada_de_id" "uuid", "p_iva_alicuota" numeric, "p_tipo_compra" "text", "p_borrador_id" "uuid", "p_devuelve_mercaderia" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cargar_factura_compra"("p_proveedor_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_forma_pago" "public"."forma_pago_compra", "p_items" "jsonb", "p_copiada_de_id" "uuid", "p_iva_alicuota" numeric, "p_tipo_compra" "text", "p_borrador_id" "uuid", "p_devuelve_mercaderia" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."cargar_factura_compra_contado"("p_proveedor_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_items" "jsonb", "p_origen" "public"."origen_egreso", "p_copiada_de_id" "uuid", "p_iva_alicuota" numeric, "p_tipo_compra" "text", "p_borrador_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cargar_factura_compra_contado"("p_proveedor_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_items" "jsonb", "p_origen" "public"."origen_egreso", "p_copiada_de_id" "uuid", "p_iva_alicuota" numeric, "p_tipo_compra" "text", "p_borrador_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cargar_factura_compra_contado"("p_proveedor_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_items" "jsonb", "p_origen" "public"."origen_egreso", "p_copiada_de_id" "uuid", "p_iva_alicuota" numeric, "p_tipo_compra" "text", "p_borrador_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."cargar_saldos_iniciales"("p_saldos_cuentas" "jsonb", "p_saldos_proveedores" "jsonb", "p_saldos_clientes" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cargar_saldos_iniciales"("p_saldos_cuentas" "jsonb", "p_saldos_proveedores" "jsonb", "p_saldos_clientes" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cargar_saldos_iniciales"("p_saldos_cuentas" "jsonb", "p_saldos_proveedores" "jsonb", "p_saldos_clientes" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."cerrar_caja"("p_tipo" "public"."tipo_cierre", "p_efectivo_contado" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cerrar_caja"("p_tipo" "public"."tipo_cierre", "p_efectivo_contado" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cerrar_caja"("p_tipo" "public"."tipo_cierre", "p_efectivo_contado" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "public"."cerrar_carga_inicial"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cerrar_carga_inicial"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cerrar_carga_inicial"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."codigo_barras_variantes"("p_codigo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."codigo_barras_variantes"("p_codigo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."codigo_barras_variantes"("p_codigo" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."confirmar_venta"("p_cliente_id" "uuid", "p_forma_pago" "public"."forma_pago_venta", "p_items" "jsonb", "p_descuento_porcentaje" numeric, "p_nota" "text", "p_recargo_porcentaje" numeric, "p_pagos" "jsonb", "p_precio_cobrado" numeric, "p_client_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."confirmar_venta"("p_cliente_id" "uuid", "p_forma_pago" "public"."forma_pago_venta", "p_items" "jsonb", "p_descuento_porcentaje" numeric, "p_nota" "text", "p_recargo_porcentaje" numeric, "p_pagos" "jsonb", "p_precio_cobrado" numeric, "p_client_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."confirmar_venta"("p_cliente_id" "uuid", "p_forma_pago" "public"."forma_pago_venta", "p_items" "jsonb", "p_descuento_porcentaje" numeric, "p_nota" "text", "p_recargo_porcentaje" numeric, "p_pagos" "jsonb", "p_precio_cobrado" numeric, "p_client_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."crear_devolucion"("p_venta_id" "uuid", "p_motivo" "public"."motivo_devolucion", "p_motivo_detalle" "text", "p_observaciones" "text", "p_items_devueltos" "jsonb", "p_items_nuevos" "jsonb", "p_forma_pago" "public"."forma_pago_venta", "p_pagos" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."crear_devolucion"("p_venta_id" "uuid", "p_motivo" "public"."motivo_devolucion", "p_motivo_detalle" "text", "p_observaciones" "text", "p_items_devueltos" "jsonb", "p_items_nuevos" "jsonb", "p_forma_pago" "public"."forma_pago_venta", "p_pagos" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."crear_devolucion"("p_venta_id" "uuid", "p_motivo" "public"."motivo_devolucion", "p_motivo_detalle" "text", "p_observaciones" "text", "p_items_devueltos" "jsonb", "p_items_nuevos" "jsonb", "p_forma_pago" "public"."forma_pago_venta", "p_pagos" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."credito_devoluciones_venta"("p_venta_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."credito_devoluciones_venta"("p_venta_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."credito_devoluciones_venta"("p_venta_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."dashboard_consumo_interno"("p_desde" "date", "p_hasta" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."dashboard_consumo_interno"("p_desde" "date", "p_hasta" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."dashboard_consumo_interno"("p_desde" "date", "p_hasta" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."dashboard_ventas_por_dia"("p_desde" "date", "p_hasta" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."dashboard_ventas_por_dia"("p_desde" "date", "p_hasta" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."dashboard_ventas_por_dia"("p_desde" "date", "p_hasta" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."dashboard_ventas_por_producto"("p_desde" "date", "p_hasta" "date", "p_ant_desde" "date", "p_ant_hasta" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."dashboard_ventas_por_producto"("p_desde" "date", "p_hasta" "date", "p_ant_desde" "date", "p_ant_hasta" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."dashboard_ventas_por_producto"("p_desde" "date", "p_hasta" "date", "p_ant_desde" "date", "p_ant_hasta" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."desaplicar_cobro"("p_aplicacion_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."desaplicar_cobro"("p_aplicacion_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."desaplicar_cobro"("p_aplicacion_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."desaplicar_pago"("p_aplicacion_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."desaplicar_pago"("p_aplicacion_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."desaplicar_pago"("p_aplicacion_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."desbloquear_emision_factura_c"("p_venta_id" "uuid", "p_nota" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."desbloquear_emision_factura_c"("p_venta_id" "uuid", "p_nota" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."desbloquear_emision_factura_c"("p_venta_id" "uuid", "p_nota" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."ean13_digito_verificador"("p_doce" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ean13_digito_verificador"("p_doce" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ean13_digito_verificador"("p_doce" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."editar_factura_compra"("p_factura_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_forma_pago" "public"."forma_pago_compra", "p_iva_alicuota" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."editar_factura_compra"("p_factura_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_forma_pago" "public"."forma_pago_compra", "p_iva_alicuota" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."editar_factura_compra"("p_factura_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_forma_pago" "public"."forma_pago_compra", "p_iva_alicuota" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "public"."editar_movimiento_cuenta"("p_movimiento_id" "uuid", "p_monto_nuevo" numeric, "p_descripcion_nueva" "text", "p_motivo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."editar_movimiento_cuenta"("p_movimiento_id" "uuid", "p_monto_nuevo" numeric, "p_descripcion_nueva" "text", "p_motivo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."editar_movimiento_cuenta"("p_movimiento_id" "uuid", "p_monto_nuevo" numeric, "p_descripcion_nueva" "text", "p_motivo" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."editar_nota"("p_nota_id" "uuid", "p_mensaje" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."editar_nota"("p_nota_id" "uuid", "p_mensaje" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."editar_nota"("p_nota_id" "uuid", "p_mensaje" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."editar_usuario"("p_user_id" "uuid", "p_nombre" "text", "p_rol" "public"."rol_usuario") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."editar_usuario"("p_user_id" "uuid", "p_nombre" "text", "p_rol" "public"."rol_usuario") TO "authenticated";
GRANT ALL ON FUNCTION "public"."editar_usuario"("p_user_id" "uuid", "p_nombre" "text", "p_rol" "public"."rol_usuario") TO "service_role";



REVOKE ALL ON FUNCTION "public"."editar_venta_interna"("p_venta_id" "uuid", "p_items" "jsonb", "p_version" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."editar_venta_interna"("p_venta_id" "uuid", "p_items" "jsonb", "p_version" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."editar_venta_interna"("p_venta_id" "uuid", "p_items" "jsonb", "p_version" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."eliminar_movimiento_cuenta"("p_movimiento_id" "uuid", "p_motivo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."eliminar_movimiento_cuenta"("p_movimiento_id" "uuid", "p_motivo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."eliminar_movimiento_cuenta"("p_movimiento_id" "uuid", "p_motivo" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."eliminar_producto"("p_producto_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."eliminar_producto"("p_producto_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."eliminar_producto"("p_producto_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."eliminar_proveedor"("p_proveedor_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."eliminar_proveedor"("p_proveedor_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."eliminar_proveedor"("p_proveedor_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."emitir_factura_c"("p_venta_id" "uuid", "p_cae" "text", "p_numero_factura" "text", "p_punto_venta" "text", "p_ambiente" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."emitir_factura_c"("p_venta_id" "uuid", "p_cae" "text", "p_numero_factura" "text", "p_punto_venta" "text", "p_ambiente" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."emitir_factura_c"("p_venta_id" "uuid", "p_cae" "text", "p_numero_factura" "text", "p_punto_venta" "text", "p_ambiente" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."existe_comprobante_compra"("p_proveedor_id" "uuid", "p_tipo" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."existe_comprobante_compra"("p_proveedor_id" "uuid", "p_tipo" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."existe_comprobante_compra"("p_proveedor_id" "uuid", "p_tipo" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."fijar_iva_productos"("p_sin_iva" "uuid"[], "p_con_iva" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fijar_iva_productos"("p_sin_iva" "uuid"[], "p_con_iva" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fijar_iva_productos"("p_sin_iva" "uuid"[], "p_con_iva" "uuid"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."finalizar_venta_interna"("p_venta_id" "uuid", "p_version" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."finalizar_venta_interna"("p_venta_id" "uuid", "p_version" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."finalizar_venta_interna"("p_venta_id" "uuid", "p_version" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_auditoria_generica"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_auditoria_generica"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_productos_precio_historial"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_productos_precio_historial"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_proteger_alta_producto"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_proteger_alta_producto"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_proteger_alta_producto"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_proteger_eliminacion_cliente"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_proteger_eliminacion_cliente"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_proteger_eliminacion_proveedor"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_proteger_eliminacion_proveedor"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_proteger_margen_producto"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_proteger_margen_producto"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_proteger_margen_proveedor"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_proteger_margen_proveedor"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_proteger_tipo_cliente"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_proteger_tipo_cliente"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_sin_acentos"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_sin_acentos"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."generar_codigo_interno"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."generar_codigo_interno"() TO "service_role";
GRANT ALL ON FUNCTION "public"."generar_codigo_interno"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."liberar_emision_factura_c"("p_venta_id" "uuid", "p_token" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."liberar_emision_factura_c"("p_venta_id" "uuid", "p_token" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."liberar_emision_factura_c"("p_venta_id" "uuid", "p_token" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."listar_admins"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."listar_admins"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."listar_admins"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."listar_emisiones_factura_c_a_revisar"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."listar_emisiones_factura_c_a_revisar"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."listar_emisiones_factura_c_a_revisar"() TO "service_role";



GRANT ALL ON TABLE "public"."perfiles" TO "authenticated";
GRANT ALL ON TABLE "public"."perfiles" TO "service_role";



REVOKE ALL ON FUNCTION "public"."listar_usuarios"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."listar_usuarios"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."listar_usuarios"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."marcar_apertura_revisada"("p_apertura_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."marcar_apertura_revisada"("p_apertura_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."marcar_apertura_revisada"("p_apertura_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."marcar_etiquetas"("p_producto_ids" "uuid"[], "p_precios" numeric[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."marcar_etiquetas"("p_producto_ids" "uuid"[], "p_precios" numeric[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."marcar_etiquetas"("p_producto_ids" "uuid"[], "p_precios" numeric[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."marcar_iva_productos"("p_ids" "uuid"[], "p_lleva_iva" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."marcar_iva_productos"("p_ids" "uuid"[], "p_lleva_iva" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."marcar_iva_productos"("p_ids" "uuid"[], "p_lleva_iva" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."marcar_revisar_emision_factura_c"("p_venta_id" "uuid", "p_token" "uuid", "p_ultimo_actual" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."marcar_revisar_emision_factura_c"("p_venta_id" "uuid", "p_token" "uuid", "p_ultimo_actual" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."marcar_revisar_emision_factura_c"("p_venta_id" "uuid", "p_token" "uuid", "p_ultimo_actual" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."normalizar_descripcion_item_libre"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."normalizar_descripcion_item_libre"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."normalizar_texto_producto"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."normalizar_texto_producto"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."nota_visible_para_mi"("p_origen" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."nota_visible_para_mi"("p_origen" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."notas_internas_archivar_hilo"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notas_internas_archivar_hilo"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notas_internas_archivar_hilo"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."notas_internas_guardia"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notas_internas_guardia"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notas_internas_guardia"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."plan_costo_vinculo_item"("p_item_id" "uuid", "p_producto_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."plan_costo_vinculo_item"("p_item_id" "uuid", "p_producto_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."precios_cambiados"("p_solo_pendientes" boolean, "p_desde" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."precios_cambiados"("p_solo_pendientes" boolean, "p_desde" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."precios_cambiados"("p_solo_pendientes" boolean, "p_desde" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."productos_stock_bajo"("p_limite" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."productos_stock_bajo"("p_limite" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."productos_stock_bajo"("p_limite" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."proteger_tipo_compra"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."proteger_tipo_compra"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."quitar_acentos"("p_texto" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."quitar_acentos"("p_texto" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."quitar_acentos"("p_texto" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."reabrir_venta_interna"("p_venta_id" "uuid", "p_motivo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reabrir_venta_interna"("p_venta_id" "uuid", "p_motivo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reabrir_venta_interna"("p_venta_id" "uuid", "p_motivo" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."redondear_precio_venta"("p_precio" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."redondear_precio_venta"("p_precio" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."redondear_precio_venta"("p_precio" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "public"."reemitir_factura_c_produccion"("p_venta_id" "uuid", "p_cae" "text", "p_numero_factura" "text", "p_punto_venta" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reemitir_factura_c_produccion"("p_venta_id" "uuid", "p_cae" "text", "p_numero_factura" "text", "p_punto_venta" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reemitir_factura_c_produccion"("p_venta_id" "uuid", "p_cae" "text", "p_numero_factura" "text", "p_punto_venta" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."registrar_cobro_cliente"("p_cliente_id" "uuid", "p_medios" "jsonb", "p_venta_ids" "uuid"[], "p_origen" "public"."origen_egreso", "p_fecha" "date", "p_nota" "text", "p_monto" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."registrar_cobro_cliente"("p_cliente_id" "uuid", "p_medios" "jsonb", "p_venta_ids" "uuid"[], "p_origen" "public"."origen_egreso", "p_fecha" "date", "p_nota" "text", "p_monto" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_cobro_cliente"("p_cliente_id" "uuid", "p_medios" "jsonb", "p_venta_ids" "uuid"[], "p_origen" "public"."origen_egreso", "p_fecha" "date", "p_nota" "text", "p_monto" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "public"."registrar_egreso_general"("p_categoria" "public"."categoria_egreso", "p_monto" numeric, "p_descripcion" "text", "p_forma_pago" "public"."forma_pago_egreso", "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."registrar_egreso_general"("p_categoria" "public"."categoria_egreso", "p_monto" numeric, "p_descripcion" "text", "p_forma_pago" "public"."forma_pago_egreso", "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_egreso_general"("p_categoria" "public"."categoria_egreso", "p_monto" numeric, "p_descripcion" "text", "p_forma_pago" "public"."forma_pago_egreso", "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."registrar_egreso_general"("p_categoria" "public"."categoria_egreso", "p_monto" numeric, "p_descripcion" "text", "p_forma_pago" "public"."forma_pago_egreso", "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid", "p_fecha" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."registrar_egreso_general"("p_categoria" "public"."categoria_egreso", "p_monto" numeric, "p_descripcion" "text", "p_forma_pago" "public"."forma_pago_egreso", "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid", "p_fecha" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_egreso_general"("p_categoria" "public"."categoria_egreso", "p_monto" numeric, "p_descripcion" "text", "p_forma_pago" "public"."forma_pago_egreso", "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid", "p_fecha" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."registrar_movimiento_caja_general"("p_cuenta_id" "uuid", "p_monto" numeric, "p_tipo" "public"."tipo_movimiento_cuenta", "p_descripcion" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."registrar_movimiento_caja_general"("p_cuenta_id" "uuid", "p_monto" numeric, "p_tipo" "public"."tipo_movimiento_cuenta", "p_descripcion" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_movimiento_caja_general"("p_cuenta_id" "uuid", "p_monto" numeric, "p_tipo" "public"."tipo_movimiento_cuenta", "p_descripcion" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."registrar_pago_cliente"("p_cliente_id" "uuid", "p_venta_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_venta") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."registrar_pago_cliente"("p_cliente_id" "uuid", "p_venta_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_venta") TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_pago_cliente"("p_cliente_id" "uuid", "p_venta_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_venta") TO "service_role";



REVOKE ALL ON FUNCTION "public"."registrar_pago_proveedor"("p_proveedor_id" "uuid", "p_factura_compra_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_egreso", "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."registrar_pago_proveedor"("p_proveedor_id" "uuid", "p_factura_compra_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_egreso", "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_pago_proveedor"("p_proveedor_id" "uuid", "p_factura_compra_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_egreso", "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."registrar_pago_proveedor"("p_proveedor_id" "uuid", "p_factura_compra_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_egreso", "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid", "p_cheque_numero" "text", "p_cheque_fecha_salida" "date", "p_cheque_fecha_vencimiento" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."registrar_pago_proveedor"("p_proveedor_id" "uuid", "p_factura_compra_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_egreso", "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid", "p_cheque_numero" "text", "p_cheque_fecha_salida" "date", "p_cheque_fecha_vencimiento" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_pago_proveedor"("p_proveedor_id" "uuid", "p_factura_compra_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_egreso", "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid", "p_cheque_numero" "text", "p_cheque_fecha_salida" "date", "p_cheque_fecha_vencimiento" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."registrar_pago_proveedor_v2"("p_proveedor_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_egreso", "p_factura_ids" "uuid"[], "p_nota_credito_ids" "uuid"[], "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid", "p_fecha" "date", "p_nota" "text", "p_cheque_numero" "text", "p_cheque_fecha_salida" "date", "p_cheque_fecha_vencimiento" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."registrar_pago_proveedor_v2"("p_proveedor_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_egreso", "p_factura_ids" "uuid"[], "p_nota_credito_ids" "uuid"[], "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid", "p_fecha" "date", "p_nota" "text", "p_cheque_numero" "text", "p_cheque_fecha_salida" "date", "p_cheque_fecha_vencimiento" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_pago_proveedor_v2"("p_proveedor_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_egreso", "p_factura_ids" "uuid"[], "p_nota_credito_ids" "uuid"[], "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid", "p_fecha" "date", "p_nota" "text", "p_cheque_numero" "text", "p_cheque_fecha_salida" "date", "p_cheque_fecha_vencimiento" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."registrar_pago_proveedor_v3"("p_proveedor_id" "uuid", "p_medios" "jsonb", "p_factura_ids" "uuid"[], "p_nota_credito_ids" "uuid"[], "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid", "p_fecha" "date", "p_nota" "text", "p_monto" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."registrar_pago_proveedor_v3"("p_proveedor_id" "uuid", "p_medios" "jsonb", "p_factura_ids" "uuid"[], "p_nota_credito_ids" "uuid"[], "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid", "p_fecha" "date", "p_nota" "text", "p_monto" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_pago_proveedor_v3"("p_proveedor_id" "uuid", "p_medios" "jsonb", "p_factura_ids" "uuid"[], "p_nota_credito_ids" "uuid"[], "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid", "p_fecha" "date", "p_nota" "text", "p_monto" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "public"."registrar_retiro_caja"("p_monto" numeric, "p_admin_id" "uuid", "p_cajero_id" "uuid", "p_fecha" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."registrar_retiro_caja"("p_monto" numeric, "p_admin_id" "uuid", "p_cajero_id" "uuid", "p_fecha" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_retiro_caja"("p_monto" numeric, "p_admin_id" "uuid", "p_cajero_id" "uuid", "p_fecha" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."registrar_ultimo_arca_emision_factura_c"("p_venta_id" "uuid", "p_token" "uuid", "p_ambiente" "text", "p_ultimo" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."registrar_ultimo_arca_emision_factura_c"("p_venta_id" "uuid", "p_token" "uuid", "p_ambiente" "text", "p_ultimo" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_ultimo_arca_emision_factura_c"("p_venta_id" "uuid", "p_token" "uuid", "p_ambiente" "text", "p_ultimo" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."reservar_emision_factura_c"("p_venta_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reservar_emision_factura_c"("p_venta_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reservar_emision_factura_c"("p_venta_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."resumen_stock_inventario"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."resumen_stock_inventario"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."resumen_stock_inventario"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."revertir_alta"("p_auditoria_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."revertir_alta"("p_auditoria_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."revertir_alta"("p_auditoria_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."revertir_edicion"("p_auditoria_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."revertir_edicion"("p_auditoria_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."revertir_edicion"("p_auditoria_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."revertir_movimiento"("p_auditoria_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."revertir_movimiento"("p_auditoria_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."revertir_movimiento"("p_auditoria_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_usuario_activo"("p_user_id" "uuid", "p_activo" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_usuario_activo"("p_user_id" "uuid", "p_activo" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_usuario_activo"("p_user_id" "uuid", "p_activo" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."transferir_entre_cuentas"("p_cuenta_origen_id" "uuid", "p_cuenta_destino_id" "uuid", "p_monto" numeric, "p_descripcion" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."transferir_entre_cuentas"("p_cuenta_origen_id" "uuid", "p_cuenta_destino_id" "uuid", "p_monto" numeric, "p_descripcion" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."transferir_entre_cuentas"("p_cuenta_origen_id" "uuid", "p_cuenta_destino_id" "uuid", "p_monto" numeric, "p_descripcion" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."validar_cierre_z"("p_cierre_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."validar_cierre_z"("p_cierre_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."validar_cierre_z"("p_cierre_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."vincular_item_factura_compra"("p_item_id" "uuid", "p_producto_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."vincular_item_factura_compra"("p_item_id" "uuid", "p_producto_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vincular_item_factura_compra"("p_item_id" "uuid", "p_producto_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."vista_previa_vincular_item_factura_compra"("p_item_id" "uuid", "p_producto_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."vista_previa_vincular_item_factura_compra"("p_item_id" "uuid", "p_producto_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vista_previa_vincular_item_factura_compra"("p_item_id" "uuid", "p_producto_id" "uuid") TO "service_role";


















GRANT ALL ON TABLE "public"."aperturas_caja" TO "authenticated";
GRANT ALL ON TABLE "public"."aperturas_caja" TO "service_role";



GRANT ALL ON TABLE "public"."arca_wsaa_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."arca_wsaa_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."auditoria" TO "authenticated";
GRANT ALL ON TABLE "public"."auditoria" TO "service_role";



GRANT ALL ON TABLE "public"."borradores" TO "service_role";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."borradores" TO "authenticated";



GRANT ALL ON TABLE "public"."carga_inicial_operaciones" TO "authenticated";
GRANT ALL ON TABLE "public"."carga_inicial_operaciones" TO "service_role";



GRANT ALL ON TABLE "public"."pagos_proveedor" TO "authenticated";
GRANT ALL ON TABLE "public"."pagos_proveedor" TO "service_role";



GRANT ALL ON TABLE "public"."pagos_proveedor_medios" TO "authenticated";
GRANT ALL ON TABLE "public"."pagos_proveedor_medios" TO "service_role";



GRANT ALL ON TABLE "public"."proveedores" TO "authenticated";
GRANT ALL ON TABLE "public"."proveedores" TO "service_role";



GRANT ALL ON TABLE "public"."cartera_cheques_emitidos" TO "authenticated";
GRANT ALL ON TABLE "public"."cartera_cheques_emitidos" TO "service_role";



GRANT ALL ON TABLE "public"."cierres_caja" TO "authenticated";
GRANT ALL ON TABLE "public"."cierres_caja" TO "service_role";



GRANT ALL ON TABLE "public"."clientes" TO "authenticated";
GRANT ALL ON TABLE "public"."clientes" TO "service_role";



GRANT ALL ON TABLE "public"."pagos_cliente" TO "authenticated";
GRANT ALL ON TABLE "public"."pagos_cliente" TO "service_role";



GRANT ALL ON TABLE "public"."pagos_cliente_aplicaciones" TO "service_role";
GRANT SELECT ON TABLE "public"."pagos_cliente_aplicaciones" TO "authenticated";



GRANT ALL ON TABLE "public"."pagos_cliente_a_cuenta" TO "service_role";
GRANT SELECT ON TABLE "public"."pagos_cliente_a_cuenta" TO "authenticated";



GRANT ALL ON TABLE "public"."ventas" TO "authenticated";
GRANT ALL ON TABLE "public"."ventas" TO "service_role";



GRANT ALL ON TABLE "public"."ventas_cuenta_corriente_saldo" TO "service_role";
GRANT SELECT ON TABLE "public"."ventas_cuenta_corriente_saldo" TO "authenticated";



GRANT ALL ON TABLE "public"."clientes_saldo" TO "service_role";
GRANT SELECT ON TABLE "public"."clientes_saldo" TO "authenticated";



GRANT ALL ON SEQUENCE "public"."codigo_interno_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."codigo_interno_seq" TO "service_role";



GRANT ALL ON TABLE "public"."consumo_interno_mensual" TO "service_role";
GRANT SELECT ON TABLE "public"."consumo_interno_mensual" TO "authenticated";



GRANT ALL ON TABLE "public"."cuenta_forma_pago" TO "authenticated";
GRANT ALL ON TABLE "public"."cuenta_forma_pago" TO "service_role";



GRANT ALL ON TABLE "public"."cuentas" TO "authenticated";
GRANT ALL ON TABLE "public"."cuentas" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."cuentas_saldo" TO "authenticated";
GRANT ALL ON TABLE "public"."cuentas_saldo" TO "service_role";



GRANT ALL ON TABLE "public"."devolucion_items" TO "authenticated";
GRANT ALL ON TABLE "public"."devolucion_items" TO "service_role";



GRANT ALL ON TABLE "public"."devolucion_pagos" TO "authenticated";
GRANT ALL ON TABLE "public"."devolucion_pagos" TO "service_role";



GRANT ALL ON TABLE "public"."devoluciones" TO "authenticated";
GRANT ALL ON TABLE "public"."devoluciones" TO "service_role";



GRANT ALL ON SEQUENCE "public"."devoluciones_numero_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."devoluciones_numero_seq" TO "service_role";



GRANT ALL ON TABLE "public"."egresos" TO "authenticated";
GRANT ALL ON TABLE "public"."egresos" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."emisiones_factura_c_en_curso" TO "authenticated";
GRANT ALL ON TABLE "public"."emisiones_factura_c_en_curso" TO "service_role";



GRANT ALL ON TABLE "public"."facturas_c" TO "authenticated";
GRANT ALL ON TABLE "public"."facturas_c" TO "service_role";



GRANT ALL ON TABLE "public"."facturas_compra" TO "authenticated";
GRANT ALL ON TABLE "public"."facturas_compra" TO "service_role";



GRANT ALL ON TABLE "public"."facturas_compra_items" TO "authenticated";
GRANT ALL ON TABLE "public"."facturas_compra_items" TO "service_role";



GRANT ALL ON TABLE "public"."pagos_proveedor_aplicaciones" TO "authenticated";
GRANT ALL ON TABLE "public"."pagos_proveedor_aplicaciones" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."facturas_compra_saldo" TO "authenticated";
GRANT ALL ON TABLE "public"."facturas_compra_saldo" TO "service_role";



GRANT ALL ON TABLE "public"."movimientos_cuenta" TO "authenticated";
GRANT ALL ON TABLE "public"."movimientos_cuenta" TO "service_role";



GRANT ALL ON TABLE "public"."movimientos_stock" TO "authenticated";
GRANT ALL ON TABLE "public"."movimientos_stock" TO "service_role";



GRANT ALL ON TABLE "public"."notas_internas" TO "authenticated";
GRANT ALL ON TABLE "public"."notas_internas" TO "service_role";



GRANT ALL ON TABLE "public"."notas_internas_con_autor" TO "service_role";
GRANT SELECT ON TABLE "public"."notas_internas_con_autor" TO "authenticated";



GRANT ALL ON TABLE "public"."pagos_cliente_medios" TO "service_role";
GRANT SELECT ON TABLE "public"."pagos_cliente_medios" TO "authenticated";



GRANT ALL ON TABLE "public"."pagos_proveedor_a_cuenta" TO "service_role";
GRANT SELECT ON TABLE "public"."pagos_proveedor_a_cuenta" TO "authenticated";



GRANT SELECT,MAINTAIN ON TABLE "public"."perfiles_publico" TO "authenticated";
GRANT ALL ON TABLE "public"."perfiles_publico" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,TRIGGER,MAINTAIN,UPDATE ON TABLE "public"."productos" TO "authenticated";
GRANT ALL ON TABLE "public"."productos" TO "service_role";



GRANT ALL ON TABLE "public"."productos_etiqueta" TO "service_role";
GRANT SELECT ON TABLE "public"."productos_etiqueta" TO "authenticated";



GRANT ALL ON TABLE "public"."productos_precios_historial" TO "service_role";
GRANT SELECT ON TABLE "public"."productos_precios_historial" TO "authenticated";



GRANT ALL ON SEQUENCE "public"."productos_precios_historial_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."productos_precios_historial_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."proveedores_a_cuenta" TO "service_role";
GRANT SELECT ON TABLE "public"."proveedores_a_cuenta" TO "authenticated";



GRANT SELECT,MAINTAIN ON TABLE "public"."proveedores_saldo" TO "authenticated";
GRANT ALL ON TABLE "public"."proveedores_saldo" TO "service_role";



GRANT ALL ON TABLE "public"."retiros_caja" TO "authenticated";
GRANT ALL ON TABLE "public"."retiros_caja" TO "service_role";



GRANT ALL ON TABLE "public"."stock_ubicaciones" TO "authenticated";
GRANT ALL ON TABLE "public"."stock_ubicaciones" TO "service_role";



GRANT ALL ON TABLE "public"."venta_items" TO "authenticated";
GRANT ALL ON TABLE "public"."venta_items" TO "service_role";



GRANT ALL ON TABLE "public"."venta_pagos" TO "authenticated";
GRANT ALL ON TABLE "public"."venta_pagos" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ventas_numero_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ventas_numero_seq" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" REVOKE ALL ON FUNCTIONS FROM PUBLIC;




























