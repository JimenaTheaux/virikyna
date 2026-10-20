-- 49 — Las apps generan el código de un alta sin código con generar_codigo_interno()
--
-- Correr desde la raíz del repo con `npx supabase db query --linked -f docs/49_codigo_interno_apps.sql`,
-- después de 48. Auditoría: docs/auditoria-2026-10-19.md, sección C.5.
--
-- Contexto (relevado contra la base real el 2026-10-19):
--   - Había dos generadores: el SQL generar_codigo_interno() ('20' + secuencia de 10 dígitos + dígito
--     verificador EAN-13: numérico de 13 dígitos, lo usa carga_inicial_finalizar y lo guarda en
--     codigo_barras) y uno JS (INT- + base36, alfanumérico, en codigo_interno) en los 3 formularios
--     de producto. La cámara ahora acepta solo dígitos: el código INT- no se podría escanear.
--   - docs/39 le sacó EXECUTE a authenticated porque ninguna app lo llamaba. Ahora los formularios
--     lo llaman para un alta sin código. La función ya valida perfil activo adentro.
--   - Las apps viejas (Local ≤ v0.5.2) siguen generando INT- hasta actualizarse: este cambio no
--     las afecta.
--
-- Qué hace: GRANT EXECUTE ON generar_codigo_interno() TO authenticated.
-- La limpieza de códigos con prefijo (antes pensada como docs/49) queda para una migración posterior.

BEGIN;
GRANT EXECUTE ON FUNCTION public.generar_codigo_interno() TO authenticated;
COMMENT ON FUNCTION public.generar_codigo_interno() IS
  'Código numérico de 13 dígitos (20 + secuencia + verificador EAN-13) para productos sin código. Lo usan carga_inicial_finalizar y los formularios de producto de las 3 apps (docs/49).';
NOTIFY pgrst, 'reload schema';
COMMIT;

-- Verificación (solo lectura): authenticated puede ejecutarla; anon no.
SELECT has_function_privilege('authenticated', 'public.generar_codigo_interno()', 'EXECUTE') AS authenticated_ok,
       NOT has_function_privilege('anon', 'public.generar_codigo_interno()', 'EXECUTE') AS anon_sin_permiso,
       (SELECT array_to_string(proacl, ',') FROM pg_proc WHERE oid = 'public.generar_codigo_interno()'::regprocedure) AS acl;
