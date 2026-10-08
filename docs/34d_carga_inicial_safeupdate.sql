-- 34d — Carga inicial: abrir/cerrar con WHERE (pg_safeupdate)
--
-- docs/06_estructura_de_datos.md, sección 24 (subsección 34d). Correr en el SQL Editor de Supabase
-- (proyecto ccpinvtleqlsukcqnili), después de 34c:
--   PARTE A — cambios (una transacción). Una sola vez.
--   PARTE C — test, dentro de BEGIN … ROLLBACK.
--
-- Bug (encontrado en la prueba E2E del 2026-10-08): "Abrir carga" en Gestión respondía 400
-- "UPDATE requires a WHERE clause". Supabase carga la extensión safeupdate para las conexiones de la
-- API (rol authenticator: session_preload_libraries = supautils, safeupdate), que rechaza todo
-- UPDATE/DELETE sin WHERE — aunque la tabla tenga una sola fila. abrir_carga_inicial y
-- cerrar_carga_inicial (docs/34) hacían UPDATE configuracion SET … sin WHERE. Los tests de 34/34b/34c
-- no lo vieron porque corren por el SQL Editor / Management API, donde safeupdate no se carga.
--
-- Revisadas todas las funciones de public: son las dos únicas con UPDATE/DELETE sin WHERE (los
-- "ON CONFLICT … DO UPDATE" no cuentan para safeupdate).
--
-- Regla para lo que venga: toda escritura en configuracion lleva WHERE fila_unica.


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios (una transacción)
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION abrir_carga_inicial() RETURNS configuracion
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
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

CREATE OR REPLACE FUNCTION cerrar_carga_inicial() RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
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

COMMIT;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — TEST (después de A). BEGIN … ROLLBACK: no deja datos.
-- safeupdate no se puede cargar desde el SQL Editor (LOAD 'safeupdate' → "access to library is not
-- allowed"), así que acá se controla el cuerpo de las funciones y que abran/cierren. La prueba real
-- con safeupdate es desde la app (botones Abrir / Cerrar carga de Gestión).
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $$
DECLARE
  v_admin UUID;
  v_abierta BOOLEAN;
  v_res JSONB;
BEGIN
  SELECT id INTO v_admin FROM perfiles WHERE rol = 'admin' AND activo ORDER BY created_at LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  ASSERT (SELECT bool_and(prosrc ~ 'UPDATE configuracion[^;]*WHERE fila_unica') FROM pg_proc
          WHERE pronamespace = 'public'::regnamespace AND proname IN ('abrir_carga_inicial', 'cerrar_carga_inicial')),
         'abrir/cerrar: UPDATE configuracion con WHERE fila_unica';

  SELECT carga_inicial_abierta INTO v_abierta FROM configuracion;
  IF v_abierta THEN
    v_res := cerrar_carga_inicial();
    ASSERT NOT (SELECT carga_inicial_abierta FROM configuracion), 'cerrar con safeupdate';
    PERFORM abrir_carga_inicial();
    ASSERT (SELECT carga_inicial_abierta FROM configuracion), 'abrir con safeupdate';
  ELSE
    PERFORM abrir_carga_inicial();
    ASSERT (SELECT carga_inicial_abierta AND abierta_por = v_admin FROM configuracion), 'abrir con safeupdate';
    v_res := cerrar_carga_inicial();
    ASSERT NOT (SELECT carga_inicial_abierta FROM configuracion), 'cerrar con safeupdate';
  END IF;

  RAISE NOTICE 'docs/34d: test pasó';
END;
$$;

ROLLBACK;
