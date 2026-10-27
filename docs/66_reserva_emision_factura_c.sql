-- 66 — Reserva de la venta antes de pedir CAE: una venta, una sola Factura C aunque se emita desde dos pantallas
--
-- ✅ APLICADO en producción el 2026-10-27 19:13 (PARTE A), con backup previo
-- virikyna_2026-10-27_pre-docs66-aplicar. Antes se verificó que emitir_factura_c en prod era idéntica a
-- docs/59 y que las RPC nuevas no existían. PARTE B ok (7 funciones SECURITY DEFINER sin anon, RLS, 0
-- filas); PARTE C 9/9 en producción. Después: deploy de arca-emitir-factura v19. Prueba de simultaneidad
-- sin emitir: dos transacciones (abortadas) sobre la misma venta, la segunda esperó 4,1 s el lock.
-- Antes se había probado entera (A + B + C) sobre la restauración local del backup
-- virikyna_2026-10-27_pre-docs66-reserva-fc (restaurar-prueba.ps1, :54329): PARTE C 9/9, dos corridas.
--
-- Correr desde la raíz del repo, por partes, con `supabase db query --linked -f <archivo>` (o en el SQL
-- Editor del proyecto ccpinvtleqlsukcqnili), después de 65. La PARTE A se puede re-correr; la PARTE B solo
-- lee; la PARTE C es un test (termina en error a propósito: la transacción aborta y el mensaje trae
-- "RESULTADO").
--
-- Orden de deploy: 1) esta migración, 2) arca-emitir-factura, 3) apps. La función nueva necesita estas RPC;
-- las apps instaladas siguen andando con la función nueva (emitir_factura_c es idempotente, ver abajo).
--
-- Contexto (relevado el 2026-10-27): la Edge Function revisaba "sin factura" con un SELECT común y recién
-- después de hablar con ARCA el cliente guardaba el CAE. Dos pantallas emitiendo la misma venta pasaban las
-- dos el control, ARCA les daba N+1 y N+2 (dos CAE reales) y el UNIQUE de facturas_c.venta_id hacía fallar
-- el guardado de la segunda: comprobante fiscal huérfano, sin Nota de Crédito para anularlo. Mismo riesgo si
-- la app se cerraba entre la respuesta de ARCA y el guardado. Chequeo de huérfanos al 2026-10-27
-- (scripts/chequear-huerfanos-factura-c.ts): ARCA producción PV 2 último 44 = máximo de la base; solo falta
-- el N° 1 (prueba conocida del 14/09). No hubo ninguno.
--
-- Qué hace:
--   1. Tabla emisiones_factura_c_en_curso: una fila por venta reservada. Tabla aparte y no columnas en
--      ventas para no llenar auditoria con una "edición de venta" por cada reserva/liberación
--      (trg_auditoria_ventas). Solo se escribe por estas RPC (RLS: lectura para activos, sin escritura).
--   2. reservar_emision_factura_c: toma la venta (FOR UPDATE) si está sin facturar, sin reserva vigente y
--      sin marca de revisar. Una reserva vence a los 5 minutos (más que lo que puede durar la función con
--      la reserva tomada, ~2 min). Al tomar una vencida devuelve el último número de ARCA que había
--      guardado el intento anterior (pendiente): la función compara con ARCA antes de emitir.
--   3. registrar_ultimo_arca_emision_factura_c: la función guarda el último número de ARCA ANTES de pedir
--      el CAE. Si muere después, el que tome la reserva vencida sabe contra qué comparar.
--   4. liberar_emision_factura_c: suelta la reserva cuando seguro no se emitió nada (ARCA rechazó, o falló
--      antes de pedir el CAE). Ante un error ambiguo (timeout, red) la función NO libera: la reserva vence.
--   5. marcar_revisar_emision_factura_c: reserva vencida y el último número de ARCA cambió → puede haber una
--      factura emitida para esta venta. Queda bloqueada hasta que un admin la revise.
--   6. emitir_factura_c: idempotente (mismo CAE para la misma venta → devuelve la factura existente; las
--      apps instaladas lo llaman después de que la función ya guardó) y borra la reserva.
--   7. listar_emisiones_factura_c_a_revisar (activos) y desbloquear_emision_factura_c (admin, auditado).
--
-- Fuera de alcance: recuperar automáticamente el CAE con FECompConsultar; la acción `reemitir` (script de
-- admin, docs/59) no reserva.

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ─── 1. Tabla ────────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.emisiones_factura_c_en_curso (
  venta_id uuid PRIMARY KEY REFERENCES public.ventas(id),
  -- Cambia en cada toma (también al tomar una vencida): las RPC siguientes la exigen, así una función
  -- vieja a la que le tomaron la reserva no pisa nada.
  token uuid NOT NULL,
  tomada_at timestamptz NOT NULL,
  tomada_por uuid NOT NULL REFERENCES public.perfiles(id),
  -- Último número autorizado en ARCA justo antes de pedir el CAE, y quién/cuándo lo pidió. Sobreviven a
  -- la toma de una reserva vencida: son lo que hay que comparar.
  ambiente text CHECK (ambiente IN ('homologacion', 'produccion')),
  ultimo_arca integer,
  registrado_at timestamptz,
  registrado_por uuid REFERENCES public.perfiles(id),
  -- Bloqueada para revisión: cuándo, quién lo detectó y qué número tenía ARCA en ese momento.
  revisar_at timestamptz,
  revisar_detectado_por uuid REFERENCES public.perfiles(id),
  ultimo_arca_actual integer,
  CHECK ((ultimo_arca IS NULL) = (ambiente IS NULL))
);

ALTER TABLE public.emisiones_factura_c_en_curso ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS emisiones_factura_c_en_curso_select ON public.emisiones_factura_c_en_curso;
CREATE POLICY emisiones_factura_c_en_curso_select ON public.emisiones_factura_c_en_curso
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.activo = true));
REVOKE ALL ON public.emisiones_factura_c_en_curso FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.emisiones_factura_c_en_curso FROM authenticated;
GRANT SELECT ON public.emisiones_factura_c_en_curso TO authenticated;

-- ─── 2. reservar_emision_factura_c ───────────────────────────────────────────────────────────
-- resultado: 'reservada' (con token y, si se tomó una vencida que había llegado a ARCA, pendiente_*),
-- 'en_curso', 'revisar', 'ya_facturada' o 'no_encontrada'.
CREATE OR REPLACE FUNCTION public.reservar_emision_factura_c(p_venta_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_estado estado_comprobante;
  v_res emisiones_factura_c_en_curso%ROWTYPE;
  v_token uuid := gen_random_uuid();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  -- El lock de la venta serializa reservas y el guardado de la factura (emitir_factura_c).
  SELECT estado INTO v_estado FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('resultado', 'no_encontrada');
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

-- ─── 3. registrar_ultimo_arca_emision_factura_c ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.registrar_ultimo_arca_emision_factura_c(
  p_venta_id uuid, p_token uuid, p_ambiente text, p_ultimo integer
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
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

-- ─── 4. liberar_emision_factura_c ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.liberar_emision_factura_c(p_venta_id uuid, p_token uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
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

-- ─── 5. marcar_revisar_emision_factura_c ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.marcar_revisar_emision_factura_c(
  p_venta_id uuid, p_token uuid, p_ultimo_actual integer
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
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

-- ─── 6. emitir_factura_c idempotente + borra la reserva ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.emitir_factura_c(
  p_venta_id uuid,
  p_cae text,
  p_numero_factura text,
  p_punto_venta text,
  p_ambiente text DEFAULT 'homologacion'
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
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

-- ─── 7. Revisión (admin) ─────────────────────────────────────────────────────────────────────
-- SECURITY DEFINER para poder mostrar nombres: perfiles solo deja leer el propio.
CREATE OR REPLACE FUNCTION public.listar_emisiones_factura_c_a_revisar()
RETURNS TABLE (
  venta_id uuid,
  venta_numero bigint,
  venta_total numeric,
  venta_fecha timestamptz,
  ambiente text,
  registrado_at timestamptz,
  registrado_por_nombre text,
  ultimo_arca integer,
  ultimo_arca_actual integer,
  revisar_at timestamptz,
  revisar_detectado_por_nombre text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
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

-- El admin confirmó en ARCA que no hay factura para esta venta: se puede volver a emitir.
CREATE OR REPLACE FUNCTION public.desbloquear_emision_factura_c(p_venta_id uuid, p_nota text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
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

REVOKE ALL ON FUNCTION public.reservar_emision_factura_c(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.registrar_ultimo_arca_emision_factura_c(uuid, uuid, text, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.liberar_emision_factura_c(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.marcar_revisar_emision_factura_c(uuid, uuid, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.emitir_factura_c(uuid, text, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.listar_emisiones_factura_c_a_revisar() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.desbloquear_emision_factura_c(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reservar_emision_factura_c(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.registrar_ultimo_arca_emision_factura_c(uuid, uuid, text, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.liberar_emision_factura_c(uuid, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.marcar_revisar_emision_factura_c(uuid, uuid, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.emitir_factura_c(uuid, text, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.listar_emisiones_factura_c_a_revisar() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.desbloquear_emision_factura_c(uuid, text) TO authenticated, service_role;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (solo lee)
-- ════════════════════════════════════════════════════════════════════════════════════════════
SELECT p.oid::regprocedure AS funcion, p.prosecdef AS security_definer, p.proacl
FROM pg_proc p
WHERE p.proname IN ('reservar_emision_factura_c', 'registrar_ultimo_arca_emision_factura_c',
                    'liberar_emision_factura_c', 'marcar_revisar_emision_factura_c', 'emitir_factura_c',
                    'listar_emisiones_factura_c_a_revisar', 'desbloquear_emision_factura_c')
ORDER BY 1;

SELECT relrowsecurity, (SELECT count(*) FROM emisiones_factura_c_en_curso) AS filas
FROM pg_class WHERE oid = 'public.emisiones_factura_c_en_curso'::regclass;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (BEGIN … ROLLBACK: no deja nada escrito; termina siempre en RAISE con el resultado)
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
  v_admin uuid;
  v_cajero uuid;
  v_venta uuid;
  v_r1 jsonb;
  v_r2 jsonb;
  v_token uuid;
  v_factura uuid;
  v_factura2 uuid;
  v_ok int := 0;
  v_fallas text := '';
  v_b boolean;
BEGIN
  SELECT id INTO v_admin FROM perfiles WHERE rol = 'admin' AND activo LIMIT 1;
  SELECT id INTO v_cajero FROM perfiles WHERE rol = 'cajero' AND activo LIMIT 1;
  SELECT v.id INTO v_venta FROM ventas v
    WHERE v.estado = 'sin_facturar'
      AND NOT EXISTS (SELECT 1 FROM facturas_c f WHERE f.venta_id = v.id)
      AND NOT EXISTS (SELECT 1 FROM emisiones_factura_c_en_curso e WHERE e.venta_id = v.id)
    LIMIT 1;
  IF v_venta IS NULL THEN
    RAISE EXCEPTION 'RESULTADO: sin venta libre para probar';
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_cajero, 'role', 'authenticated')::text, true);

  -- 1. Reserva doble: la segunda no la consigue.
  v_r1 := reservar_emision_factura_c(v_venta);
  v_r2 := reservar_emision_factura_c(v_venta);
  IF v_r1->>'resultado' = 'reservada' AND v_r1->>'token' IS NOT NULL AND v_r2->>'resultado' = 'en_curso' THEN
    v_ok := v_ok + 1; ELSE v_fallas := v_fallas || ' [1 ' || v_r1::text || ' / ' || v_r2::text || ']'; END IF;
  v_token := (v_r1->>'token')::uuid;

  -- 2. Reserva vencida sin número de ARCA (murió antes de pedir el CAE) → se vuelve a tomar, sin pendiente,
  --    y el token viejo ya no sirve.
  UPDATE emisiones_factura_c_en_curso SET tomada_at = now() - interval '6 minutes' WHERE venta_id = v_venta;
  v_r2 := reservar_emision_factura_c(v_venta);
  v_b := registrar_ultimo_arca_emision_factura_c(v_venta, v_token, 'produccion', 44);
  IF v_r2->>'resultado' = 'reservada' AND (v_r2->>'token')::uuid <> v_token
     AND v_r2->>'pendiente_ultimo_arca' IS NULL AND NOT v_b THEN
    v_ok := v_ok + 1; ELSE v_fallas := v_fallas || ' [2 ' || v_r2::text || ' token viejo: ' || v_b || ']'; END IF;
  v_token := (v_r2->>'token')::uuid;

  -- 3. Emitir limpia la reserva (y factura la venta).
  IF registrar_ultimo_arca_emision_factura_c(v_venta, v_token, 'produccion', 44) THEN
    v_factura := emitir_factura_c(v_venta, '70000000000001', '00000045', '0002', 'produccion');
    IF NOT EXISTS (SELECT 1 FROM emisiones_factura_c_en_curso WHERE venta_id = v_venta)
       AND (SELECT estado FROM ventas WHERE id = v_venta) = 'facturado' THEN
      v_ok := v_ok + 1; ELSE v_fallas := v_fallas || ' [3 reserva no limpiada]'; END IF;
  ELSE
    v_fallas := v_fallas || ' [3 no registró el número]';
  END IF;

  -- 4. Mismo CAE dos veces (app instalada después de que guardó la función) → mismo id, sin error,
  --    aunque mande el ambiente por default.
  BEGIN
    v_factura2 := emitir_factura_c(v_venta, '70000000000001', '00000045', '0002');
    IF v_factura2 = v_factura AND (SELECT count(*) FROM facturas_c WHERE venta_id = v_venta) = 1
       AND (SELECT ambiente FROM facturas_c WHERE id = v_factura) = 'produccion' THEN
      v_ok := v_ok + 1; ELSE v_fallas := v_fallas || ' [4 idempotencia]'; END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || ' [4 ' || SQLERRM || ']';
  END;

  -- 5. CAE distinto → sigue fallando.
  BEGIN
    PERFORM emitir_factura_c(v_venta, '70000000000002', '00000046', '0002', 'produccion');
    v_fallas := v_fallas || ' [5 aceptó un segundo CAE]';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%ya tiene una Factura C%' THEN v_ok := v_ok + 1; ELSE v_fallas := v_fallas || ' [5 ' || SQLERRM || ']'; END IF;
  END;

  -- 5b. Venta ya facturada → no se reserva.
  IF reservar_emision_factura_c(v_venta)->>'resultado' = 'ya_facturada' THEN
    v_ok := v_ok + 1; ELSE v_fallas := v_fallas || ' [5b reservó una facturada]'; END IF;

  -- 6. Reserva vencida con número cambiado → bloqueada. Otra venta libre: la anterior quedó facturada.
  DELETE FROM facturas_c WHERE venta_id = v_venta;
  UPDATE ventas SET estado = 'sin_facturar' WHERE id = v_venta;
  v_r1 := reservar_emision_factura_c(v_venta);
  v_token := (v_r1->>'token')::uuid;
  PERFORM registrar_ultimo_arca_emision_factura_c(v_venta, v_token, 'produccion', 44);
  UPDATE emisiones_factura_c_en_curso SET tomada_at = now() - interval '6 minutes' WHERE venta_id = v_venta;
  -- otra pantalla toma la vencida: recibe el número pendiente
  v_r2 := reservar_emision_factura_c(v_venta);
  IF v_r2->>'resultado' = 'reservada' AND (v_r2->>'pendiente_ultimo_arca')::int = 44
     AND v_r2->>'pendiente_ambiente' = 'produccion' THEN
    -- la función ve en ARCA 45 ≠ 44 → marca y no emite
    v_b := marcar_revisar_emision_factura_c(v_venta, (v_r2->>'token')::uuid, 45);
    v_r1 := reservar_emision_factura_c(v_venta);
    IF v_b AND v_r1->>'resultado' = 'revisar'
       AND NOT liberar_emision_factura_c(v_venta, (v_r2->>'token')::uuid)
       AND EXISTS (SELECT 1 FROM listar_emisiones_factura_c_a_revisar() l
                   WHERE l.venta_id = v_venta AND l.ultimo_arca = 44 AND l.ultimo_arca_actual = 45
                     AND l.registrado_por_nombre IS NOT NULL) THEN
      v_ok := v_ok + 1; ELSE v_fallas := v_fallas || ' [6 no quedó bloqueada: ' || v_r1::text || ']'; END IF;
  ELSE
    v_fallas := v_fallas || ' [6 toma de vencida: ' || v_r2::text || ']';
  END IF;

  -- 7. Desbloquear: cajero no puede; admin sí, con nota, y queda en auditoria.
  BEGIN
    PERFORM desbloquear_emision_factura_c(v_venta, 'revisado');
    v_fallas := v_fallas || ' [7 cajero pudo desbloquear]';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'Solo un administrador%' THEN
      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
      PERFORM desbloquear_emision_factura_c(v_venta, 'No figura en Mis Comprobantes');
      IF NOT EXISTS (SELECT 1 FROM emisiones_factura_c_en_curso WHERE venta_id = v_venta)
         AND EXISTS (SELECT 1 FROM auditoria WHERE tabla_afectada = 'emisiones_factura_c_en_curso'
                     AND registro_id = v_venta AND usuario_id = v_admin
                     AND valores_anteriores->>'ultimo_arca_actual' = '45' AND nota LIKE '%Mis Comprobantes%')
         AND reservar_emision_factura_c(v_venta)->>'resultado' = 'reservada' THEN
        v_ok := v_ok + 1; ELSE v_fallas := v_fallas || ' [7 desbloqueo]'; END IF;
    ELSE
      v_fallas := v_fallas || ' [7 ' || SQLERRM || ']';
    END IF;
  END;

  -- 8. Liberar con el token correcto suelta la reserva; la escritura directa a la tabla está cerrada.
  -- (liberar en su propia sentencia: el NOT EXISTS de la misma expresión ve la foto previa al DELETE)
  v_token := (SELECT token FROM emisiones_factura_c_en_curso WHERE venta_id = v_venta);
  v_b := liberar_emision_factura_c(v_venta, v_token);
  IF v_b
     AND NOT EXISTS (SELECT 1 FROM emisiones_factura_c_en_curso WHERE venta_id = v_venta)
     AND NOT has_table_privilege('authenticated', 'public.emisiones_factura_c_en_curso', 'INSERT')
     AND NOT has_table_privilege('authenticated', 'public.emisiones_factura_c_en_curso', 'DELETE')
     AND NOT has_function_privilege('anon', 'public.reservar_emision_factura_c(uuid)', 'EXECUTE') THEN
    v_ok := v_ok + 1; ELSE v_fallas := v_fallas || ' [8 liberar/permisos]'; END IF;

  RAISE EXCEPTION 'RESULTADO: %/9 ok%', v_ok, CASE WHEN v_fallas = '' THEN '' ELSE ' — FALLAS:' || v_fallas END;
END;
$$;
ROLLBACK;
