-- docs/75 — Corrección de datos: devoluciones N° 2 y N° 3 (12/11/2026, motivo "Regalo")
--
-- Qué pasó: con Local v0.14.0 (docs/74) "defectuoso" pasó a ser una casilla por producto,
-- independiente del motivo. En estas dos devoluciones la casilla quedó tildada en los 4 productos
-- devueltos (se usó para elegir qué se devolvía), así que no volvieron al stock aunque el motivo
-- era Regalo. Desde Local v0.15.0 la casilla solo aparece con motivo Defectuoso.
--
-- Corrección (hecha a pedido el 13/11/2026, backup virikyna_2026-11-13_pre-correccion-devol-2-3):
--   * devolucion_items: defectuoso = false, reingresa_stock = true en las 4 líneas devueltas.
--   * movimientos_stock: +cantidad en 'local', con la fecha y el usuario de la devolución original,
--     el mismo texto que habría puesto crear_devolucion_tickets + " · corregido 13/11".
--   * stock_ubicaciones: +cantidad en 'local'.
-- Si algo no coincide con lo relevado (otra cantidad de líneas, alguna ya corregida o una devolución
-- anulada), aborta sin tocar nada.
--
-- APLICADO en producción: 13/11/2026.

BEGIN;

DO $$
DECLARE
  v_lineas int;
  r record;
BEGIN
  SELECT count(*) INTO v_lineas
  FROM devolucion_items di JOIN devoluciones d ON d.id = di.devolucion_id
  WHERE d.numero IN (2, 3) AND di.tipo = 'devuelto';
  IF v_lineas <> 4 THEN RAISE EXCEPTION 'Se esperaban 4 líneas devueltas, hay %', v_lineas; END IF;

  IF EXISTS (SELECT 1 FROM devolucion_items di JOIN devoluciones d ON d.id = di.devolucion_id
             WHERE d.numero IN (2, 3) AND di.tipo = 'devuelto'
               AND (NOT di.defectuoso OR di.reingresa_stock OR d.estado <> 'activa' OR d.motivo <> 'regalo')) THEN
    RAISE EXCEPTION 'El estado cambió desde el relevamiento: revisar antes de corregir';
  END IF;

  IF EXISTS (SELECT 1 FROM movimientos_stock m JOIN devoluciones d ON d.id = m.referencia_id
             JOIN devolucion_items di ON di.devolucion_id = d.id AND di.producto_id = m.producto_id AND di.tipo = 'devuelto'
             WHERE d.numero IN (2, 3) AND m.cantidad > 0) THEN
    RAISE EXCEPTION 'Ya hay un reingreso de stock para estas devoluciones';
  END IF;

  FOR r IN
    SELECT di.id, di.producto_id, di.cantidad, d.id AS dev_id, d.numero AS dev_numero, d.created_at,
           d.usuario_id, d.motivo, d.cantidad_tickets, v.numero AS venta_numero
    FROM devolucion_items di
    JOIN devoluciones d ON d.id = di.devolucion_id
    JOIN ventas v ON v.id = di.venta_id
    WHERE d.numero IN (2, 3) AND di.tipo = 'devuelto'
  LOOP
    UPDATE devolucion_items SET defectuoso = false, reingresa_stock = true WHERE id = r.id;

    INSERT INTO movimientos_stock (producto_id, ubicacion, tipo, cantidad, motivo, referencia_id, usuario_id, origen, created_at)
    VALUES (r.producto_id, 'local', 'ajuste', r.cantidad,
            'Devolución de venta #' || r.venta_numero || ' (' || r.motivo::text || ')'
              || CASE WHEN r.cantidad_tickets > 1 THEN ' · devolución #' || r.dev_numero ELSE '' END
              || ' · corregido 13/11 (no era defectuoso)',
            r.dev_id, r.usuario_id, 'devolucion_cliente', r.created_at);

    INSERT INTO stock_ubicaciones (producto_id, ubicacion, cantidad)
    VALUES (r.producto_id, 'local', r.cantidad)
    ON CONFLICT (producto_id, ubicacion) DO UPDATE SET cantidad = stock_ubicaciones.cantidad + EXCLUDED.cantidad;
  END LOOP;
END $$;

-- Verificación
SELECT d.numero, di.producto_nombre, di.defectuoso, di.reingresa_stock,
       (SELECT cantidad FROM stock_ubicaciones s WHERE s.producto_id = di.producto_id AND s.ubicacion = 'local') AS stock_local,
       (SELECT string_agg(to_char(m.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires', 'DD/MM HH24:MI') || ' +' || m.cantidad || ' ' || m.motivo, ' | ')
          FROM movimientos_stock m WHERE m.referencia_id = d.id AND m.producto_id = di.producto_id AND m.cantidad > 0) AS reingreso
FROM devolucion_items di JOIN devoluciones d ON d.id = di.devolucion_id
WHERE d.numero IN (2, 3) AND di.tipo = 'devuelto'
ORDER BY d.numero, di.producto_nombre;

COMMIT;
