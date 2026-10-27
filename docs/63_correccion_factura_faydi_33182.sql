-- 63 — Corrección de la factura de compra FAYDI A 0011-00033182 (17/10/2026)
--
-- ✅ APLICADO en producción el 2026-10-27 13:43, con backup previo virikyna_2026-10-27_pre-docs63.
-- Factura: 4.146.099,30 + IVA = 5.016.780,15 → 4.129.619,40 + 867.220,07 = 4.996.839,47 (= 2 × PDF);
-- 112 ítems, 468 unidades; saldo FAYDI 4.563.229,44 → 4.543.288,76. Códigos de los productos nuevos:
-- 2000000000145 (Skate banana FD3108T), …152 (Skate banana FD3108), …169 (Sole ojos fijos),
-- …176 (Coche paseo toldo). Los dry-runs consumieron códigos de la secuencia (quedan huecos antes de …145).
--
-- Datos de una sola vez, no es una migración de schema. Correr desde la raíz del repo con
-- `supabase db query --linked -f docs/63_correccion_factura_faydi_33182.sql`, con backup previo.
-- El dry-run es este mismo archivo con ROLLBACK en lugar de COMMIT.
--
-- Contexto (relevado contra la base real y el PDF de la factura el 2026-10-27):
--   - FAYDI factura a mitad de precio: la factura se carga con el precio de cada artículo × 2
--     (observaciones del proveedor). La cargó Jose el 22/10 16:10 (3076dfb2…, 109 ítems).
--   - La "CASITA DE JUEGOS CASTILLO PRINCESA ART FYCS9989" no estaba en la factura: Jose la dio de
--     alta a mano el 23/10 14:00 sin stock, Ale la vendió el 23/10 19:41 (venta 72) y quedó en −1.
--     Alicia la corrigió el 27/10 10:42 con una carga inicial (−1 → 0).
--   - Cruzando el PDF línea por línea con lo cargado (todo × 2):
--       faltaban:  Castillo Rosa FYCS9989 ×1, Contador educativo FD229155 ×6, Paleta ping pong x2
--                  FD7700 ×2, Coche paseo con toldo FD05881 ×1 (sin producto), Muñeca Sole ojos
--                  fijos ×2 (cargadas las 4 como ojos movibles), Skate banana FD3108T y FD3108 ×1
--                  (los 4 skates se cargaron como Patineta reforzada ×2 + Skate doble dibujo ×2).
--       de más:    Pelotero Unicornio en 5 líneas de 1 (el PDF trae 1); Pelotero Festival ×3
--                  (el PDF trae Festival ×1 + Igloo FD27866 ×2: la línea "FESTIVAL … ART FD27866"
--                  era el Igloo).
--       precio:    Casita Policía 2.290 (era 22.900), Torre flor 7.990 (era 9.490), y 6 líneas con
--                  $1 de menos por redondeo de precios con medio peso (3.839,5 × 2 = 7.679).
--   - Decisión de la dueña (2026-10-27): cada producto queda con la cantidad del PDF y el precio
--     exacto × 2; lo que falta se crea y entra como si hubiera venido en la factura; el total cambia.
--   - Los puzzles quedan agrupados como se cargaron ("DISEÑOS VARIOS" ×8, "PROFESIONAL" ×3): son
--     productos genéricos a propósito y el precio coincide.
--
-- Qué hace (como Jimena, igual que docs/56 y docs/58):
--   1. Productos nuevos (FAYDI, márgenes 100/20, código EAN interno de generar_codigo_interno()).
--   2. Ítems: corrige precio/cantidad, agrega los que faltan, borra las 4 líneas de más del Unicornio
--      y pasa la línea "FESTIVAL … FD27866" al producto Iglú.
--   3. Stock: movimiento 'compra' con referencia a la factura por cada diferencia (negativo si sobraba),
--      así anular_factura_compra (neto por referencia) sigue revirtiendo exactamente lo correcto.
--      Castillo: contra-asiento 'inicial' −1 de la corrección de Alicia (la casita entra por factura).
--   4. Costo de producto = precio × (1 − 10 %) como cargar_factura_compra, solo donde el costo
--      todavía es el que puso esta factura (no pisa ediciones a mano).
--   5. Totales de la factura recalculados desde los ítems (21 %), y una fila de auditoría
--      'nota_correccion' con los ítems antes/después (facturas_compra_items no tiene trigger).
-- Cualquier diferencia con lo relevado aborta todo.

BEGIN;

SELECT set_config('request.jwt.claims', '{"sub":"4b6fc500-fa5f-4512-84b8-13345382b761","role":"authenticated"}', true);

CREATE TEMP TABLE t63_items_antes ON COMMIT DROP AS
SELECT * FROM facturas_compra_items WHERE factura_compra_id = '3076dfb2-7654-4b22-8b0c-f709f940dc55';

CREATE TEMP TABLE t63_stock (codigo text, producto text, local numeric) ON COMMIT DROP;
CREATE TEMP TABLE t63_prod (codigo text PRIMARY KEY, id uuid) ON COMMIT DROP;

DO $correccion$
DECLARE
  c_factura CONSTANT uuid := '3076dfb2-7654-4b22-8b0c-f709f940dc55';
  c_faydi CONSTANT uuid := '1b9b2e1d-7e2c-4dd5-9402-8f0601574f24';
  c_motivo CONSTANT text := 'Correccion factura FAYDI 0011-33182 contra el PDF (docs/63)';
  n int;
  v_id uuid;
  r record;
BEGIN
  -- ─── Guardas: la factura y los productos están como se relevaron ──────────────────────────────
  IF NOT EXISTS (SELECT 1 FROM facturas_compra WHERE id = c_factura AND total = 5016780.15
                   AND total_sin_iva = 4146099.30 AND NOT anulada AND iva_alicuota = 21) THEN
    RAISE EXCEPTION 'La factura no está como se relevó (total/anulada/IVA)';
  END IF;
  IF (SELECT count(*) FROM t63_items_antes) <> 109 THEN
    RAISE EXCEPTION 'La factura no tiene 109 ítems';
  END IF;

  -- Productos existentes por código de barras (único) — exactamente 1 cada uno.
  INSERT INTO t63_prod (codigo, id)
  SELECT p.codigo_barras, p.id FROM productos p WHERE p.codigo_barras IN (
    '7791584741696',  -- Castillo Princesa FYCS9989
    '229155',         -- Contador educativo FD229155
    '9812345678988',  -- Set paletas ping pong x2 (FD7700)
    '7798323435267',  -- Pelotero Iglú Mickey FD27866
    '27866',          -- Pelotero Festival … ART FD27866 (la línea era el Iglú)
    '7798323435939',  -- Pelotero Festival contiene 75
    '7798323435892',  -- Pelotero Unicornio
    '7798323432631',  -- Patineta reforzada grande (skate común FD3010T)
    '7798323432778',  -- Skate doble dibujo ART3010
    '7798323437186'); -- Muñeca Sole ojos movibles
  IF (SELECT count(*) FROM t63_prod) <> 10 THEN
    RAISE EXCEPTION 'No se encontraron los 10 productos por código';
  END IF;

  -- Ninguno de los productos tocados está en otra factura (esta es su última compra).
  IF EXISTS (SELECT 1 FROM facturas_compra_items i
             WHERE i.factura_compra_id <> c_factura
               AND i.producto_id IN (SELECT id FROM t63_prod UNION
                                     SELECT producto_id FROM t63_items_antes WHERE id IN (
                                       'c4c05945-06ed-455d-b393-4d5c5dc733c5','84373ab0-1fb7-47ab-b3ca-b6054453a673',
                                       'e9df5754-8ea5-47c5-b110-5a9d96a9e02f','40acf736-5a9c-4ed7-a8cc-76ff89330321',
                                       'd6570a3c-4b96-4c91-a7a1-c1c6eeb9dc50','b451dfc8-b21e-4ef5-8588-429b68555adc',
                                       '706e179e-4dc9-4cad-a34d-e23edd80a785','3e8a09d8-2c69-4884-9316-1c99869b7f7d'))) THEN
    RAISE EXCEPTION 'Algún producto tocado aparece en otra factura de compra';
  END IF;

  -- Stock relevado: lo que se baja tiene que estar.
  IF EXISTS (
    SELECT 1 FROM (VALUES ('7798323435892', 5), ('27866', 1), ('7798323435939', 2), ('7798323432631', 3),
                          ('7798323432778', 2), ('7798323437186', 4), ('7791584741696', 0)) AS e(codigo, cant)
    JOIN t63_prod p ON p.codigo = e.codigo
    LEFT JOIN stock_ubicaciones s ON s.producto_id = p.id AND s.ubicacion = 'local'
    WHERE COALESCE(s.cantidad, 0) <> e.cant) THEN
    RAISE EXCEPTION 'El stock de algún producto cambió desde el relevamiento';
  END IF;
  -- Sin stock (ni fila) los que entran por primera vez.
  IF EXISTS (SELECT 1 FROM stock_ubicaciones s JOIN t63_prod p ON p.id = s.producto_id
             WHERE p.codigo IN ('229155', '9812345678988', '7798323435267') AND s.cantidad <> 0) THEN
    RAISE EXCEPTION 'Contador, ping pong o Iglú ya tienen stock';
  END IF;
  -- Castillo: la corrección de Alicia sigue siendo el último movimiento.
  IF (SELECT count(*) FROM movimientos_stock m JOIN t63_prod p ON p.id = m.producto_id
      WHERE p.codigo = '7791584741696') <> 2
     OR NOT EXISTS (SELECT 1 FROM movimientos_stock m JOIN t63_prod p ON p.id = m.producto_id
                    WHERE p.codigo = '7791584741696' AND m.tipo = 'inicial' AND m.cantidad = 1
                      AND m.usuario_id = '696bd7fb-aa27-4051-b8cd-d611ee90d1ae') THEN
    RAISE EXCEPTION 'Los movimientos del Castillo cambiaron desde el relevamiento';
  END IF;

  -- ─── 1. Productos nuevos ──────────────────────────────────────────────────────────────────────
  FOR r IN SELECT * FROM (VALUES
      ('N_BANANA_T',  'SKATE BANANA RUEDAS TRANSPARENTES ART FD3108T', 21393::numeric),
      ('N_BANANA_DD', 'SKATE BANANA DOBLE DIBUJO ART FD3108',           18289::numeric),
      ('N_SOLE_FIJ',  'MUÑECA SOLE EN CAJA OJOS FIJOS ART FD5663313',    39990::numeric),
      ('N_COCHE_TOL', 'COCHE PASEO CON TOLDO PARA BEBOTES ART FD05881',  18990::numeric)) AS x(clave, nombre, pu)
  LOOP
    IF EXISTS (SELECT 1 FROM productos WHERE nombre = r.nombre) THEN
      RAISE EXCEPTION 'Ya existe un producto %', r.nombre;
    END IF;
    INSERT INTO productos (nombre, codigo_barras, proveedor_id, marca, costo, margen_1, margen_2, iva_porcentaje)
    VALUES (r.nombre, generar_codigo_interno(), c_faydi, 'FAYDI', ROUND(r.pu * 0.9, 2), 100, 20, 21)
    RETURNING id INTO v_id;
    INSERT INTO t63_prod VALUES (r.clave, v_id);
  END LOOP;

  -- ─── 2. Ítems existentes: precio y/o cantidad ─────────────────────────────────────────────────
  -- (id, cantidad antes, precio antes, cantidad nueva, precio nuevo) — exige que estén como se relevó.
  FOR r IN SELECT * FROM (VALUES
      ('c4c05945-06ed-455d-b393-4d5c5dc733c5'::uuid, 1, 2290::numeric, 1, 22900::numeric),  -- Casita Policía
      ('84373ab0-1fb7-47ab-b3ca-b6054453a673'::uuid, 6, 7990, 6, 9490),    -- Torre flor FDKW696
      ('e9df5754-8ea5-47c5-b110-5a9d96a9e02f'::uuid, 6, 8788, 6, 8789),    -- Cilindro formas FD929150
      ('40acf736-5a9c-4ed7-a8cc-76ff89330321'::uuid, 6, 8788, 6, 8789),    -- Torre x4 formas FDKW440
      ('d6570a3c-4b96-4c91-a7a1-c1c6eeb9dc50'::uuid, 6, 3838, 6, 3839),    -- Encastre x4 FD92844
      ('b451dfc8-b21e-4ef5-8588-429b68555adc'::uuid, 4, 6588, 4, 6589),    -- Pistola cowboy x2 886A
      ('706e179e-4dc9-4cad-a34d-e23edd80a785'::uuid, 4, 6588, 4, 6589),    -- Paleta madera champion
      ('3e8a09d8-2c69-4884-9316-1c99869b7f7d'::uuid, 6, 4188, 6, 4189),    -- Arma collar rectangular
      ('beb552ab-a235-444c-8ac7-a449cd258be9'::uuid, 2, 22900, 1, 22900),  -- Patineta = skate común FD3010T
      ('74db59f6-1085-4825-a597-c6a875fd43e6'::uuid, 2, 21392, 1, 19839),  -- Skate doble dibujo FD3010
      ('011701aa-fcd0-4d82-9191-e7613ee6eab5'::uuid, 2, 39900, 1, 39900),  -- Pelotero Festival
      ('a2df172a-c54c-4472-834f-7a5b8c1967f2'::uuid, 4, 39990, 2, 39990)   -- Muñeca Sole ojos movibles
    ) AS x(id, cant_antes, pu_antes, cant, pu)
  LOOP
    UPDATE facturas_compra_items
    SET cantidad = r.cant, precio_unitario_sin_iva = r.pu,
        precio_total_sin_iva = ROUND(r.cant * r.pu * (1 - descuento_porcentaje / 100.0), 2)
    WHERE id = r.id AND factura_compra_id = c_factura AND cantidad = r.cant_antes
      AND precio_unitario_sin_iva = r.pu_antes AND descuento_porcentaje = 10 AND ubicacion = 'local';
    GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'ítem %: % filas', r.id, n; END IF;
  END LOOP;

  -- Línea "PELOTERO FESTIVAL … ART FD27866" ×1 → Pelotero Iglú ×2 (mismo precio).
  UPDATE facturas_compra_items i
  SET producto_id = (SELECT id FROM t63_prod WHERE codigo = '7798323435267'),
      descripcion = (SELECT nombre FROM productos WHERE codigo_barras = '7798323435267'),
      cantidad = 2, precio_total_sin_iva = ROUND(2 * 39900 * 0.9, 2)
  WHERE i.id = '24c4e67c-bc98-469b-8e00-330b8a0948ec' AND i.factura_compra_id = c_factura
    AND i.producto_id = (SELECT id FROM t63_prod WHERE codigo = '27866')
    AND i.cantidad = 1 AND i.precio_unitario_sin_iva = 39900 AND i.descuento_porcentaje = 10;
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'línea Festival FD27866: % filas', n; END IF;

  -- Pelotero Unicornio: 5 líneas iguales de 1 → queda la primera (por id), se borran 4.
  IF (SELECT count(*) FROM facturas_compra_items WHERE factura_compra_id = c_factura
        AND producto_id = (SELECT id FROM t63_prod WHERE codigo = '7798323435892')
        AND cantidad = 1 AND precio_unitario_sin_iva = 39900 AND descuento_porcentaje = 10) <> 5 THEN
    RAISE EXCEPTION 'El Unicornio no tiene las 5 líneas relevadas';
  END IF;
  DELETE FROM facturas_compra_items
  WHERE factura_compra_id = c_factura
    AND producto_id = (SELECT id FROM t63_prod WHERE codigo = '7798323435892')
    AND id <> (SELECT min(id::text)::uuid FROM facturas_compra_items WHERE factura_compra_id = c_factura
                 AND producto_id = (SELECT id FROM t63_prod WHERE codigo = '7798323435892'));
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 4 THEN RAISE EXCEPTION 'Unicornio: se borraron % líneas', n; END IF;

  -- ─── 2b. Ítems que faltaban ───────────────────────────────────────────────────────────────────
  INSERT INTO facturas_compra_items (factura_compra_id, producto_id, descripcion, cantidad,
         precio_unitario_sin_iva, descuento_porcentaje, precio_total_sin_iva, ubicacion)
  SELECT c_factura, p.id, pr.nombre, x.cant, x.pu, 10, ROUND(x.cant * x.pu * 0.9, 2), 'local'
  FROM (VALUES ('7791584741696', 1, 26900::numeric),   -- Casita Castillo Rosa FYCS9989
               ('229155',        6, 8990),             -- Contador educativo FD229155
               ('9812345678988', 2, 8990),             -- Paleta ping pong x2 FD7700
               ('N_BANANA_T',    1, 21393),            -- Skate banana FD3108T
               ('N_BANANA_DD',   1, 18289),            -- Skate banana doble dibujo FD3108
               ('N_SOLE_FIJ',    2, 39990),            -- Muñeca Sole ojos fijos
               ('N_COCHE_TOL',   1, 18990)) AS x(codigo, cant, pu)
  JOIN t63_prod p ON p.codigo = x.codigo
  JOIN productos pr ON pr.id = p.id;
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 7 THEN RAISE EXCEPTION 'ítems nuevos: % filas', n; END IF;

  -- ─── 3. Stock: una 'compra' (con referencia a la factura) por cada diferencia ─────────────────
  FOR r IN SELECT * FROM (VALUES
      ('7791584741696', 1), ('229155', 6), ('9812345678988', 2), ('7798323435267', 2),
      ('N_BANANA_T', 1), ('N_BANANA_DD', 1), ('N_SOLE_FIJ', 2), ('N_COCHE_TOL', 1),
      ('27866', -1), ('7798323435939', -1), ('7798323435892', -4),
      ('7798323432631', -1), ('7798323432778', -1), ('7798323437186', -2)) AS x(codigo, cant)
  LOOP
    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id)
    VALUES ((SELECT id FROM t63_prod WHERE codigo = r.codigo), 'local', 'compra', r.cant, c_motivo, c_factura, auth.uid());

    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES ((SELECT id FROM t63_prod WHERE codigo = r.codigo), 'local', r.cant)
    ON CONFLICT (producto_id, ubicacion)
    DO UPDATE SET cantidad = stock_ubicaciones.cantidad + EXCLUDED.cantidad;
  END LOOP;

  -- Castillo: contra-asiento de la carga inicial de Alicia (27/10 10:42), ahora entra por la factura.
  INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, usuario_id)
  VALUES ((SELECT id FROM t63_prod WHERE codigo = '7791584741696'), 'local', 'inicial', -1,
          'Revierte la correccion de cantidad del 27/10 10:42: la casita entra por la factura FAYDI 0011-33182 (docs/63)', auth.uid());
  UPDATE stock_ubicaciones SET cantidad = cantidad - 1
  WHERE producto_id = (SELECT id FROM t63_prod WHERE codigo = '7791584741696') AND ubicacion = 'local';
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 1 THEN RAISE EXCEPTION 'stock Castillo: % filas', n; END IF;

  -- ─── 4. Costo de producto, como cargar_factura_compra (precio × 0,9) ──────────────────────────
  -- Ítems con precio corregido: solo si el producto conserva el costo que le puso esta factura.
  UPDATE productos p
  SET costo = ROUND(i.precio_unitario_sin_iva * 0.9, 2), precio_manual = NULL, updated_at = now()
  FROM facturas_compra_items i
  JOIN t63_items_antes a ON a.id = i.id
  WHERE p.id = i.producto_id
    AND a.precio_unitario_sin_iva <> i.precio_unitario_sin_iva
    AND p.costo = ROUND(a.precio_unitario_sin_iva * 0.9, 2);
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 8 THEN RAISE EXCEPTION 'costos corregidos: % (se esperaban 8)', n; END IF;  -- Policía ya estaba en 20.610

  -- Productos que entran por la factura ahora (ya son FAYDI 100/20): costo de su línea.
  UPDATE productos p
  SET costo = ROUND(i.precio_unitario_sin_iva * 0.9, 2), precio_manual = NULL, updated_at = now()
  FROM facturas_compra_items i
  WHERE i.factura_compra_id = c_factura AND p.id = i.producto_id
    AND p.id IN (SELECT id FROM t63_prod WHERE codigo IN ('7791584741696', '229155', '9812345678988', '7798323435267'))
    AND p.proveedor_id = c_faydi AND p.margen_1 = 100 AND p.margen_2 = 20;
  GET DIAGNOSTICS n = ROW_COUNT; IF n <> 4 THEN RAISE EXCEPTION 'costos de productos que entran: % filas', n; END IF;

  -- ─── 5. Totales de la factura y nota de auditoría ─────────────────────────────────────────────
  UPDATE facturas_compra f
  SET total_sin_iva = s.sin_iva, iva = ROUND(s.sin_iva * 0.21, 2), total = s.sin_iva + ROUND(s.sin_iva * 0.21, 2)
  FROM (SELECT SUM(precio_total_sin_iva) AS sin_iva FROM facturas_compra_items WHERE factura_compra_id = c_factura) s
  WHERE f.id = c_factura;

  INSERT INTO auditoria (tabla_afectada, registro_id, accion, valores_anteriores, valores_nuevos, nota, usuario_id)
  SELECT 'facturas_compra', c_factura, 'nota_correccion',
    (SELECT jsonb_agg(to_jsonb(a)) FROM t63_items_antes a
      WHERE NOT EXISTS (SELECT 1 FROM facturas_compra_items i WHERE i.id = a.id AND to_jsonb(i) = to_jsonb(a))),
    (SELECT jsonb_agg(to_jsonb(i)) FROM facturas_compra_items i
      WHERE i.factura_compra_id = c_factura
        AND NOT EXISTS (SELECT 1 FROM t63_items_antes a WHERE a.id = i.id AND to_jsonb(a) = to_jsonb(i))),
    'Corrección contra el PDF (docs/63): faltaban Castillo Rosa FYCS9989, Contador FD229155, Ping pong FD7700, '
    || 'Coche paseo toldo FD05881, Sole ojos fijos y Skates banana FD3108T/FD3108; sobraban 4 Pelotero Unicornio; '
    || 'la línea Festival FD27866 era el Igloo; precios corregidos a × 2 exacto (Policía, Torre flor y 6 de $1).',
    auth.uid();
END
$correccion$;

-- ─── Verificación ───────────────────────────────────────────────────────────────────────────────
INSERT INTO t63_stock
SELECT p.codigo, pr.nombre, COALESCE(s.cantidad, 0)
FROM t63_prod p JOIN productos pr ON pr.id = p.id
LEFT JOIN stock_ubicaciones s ON s.producto_id = p.id AND s.ubicacion = 'local';

SELECT json_build_object(
  'factura', (SELECT row_to_json(x) FROM (
      SELECT total_sin_iva, iva, total, (SELECT count(*) FROM facturas_compra_items WHERE factura_compra_id = f.id) items,
             (SELECT sum(cantidad) FROM facturas_compra_items WHERE factura_compra_id = f.id) unidades
      FROM facturas_compra f WHERE id = '3076dfb2-7654-4b22-8b0c-f709f940dc55') x),
  'stock', (SELECT json_object_agg(producto, local ORDER BY producto) FROM t63_stock),
  'saldo_faydi', (SELECT saldo_actual FROM proveedores_saldo WHERE id = '1b9b2e1d-7e2c-4dd5-9402-8f0601574f24'),
  'nuevos', (SELECT json_agg(json_build_object('n', pr.nombre, 'cod', pr.codigo_barras, 'costo', pr.costo, 'pv', pr.precio_venta))
             FROM t63_prod p JOIN productos pr ON pr.id = p.id WHERE p.codigo LIKE 'N\_%'),
  'costos', (SELECT json_agg(json_build_object('n', pr.nombre, 'costo', pr.costo, 'pv', pr.precio_venta))
             FROM productos pr WHERE pr.id IN (SELECT producto_id FROM facturas_compra_items
               WHERE factura_compra_id = '3076dfb2-7654-4b22-8b0c-f709f940dc55')
               AND pr.updated_at = now()),
  'compra_vs_items', (SELECT count(*) FROM (
      SELECT producto_id, SUM(cantidad) c FROM facturas_compra_items
      WHERE factura_compra_id = '3076dfb2-7654-4b22-8b0c-f709f940dc55' AND producto_id IS NOT NULL GROUP BY 1) i
      FULL JOIN (SELECT producto_id, SUM(cantidad) c FROM movimientos_stock
      WHERE referencia_id = '3076dfb2-7654-4b22-8b0c-f709f940dc55' GROUP BY 1) m USING (producto_id)
      WHERE COALESCE(i.c, 0) <> COALESCE(m.c, 0))
) AS resultado;

-- Esperado: 2 × subtotal del PDF (2.294.233) − 10 % = 4.129.619,40 sin IVA, 468 unidades, 112 ítems
-- (109 − 4 + 7), stock como abajo (Castillo 0 = compra +1, venta −1) y compra neta = ítems en todos.
DO $guarda$
BEGIN
  IF NOT (SELECT total_sin_iva = 4129619.40 AND iva = 867220.07 AND total = 4996839.47
          FROM facturas_compra WHERE id = '3076dfb2-7654-4b22-8b0c-f709f940dc55')
     OR (SELECT sum(cantidad) FROM facturas_compra_items WHERE factura_compra_id = '3076dfb2-7654-4b22-8b0c-f709f940dc55') <> 468
     OR (SELECT count(*) FROM facturas_compra_items WHERE factura_compra_id = '3076dfb2-7654-4b22-8b0c-f709f940dc55') <> 112
     OR EXISTS (
       SELECT 1 FROM (VALUES ('7791584741696', 0), ('229155', 6), ('9812345678988', 2), ('7798323435267', 2),
                             ('27866', 0), ('7798323435939', 1), ('7798323435892', 1), ('7798323432631', 2),
                             ('7798323432778', 1), ('7798323437186', 2), ('N_BANANA_T', 1), ('N_BANANA_DD', 1),
                             ('N_SOLE_FIJ', 2), ('N_COCHE_TOL', 1)) AS e(codigo, cant)
       FULL JOIN t63_stock s USING (codigo)
       WHERE s.local IS DISTINCT FROM e.cant)
     OR EXISTS (
       SELECT 1 FROM (SELECT producto_id, SUM(cantidad) c FROM facturas_compra_items
                      WHERE factura_compra_id = '3076dfb2-7654-4b22-8b0c-f709f940dc55' AND producto_id IS NOT NULL GROUP BY 1) i
       FULL JOIN (SELECT producto_id, SUM(cantidad) c FROM movimientos_stock
                  WHERE referencia_id = '3076dfb2-7654-4b22-8b0c-f709f940dc55' GROUP BY 1) m USING (producto_id)
       WHERE COALESCE(i.c, 0) <> COALESCE(m.c, 0))
  THEN
    RAISE EXCEPTION 'El resultado no coincide con lo esperado: no se confirma nada';
  END IF;
END
$guarda$;

COMMIT;
