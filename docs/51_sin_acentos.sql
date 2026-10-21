-- 51 — Textos sin acentos en todo el sistema (bloque A de docs/auditoria-2026-10-19.md, parte acentos)
--
-- ✅ APLICADO el 2026-10-20 (archivo completo), con backup previo virikyna_2026-10-20_pre-sin-acentos.
-- Antes se corrió entero en BEGIN … ROLLBACK con pruebas: 161 productos limpiados, precio_venta y
-- precio_calculado sin cambios, Ñ conservada, un UPDATE nuevo con acento entra sin acento.
-- PARTE C dio 0 en las 16 tablas.
--
-- Contexto (relevado contra la base real el 2026-10-20):
--   La auditoría del 19/10 dejó planteado "sin acentos" pero no se aplicó: docs/42 pone MAYÚSCULAS
--   y formato oración, y conserva los acentos. Hoy hay textos con acento en productos.nombre (185),
--   productos.descripcion (17), venta_items.producto_nombre (3), movimientos_stock.motivo (224,
--   textos generados como "Carga inicial: corrección…"), proveedores.observaciones (1) y 3
--   correcciones de caja del 20/10 (egresos, movimientos_cuenta, pagos_proveedor).
--
-- Reglas:
--   - Se quitan tildes, diéresis y acentos graves/circunflejos (á→a, Ü→U…). La Ñ se CONSERVA: es
--     una letra, no un acento (la auditoría lo pedía así; unaccent la convertiría en N, por eso
--     translate() explícito y sin extensión).
--   - Mayúsculas / minúsculas no cambian: eso lo siguen haciendo los triggers de docs/42.
--   - Se excluye lo que no es texto de negocio: códigos de barras/internos, CUIT, mails, teléfonos,
--     datos fiscales ARCA, números de comprobante, enums, y `auditoria` (histórico append-only).
--
-- Qué hace:
--   PARTE A. quitar_acentos(text) + trigger genérico fn_sin_acentos() (BEFORE INSERT OR UPDATE, las
--     columnas van como argumentos) en cada tabla de texto. Cubre a la vez las 3 apps, las RPCs y
--     cualquier escritura directa: lo que se guarde a partir de ahora entra sin acentos.
--   PARTE B. Limpieza de lo existente, sin filas en `auditoria` (virikyna.suppress_audit: son ~450
--     cambios de formato, no acciones de un usuario). Backup previo: backups/virikyna_2026-10-20_pre-sin-acentos.
--   PARTE C. Verificación (esperado: 0 textos con acento en las columnas cubiertas).
--
-- Búsquedas: con la base sin acentos, lo que se TIPEA también se limpia (packages/shared/lib/texto.ts),
-- así "línea" encuentra "LINEA" en las tres apps.
--
-- Duplicado que aparece al quitar acentos (no se fusiona, queda para revisar a mano):
--   JUEGO DE MESA CODIGO SECRETO / JUEGO DE MESA CÓDIGO SECRETO [DEVIR] → mismo nombre.

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A
-- ════════════════════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION quitar_acentos(p_texto TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path = public
AS $$
  -- 20 minúsculas + 20 mayúsculas, en el mismo orden. Ñ/ñ no están: se conservan.
  SELECT translate(p_texto,
    'áéíóúüàèìòùäëïöâêîôûÁÉÍÓÚÜÀÈÌÒÙÄËÏÖÂÊÎÔÛ',
    'aeiouuaeiouaeioaeiouAEIOUUAEIOUAEIOAEIOU');
$$;

COMMENT ON FUNCTION quitar_acentos(TEXT) IS
  'Quita tildes, diéresis y acentos graves/circunflejos; conserva la Ñ. docs/51.';

-- Trigger genérico: TG_ARGV = columnas de texto a limpiar. Solo toca las que cambian, vía jsonb
-- (plpgsql no puede asignar NEW.<columna> con nombre dinámico). Las columnas generadas
-- (productos.precio_venta) no se tocan: se recalculan después del trigger.
CREATE OR REPLACE FUNCTION fn_sin_acentos() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public
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

REVOKE ALL ON FUNCTION public.fn_sin_acentos() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_sin_acentos ON productos;
CREATE TRIGGER trg_sin_acentos BEFORE INSERT OR UPDATE ON productos
  FOR EACH ROW EXECUTE FUNCTION fn_sin_acentos('nombre', 'marca', 'descripcion');
DROP TRIGGER IF EXISTS trg_sin_acentos ON carga_inicial_items;
CREATE TRIGGER trg_sin_acentos BEFORE INSERT OR UPDATE ON carga_inicial_items
  FOR EACH ROW EXECUTE FUNCTION fn_sin_acentos('nombre', 'marca', 'descripcion');
DROP TRIGGER IF EXISTS trg_sin_acentos ON venta_items;
CREATE TRIGGER trg_sin_acentos BEFORE INSERT OR UPDATE ON venta_items
  FOR EACH ROW EXECUTE FUNCTION fn_sin_acentos('producto_nombre', 'producto_marca');
DROP TRIGGER IF EXISTS trg_sin_acentos ON devolucion_items;
CREATE TRIGGER trg_sin_acentos BEFORE INSERT OR UPDATE ON devolucion_items
  FOR EACH ROW EXECUTE FUNCTION fn_sin_acentos('producto_nombre', 'producto_marca');
DROP TRIGGER IF EXISTS trg_sin_acentos ON facturas_compra_items;
CREATE TRIGGER trg_sin_acentos BEFORE INSERT OR UPDATE ON facturas_compra_items
  FOR EACH ROW EXECUTE FUNCTION fn_sin_acentos('descripcion');
DROP TRIGGER IF EXISTS trg_sin_acentos ON proveedores;
CREATE TRIGGER trg_sin_acentos BEFORE INSERT OR UPDATE ON proveedores
  FOR EACH ROW EXECUTE FUNCTION fn_sin_acentos('razon_social', 'contacto', 'direccion', 'observaciones');
DROP TRIGGER IF EXISTS trg_sin_acentos ON clientes;
CREATE TRIGGER trg_sin_acentos BEFORE INSERT OR UPDATE ON clientes
  FOR EACH ROW EXECUTE FUNCTION fn_sin_acentos('razon_social', 'nombre_fantasia', 'domicilio');
DROP TRIGGER IF EXISTS trg_sin_acentos ON cuentas;
CREATE TRIGGER trg_sin_acentos BEFORE INSERT OR UPDATE ON cuentas
  FOR EACH ROW EXECUTE FUNCTION fn_sin_acentos('nombre');
DROP TRIGGER IF EXISTS trg_sin_acentos ON perfiles;
CREATE TRIGGER trg_sin_acentos BEFORE INSERT OR UPDATE ON perfiles
  FOR EACH ROW EXECUTE FUNCTION fn_sin_acentos('nombre');
DROP TRIGGER IF EXISTS trg_sin_acentos ON ventas;
CREATE TRIGGER trg_sin_acentos BEFORE INSERT OR UPDATE ON ventas
  FOR EACH ROW EXECUTE FUNCTION fn_sin_acentos('nota');
DROP TRIGGER IF EXISTS trg_sin_acentos ON devoluciones;
CREATE TRIGGER trg_sin_acentos BEFORE INSERT OR UPDATE ON devoluciones
  FOR EACH ROW EXECUTE FUNCTION fn_sin_acentos('motivo_detalle', 'observaciones', 'motivo_anulacion');
DROP TRIGGER IF EXISTS trg_sin_acentos ON egresos;
CREATE TRIGGER trg_sin_acentos BEFORE INSERT OR UPDATE ON egresos
  FOR EACH ROW EXECUTE FUNCTION fn_sin_acentos('descripcion');
DROP TRIGGER IF EXISTS trg_sin_acentos ON movimientos_cuenta;
CREATE TRIGGER trg_sin_acentos BEFORE INSERT OR UPDATE ON movimientos_cuenta
  FOR EACH ROW EXECUTE FUNCTION fn_sin_acentos('descripcion');
DROP TRIGGER IF EXISTS trg_sin_acentos ON movimientos_stock;
CREATE TRIGGER trg_sin_acentos BEFORE INSERT OR UPDATE ON movimientos_stock
  FOR EACH ROW EXECUTE FUNCTION fn_sin_acentos('motivo');
DROP TRIGGER IF EXISTS trg_sin_acentos ON notas_internas;
CREATE TRIGGER trg_sin_acentos BEFORE INSERT OR UPDATE ON notas_internas
  FOR EACH ROW EXECUTE FUNCTION fn_sin_acentos('mensaje');
DROP TRIGGER IF EXISTS trg_sin_acentos ON pagos_proveedor;
CREATE TRIGGER trg_sin_acentos BEFORE INSERT OR UPDATE ON pagos_proveedor
  FOR EACH ROW EXECUTE FUNCTION fn_sin_acentos('nota');


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — limpieza de lo existente (una transacción). `SET col = col` alcanza: el trigger de la
-- parte A hace el trabajo; el WHERE limita a las filas con acento.
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;
SELECT set_config('virikyna.suppress_audit', 'true', true);

UPDATE productos SET nombre = nombre
  WHERE nombre <> quitar_acentos(nombre) OR marca <> quitar_acentos(marca) OR descripcion <> quitar_acentos(descripcion);
UPDATE carga_inicial_items SET nombre = nombre
  WHERE nombre <> quitar_acentos(nombre) OR marca <> quitar_acentos(marca) OR descripcion <> quitar_acentos(descripcion);
UPDATE venta_items SET producto_nombre = producto_nombre
  WHERE producto_nombre <> quitar_acentos(producto_nombre) OR producto_marca <> quitar_acentos(producto_marca);
UPDATE devolucion_items SET producto_nombre = producto_nombre
  WHERE producto_nombre <> quitar_acentos(producto_nombre) OR producto_marca <> quitar_acentos(producto_marca);
UPDATE facturas_compra_items SET descripcion = descripcion WHERE descripcion <> quitar_acentos(descripcion);
UPDATE proveedores SET razon_social = razon_social
  WHERE razon_social <> quitar_acentos(razon_social) OR contacto <> quitar_acentos(contacto)
     OR direccion <> quitar_acentos(direccion) OR observaciones <> quitar_acentos(observaciones);
UPDATE clientes SET razon_social = razon_social
  WHERE razon_social <> quitar_acentos(razon_social) OR nombre_fantasia <> quitar_acentos(nombre_fantasia)
     OR domicilio <> quitar_acentos(domicilio);
UPDATE cuentas SET nombre = nombre WHERE nombre <> quitar_acentos(nombre);
UPDATE perfiles SET nombre = nombre WHERE nombre <> quitar_acentos(nombre);
UPDATE ventas SET nota = nota WHERE nota <> quitar_acentos(nota);
UPDATE devoluciones SET motivo_detalle = motivo_detalle
  WHERE motivo_detalle <> quitar_acentos(motivo_detalle) OR observaciones <> quitar_acentos(observaciones)
     OR motivo_anulacion <> quitar_acentos(motivo_anulacion);
UPDATE egresos SET descripcion = descripcion WHERE descripcion <> quitar_acentos(descripcion);
UPDATE movimientos_cuenta SET descripcion = descripcion WHERE descripcion <> quitar_acentos(descripcion);
UPDATE movimientos_stock SET motivo = motivo WHERE motivo <> quitar_acentos(motivo);
UPDATE notas_internas SET mensaje = mensaje WHERE mensaje <> quitar_acentos(mensaje);
UPDATE pagos_proveedor SET nota = nota WHERE nota <> quitar_acentos(nota);

COMMIT;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — verificación (esperado: una fila por columna, todas con 0)
-- ════════════════════════════════════════════════════════════════════════════════════════════
SELECT c.col, c.con_acento FROM (
  SELECT 'productos' col, count(*) FILTER (WHERE nombre <> quitar_acentos(nombre) OR marca <> quitar_acentos(marca) OR descripcion <> quitar_acentos(descripcion)) con_acento FROM productos
  UNION ALL SELECT 'carga_inicial_items', count(*) FILTER (WHERE nombre <> quitar_acentos(nombre) OR marca <> quitar_acentos(marca) OR descripcion <> quitar_acentos(descripcion)) FROM carga_inicial_items
  UNION ALL SELECT 'venta_items', count(*) FILTER (WHERE producto_nombre <> quitar_acentos(producto_nombre) OR producto_marca <> quitar_acentos(producto_marca)) FROM venta_items
  UNION ALL SELECT 'devolucion_items', count(*) FILTER (WHERE producto_nombre <> quitar_acentos(producto_nombre) OR producto_marca <> quitar_acentos(producto_marca)) FROM devolucion_items
  UNION ALL SELECT 'facturas_compra_items', count(*) FILTER (WHERE descripcion <> quitar_acentos(descripcion)) FROM facturas_compra_items
  UNION ALL SELECT 'proveedores', count(*) FILTER (WHERE razon_social <> quitar_acentos(razon_social) OR contacto <> quitar_acentos(contacto) OR direccion <> quitar_acentos(direccion) OR observaciones <> quitar_acentos(observaciones)) FROM proveedores
  UNION ALL SELECT 'clientes', count(*) FILTER (WHERE razon_social <> quitar_acentos(razon_social) OR nombre_fantasia <> quitar_acentos(nombre_fantasia) OR domicilio <> quitar_acentos(domicilio)) FROM clientes
  UNION ALL SELECT 'cuentas', count(*) FILTER (WHERE nombre <> quitar_acentos(nombre)) FROM cuentas
  UNION ALL SELECT 'perfiles', count(*) FILTER (WHERE nombre <> quitar_acentos(nombre)) FROM perfiles
  UNION ALL SELECT 'ventas', count(*) FILTER (WHERE nota <> quitar_acentos(nota)) FROM ventas
  UNION ALL SELECT 'devoluciones', count(*) FILTER (WHERE motivo_detalle <> quitar_acentos(motivo_detalle) OR observaciones <> quitar_acentos(observaciones) OR motivo_anulacion <> quitar_acentos(motivo_anulacion)) FROM devoluciones
  UNION ALL SELECT 'egresos', count(*) FILTER (WHERE descripcion <> quitar_acentos(descripcion)) FROM egresos
  UNION ALL SELECT 'movimientos_cuenta', count(*) FILTER (WHERE descripcion <> quitar_acentos(descripcion)) FROM movimientos_cuenta
  UNION ALL SELECT 'movimientos_stock', count(*) FILTER (WHERE motivo <> quitar_acentos(motivo)) FROM movimientos_stock
  UNION ALL SELECT 'notas_internas', count(*) FILTER (WHERE mensaje <> quitar_acentos(mensaje)) FROM notas_internas
  UNION ALL SELECT 'pagos_proveedor', count(*) FILTER (WHERE nota <> quitar_acentos(nota)) FROM pagos_proveedor
) c;
