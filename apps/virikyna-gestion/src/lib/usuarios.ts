// Gestión de usuarios (docs/04_modulos_y_funciones.md, módulo 9) — exclusiva de Virikyna Gestión.
// Editar nombre/rol sigue por RPC SECURITY DEFINER (solo toca `perfiles`, sin necesidad de
// service_role). Crear usuario, blanquear contraseña y desactivar/reactivar tocan auth.users o
// necesitan saltar RLS con criterio de admin — las tres van por la Edge Function
// `admin-usuarios`, nunca con la service_role key en este bundle.
import type { Perfil, RolUsuario } from '@virikyna/shared'
import { supabase } from './supabaseClient'

export async function listarUsuarios(): Promise<{ data: Perfil[]; error: unknown }> {
  const { data, error } = await supabase.rpc('listar_usuarios')
  return { data: (data ?? []) as Perfil[], error }
}

export async function editarUsuario(userId: string, nombre: string, rol: RolUsuario) {
  return supabase.rpc('editar_usuario', { p_user_id: userId, p_nombre: nombre, p_rol: rol })
}

type AdminUsuariosResponse = { error?: string }

export async function crearUsuario(email: string, password: string, nombre: string, rol: RolUsuario) {
  const { data, error } = await supabase.functions.invoke<AdminUsuariosResponse>('admin-usuarios', {
    body: { accion: 'crear_usuario', email, password, nombre, rol },
  })
  if (error) return { error: error.message }
  if (data?.error) return { error: data.error }
  return { error: null }
}

export async function blanquearPassword(userId: string, passwordNueva: string) {
  const { data, error } = await supabase.functions.invoke<AdminUsuariosResponse>('admin-usuarios', {
    body: { accion: 'blanquear_password', user_id: userId, password_nueva: passwordNueva },
  })
  if (error) return { error: error.message }
  if (data?.error) return { error: data.error }
  return { error: null }
}

export async function setUsuarioActivo(userId: string, activo: boolean) {
  const { data, error } = await supabase.functions.invoke<AdminUsuariosResponse>('admin-usuarios', {
    body: { accion: 'desactivar_usuario', user_id: userId, activo },
  })
  if (error) return { error: error.message }
  if (data?.error) return { error: data.error }
  return { error: null }
}
