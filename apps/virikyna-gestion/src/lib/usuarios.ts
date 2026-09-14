// Gestión de usuarios (docs/04_modulos_y_funciones.md, módulo 9) — exclusiva de Virikyna Gestión.
// Editar nombre/rol sigue por RPC SECURITY DEFINER (solo toca `perfiles`, sin necesidad de
// service_role). Crear usuario, blanquear contraseña y desactivar/reactivar tocan auth.users o
// necesitan saltar RLS con criterio de admin — las tres van por la Edge Function
// `admin-usuarios`, nunca con la service_role key en este bundle.
import { FunctionsHttpError } from '@supabase/supabase-js'
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

// FunctionsHttpError.message siempre es el string genérico "Edge Function returned a non-2xx
// status code" — el motivo real (el {error: '...'} que devuelve admin-usuarios/index.ts) viaja
// en error.context, el Response crudo, y hay que leerlo aparte.
async function mensajeErrorFuncion(error: unknown): Promise<string> {
  if (error instanceof FunctionsHttpError) {
    try {
      const body = (await error.context.json()) as { error?: string }
      if (body?.error) return body.error
    } catch {
      // el body no era JSON parseable — cae al mensaje genérico de abajo
    }
  }
  return error instanceof Error ? error.message : 'Error desconocido'
}

export async function crearUsuario(email: string, password: string, nombre: string, rol: RolUsuario) {
  const { data, error } = await supabase.functions.invoke<AdminUsuariosResponse>('admin-usuarios', {
    body: { accion: 'crear_usuario', email, password, nombre, rol },
  })
  if (error) return { error: await mensajeErrorFuncion(error) }
  if (data?.error) return { error: data.error }
  return { error: null }
}

export async function blanquearPassword(userId: string, passwordNueva: string) {
  const { data, error } = await supabase.functions.invoke<AdminUsuariosResponse>('admin-usuarios', {
    body: { accion: 'blanquear_password', user_id: userId, password_nueva: passwordNueva },
  })
  if (error) return { error: await mensajeErrorFuncion(error) }
  if (data?.error) return { error: data.error }
  return { error: null }
}

export async function setUsuarioActivo(userId: string, activo: boolean) {
  const { data, error } = await supabase.functions.invoke<AdminUsuariosResponse>('admin-usuarios', {
    body: { accion: 'desactivar_usuario', user_id: userId, activo },
  })
  if (error) return { error: await mensajeErrorFuncion(error) }
  if (data?.error) return { error: data.error }
  return { error: null }
}
