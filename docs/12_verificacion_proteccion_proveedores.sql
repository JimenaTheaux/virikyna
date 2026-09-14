-- Verificación puntual: qué protección quedó realmente sobre `proveedores` (eliminar con
-- historial / solo admin). Corré esto en el SQL Editor de Supabase y pegame el resultado.

-- 1. Triggers colgados de proveedores (¿hay un BEFORE DELETE nuevo?)
SELECT
  t.tgname AS trigger,
  pg_get_triggerdef(t.oid) AS definicion
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
WHERE c.relname = 'proveedores' AND NOT t.tgisinternal;

-- 2. Si hay trigger, el texto exacto de la función que dispara (para ver el mensaje de RAISE EXCEPTION)
SELECT proname, prosrc
FROM pg_proc
WHERE proname ILIKE '%proveedor%' AND proname NOT IN ('cargar_factura_compra', 'anular_factura_compra', 'editar_factura_compra');

-- 3. Policies vigentes sobre proveedores (¿cambió algo respecto de "proveedores_todos" FOR ALL?)
SELECT policyname, cmd, roles, qual, with_check
FROM pg_policies
WHERE tablename = 'proveedores';
