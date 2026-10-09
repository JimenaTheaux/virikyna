


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


CREATE TYPE "public"."forma_pago_compra" AS ENUM (
    'contado',
    'cuenta_corriente'
);


ALTER TYPE "public"."forma_pago_compra" OWNER TO "postgres";


CREATE TYPE "public"."forma_pago_egreso" AS ENUM (
    'efectivo',
    'transferencia',
    'cheque',
    'echeq'
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
  v_item RECORD;
  v_ya_anulada BOOLEAN;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede anular una factura de compra';
  END IF;
  IF p_motivo IS NULL OR trim(p_motivo) = '' THEN
    RAISE EXCEPTION 'El motivo es obligatorio para anular una factura de compra';
  END IF;

  SELECT anulada INTO v_ya_anulada FROM facturas_compra WHERE id = p_factura_id;
  IF v_ya_anulada IS NULL THEN
    RAISE EXCEPTION 'Factura de compra no encontrada';
  END IF;
  IF v_ya_anulada THEN
    RAISE EXCEPTION 'Esta factura ya estaba anulada';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pagos_proveedor_aplicaciones
    WHERE (factura_compra_id = p_factura_id OR nota_credito_id = p_factura_id)
      AND revertida_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Este comprobante tiene pagos o notas de crédito aplicadas — revertí esos pagos antes de anularlo';
  END IF;

  FOR v_item IN
    SELECT producto_id, cantidad, ubicacion FROM facturas_compra_items
    WHERE factura_compra_id = p_factura_id AND producto_id IS NOT NULL
  LOOP
    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
    VALUES (v_item.producto_id, v_item.ubicacion, 'ajuste', -1 * v_item.cantidad,
            'Anulación de factura de compra: ' || p_motivo, p_factura_id, auth.uid());

    UPDATE stock_ubicaciones SET cantidad = cantidad - v_item.cantidad
    WHERE producto_id = v_item.producto_id AND ubicacion = v_item.ubicacion;
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


CREATE OR REPLACE FUNCTION "public"."cargar_factura_compra"("p_proveedor_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_forma_pago" "public"."forma_pago_compra", "p_items" "jsonb", "p_copiada_de_id" "uuid" DEFAULT NULL::"uuid") RETURNS "uuid"
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
  v_cambia_proveedor BOOLEAN;
  v_precio_manual NUMERIC;   -- docs/34
  v_pone_costo BOOLEAN;      -- docs/34
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
    SELECT proveedor_id, costo, precio_manual INTO v_producto_proveedor_id, v_costo_actual, v_precio_manual  -- docs/34
    FROM productos WHERE id = v_row.producto_id FOR UPDATE;

    -- Producto sin proveedor (null): IS DISTINCT FROM da true → toma proveedor y márgenes default.
    v_cambia_proveedor := v_producto_proveedor_id IS DISTINCT FROM p_proveedor_id;
    -- docs/34: la factura le pone costo (no NC/ND, precio > 0). Desde ahí el precio sale de la fórmula.
    v_pone_costo := v_actualiza_costo AND v_row.precio > 0;
    v_costo_nuevo := CASE WHEN v_pone_costo
                          THEN ROUND(v_row.precio, 2) ELSE v_costo_actual END;

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
$$;


ALTER FUNCTION "public"."cargar_factura_compra"("p_proveedor_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_forma_pago" "public"."forma_pago_compra", "p_items" "jsonb", "p_copiada_de_id" "uuid") OWNER TO "postgres";


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

  -- docs/31: solo egresos de la caja de Local (origen 'turno'); los de Gestión ('general') no.
  SELECT COALESCE(SUM(monto), 0) INTO v_total_egresos
  FROM egresos WHERE created_at::date = current_date AND origen = 'turno';

  SELECT COALESCE(SUM(monto), 0) INTO v_total_egresos_efectivo
  FROM egresos WHERE created_at::date = current_date AND origen = 'turno' AND forma_pago = 'efectivo';

  SELECT COALESCE(SUM(monto), 0) INTO v_total_retiros
  FROM retiros_caja WHERE fecha = current_date;

  v_efectivo_esperado := v_monto_base + v_total_efectivo + v_dev_efectivo - v_total_egresos_efectivo - v_total_retiros;
  v_diferencia := CASE WHEN p_efectivo_contado IS NOT NULL THEN p_efectivo_contado - v_efectivo_esperado ELSE NULL END;

  INSERT INTO cierres_caja (tipo, turno_fecha, total_efectivo, total_transferencia, total_qr, total_tarjeta,
         total_cuenta_corriente, total_egresos, total_retiros, efectivo_esperado, efectivo_contado, diferencia,
         estado_validacion, usuario_id, apertura_id,
         cantidad_devoluciones, total_devoluciones_efectivo, total_devoluciones_transferencia,
         total_devoluciones_qr, total_devoluciones_tarjeta)
  VALUES (p_tipo, current_date, v_total_efectivo, v_total_transferencia, v_total_qr, v_total_tarjeta,
         v_total_cuenta_corriente, v_total_egresos, v_total_retiros, v_efectivo_esperado, p_efectivo_contado, v_diferencia,
         CASE WHEN p_tipo = 'z' THEN 'pendiente_validacion'::estado_cierre_z ELSE NULL END, auth.uid(), v_apertura.id,
         v_cant_devoluciones, v_dev_efectivo, v_dev_transferencia, v_dev_qr, v_dev_tarjeta)
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


CREATE OR REPLACE FUNCTION "public"."confirmar_venta"("p_cliente_id" "uuid", "p_forma_pago" "public"."forma_pago_venta", "p_items" "jsonb", "p_descuento_porcentaje" numeric DEFAULT 0, "p_nota" "text" DEFAULT NULL::"text", "p_recargo_porcentaje" numeric DEFAULT 0, "p_pagos" "jsonb" DEFAULT NULL::"jsonb", "p_precio_cobrado" numeric DEFAULT NULL::numeric) RETURNS "uuid"
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
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
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
         precio_oficial, precio_cobrado, nota, usuario_id)
  VALUES (p_cliente_id, v_forma_pago_final, v_subtotal, COALESCE(p_descuento_porcentaje,0),
          COALESCE(p_recargo_porcentaje,0), v_precio_cobrado, v_precio_oficial, v_precio_cobrado, p_nota, auth.uid())
  RETURNING id INTO v_venta_id;

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

    INSERT INTO venta_items (venta_id, producto_id, cantidad, precio_unitario, descuento_porcentaje, importe)
    VALUES (v_venta_id, (v_item->>'producto_id')::UUID, (v_item->>'cantidad')::NUMERIC,
            (v_item->>'precio_unitario')::NUMERIC, COALESCE((v_item->>'descuento_porcentaje')::NUMERIC,0), v_importe);

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


ALTER FUNCTION "public"."confirmar_venta"("p_cliente_id" "uuid", "p_forma_pago" "public"."forma_pago_venta", "p_items" "jsonb", "p_descuento_porcentaje" numeric, "p_nota" "text", "p_recargo_porcentaje" numeric, "p_pagos" "jsonb", "p_precio_cobrado" numeric) OWNER TO "postgres";


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
  v_items_devueltos JSONB := '[]'::jsonb;
  v_items_nuevos JSONB := '[]'::jsonb;
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

  -- ---- Forma de pago de la diferencia ----
  IF v_diferencia <> 0 THEN
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
                            diferencia_monto, diferencia_forma_pago)
  VALUES (p_venta_id, auth.uid(), p_motivo, NULLIF(btrim(p_motivo_detalle), ''), NULLIF(btrim(p_observaciones), ''),
          v_diferencia, v_forma_final)
  RETURNING id INTO v_devolucion_id;

  -- Pagos de la diferencia (monto siempre positivo). La última parte absorbe el centavo de redondeo.
  IF v_diferencia <> 0 THEN
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
    INSERT INTO devolucion_items (devolucion_id, tipo, producto_id, cantidad, precio_unitario, reingresa_stock)
    VALUES (v_devolucion_id, 'devuelto', v_row.producto_id, v_row.cantidad, v_row.precio_unitario, v_reingresa);

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
    INSERT INTO devolucion_items (devolucion_id, tipo, producto_id, cantidad, precio_unitario, reingresa_stock)
    VALUES (v_devolucion_id, 'nuevo', v_row.producto_id, v_row.cantidad, v_row.precio_unitario, true);

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


CREATE OR REPLACE FUNCTION "public"."dashboard_ventas_por_dia"("p_desde" "date", "p_hasta" "date") RETURNS TABLE("fecha" "date", "total" numeric, "cantidad" integer)
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  WITH ventas_rango AS (
    SELECT (v.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS dia,
           v.precio_cobrado
    FROM ventas v
    WHERE v.estado <> 'anulada'
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


CREATE OR REPLACE FUNCTION "public"."ean13_digito_verificador"("p_doce" "text") RETURNS integer
    LANGUAGE "sql" IMMUTABLE STRICT PARALLEL SAFE
    SET "search_path" TO 'public'
    AS $$
  SELECT (10 - (SUM(substr(p_doce, i, 1)::INT * CASE WHEN i % 2 = 0 THEN 3 ELSE 1 END) % 10)::INT) % 10
  FROM generate_series(1, 12) AS i;
$$;


ALTER FUNCTION "public"."ean13_digito_verificador"("p_doce" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."editar_factura_compra"("p_factura_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra" DEFAULT NULL::"public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra" DEFAULT NULL::"public"."letra_comprobante_compra", "p_punto_venta" "text" DEFAULT NULL::"text", "p_numero_comprobante" "text" DEFAULT NULL::"text", "p_fecha_comprobante" "date" DEFAULT NULL::"date", "p_fecha_fiscal" "date" DEFAULT NULL::"date", "p_forma_pago" "public"."forma_pago_compra" DEFAULT NULL::"public"."forma_pago_compra") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_tipo_actual tipo_comprobante_compra;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede editar una factura de compra ya cargada';
  END IF;
  IF EXISTS (SELECT 1 FROM facturas_compra WHERE id = p_factura_id AND anulada = true) THEN
    RAISE EXCEPTION 'Esta factura está anulada, no se edita';
  END IF;

  SELECT tipo_comprobante INTO v_tipo_actual FROM facturas_compra WHERE id = p_factura_id;
  IF p_tipo_comprobante IS NOT NULL
     AND (p_tipo_comprobante = 'nota_credito') <> (v_tipo_actual = 'nota_credito')
     AND EXISTS (
       SELECT 1 FROM pagos_proveedor_aplicaciones
       WHERE (factura_compra_id = p_factura_id OR nota_credito_id = p_factura_id)
         AND revertida_at IS NULL
     ) THEN
    RAISE EXCEPTION 'Este comprobante ya tiene pagos o créditos aplicados: no se puede cambiar de/a nota de crédito. Revertí esos pagos primero';
  END IF;

  UPDATE facturas_compra SET
    tipo_comprobante = COALESCE(p_tipo_comprobante, tipo_comprobante),
    letra = COALESCE(p_letra, letra),
    punto_venta = COALESCE(p_punto_venta, punto_venta),
    numero_comprobante = COALESCE(p_numero_comprobante, numero_comprobante),
    fecha_comprobante = COALESCE(p_fecha_comprobante, fecha_comprobante),
    fecha_fiscal = COALESCE(p_fecha_fiscal, fecha_fiscal),
    forma_pago = COALESCE(p_forma_pago, forma_pago)
  WHERE id = p_factura_id;
END;
$$;


ALTER FUNCTION "public"."editar_factura_compra"("p_factura_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_forma_pago" "public"."forma_pago_compra") OWNER TO "postgres";


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


CREATE OR REPLACE FUNCTION "public"."emitir_factura_c"("p_venta_id" "uuid", "p_cae" "text", "p_numero_factura" "text", "p_punto_venta" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_factura_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF EXISTS (SELECT 1 FROM ventas WHERE id = p_venta_id AND estado = 'facturado') THEN
    RAISE EXCEPTION 'Esta venta ya tiene una Factura C emitida';
  END IF;

  INSERT INTO facturas_c (venta_id, cae, numero_factura, punto_venta, fecha_emision, usuario_id)
  VALUES (p_venta_id, p_cae, p_numero_factura, p_punto_venta, now(), auth.uid())
  RETURNING id INTO v_factura_id;

  UPDATE ventas SET estado = 'facturado' WHERE id = p_venta_id;

  RETURN v_factura_id;
END;
$$;


ALTER FUNCTION "public"."emitir_factura_c"("p_venta_id" "uuid", "p_cae" "text", "p_numero_factura" "text", "p_punto_venta" "text") OWNER TO "postgres";


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
      RETURN NEW;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
      RAISE EXCEPTION 'Solo un administrador puede modificar el margen de un producto';
    END IF;
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


CREATE OR REPLACE FUNCTION "public"."productos_stock_bajo"("p_limite" integer DEFAULT NULL::integer) RETURNS TABLE("id" "uuid", "nombre" "text", "stock_total" numeric, "stock_minimo" numeric, "total_count" integer)
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  WITH stock AS (
    SELECT p.id, p.nombre, p.stock_minimo,
           COALESCE(SUM(s.cantidad), 0) AS stock_total
    FROM productos p
    LEFT JOIN stock_ubicaciones s ON s.producto_id = p.id
    WHERE p.estado = 'activo'
    GROUP BY p.id, p.nombre, p.stock_minimo
  )
  SELECT st.id, st.nombre, st.stock_total, st.stock_minimo,
         (COUNT(*) OVER ())::int AS total_count
  FROM stock st
  WHERE st.stock_total <= st.stock_minimo
  ORDER BY st.stock_total - st.stock_minimo, st.nombre
  LIMIT p_limite;
$$;


ALTER FUNCTION "public"."productos_stock_bajo"("p_limite" integer) OWNER TO "postgres";


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

  IF p_forma_pago IN ('efectivo', 'transferencia') THEN
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

  IF p_forma_pago IN ('efectivo', 'transferencia') THEN
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
DECLARE v_pago_id UUID;
BEGIN
  IF p_forma_pago = 'cuenta_corriente' THEN
    RAISE EXCEPTION 'La forma de pago no puede ser cuenta_corriente para saldar una cuenta corriente';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  INSERT INTO pagos_cliente (cliente_id, venta_id, monto, forma_pago, usuario_id)
  VALUES (p_cliente_id, p_venta_id, p_monto, p_forma_pago, auth.uid())
  RETURNING id INTO v_pago_id;
  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
  SELECT cuenta_id, 'pago_cliente', abs(p_monto), v_pago_id, auth.uid()
  FROM cuenta_forma_pago WHERE forma_pago = p_forma_pago;
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
    AS $_$
DECLARE
  v_monto NUMERIC := round(p_monto, 2);
  v_fecha DATE := COALESCE(p_fecha, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);
  v_nota TEXT := NULLIF(trim(p_nota), '');
  v_es_cheque BOOLEAN := p_forma_pago IN ('cheque', 'echeq');
  v_factura_ids UUID[];
  v_nc_ids UUID[];
  v_mal facturas_compra%ROWTYPE;
  -- Comprobantes a cancelar (ordenados) y su saldo, que se va descontando en memoria.
  v_doc_ids UUID[] := '{}';
  v_doc_saldos NUMERIC[] := '{}';
  -- NC a usar (ordenadas) y su crédito disponible.
  v_nc_orden UUID[] := '{}';
  v_nc_disp NUMERIC[] := '{}';
  -- Plan de aplicaciones: (comprobante, monto, NC o NULL si sale del pago).
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
  v_restante NUMERIC;
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
  IF p_forma_pago IS NULL THEN
    RAISE EXCEPTION 'La forma de pago es obligatoria';
  END IF;

  SELECT array_agg(DISTINCT x) INTO v_factura_ids FROM unnest(p_factura_ids) AS x WHERE x IS NOT NULL;
  SELECT array_agg(DISTINCT x) INTO v_nc_ids FROM unnest(p_nota_credito_ids) AS x WHERE x IS NOT NULL;

  IF v_monto IS NULL OR v_monto < 0 THEN
    RAISE EXCEPTION 'El monto no puede ser negativo';
  END IF;
  IF v_monto = 0 AND v_nc_ids IS NULL THEN
    RAISE EXCEPTION 'Ingresá un monto mayor a cero o elegí una nota de crédito para aplicar';
  END IF;
  IF v_monto = 0 AND v_es_cheque THEN
    RAISE EXCEPTION 'Un pago sin monto (solo aplicación de notas de crédito) no puede ser con cheque';
  END IF;
  IF v_es_cheque THEN
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

  -- Serializa los pagos de un mismo proveedor: dos cajas pagando la misma factura a la vez no
  -- pueden leer el mismo saldo y sobrepagarla.
  PERFORM 1 FROM proveedores WHERE id = p_proveedor_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Proveedor no encontrado';
  END IF;

  -- ── Validación de comprobantes a pagar ──
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

  -- ── Validación de notas de crédito ──
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

  -- ── Con selección: el pago no puede superar lo que queda de esos comprobantes ──
  SELECT COALESCE(SUM(s), 0) INTO v_restante FROM unnest(v_doc_saldos) AS s;
  IF v_factura_ids IS NOT NULL AND v_monto > v_restante THEN
    RAISE EXCEPTION 'El monto a pagar ($ %) supera el saldo de los comprobantes elegidos ($ %)',
      to_char(v_monto, 'FM999G999G990D00'), to_char(v_restante, 'FM999G999G990D00');
  END IF;

  -- ── Paso 2: repartir el pago, más viejos primero. Sin selección, el sobrante queda a cuenta ──
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
  INSERT INTO pagos_proveedor (
    proveedor_id, factura_compra_id, monto, forma_pago, usuario_id, fecha, nota,
    cheque_numero, cheque_fecha_salida, cheque_fecha_vencimiento
  )
  VALUES (
    p_proveedor_id,
    -- deprecated: solo si todo el pago cancela una única factura (compatibilidad con las pantallas actuales)
    CASE WHEN cardinality(v_pago_docs) = 1 AND v_rest = 0 THEN v_pago_docs[1] END,
    v_monto, p_forma_pago, auth.uid(), v_fecha, v_nota,
    CASE WHEN v_es_cheque THEN trim(p_cheque_numero) END,
    CASE WHEN v_es_cheque THEN p_cheque_fecha_salida END,
    CASE WHEN v_es_cheque THEN p_cheque_fecha_vencimiento END
  )
  RETURNING id INTO v_pago_id;

  INSERT INTO pagos_proveedor_aplicaciones
    (factura_compra_id, monto, pago_proveedor_id, nota_credito_id, operacion_id, usuario_id)
  SELECT t.doc, t.monto, CASE WHEN t.nc IS NULL THEN v_pago_id END, t.nc, v_pago_id, auth.uid()
  FROM unnest(v_plan_doc, v_plan_monto, v_plan_nc) AS t(doc, monto, nc);

  IF v_monto > 0 THEN
    INSERT INTO egresos (cierre_caja_id, origen, categoria, monto, descripcion, forma_pago, usuario_id, fecha, pago_proveedor_id)
    VALUES (p_cierre_caja_id, p_origen, 'pago_proveedor', v_monto,
            'Pago a proveedor' || COALESCE(' — ' || v_nota, ''),
            p_forma_pago, auth.uid(), v_fecha, v_pago_id);

    -- Cheque y echeq no impactan cuentas (no son plata líquida al registrarse — docs/15).
    IF p_forma_pago IN ('efectivo', 'transferencia') THEN
      INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
      SELECT cuenta_id, 'pago_proveedor', -abs(v_monto), v_pago_id, auth.uid()
      FROM cuenta_forma_pago WHERE forma_pago = p_forma_pago::text::forma_pago_venta;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'pago_id', v_pago_id,
    'monto', v_monto,
    'aplicado_pago', v_monto - v_rest,
    'aplicado_nota_credito', v_total_nc,
    'a_cuenta', v_rest,
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
$_$;


ALTER FUNCTION "public"."registrar_pago_proveedor_v2"("p_proveedor_id" "uuid", "p_monto" numeric, "p_forma_pago" "public"."forma_pago_egreso", "p_factura_ids" "uuid"[], "p_nota_credito_ids" "uuid"[], "p_origen" "public"."origen_egreso", "p_cierre_caja_id" "uuid", "p_fecha" "date", "p_nota" "text", "p_cheque_numero" "text", "p_cheque_fecha_salida" "date", "p_cheque_fecha_vencimiento" "date") OWNER TO "postgres";


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

  INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
  SELECT cfp.cuenta_id, 'cierre_z', v.monto, p_cierre_id, auth.uid()
  FROM (VALUES
    ('transferencia'::forma_pago_venta, v_cierre.total_transferencia + v_cierre.total_devoluciones_transferencia),
    ('qr'::forma_pago_venta, v_cierre.total_qr + v_cierre.total_devoluciones_qr)
  ) AS v(forma_pago, monto)
  JOIN cuenta_forma_pago cfp ON cfp.forma_pago = v.forma_pago
  WHERE v.monto <> 0;

  -- Tarjeta (débito+crédito) va a la misma cuenta que QR (Galicia)
  v_monto_tarjeta := v_cierre.total_tarjeta + v_cierre.total_devoluciones_tarjeta;
  IF v_monto_tarjeta <> 0 THEN
    INSERT INTO movimientos_cuenta (cuenta_id, tipo, monto, referencia_id, usuario_id)
    SELECT cuenta_id, 'cierre_z', v_monto_tarjeta, p_cierre_id, auth.uid()
    FROM cuenta_forma_pago WHERE forma_pago = 'qr';
  END IF;
END;
$$;


ALTER FUNCTION "public"."validar_cierre_z"("p_cierre_id" "uuid") OWNER TO "postgres";


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
    "total_devoluciones_tarjeta" numeric(12,2) DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."cierres_caja" OWNER TO "postgres";


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
    "condicion_iva" "public"."condicion_iva_cliente" DEFAULT 'consumidor_final'::"public"."condicion_iva_cliente" NOT NULL
);


ALTER TABLE "public"."clientes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pagos_cliente" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "cliente_id" "uuid" NOT NULL,
    "venta_id" "uuid",
    "monto" numeric(12,2) NOT NULL,
    "usuario_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "forma_pago" "public"."forma_pago_venta" NOT NULL,
    "revierte_pago_cliente_id" "uuid",
    CONSTRAINT "chk_pago_cliente_forma_pago" CHECK (("forma_pago" <> ALL (ARRAY['cuenta_corriente'::"public"."forma_pago_venta", 'combinado'::"public"."forma_pago_venta"])))
);


ALTER TABLE "public"."pagos_cliente" OWNER TO "postgres";


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
    CONSTRAINT "chk_venta_cta_cte_requiere_cliente" CHECK ((NOT (("forma_pago" = 'cuenta_corriente'::"public"."forma_pago_venta") AND ("cliente_id" IS NULL)))),
    CONSTRAINT "chk_ventas_precio_cobrado_positivo" CHECK (("precio_cobrado" > (0)::numeric))
);


ALTER TABLE "public"."ventas" OWNER TO "postgres";


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
    (("c"."saldo_inicial" + COALESCE("ventas_cta"."total_cuenta_corriente", (0)::numeric)) - COALESCE("pagos"."total_pagado", (0)::numeric)) AS "saldo_actual"
   FROM (("public"."clientes" "c"
     LEFT JOIN ( SELECT "ventas"."cliente_id",
            "sum"("ventas"."total") AS "total_cuenta_corriente"
           FROM "public"."ventas"
          WHERE (("ventas"."forma_pago" = 'cuenta_corriente'::"public"."forma_pago_venta") AND ("ventas"."estado" <> 'anulada'::"public"."estado_comprobante"))
          GROUP BY "ventas"."cliente_id") "ventas_cta" ON (("ventas_cta"."cliente_id" = "c"."id")))
     LEFT JOIN ( SELECT "pagos_cliente"."cliente_id",
            "sum"("pagos_cliente"."monto") AS "total_pagado"
           FROM "public"."pagos_cliente"
          GROUP BY "pagos_cliente"."cliente_id") "pagos" ON (("pagos"."cliente_id" = "c"."id")));


ALTER VIEW "public"."clientes_saldo" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."codigo_interno_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    MAXVALUE 9999999999
    CACHE 1;


ALTER SEQUENCE "public"."codigo_interno_seq" OWNER TO "postgres";


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
    CONSTRAINT "devolucion_items_cantidad_check" CHECK (("cantidad" > (0)::numeric)),
    CONSTRAINT "devolucion_items_precio_unitario_check" CHECK (("precio_unitario" >= (0)::numeric))
);


ALTER TABLE "public"."devolucion_items" OWNER TO "postgres";


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
    CONSTRAINT "chk_devolucion_forma_pago_coherente" CHECK (((("diferencia_monto" = (0)::numeric) AND ("diferencia_forma_pago" IS NULL)) OR (("diferencia_monto" <> (0)::numeric) AND ("diferencia_forma_pago" IS NOT NULL)))),
    CONSTRAINT "chk_devolucion_forma_pago_sin_cta_cte" CHECK ((("diferencia_forma_pago" IS NULL) OR ("diferencia_forma_pago" <> 'cuenta_corriente'::"public"."forma_pago_venta"))),
    CONSTRAINT "chk_devolucion_motivo_otro" CHECK ((("motivo" <> 'otro'::"public"."motivo_devolucion") OR (("motivo_detalle" IS NOT NULL) AND ("btrim"("motivo_detalle") <> ''::"text"))))
);


ALTER TABLE "public"."devoluciones" OWNER TO "postgres";


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
    "pago_proveedor_id" "uuid"
);


ALTER TABLE "public"."egresos" OWNER TO "postgres";


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
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
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
    "copiada_de_id" "uuid"
);


ALTER TABLE "public"."facturas_compra" OWNER TO "postgres";


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
    "fc"."copiada_de_id"
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
    CONSTRAINT "notas_internas_origen_check" CHECK (("origen" = ANY (ARRAY['local'::"text", 'gestion'::"text"])))
);


ALTER TABLE "public"."notas_internas" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."notas_internas_con_autor" AS
 SELECT "n"."id",
    "n"."mensaje",
    "n"."autor_id",
    "n"."origen",
    "n"."archivada",
    "n"."archivada_at",
    "n"."created_at",
    "p"."nombre" AS "autor_nombre"
   FROM ("public"."notas_internas" "n"
     JOIN "public"."perfiles" "p" ON (("p"."id" = "n"."autor_id")));


ALTER VIEW "public"."notas_internas_con_autor" OWNER TO "postgres";


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
    CONSTRAINT "productos_precio_manual_positivo" CHECK ((("precio_manual" IS NULL) OR ("precio_manual" > (0)::numeric)))
);


ALTER TABLE "public"."productos" OWNER TO "postgres";


COMMENT ON COLUMN "public"."productos"."precio_manual" IS 'Precio de venta cargado a mano (carga inicial, sin costo). Exacto, sin redondeo. Tiene prioridad sobre la fórmula; cargar_factura_compra lo borra al ponerle costo al producto.';



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
    "importe" numeric(12,2) NOT NULL
);


ALTER TABLE "public"."venta_items" OWNER TO "postgres";


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



ALTER TABLE ONLY "public"."pagos_cliente"
    ADD CONSTRAINT "pagos_cliente_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pagos_proveedor_aplicaciones"
    ADD CONSTRAINT "pagos_proveedor_aplicaciones_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pagos_proveedor"
    ADD CONSTRAINT "pagos_proveedor_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."perfiles"
    ADD CONSTRAINT "perfiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."productos"
    ADD CONSTRAINT "productos_codigo_barras_key" UNIQUE ("codigo_barras");



ALTER TABLE ONLY "public"."productos"
    ADD CONSTRAINT "productos_codigo_interno_key" UNIQUE ("codigo_interno");



ALTER TABLE ONLY "public"."productos"
    ADD CONSTRAINT "productos_pkey" PRIMARY KEY ("id");



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



CREATE INDEX "idx_facturas_compra_copiada_de" ON "public"."facturas_compra" USING "btree" ("copiada_de_id") WHERE ("copiada_de_id" IS NOT NULL);



CREATE INDEX "idx_facturas_compra_proveedor" ON "public"."facturas_compra" USING "btree" ("proveedor_id");



CREATE INDEX "idx_movimientos_cuenta_cuenta" ON "public"."movimientos_cuenta" USING "btree" ("cuenta_id");



CREATE INDEX "idx_movimientos_stock_producto" ON "public"."movimientos_stock" USING "btree" ("producto_id");



CREATE INDEX "idx_pagos_proveedor_cheque_vencimiento" ON "public"."pagos_proveedor" USING "btree" ("cheque_fecha_vencimiento") WHERE ("forma_pago" = ANY (ARRAY['cheque'::"public"."forma_pago_egreso", 'echeq'::"public"."forma_pago_egreso"]));



CREATE INDEX "idx_ppa_factura" ON "public"."pagos_proveedor_aplicaciones" USING "btree" ("factura_compra_id");



CREATE INDEX "idx_ppa_nota_credito" ON "public"."pagos_proveedor_aplicaciones" USING "btree" ("nota_credito_id");



CREATE INDEX "idx_ppa_operacion" ON "public"."pagos_proveedor_aplicaciones" USING "btree" ("operacion_id");



CREATE INDEX "idx_ppa_pago" ON "public"."pagos_proveedor_aplicaciones" USING "btree" ("pago_proveedor_id");



CREATE INDEX "idx_productos_estado" ON "public"."productos" USING "btree" ("estado");



CREATE INDEX "idx_productos_proveedor" ON "public"."productos" USING "btree" ("proveedor_id");



CREATE INDEX "idx_retiros_caja_fecha" ON "public"."retiros_caja" USING "btree" ("fecha");



CREATE INDEX "idx_venta_pagos_venta" ON "public"."venta_pagos" USING "btree" ("venta_id");



CREATE INDEX "idx_ventas_cliente" ON "public"."ventas" USING "btree" ("cliente_id");



CREATE INDEX "idx_ventas_created_at" ON "public"."ventas" USING "btree" ("created_at");



CREATE INDEX "idx_ventas_estado" ON "public"."ventas" USING "btree" ("estado");



CREATE UNIQUE INDEX "uq_carga_inicial_items_usuario_codigo" ON "public"."carga_inicial_items" USING "btree" ("usuario_id", "codigo_barras") WHERE ("codigo_barras" IS NOT NULL);



CREATE UNIQUE INDEX "ux_aperturas_caja_abierta" ON "public"."aperturas_caja" USING "btree" ((true)) WHERE ("cierre_z_id" IS NULL);



CREATE UNIQUE INDEX "ux_cierres_caja_z_unico_por_dia" ON "public"."cierres_caja" USING "btree" ("turno_fecha") WHERE ("tipo" = 'z'::"public"."tipo_cierre");



CREATE UNIQUE INDEX "ux_egresos_pago_proveedor" ON "public"."egresos" USING "btree" ("pago_proveedor_id") WHERE (("pago_proveedor_id" IS NOT NULL) AND ("revierte_egreso_id" IS NULL));



CREATE UNIQUE INDEX "ux_movimientos_cuenta_saldo_inicial_por_cuenta" ON "public"."movimientos_cuenta" USING "btree" ("cuenta_id") WHERE ("tipo" = 'saldo_inicial'::"public"."tipo_movimiento_cuenta");



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



CREATE OR REPLACE TRIGGER "trg_auditoria_pagos_proveedor" AFTER INSERT OR DELETE OR UPDATE ON "public"."pagos_proveedor" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_pagos_proveedor_aplicaciones" AFTER INSERT OR UPDATE ON "public"."pagos_proveedor_aplicaciones" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_productos" AFTER INSERT OR DELETE OR UPDATE ON "public"."productos" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_proveedores" AFTER INSERT OR DELETE OR UPDATE ON "public"."proveedores" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_retiros_caja" AFTER INSERT ON "public"."retiros_caja" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_stock_ubicaciones" AFTER UPDATE ON "public"."stock_ubicaciones" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_auditoria_ventas" AFTER INSERT OR DELETE OR UPDATE ON "public"."ventas" FOR EACH ROW EXECUTE FUNCTION "public"."fn_auditoria_generica"();



CREATE OR REPLACE TRIGGER "trg_proteger_eliminacion_cliente" BEFORE DELETE ON "public"."clientes" FOR EACH ROW EXECUTE FUNCTION "public"."fn_proteger_eliminacion_cliente"();



CREATE OR REPLACE TRIGGER "trg_proteger_eliminacion_proveedor" BEFORE DELETE ON "public"."proveedores" FOR EACH ROW EXECUTE FUNCTION "public"."fn_proteger_eliminacion_proveedor"();



CREATE OR REPLACE TRIGGER "trg_proteger_margen_producto" BEFORE UPDATE ON "public"."productos" FOR EACH ROW EXECUTE FUNCTION "public"."fn_proteger_margen_producto"();



CREATE OR REPLACE TRIGGER "trg_proteger_margen_proveedor" BEFORE UPDATE ON "public"."proveedores" FOR EACH ROW EXECUTE FUNCTION "public"."fn_proteger_margen_proveedor"();



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
    ADD CONSTRAINT "egresos_revierte_egreso_id_fkey" FOREIGN KEY ("revierte_egreso_id") REFERENCES "public"."egresos"("id");



ALTER TABLE ONLY "public"."egresos"
    ADD CONSTRAINT "egresos_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



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
    ADD CONSTRAINT "notas_internas_autor_id_fkey" FOREIGN KEY ("autor_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."pagos_cliente"
    ADD CONSTRAINT "pagos_cliente_cliente_id_fkey" FOREIGN KEY ("cliente_id") REFERENCES "public"."clientes"("id");



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



ALTER TABLE ONLY "public"."pagos_proveedor"
    ADD CONSTRAINT "pagos_proveedor_proveedor_id_fkey" FOREIGN KEY ("proveedor_id") REFERENCES "public"."proveedores"("id");



ALTER TABLE ONLY "public"."pagos_proveedor"
    ADD CONSTRAINT "pagos_proveedor_revierte_pago_proveedor_id_fkey" FOREIGN KEY ("revierte_pago_proveedor_id") REFERENCES "public"."pagos_proveedor"("id");



ALTER TABLE ONLY "public"."pagos_proveedor"
    ADD CONSTRAINT "pagos_proveedor_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."perfiles"
    ADD CONSTRAINT "perfiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id");



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


CREATE POLICY "notas_internas_todos" ON "public"."notas_internas" USING (((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))) AND (("origen" = 'local'::"text") OR (EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'admin'::"public"."rol_usuario"))))))) WITH CHECK (((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))) AND (("origen" = 'local'::"text") OR (EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'admin'::"public"."rol_usuario")))))));



ALTER TABLE "public"."pagos_cliente" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "pagos_cliente_select" ON "public"."pagos_cliente" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



ALTER TABLE "public"."pagos_proveedor" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pagos_proveedor_aplicaciones" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "pagos_proveedor_aplicaciones_select" ON "public"."pagos_proveedor_aplicaciones" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



CREATE POLICY "pagos_proveedor_select" ON "public"."pagos_proveedor" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."activo" = true)))));



CREATE POLICY "perfil_propio" ON "public"."perfiles" FOR SELECT USING (("auth"."uid"() = "id"));



ALTER TABLE "public"."perfiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."productos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "productos_todos" ON "public"."productos" USING ((EXISTS ( SELECT 1
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



REVOKE ALL ON FUNCTION "public"."cargar_factura_compra"("p_proveedor_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_forma_pago" "public"."forma_pago_compra", "p_items" "jsonb", "p_copiada_de_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cargar_factura_compra"("p_proveedor_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_forma_pago" "public"."forma_pago_compra", "p_items" "jsonb", "p_copiada_de_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cargar_factura_compra"("p_proveedor_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_forma_pago" "public"."forma_pago_compra", "p_items" "jsonb", "p_copiada_de_id" "uuid") TO "service_role";



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



REVOKE ALL ON FUNCTION "public"."confirmar_venta"("p_cliente_id" "uuid", "p_forma_pago" "public"."forma_pago_venta", "p_items" "jsonb", "p_descuento_porcentaje" numeric, "p_nota" "text", "p_recargo_porcentaje" numeric, "p_pagos" "jsonb", "p_precio_cobrado" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."confirmar_venta"("p_cliente_id" "uuid", "p_forma_pago" "public"."forma_pago_venta", "p_items" "jsonb", "p_descuento_porcentaje" numeric, "p_nota" "text", "p_recargo_porcentaje" numeric, "p_pagos" "jsonb", "p_precio_cobrado" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."confirmar_venta"("p_cliente_id" "uuid", "p_forma_pago" "public"."forma_pago_venta", "p_items" "jsonb", "p_descuento_porcentaje" numeric, "p_nota" "text", "p_recargo_porcentaje" numeric, "p_pagos" "jsonb", "p_precio_cobrado" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "public"."crear_devolucion"("p_venta_id" "uuid", "p_motivo" "public"."motivo_devolucion", "p_motivo_detalle" "text", "p_observaciones" "text", "p_items_devueltos" "jsonb", "p_items_nuevos" "jsonb", "p_forma_pago" "public"."forma_pago_venta", "p_pagos" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."crear_devolucion"("p_venta_id" "uuid", "p_motivo" "public"."motivo_devolucion", "p_motivo_detalle" "text", "p_observaciones" "text", "p_items_devueltos" "jsonb", "p_items_nuevos" "jsonb", "p_forma_pago" "public"."forma_pago_venta", "p_pagos" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."crear_devolucion"("p_venta_id" "uuid", "p_motivo" "public"."motivo_devolucion", "p_motivo_detalle" "text", "p_observaciones" "text", "p_items_devueltos" "jsonb", "p_items_nuevos" "jsonb", "p_forma_pago" "public"."forma_pago_venta", "p_pagos" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."dashboard_ventas_por_dia"("p_desde" "date", "p_hasta" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."dashboard_ventas_por_dia"("p_desde" "date", "p_hasta" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."dashboard_ventas_por_dia"("p_desde" "date", "p_hasta" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."ean13_digito_verificador"("p_doce" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ean13_digito_verificador"("p_doce" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ean13_digito_verificador"("p_doce" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."editar_factura_compra"("p_factura_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_forma_pago" "public"."forma_pago_compra") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."editar_factura_compra"("p_factura_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_forma_pago" "public"."forma_pago_compra") TO "authenticated";
GRANT ALL ON FUNCTION "public"."editar_factura_compra"("p_factura_id" "uuid", "p_tipo_comprobante" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero_comprobante" "text", "p_fecha_comprobante" "date", "p_fecha_fiscal" "date", "p_forma_pago" "public"."forma_pago_compra") TO "service_role";



REVOKE ALL ON FUNCTION "public"."editar_movimiento_cuenta"("p_movimiento_id" "uuid", "p_monto_nuevo" numeric, "p_descripcion_nueva" "text", "p_motivo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."editar_movimiento_cuenta"("p_movimiento_id" "uuid", "p_monto_nuevo" numeric, "p_descripcion_nueva" "text", "p_motivo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."editar_movimiento_cuenta"("p_movimiento_id" "uuid", "p_monto_nuevo" numeric, "p_descripcion_nueva" "text", "p_motivo" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."editar_usuario"("p_user_id" "uuid", "p_nombre" "text", "p_rol" "public"."rol_usuario") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."editar_usuario"("p_user_id" "uuid", "p_nombre" "text", "p_rol" "public"."rol_usuario") TO "authenticated";
GRANT ALL ON FUNCTION "public"."editar_usuario"("p_user_id" "uuid", "p_nombre" "text", "p_rol" "public"."rol_usuario") TO "service_role";



REVOKE ALL ON FUNCTION "public"."eliminar_movimiento_cuenta"("p_movimiento_id" "uuid", "p_motivo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."eliminar_movimiento_cuenta"("p_movimiento_id" "uuid", "p_motivo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."eliminar_movimiento_cuenta"("p_movimiento_id" "uuid", "p_motivo" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."eliminar_proveedor"("p_proveedor_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."eliminar_proveedor"("p_proveedor_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."eliminar_proveedor"("p_proveedor_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."emitir_factura_c"("p_venta_id" "uuid", "p_cae" "text", "p_numero_factura" "text", "p_punto_venta" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."emitir_factura_c"("p_venta_id" "uuid", "p_cae" "text", "p_numero_factura" "text", "p_punto_venta" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."emitir_factura_c"("p_venta_id" "uuid", "p_cae" "text", "p_numero_factura" "text", "p_punto_venta" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."existe_comprobante_compra"("p_proveedor_id" "uuid", "p_tipo" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."existe_comprobante_compra"("p_proveedor_id" "uuid", "p_tipo" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."existe_comprobante_compra"("p_proveedor_id" "uuid", "p_tipo" "public"."tipo_comprobante_compra", "p_letra" "public"."letra_comprobante_compra", "p_punto_venta" "text", "p_numero" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_auditoria_generica"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_auditoria_generica"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_proteger_eliminacion_cliente"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_proteger_eliminacion_cliente"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_proteger_eliminacion_proveedor"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_proteger_eliminacion_proveedor"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_proteger_margen_producto"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_proteger_margen_producto"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_proteger_margen_proveedor"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_proteger_margen_proveedor"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."generar_codigo_interno"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."generar_codigo_interno"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."listar_admins"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."listar_admins"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."listar_admins"() TO "service_role";



GRANT ALL ON TABLE "public"."perfiles" TO "authenticated";
GRANT ALL ON TABLE "public"."perfiles" TO "service_role";



REVOKE ALL ON FUNCTION "public"."listar_usuarios"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."listar_usuarios"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."listar_usuarios"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."marcar_apertura_revisada"("p_apertura_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."marcar_apertura_revisada"("p_apertura_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."marcar_apertura_revisada"("p_apertura_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."productos_stock_bajo"("p_limite" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."productos_stock_bajo"("p_limite" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."productos_stock_bajo"("p_limite" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."redondear_precio_venta"("p_precio" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."redondear_precio_venta"("p_precio" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."redondear_precio_venta"("p_precio" numeric) TO "service_role";



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



REVOKE ALL ON FUNCTION "public"."registrar_retiro_caja"("p_monto" numeric, "p_admin_id" "uuid", "p_cajero_id" "uuid", "p_fecha" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."registrar_retiro_caja"("p_monto" numeric, "p_admin_id" "uuid", "p_cajero_id" "uuid", "p_fecha" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_retiro_caja"("p_monto" numeric, "p_admin_id" "uuid", "p_cajero_id" "uuid", "p_fecha" "date") TO "service_role";



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


















GRANT ALL ON TABLE "public"."aperturas_caja" TO "authenticated";
GRANT ALL ON TABLE "public"."aperturas_caja" TO "service_role";



GRANT ALL ON TABLE "public"."arca_wsaa_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."arca_wsaa_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."auditoria" TO "authenticated";
GRANT ALL ON TABLE "public"."auditoria" TO "service_role";



GRANT ALL ON TABLE "public"."carga_inicial_operaciones" TO "authenticated";
GRANT ALL ON TABLE "public"."carga_inicial_operaciones" TO "service_role";



GRANT ALL ON TABLE "public"."cierres_caja" TO "authenticated";
GRANT ALL ON TABLE "public"."cierres_caja" TO "service_role";



GRANT ALL ON TABLE "public"."clientes" TO "authenticated";
GRANT ALL ON TABLE "public"."clientes" TO "service_role";



GRANT ALL ON TABLE "public"."pagos_cliente" TO "authenticated";
GRANT ALL ON TABLE "public"."pagos_cliente" TO "service_role";



GRANT ALL ON TABLE "public"."ventas" TO "authenticated";
GRANT ALL ON TABLE "public"."ventas" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."clientes_saldo" TO "authenticated";
GRANT ALL ON TABLE "public"."clientes_saldo" TO "service_role";



GRANT ALL ON SEQUENCE "public"."codigo_interno_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."codigo_interno_seq" TO "service_role";



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



GRANT SELECT,MAINTAIN ON TABLE "public"."notas_internas_con_autor" TO "authenticated";
GRANT ALL ON TABLE "public"."notas_internas_con_autor" TO "service_role";



GRANT ALL ON TABLE "public"."pagos_proveedor" TO "authenticated";
GRANT ALL ON TABLE "public"."pagos_proveedor" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."perfiles_publico" TO "authenticated";
GRANT ALL ON TABLE "public"."perfiles_publico" TO "service_role";



GRANT ALL ON TABLE "public"."productos" TO "authenticated";
GRANT ALL ON TABLE "public"."productos" TO "service_role";



GRANT ALL ON TABLE "public"."proveedores" TO "authenticated";
GRANT ALL ON TABLE "public"."proveedores" TO "service_role";



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




























