-- 39 — Security Advisor: funciones internas fuera de la API
--
-- Se corre a mano en el SQL Editor de Supabase (proyecto ccpinvtleqlsukcqnili), después de docs/38.
-- Bloque 1 primero; bloque 2 al final, después de las pruebas.
--
-- Contexto: el Security Advisor (2026-10-09) marca con "Signed-In Users Can Execute SECURITY
-- DEFINER Function" (lint 0029) a todas las RPCs SECURITY DEFINER que authenticated puede llamar.
-- Para casi todas es intencional: así funciona Virikyna (confirmar_venta, cerrar_caja, pagos,
-- carga inicial, etc.), y cada una valida adentro perfil activo y rol. Esas se dejan como están.
--
-- Se corrigen solo las que NO son RPCs: nadie las llama desde una app (grep de .rpc('...') en las
-- 3 apps, packages/shared y supabase/functions, incluido el helper dinámico de cargaInicial.ts).
--   - Triggers: fn_auditoria_generica, fn_proteger_eliminacion_cliente,
--     fn_proteger_eliminacion_proveedor, fn_proteger_margen_producto, fn_proteger_margen_proveedor.
--     Un trigger se dispara aunque quien escribe no tenga EXECUTE sobre su función (Postgres lo
--     chequea solo al crear el trigger).
--   - Helpers que solo se llaman desde otras funciones SECURITY DEFINER (corren como postgres):
--     carga_inicial_verificar_acceso (todas las RPCs de carga inicial) y generar_codigo_interno
--     (carga_inicial_finalizar).
--
-- Quedan en el Advisor, a propósito:
--   - ERROR security_definer_view en perfiles_publico y notas_internas_con_autor: siguen definer
--     para que se vean los nombres de los demás usuarios (docs/38, docs/06 sección 25). Solo
--     authenticated las lee.
--   - WARN 0029 en las RPCs que usan las apps.


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- BLOQUE 1
-- ════════════════════════════════════════════════════════════════════════════════════════════

BEGIN;

-- PUBLIC y anon ya no tenían EXECUTE (docs/38). service_role lo conserva.
REVOKE EXECUTE ON FUNCTION
  fn_auditoria_generica(),
  fn_proteger_eliminacion_cliente(),
  fn_proteger_eliminacion_proveedor(),
  fn_proteger_margen_producto(),
  fn_proteger_margen_proveedor(),
  carga_inicial_verificar_acceso(),
  generar_codigo_interno()
FROM authenticated;

COMMIT;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- BLOQUE 2 — Correr AL FINAL, después de las pruebas. Una prueba que da de alta un producto sin
-- código consume codigo_interno_seq aunque haga ROLLBACK. Solo reinicia si no hay productos ni
-- borradores (nadie usó todavía un código interno).
-- ════════════════════════════════════════════════════════════════════════════════════════════

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM productos) AND NOT EXISTS (SELECT 1 FROM carga_inicial_items) THEN
    ALTER SEQUENCE codigo_interno_seq RESTART WITH 1;
  ELSE
    RAISE NOTICE 'Hay productos o borradores: codigo_interno_seq no se reinicia';
  END IF;
END $$;


-- ════════════════════════════════════════════════════════════════════════════════════════════
-- VERIFICACIÓN (solo lectura)
-- ════════════════════════════════════════════════════════════════════════════════════════════

-- Las 7 sin EXECUTE para authenticated, anon ni PUBLIC (todo false = OK).
SELECT p.proname,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon,
       has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role
FROM pg_proc p
WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('fn_auditoria_generica', 'fn_proteger_eliminacion_cliente', 'fn_proteger_eliminacion_proveedor',
                    'fn_proteger_margen_producto', 'fn_proteger_margen_proveedor',
                    'carga_inicial_verificar_acceso', 'generar_codigo_interno')
ORDER BY 1;
