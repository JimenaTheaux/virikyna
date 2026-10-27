-- 59 — Factura C en producción: ambiente guardado por comprobante + re-emisión de los de homologación
--
-- ✅ APLICADO en producción el 2026-10-26 23:06 (PARTE A), con backup previo
-- virikyna_2026-10-26_pre-docs59-arca. PARTE C 9/9 (antes y después de aplicar). Edge Function
-- desplegada a continuación. Re-emisión (scripts/reemitir-facturas-c.ts) 23:08–23:10: las 43
-- Factura C quedaron en producción, PV 0002 N° 2 a 44, verificadas una por una con
-- FECompConsultar (CAE, importe y Resultado "A"). Registro en ~/Backups/virikyna/
-- reemision-facturas-c-2026-10-26.jsonl.
--
-- Correr desde la raíz del repo con
-- `supabase db query --linked -f docs/59_factura_c_produccion.sql` (o en el SQL Editor del proyecto
-- ccpinvtleqlsukcqnili), después de 58. La PARTE A se puede re-correr; la PARTE B solo lee y la
-- PARTE C es un test (BEGIN … ROLLBACK).
--
-- Contexto (relevado contra la base real el 2026-10-26):
--   - Los botones de emitir Factura C llamaban a arca-emitir-factura sin `ambiente`, y la función usa
--     homologación por default: las 43 Factura C guardadas (19/10 al 26/10, ventas N° 17 a 198,
--     punto de venta 00001) tienen CAE de HOMOLOGACIÓN, sin validez fiscal. En ARCA producción solo
--     existe la prueba del 14/09 (PV 0002 N° 1, borrada de la base en la limpieza del 13/10).
--   - facturas_c no guardaba el ambiente: un CAE de prueba y uno real se veían iguales.
--   - 42 de las 43 las emitió un cajero.
--
-- Qué hace:
--   1. facturas_c.ambiente ('homologacion' | 'produccion', NOT NULL). Las filas existentes quedan
--      'homologacion' (todas lo son, ver arriba).
--   2. emitir_factura_c recibe p_ambiente. Default 'homologacion' a propósito: la versión de las apps
--      ya instalada lo llama con 4 parámetros y emite en homologación, así que queda bien registrada
--      hasta que se actualice. La versión nueva (arcaFacturacion.ts) manda siempre el ambiente que
--      devolvió la Edge Function.
--   3. RPC nueva reemitir_factura_c_produccion (solo admin): reemplaza el comprobante de homologación
--      de una venta por el que ARCA producción acaba de emitir (acción `reemitir` de la Edge Function).
--      La fila vieja queda en auditoria (valores_anteriores) con una nota.

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE A — cambios
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ─── 1. facturas_c.ambiente ──────────────────────────────────────────────────────────────────
ALTER TABLE public.facturas_c ADD COLUMN IF NOT EXISTS ambiente text;
UPDATE public.facturas_c SET ambiente = 'homologacion' WHERE ambiente IS NULL;
ALTER TABLE public.facturas_c ALTER COLUMN ambiente SET NOT NULL;
ALTER TABLE public.facturas_c DROP CONSTRAINT IF EXISTS facturas_c_ambiente_check;
ALTER TABLE public.facturas_c ADD CONSTRAINT facturas_c_ambiente_check
  CHECK (ambiente IN ('homologacion', 'produccion'));

-- ─── 2. emitir_factura_c con p_ambiente ──────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.emitir_factura_c(uuid, text, text, text);

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
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true) THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;
  IF EXISTS (SELECT 1 FROM ventas WHERE id = p_venta_id AND estado = 'facturado') THEN
    RAISE EXCEPTION 'Esta venta ya tiene una Factura C emitida';
  END IF;

  INSERT INTO facturas_c (venta_id, cae, numero_factura, punto_venta, fecha_emision, usuario_id, ambiente)
  VALUES (p_venta_id, p_cae, p_numero_factura, p_punto_venta, now(), auth.uid(), p_ambiente)
  RETURNING id INTO v_factura_id;

  UPDATE ventas SET estado = 'facturado' WHERE id = p_venta_id;

  RETURN v_factura_id;
END;
$$;

REVOKE ALL ON FUNCTION public.emitir_factura_c(uuid, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.emitir_factura_c(uuid, text, text, text, text) TO authenticated, service_role;

-- ─── 3. reemitir_factura_c_produccion ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reemitir_factura_c_produccion(
  p_venta_id uuid,
  p_cae text,
  p_numero_factura text,
  p_punto_venta text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
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
$$;

REVOKE ALL ON FUNCTION public.reemitir_factura_c_produccion(uuid, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reemitir_factura_c_produccion(uuid, text, text, text) TO authenticated, service_role;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE B — verificación (solo lee)
-- ════════════════════════════════════════════════════════════════════════════════════════════
SELECT p.oid::regprocedure AS funcion, p.proacl
FROM pg_proc p
WHERE p.proname IN ('emitir_factura_c', 'reemitir_factura_c_produccion')
ORDER BY 1;

SELECT ambiente, count(*) FROM facturas_c GROUP BY ambiente;

-- ════════════════════════════════════════════════════════════════════════════════════════════
-- PARTE C — test (BEGIN … ROLLBACK: no deja nada escrito; termina siempre en RAISE con el resultado)
-- ════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
  v_admin uuid;
  v_cajero uuid;
  v_venta_libre uuid;
  v_venta_homo uuid;
  v_factura uuid;
  v_ok int := 0;
  v_fallas text := '';
  v_txt text;
  v_n int;
BEGIN
  SELECT id INTO v_admin FROM perfiles WHERE rol = 'admin' AND activo LIMIT 1;
  SELECT id INTO v_cajero FROM perfiles WHERE rol = 'cajero' AND activo LIMIT 1;
  SELECT v.id INTO v_venta_libre FROM ventas v
    WHERE v.estado = 'sin_facturar' AND NOT EXISTS (SELECT 1 FROM facturas_c f WHERE f.venta_id = v.id) LIMIT 1;
  SELECT venta_id INTO v_venta_homo FROM facturas_c WHERE ambiente = 'homologacion' ORDER BY fecha_emision LIMIT 1;

  -- 1. columna NOT NULL y todas las existentes en homologación
  IF (SELECT is_nullable FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'facturas_c' AND column_name = 'ambiente') = 'NO'
     AND NOT EXISTS (SELECT 1 FROM facturas_c WHERE ambiente <> 'homologacion') THEN
    v_ok := v_ok + 1; ELSE v_fallas := v_fallas || ' [1 columna]'; END IF;

  -- 2. una sola emitir_factura_c, sin anon
  SELECT count(*) INTO v_n FROM pg_proc WHERE proname = 'emitir_factura_c';
  IF v_n = 1 AND NOT has_function_privilege('anon', 'public.emitir_factura_c(uuid,text,text,text,text)', 'EXECUTE')
     AND NOT has_function_privilege('anon', 'public.reemitir_factura_c_produccion(uuid,text,text,text)', 'EXECUTE')
     AND has_function_privilege('authenticated', 'public.reemitir_factura_c_produccion(uuid,text,text,text)', 'EXECUTE') THEN
    v_ok := v_ok + 1; ELSE v_fallas := v_fallas || ' [2 firmas/grants]'; END IF;

  -- 3. llamada con 4 parámetros (apps ya instaladas) → homologación
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_cajero, 'role', 'authenticated')::text, true);
  IF v_venta_libre IS NULL THEN
    v_fallas := v_fallas || ' [3 sin venta libre para probar]';
  ELSE
    v_factura := emitir_factura_c(p_venta_id => v_venta_libre, p_cae => '11111111111111',
                                  p_numero_factura => '00000099', p_punto_venta => '00001');
    IF (SELECT ambiente FROM facturas_c WHERE id = v_factura) = 'homologacion'
       AND (SELECT estado FROM ventas WHERE id = v_venta_libre) = 'facturado' THEN
      v_ok := v_ok + 1; ELSE v_fallas := v_fallas || ' [3 default]'; END IF;
    -- 4. con p_ambiente = produccion (cajero)
    DELETE FROM facturas_c WHERE id = v_factura;
    UPDATE ventas SET estado = 'sin_facturar' WHERE id = v_venta_libre;
    v_factura := emitir_factura_c(v_venta_libre, '22222222222222', '00000002', '00002', 'produccion');
    IF (SELECT ambiente FROM facturas_c WHERE id = v_factura) = 'produccion' THEN
      v_ok := v_ok + 1; ELSE v_fallas := v_fallas || ' [4 produccion]'; END IF;
    -- 5. ambiente inválido → error
    DELETE FROM facturas_c WHERE id = v_factura;
    UPDATE ventas SET estado = 'sin_facturar' WHERE id = v_venta_libre;
    BEGIN
      PERFORM emitir_factura_c(v_venta_libre, '33333333333333', '00000003', '00002', 'prueba');
      v_fallas := v_fallas || ' [5 aceptó ambiente inválido]';
    EXCEPTION WHEN check_violation THEN v_ok := v_ok + 1;
    END;
  END IF;

  -- 6. re-emitir como cajero → rechazado
  BEGIN
    PERFORM reemitir_factura_c_produccion(v_venta_homo, '44444444444444', '00000002', '00002');
    v_fallas := v_fallas || ' [6 cajero pudo re-emitir]';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'Solo un administrador%' THEN v_ok := v_ok + 1; ELSE v_fallas := v_fallas || ' [6 ' || SQLERRM || ']'; END IF;
  END;

  -- 7. re-emitir como admin: CAE inválido → rechazado
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM reemitir_factura_c_produccion(v_venta_homo, '', '00000002', '00002');
    v_fallas := v_fallas || ' [7 aceptó CAE vacío]';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'CAE inválido%' THEN v_ok := v_ok + 1; ELSE v_fallas := v_fallas || ' [7 ' || SQLERRM || ']'; END IF;
  END;

  -- 8. re-emitir como admin → producción + auditoría con el CAE viejo
  SELECT cae INTO v_txt FROM facturas_c WHERE venta_id = v_venta_homo;
  v_factura := reemitir_factura_c_produccion(v_venta_homo, '55555555555555', '00000002', '00002');
  IF (SELECT ambiente = 'produccion' AND cae = '55555555555555' AND punto_venta = '00002' FROM facturas_c WHERE id = v_factura)
     AND EXISTS (SELECT 1 FROM auditoria WHERE tabla_afectada = 'facturas_c' AND registro_id = v_factura
                 AND valores_anteriores->>'cae' = v_txt AND valores_nuevos->>'ambiente' = 'produccion'
                 AND usuario_id = v_admin AND nota LIKE '%' || v_txt || '%')
     AND (SELECT count(*) FROM facturas_c WHERE venta_id = v_venta_homo) = 1 THEN
    v_ok := v_ok + 1; ELSE v_fallas := v_fallas || ' [8 re-emisión]'; END IF;

  -- 9. re-emitir de nuevo la misma → rechazado
  BEGIN
    PERFORM reemitir_factura_c_produccion(v_venta_homo, '66666666666666', '00000003', '00002');
    v_fallas := v_fallas || ' [9 re-emitió dos veces]';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%ya es de producción%' THEN v_ok := v_ok + 1; ELSE v_fallas := v_fallas || ' [9 ' || SQLERRM || ']'; END IF;
  END;

  RAISE EXCEPTION 'RESULTADO: %/9 ok%', v_ok, CASE WHEN v_fallas = '' THEN '' ELSE ' — FALLAS:' || v_fallas END;
END;
$$;
ROLLBACK;
