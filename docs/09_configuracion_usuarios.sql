-- 09 — Configuración de Usuarios — RPCs para Virikyna Gestión (módulo 9)
--
-- Resuelve el "Pendiente técnico" que quedó anotado en 07_guia_desarrollo_iterativo.md:
-- la policy "admin_gestiona_usuarios" sobre `perfiles` se tuvo que eliminar en Fase 2 porque
-- se auto-referenciaba (un FOR ALL que consulta la misma tabla `perfiles` para decidir si el
-- que pide sos admin) y devolvía 500 en cualquier lectura. La solución, ya prevista en ese
-- doc, es resolver la gestión de usuarios con funciones SECURITY DEFINER que validan el rol
-- del que llama al principio de la función — corren como dueño de la función, sin pasar por
-- RLS, así que no hay recursión posible.
--
-- Ejecutar este archivo completo en el SQL Editor de Supabase (mismo proyecto que ya tiene
-- 06_estructura_de_datos.md aplicado). Correr una sola vez.

-- ============================================================
-- 1. listar_usuarios — trae TODOS los perfiles (incluidos inactivos, para poder reactivarlos)
-- ============================================================
CREATE OR REPLACE FUNCTION listar_usuarios()
RETURNS SETOF perfiles
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede ver el listado de usuarios';
  END IF;

  RETURN QUERY SELECT * FROM perfiles ORDER BY nombre;
END;
$$;

-- ============================================================
-- 2. editar_usuario — nombre y rol (el email no se reasigna desde acá)
-- ============================================================
CREATE OR REPLACE FUNCTION editar_usuario(
  p_user_id UUID,
  p_nombre TEXT,
  p_rol rol_usuario
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede editar usuarios';
  END IF;
  IF p_nombre IS NULL OR trim(p_nombre) = '' THEN
    RAISE EXCEPTION 'El nombre es obligatorio';
  END IF;

  UPDATE perfiles SET nombre = trim(p_nombre), rol = p_rol WHERE id = p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Usuario no encontrado'; END IF;
END;
$$;

-- ============================================================
-- 3. set_usuario_activo — desactivar / reactivar (nunca se borra el perfil)
-- ============================================================
CREATE OR REPLACE FUNCTION set_usuario_activo(
  p_user_id UUID,
  p_activo BOOLEAN
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin' AND activo = true) THEN
    RAISE EXCEPTION 'Solo un administrador puede desactivar o reactivar usuarios';
  END IF;
  IF p_user_id = auth.uid() AND p_activo = false THEN
    RAISE EXCEPTION 'No podés desactivar tu propio usuario';
  END IF;

  UPDATE perfiles SET activo = p_activo WHERE id = p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Usuario no encontrado'; END IF;
END;
$$;

-- Nota: crear usuario y blanquear contraseña NO son RPCs de Postgres — tocan auth.users, que
-- solo se modifica con la Admin API de Supabase (service_role). Eso vive en la Edge Function
-- `supabase/functions/admin-usuarios`, nunca en el cliente. Ver ese archivo para el deploy.
