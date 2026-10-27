-- 61 — Notas con hilos y edición + ventas por producto para el Dashboard de Gestión
--
-- ✅ APLICADO en producción el 2026-10-27 (PARTE A), con backup previo virikyna_2026-10-27_pre-docs61-aplicar.
-- Antes se re-verificó que notas_internas, sus policies y venta_items seguían como en el relevamiento.
-- PARTE B ok (3 columnas, 3 policies sin DELETE, 2 triggers nuevos, vista filtra, sin anon, 2 índices).
-- PARTE C 23/23 antes (2026-10-26, backup virikyna_2026-10-26_pre-docs61) y después de aplicar.
-- Correr desde la raíz del repo con
-- `supabase db query --linked -f docs/61_notas_hilos_y_ventas_por_producto.sql` (o en el SQL Editor
-- del proyecto ccpinvtleqlsukcqnili), después de 59. Antes: backup con etiqueta (pre-docs61).
-- La PARTE A se puede re-correr (IF NOT EXISTS / CREATE OR REPLACE / DROP … IF EXISTS); la PARTE B
-- solo lee y la PARTE C es un test (BEGIN … ROLLBACK). (60 es el registro del incidente de ARCA.)
--
-- Contexto (relevado contra la base real el 2026-10-26, dump virikyna_2026-10-26_2300):
--   - notas_internas (10 filas): id, mensaje, autor_id, archivada, archivada_at, created_at, origen.
--     Una sola policy FOR ALL: cualquier usuario activo lee/edita/BORRA cualquier nota 'local'
--     (incluso de otro autor); 'gestion' solo admin. Sin hilos, sin "editada", sin quién archivó.
--   - notas_internas_con_autor es SECURITY DEFINER a propósito (docs/38: con invoker la RLS de
--     perfiles deja sin nombre a los demás) — pero por eso mismo saltea la RLS de notas_internas:
--     un cajero que la consulta sin filtro VE las notas de Gestión. Hoy solo lo frena el
--     .eq('origen', 'local') de la app.
--   - Local v0.8.0 (instalada) archiva con un UPDATE directo a notas_internas. Si se quitara la
--     policy de UPDATE, dejaría de poder archivar hasta el próximo release: por eso el UPDATE directo
--     queda permitido, pero un trigger de guardia hace cumplir las reglas nuevas (ver 2).
--   - venta_items (271 filas) no tiene índices en venta_id ni producto_id.
--   - No hay categorías de producto: el Dashboard agrupa por marca (decisión 2026-10-26).
--
-- Qué hace:
--   1. notas_internas: parent_id (respuesta a otra nota, hilo anidado), editada_at, archivada_por.
--   2. Trigger de guardia (BEFORE INSERT/UPDATE):
--      - el padre existe, es del mismo origen y no está archivado; sin ciclos;
--      - autor_id, origen, parent_id y created_at no se cambian después del INSERT;
--      - mensaje: solo lo cambia el autor, y al cambiarlo marca editada_at;
--      - archivar/desarchivar completa archivada_at/archivada_por (también desde Local v0.8.0).
--      Trigger AFTER UPDATE: archivar o desarchivar una nota hace lo mismo con todas sus respuestas
--      (recursivo: el UPDATE de cada hija dispara el suyo).
--   3. RLS: SELECT, INSERT (autor = el usuario logueado) y UPDATE con la misma regla de origen que
--      antes. Sin policy de DELETE: ya no se puede borrar una nota desde la app.
--   4. Vista notas_internas_con_autor: DROP + CREATE con las columnas nuevas y filtro propio
--      (usuario activo y origen 'local' o admin) — sigue definer para mostrar nombres.
--   5. RPC editar_nota(id, mensaje): solo el autor; marca editada_at (vía trigger).
--      RPC archivar_nota(id, archivar): cualquier usuario que vea la nota; solo notas principales
--      (archiva/desarchiva el hilo entero).
--   6. Índices venta_items(venta_id) y venta_items(producto_id).
--   7. RPC dashboard_ventas_por_producto(desde, hasta[, ant_desde, ant_hasta]): por producto, en
--      hora AR y sin ventas anuladas — unidades e importe netos de devoluciones activas (devuelto
--      resta, nuevo entregado en un cambio suma, por la fecha de la devolución), stock actual,
--      stock mínimo y lo mismo del período anterior. El importe de cada ítem se prorratea con el
--      precio cobrado de su venta (descuento/recargo incluidos), así la suma por producto coincide
--      con "Ventas" de dashboard_ventas_por_dia. El período anterior por defecto son los mismos días
--      justo antes; el Dashboard pasa el suyo ("mismo tramo de la semana/mes pasado").

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ─── 1. Columnas nuevas ───────────────────────────────────────────────────────────────────────
ALTER TABLE public.notas_internas ADD COLUMN IF NOT EXISTS parent_id uuid REFERENCES public.notas_internas(id);
ALTER TABLE public.notas_internas ADD COLUMN IF NOT EXISTS editada_at timestamptz;
ALTER TABLE public.notas_internas ADD COLUMN IF NOT EXISTS archivada_por uuid REFERENCES public.perfiles(id);
CREATE INDEX IF NOT EXISTS idx_notas_internas_parent ON public.notas_internas(parent_id);

-- ─── 2. Triggers ──────────────────────────────────────────────────────────────────────────────
-- auth.uid() NULL = SQL Editor / service_role (mantenimiento): no se le aplican las reglas de autor.
CREATE OR REPLACE FUNCTION public.notas_internas_guardia() RETURNS trigger
LANGUAGE plpgsql SET search_path = public
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

DROP TRIGGER IF EXISTS trg_notas_internas_guardia ON public.notas_internas;
CREATE TRIGGER trg_notas_internas_guardia BEFORE INSERT OR UPDATE ON public.notas_internas
  FOR EACH ROW EXECUTE FUNCTION public.notas_internas_guardia();

CREATE OR REPLACE FUNCTION public.notas_internas_archivar_hilo() RETURNS trigger
LANGUAGE plpgsql SET search_path = public
AS $$
BEGIN
  UPDATE notas_internas SET archivada = NEW.archivada
  WHERE parent_id = NEW.id AND archivada IS DISTINCT FROM NEW.archivada;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_notas_internas_archivar_hilo ON public.notas_internas;
CREATE TRIGGER trg_notas_internas_archivar_hilo AFTER UPDATE OF archivada ON public.notas_internas
  FOR EACH ROW WHEN (OLD.archivada IS DISTINCT FROM NEW.archivada)
  EXECUTE FUNCTION public.notas_internas_archivar_hilo();

-- ─── 3. RLS ───────────────────────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "notas_internas_todos" ON public.notas_internas;
DROP POLICY IF EXISTS "notas_internas_select" ON public.notas_internas;
DROP POLICY IF EXISTS "notas_internas_insert" ON public.notas_internas;
DROP POLICY IF EXISTS "notas_internas_update" ON public.notas_internas;

CREATE POLICY "notas_internas_select" ON public.notas_internas FOR SELECT USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
  AND (origen = 'local' OR EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin'))
);
CREATE POLICY "notas_internas_insert" ON public.notas_internas FOR INSERT WITH CHECK (
  autor_id = auth.uid()
  AND EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
  AND (origen = 'local' OR EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin'))
);
-- UPDATE directo: lo sigue usando Local v0.8.0 para archivar. Las reglas finas (autor, campos
-- fijos) las hace cumplir trg_notas_internas_guardia.
CREATE POLICY "notas_internas_update" ON public.notas_internas FOR UPDATE USING (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
  AND (origen = 'local' OR EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin'))
) WITH CHECK (
  EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
  AND (origen = 'local' OR EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin'))
);
-- Sin policy de DELETE: con RLS activa, un DELETE desde la app no borra nada.

-- ─── 4. Vista ─────────────────────────────────────────────────────────────────────────────────
-- Definer (dueño postgres) a propósito para resolver autor_nombre; por eso filtra ella misma con
-- la misma regla que la policy de SELECT. security_barrier: el filtro se evalúa antes que
-- cualquier condición que agregue quien consulta.
DROP VIEW IF EXISTS public.notas_internas_con_autor;
CREATE VIEW public.notas_internas_con_autor WITH (security_barrier = true) AS
SELECT n.id, n.mensaje, n.autor_id, n.origen, n.parent_id, n.archivada, n.archivada_at, n.archivada_por,
       n.editada_at, n.created_at,
       p.nombre AS autor_nombre
FROM notas_internas n
JOIN perfiles p ON p.id = n.autor_id
WHERE EXISTS (SELECT 1 FROM perfiles yo WHERE yo.id = auth.uid() AND yo.activo = true)
  AND (n.origen = 'local' OR EXISTS (SELECT 1 FROM perfiles yo WHERE yo.id = auth.uid() AND yo.rol = 'admin'));
REVOKE ALL ON public.notas_internas_con_autor FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.notas_internas_con_autor TO authenticated;

-- ─── 5. RPCs de notas ─────────────────────────────────────────────────────────────────────────
-- Misma regla de visibilidad que la policy, para las RPC SECURITY DEFINER (que saltean RLS).
CREATE OR REPLACE FUNCTION public.nota_visible_para_mi(p_origen text) RETURNS boolean
LANGUAGE sql STABLE SET search_path = public
AS $$
  SELECT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
     AND (p_origen = 'local' OR EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin'));
$$;
REVOKE ALL ON FUNCTION public.nota_visible_para_mi(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.editar_nota(p_nota_id uuid, p_mensaje text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
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
REVOKE ALL ON FUNCTION public.editar_nota(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.editar_nota(uuid, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.archivar_nota(p_nota_id uuid, p_archivar boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
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
REVOKE ALL ON FUNCTION public.archivar_nota(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.archivar_nota(uuid, boolean) TO authenticated, service_role;

-- ─── 6. Índices ───────────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_venta_items_venta ON public.venta_items(venta_id);
CREATE INDEX IF NOT EXISTS idx_venta_items_producto ON public.venta_items(producto_id);

-- ─── 7. dashboard_ventas_por_producto ─────────────────────────────────────────────────────────
-- Invoker (como dashboard_ventas_por_dia): lee con la RLS de quien llama.
CREATE OR REPLACE FUNCTION public.dashboard_ventas_por_producto(
  p_desde date,
  p_hasta date,
  p_ant_desde date DEFAULT NULL,
  p_ant_hasta date DEFAULT NULL
) RETURNS TABLE (
  producto_id uuid,
  nombre text,
  marca text,
  unidades numeric,
  importe numeric,
  stock_actual numeric,
  stock_minimo numeric,
  unidades_periodo_anterior numeric,
  importe_periodo_anterior numeric
)
LANGUAGE sql STABLE SET search_path = public
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
    CROSS JOIN rango r
    WHERE d.estado = 'activa' AND d.fecha BETWEEN r.desde AND r.hasta
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
REVOKE ALL ON FUNCTION public.dashboard_ventas_por_producto(date, date, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dashboard_ventas_por_producto(date, date, date, date) TO authenticated, service_role;

COMMIT;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (solo lectura)
-- ════════════════════════════════════════════════════════════════════════════════════════════
SELECT 'columnas' AS que, string_agg(column_name, ', ' ORDER BY column_name) AS valor
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'notas_internas' AND column_name IN ('parent_id', 'editada_at', 'archivada_por')
UNION ALL
SELECT 'policies', string_agg(policyname || ':' || cmd, ', ' ORDER BY policyname) FROM pg_policies WHERE tablename = 'notas_internas'
UNION ALL
SELECT 'triggers', string_agg(tgname, ', ' ORDER BY tgname) FROM pg_trigger WHERE tgrelid = 'public.notas_internas'::regclass AND NOT tgisinternal
UNION ALL
SELECT 'vista filtra', (pg_get_viewdef('public.notas_internas_con_autor') LIKE '%auth.uid()%')::text
UNION ALL
SELECT 'anon ejecuta', string_agg(p.proname, ', ') FROM pg_proc p
  WHERE p.pronamespace = 'public'::regnamespace
    AND p.proname IN ('editar_nota', 'archivar_nota', 'dashboard_ventas_por_producto', 'nota_visible_para_mi')
    AND has_function_privilege('anon', p.oid, 'EXECUTE')
UNION ALL
SELECT 'indices venta_items', string_agg(indexname, ', ' ORDER BY indexname) FROM pg_indexes WHERE tablename = 'venta_items' AND indexname LIKE 'idx_%';
-- Esperado: columnas = archivada_por, editada_at, parent_id · policies = insert:INSERT, select:SELECT,
-- update:UPDATE (sin la vieja _todos) · triggers = guardia, archivar_hilo, trg_sin_acentos ·
-- vista filtra = true · anon ejecuta = NULL · índices = idx_venta_items_producto, idx_venta_items_venta.


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (no deja nada: BEGIN … ROLLBACK)
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- Corre como el rol `authenticated` con el JWT de un cajero y de un admin reales (SET LOCAL ROLE +
-- request.jwt.claims), así se prueban la RLS y la vista de verdad. Las notas y la devolución de
-- prueba se crean dentro de la transacción. Resultado: una tabla, todo ok = true.
BEGIN;

CREATE TEMP TABLE t61 (orden int, caso text, ok boolean, detalle text) ON COMMIT DROP;
CREATE TEMP TABLE t61_ids (clave text PRIMARY KEY, id uuid) ON COMMIT DROP;
GRANT ALL ON t61, t61_ids TO authenticated;

INSERT INTO t61_ids
SELECT 'cajero', (SELECT id FROM perfiles WHERE rol = 'cajero' AND activo ORDER BY created_at LIMIT 1)
UNION ALL SELECT 'cajero2', (SELECT id FROM perfiles WHERE rol = 'cajero' AND activo ORDER BY created_at OFFSET 1 LIMIT 1)
UNION ALL SELECT 'admin', (SELECT id FROM perfiles WHERE rol = 'admin' AND activo ORDER BY created_at LIMIT 1);

-- Nota de Gestión (como postgres, para tenerla seguro) — el cajero no la tiene que ver.
INSERT INTO notas_internas (id, mensaje, autor_id, origen)
SELECT '61000000-0000-0000-0000-00000000000a', 'PRUEBA 61 GESTION', id, 'gestion' FROM t61_ids WHERE clave = 'admin';

-- ─── Como cajero ──────────────────────────────────────────────────────────────────────────────
SELECT set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true) FROM t61_ids WHERE clave = 'cajero';
SET LOCAL ROLE authenticated;

DO $$
DECLARE
  v_cajero uuid := (SELECT id FROM t61_ids WHERE clave = 'cajero');
  v_otro uuid := (SELECT coalesce(max(id::text) FILTER (WHERE clave = 'cajero2'), max(id::text) FILTER (WHERE clave = 'admin'))::uuid FROM t61_ids);
  v_n int;
  v_txt text;
  v_r record;
BEGIN
  -- 1. La vista sin filtro no muestra notas de Gestión.
  SELECT count(*) INTO v_n FROM notas_internas_con_autor WHERE origen = 'gestion';
  INSERT INTO t61 VALUES (1, 'cajero: vista sin filtro no trae Gestión', v_n = 0, v_n || ' filas gestion');

  -- 2. Crear nota raíz y un hilo de 4 niveles.
  INSERT INTO notas_internas (id, mensaje, autor_id, origen) VALUES ('61000000-0000-0000-0000-000000000001', 'PRUEBA 61 RAIZ', v_cajero, 'local');
  INSERT INTO notas_internas (id, mensaje, autor_id, origen, parent_id) VALUES ('61000000-0000-0000-0000-000000000002', 'R1', v_cajero, 'local', '61000000-0000-0000-0000-000000000001');
  INSERT INTO notas_internas (id, mensaje, autor_id, origen, parent_id) VALUES ('61000000-0000-0000-0000-000000000003', 'R2', v_cajero, 'local', '61000000-0000-0000-0000-000000000002');
  INSERT INTO notas_internas (id, mensaje, autor_id, origen, parent_id) VALUES ('61000000-0000-0000-0000-000000000004', 'R3', v_cajero, 'local', '61000000-0000-0000-0000-000000000003');
  SELECT count(*) INTO v_n FROM notas_internas_con_autor WHERE id::text LIKE '61000000-0000-0000-0000-00000000000_' AND origen = 'local';
  INSERT INTO t61 VALUES (2, 'cajero: hilo anidado de 4 niveles', v_n = 4, v_n || ' notas en la vista');

  -- 3. Nota a nombre de otro usuario → RLS.
  BEGIN
    INSERT INTO notas_internas (mensaje, autor_id, origen) VALUES ('X', v_otro, 'local');
    INSERT INTO t61 VALUES (3, 'cajero: no crea notas a nombre de otro', false, 'se insertó');
  EXCEPTION WHEN insufficient_privilege THEN INSERT INTO t61 VALUES (3, 'cajero: no crea notas a nombre de otro', true, SQLERRM);
  END;

  -- 4. Nota de Gestión → RLS.
  BEGIN
    INSERT INTO notas_internas (mensaje, autor_id, origen) VALUES ('X', v_cajero, 'gestion');
    INSERT INTO t61 VALUES (4, 'cajero: no crea notas de Gestión', false, 'se insertó');
  EXCEPTION WHEN insufficient_privilege THEN INSERT INTO t61 VALUES (4, 'cajero: no crea notas de Gestión', true, SQLERRM);
  END;

  -- 5. Respuesta 'local' a una nota de Gestión → no la ve (padre "no existe" o RLS).
  BEGIN
    INSERT INTO notas_internas (mensaje, autor_id, origen, parent_id) VALUES ('X', v_cajero, 'local', '61000000-0000-0000-0000-00000000000a');
    INSERT INTO t61 VALUES (5, 'respuesta a nota de otro origen', false, 'se insertó');
  EXCEPTION WHEN OTHERS THEN INSERT INTO t61 VALUES (5, 'respuesta a nota de otro origen', true, SQLERRM);
  END;

  -- 6. editar_nota propia → editada_at.
  PERFORM editar_nota('61000000-0000-0000-0000-000000000001', 'PRUEBA 61 RAIZ EDITADA');
  SELECT mensaje, editada_at INTO v_r FROM notas_internas WHERE id = '61000000-0000-0000-0000-000000000001';
  INSERT INTO t61 VALUES (6, 'editar_nota propia marca editada_at', v_r.mensaje = 'PRUEBA 61 RAIZ EDITADA' AND v_r.editada_at IS NOT NULL, v_r.mensaje);

  -- 7. archivar_nota de una respuesta → error.
  BEGIN
    PERFORM archivar_nota('61000000-0000-0000-0000-000000000003', true);
    INSERT INTO t61 VALUES (7, 'archivar una respuesta sola', false, 'se archivó');
  EXCEPTION WHEN OTHERS THEN INSERT INTO t61 VALUES (7, 'archivar una respuesta sola', true, SQLERRM);
  END;

  -- 8. DELETE → no borra.
  DELETE FROM notas_internas WHERE id = '61000000-0000-0000-0000-000000000004';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  INSERT INTO t61 VALUES (8, 'DELETE no borra', v_n = 0, v_n || ' filas borradas');

  -- 9. Cambiar parent_id → error.
  BEGIN
    UPDATE notas_internas SET parent_id = NULL WHERE id = '61000000-0000-0000-0000-000000000004';
    INSERT INTO t61 VALUES (9, 'parent_id fijo', false, 'se cambió');
  EXCEPTION WHEN OTHERS THEN INSERT INTO t61 VALUES (9, 'parent_id fijo', true, SQLERRM);
  END;

  -- 10. RPC sin anon.
  INSERT INTO t61 VALUES (10, 'anon no ejecuta las RPC nuevas',
    NOT has_function_privilege('anon', 'public.editar_nota(uuid, text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.archivar_nota(uuid, boolean)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.dashboard_ventas_por_producto(date, date, date, date)', 'EXECUTE'), '');
END $$;

-- ─── Como otro usuario (admin) ────────────────────────────────────────────────────────────────
SELECT set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated')::text, true) FROM t61_ids WHERE clave = 'admin';

DO $$
DECLARE
  v_admin uuid := (SELECT id FROM t61_ids WHERE clave = 'admin');
  v_n int;
  v_r record;
BEGIN
  -- 11. editar_nota ajena → error.
  BEGIN
    PERFORM editar_nota('61000000-0000-0000-0000-000000000002', 'HACKEADA');
    INSERT INTO t61 VALUES (11, 'editar_nota ajena', false, 'se editó');
  EXCEPTION WHEN OTHERS THEN INSERT INTO t61 VALUES (11, 'editar_nota ajena', true, SQLERRM);
  END;

  -- 12. UPDATE directo del mensaje ajeno (camino de Local v0.8.0) → error del trigger.
  BEGIN
    UPDATE notas_internas SET mensaje = 'HACKEADA' WHERE id = '61000000-0000-0000-0000-000000000002';
    INSERT INTO t61 VALUES (12, 'UPDATE directo de mensaje ajeno', false, 'se editó');
  EXCEPTION WHEN OTHERS THEN INSERT INTO t61 VALUES (12, 'UPDATE directo de mensaje ajeno', true, SQLERRM);
  END;

  -- 13. archivar_nota de la raíz (otro usuario) → archiva el hilo entero y guarda quién.
  PERFORM archivar_nota('61000000-0000-0000-0000-000000000001', true);
  SELECT count(*) FILTER (WHERE archivada AND archivada_por = v_admin AND archivada_at IS NOT NULL) AS ok, count(*) AS total
    INTO v_r FROM notas_internas WHERE id::text LIKE '61000000-0000-0000-0000-00000000000_' AND origen = 'local';
  INSERT INTO t61 VALUES (13, 'archivar raíz archiva el hilo (4) con archivada_por', v_r.ok = 4 AND v_r.total = 4, v_r.ok || '/' || v_r.total);

  -- 14. Responder una nota archivada → error.
  BEGIN
    INSERT INTO notas_internas (mensaje, autor_id, origen, parent_id) VALUES ('X', v_admin, 'local', '61000000-0000-0000-0000-000000000002');
    INSERT INTO t61 VALUES (14, 'responder nota archivada', false, 'se insertó');
  EXCEPTION WHEN OTHERS THEN INSERT INTO t61 VALUES (14, 'responder nota archivada', true, SQLERRM);
  END;

  -- 15. Desarchivar la raíz → desarchiva el hilo y limpia archivada_at/por.
  PERFORM archivar_nota('61000000-0000-0000-0000-000000000001', false);
  SELECT count(*) FILTER (WHERE NOT archivada AND archivada_por IS NULL AND archivada_at IS NULL) AS ok
    INTO v_r FROM notas_internas WHERE id::text LIKE '61000000-0000-0000-0000-00000000000_' AND origen = 'local';
  INSERT INTO t61 VALUES (15, 'desarchivar raíz desarchiva el hilo', v_r.ok = 4, v_r.ok || '/4');

  -- 16. Archivar con UPDATE directo (Local v0.8.0) sigue andando y propaga.
  UPDATE notas_internas SET archivada = true, archivada_at = now() WHERE id = '61000000-0000-0000-0000-000000000001';
  SELECT count(*) FILTER (WHERE archivada AND archivada_por = v_admin) AS ok
    INTO v_r FROM notas_internas WHERE id::text LIKE '61000000-0000-0000-0000-00000000000_' AND origen = 'local';
  INSERT INTO t61 VALUES (16, 'UPDATE directo de archivada (v0.8.0) propaga', v_r.ok = 4, v_r.ok || '/4');

  -- 17. Admin ve la nota de Gestión en la vista.
  SELECT count(*) INTO v_n FROM notas_internas_con_autor WHERE id = '61000000-0000-0000-0000-00000000000a';
  INSERT INTO t61 VALUES (17, 'admin: vista trae Gestión', v_n = 1, v_n || '');
END $$;

-- ─── Ventas por producto ──────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_hoy date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_total_dia numeric;
  v_total_prod numeric;
  v_r record;
  v_r2 record;
BEGIN
  -- 18. Suma por producto = "Ventas" del día (sin devoluciones en el rango 7 días atrás … hace 1).
  SELECT COALESCE(SUM(total), 0) INTO v_total_dia FROM dashboard_ventas_por_dia(v_hoy - 7, v_hoy - 1);
  SELECT COALESCE(SUM(importe), 0) INTO v_total_prod FROM dashboard_ventas_por_producto(v_hoy - 7, v_hoy - 1);
  INSERT INTO t61 VALUES (18, 'suma por producto = ventas por día (sin devol.)',
    abs(v_total_dia - v_total_prod) < 0.05
    OR EXISTS (SELECT 1 FROM devoluciones WHERE estado = 'activa' AND fecha BETWEEN v_hoy - 7 AND v_hoy - 1),
    v_total_dia || ' vs ' || v_total_prod);

  -- 19. Unidades = suma de cantidades vendidas (mismo rango).
  SELECT SUM(unidades) AS u INTO v_r FROM dashboard_ventas_por_producto(v_hoy - 7, v_hoy - 1);
  SELECT SUM(vi.cantidad) AS u INTO v_r2 FROM ventas v JOIN venta_items vi ON vi.venta_id = v.id
    WHERE v.estado <> 'anulada'
      AND v.created_at >= ((v_hoy - 7)::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires')
      AND v.created_at < (v_hoy::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires');
  INSERT INTO t61 VALUES (19, 'unidades = cantidades vendidas',
    v_r.u IS NOT DISTINCT FROM v_r2.u
    OR EXISTS (SELECT 1 FROM devoluciones WHERE estado = 'activa' AND fecha BETWEEN v_hoy - 7 AND v_hoy - 1),
    coalesce(v_r.u, 0) || ' vs ' || coalesce(v_r2.u, 0));
END $$;

RESET ROLE;

-- 20. Devolución de prueba hoy (numero negativo + OVERRIDING SYSTEM VALUE: no consume la secuencia).
DO $$
DECLARE
  v_hoy date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_venta ventas%ROWTYPE;
  v_prod uuid;
  v_precio numeric;
  v_antes record;
  v_despues record;
  v_nuevo uuid;
  v_nuevo_antes numeric;
  v_nuevo_despues numeric;
BEGIN
  SELECT v.* INTO v_venta FROM ventas v WHERE v.estado <> 'anulada' ORDER BY v.created_at DESC LIMIT 1;
  SELECT vi.producto_id, vi.precio_unitario INTO v_prod, v_precio FROM venta_items vi WHERE vi.venta_id = v_venta.id LIMIT 1;
  SELECT id INTO v_nuevo FROM productos WHERE estado = 'activo' AND id <> v_prod ORDER BY nombre LIMIT 1;

  SELECT COALESCE(SUM(unidades), 0) AS u, COALESCE(SUM(importe), 0) AS i INTO v_antes FROM dashboard_ventas_por_producto(v_hoy, v_hoy) WHERE producto_id = v_prod;
  SELECT COALESCE(SUM(unidades), 0) INTO v_nuevo_antes FROM dashboard_ventas_por_producto(v_hoy, v_hoy) WHERE producto_id = v_nuevo;

  INSERT INTO devoluciones (id, numero, venta_id, fecha, usuario_id, motivo, diferencia_monto, estado)
  OVERRIDING SYSTEM VALUE
  VALUES ('61000000-0000-0000-0000-0000000000d1', -61, v_venta.id, v_hoy, v_venta.usuario_id, 'regalo', 0, 'activa');
  INSERT INTO devolucion_items (devolucion_id, tipo, producto_id, cantidad, precio_unitario, reingresa_stock)
  VALUES ('61000000-0000-0000-0000-0000000000d1', 'devuelto', v_prod, 1, v_precio, true),
         ('61000000-0000-0000-0000-0000000000d1', 'nuevo', v_nuevo, 2, 100, true);

  SELECT COALESCE(SUM(unidades), 0) AS u, COALESCE(SUM(importe), 0) AS i INTO v_despues FROM dashboard_ventas_por_producto(v_hoy, v_hoy) WHERE producto_id = v_prod;
  SELECT COALESCE(SUM(unidades), 0) INTO v_nuevo_despues FROM dashboard_ventas_por_producto(v_hoy, v_hoy) WHERE producto_id = v_nuevo;
  INSERT INTO t61 VALUES (20, 'devuelto resta unidades e importe',
    v_despues.u = v_antes.u - 1 AND v_despues.i = v_antes.i - v_precio,
    v_antes.u || '→' || v_despues.u || ' · ' || v_antes.i || '→' || v_despues.i);
  INSERT INTO t61 VALUES (21, 'nuevo entregado en cambio suma unidades', v_nuevo_despues = v_nuevo_antes + 2,
    v_nuevo_antes || '→' || v_nuevo_despues);

  -- 22. Anulada → deja de contar.
  UPDATE devoluciones SET estado = 'anulada' WHERE id = '61000000-0000-0000-0000-0000000000d1';
  SELECT COALESCE(SUM(unidades), 0) AS u INTO v_despues FROM dashboard_ventas_por_producto(v_hoy, v_hoy) WHERE producto_id = v_prod;
  INSERT INTO t61 VALUES (22, 'devolución anulada no descuenta', v_despues.u = v_antes.u, v_despues.u || '');

  -- 23. Período anterior explícito: ayer como "anterior" de hoy = unidades de ayer como actual.
  INSERT INTO t61 VALUES (23, 'unidades_periodo_anterior = período anterior pedido',
    NOT EXISTS (
      SELECT 1 FROM dashboard_ventas_por_producto(v_hoy, v_hoy, v_hoy - 1, v_hoy - 1) a
      JOIN dashboard_ventas_por_producto(v_hoy - 1, v_hoy - 1) b USING (producto_id)
      WHERE a.unidades_periodo_anterior <> b.unidades
    ), '');
END $$;

SELECT orden, caso, ok, detalle FROM t61 ORDER BY orden;

ROLLBACK;
