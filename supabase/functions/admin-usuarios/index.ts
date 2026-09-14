// Edge Function: admin-usuarios
//
// Única pieza del módulo 9 (Configuración → usuarios) que necesita `service_role`: crear un
// usuario, blanquear su contraseña, y desactivarlo/reactivarlo son operaciones sobre
// `auth.users`, que la Admin API de Supabase solo expone con esa key — nunca puede vivir en el
// bundle de una app de cliente (ver skill supabase-production-patterns, "service_role es la
// llave maestra"). Por eso las tres viven acá, no como RPC directo sobre `perfiles`.
//
// El email de un usuario nuevo lo tipea el admin a mano — a propósito, son personas reales con
// su propio mail, no se genera nada acá.
//
// Seguridad: valida el JWT de quien llama y confirma que su perfil es admin y está activo
// ANTES de tocar nada — igual que las RPCs SECURITY DEFINER del resto del sistema. Sin esa
// validación, cualquier usuario autenticado podría invocar esta función y crear cuentas admin.
//
// Deploy (requiere el proyecto Supabase de Virikyna linkeado por CLI):
//   supabase functions deploy admin-usuarios
// No hace falta configurar SUPABASE_SERVICE_ROLE_KEY a mano: Supabase la inyecta sola como
// variable de entorno en el runtime de toda Edge Function del proyecto.

import { createClient } from 'jsr:@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!

type Body =
  | { accion: 'crear_usuario'; email: string; password: string; nombre: string; rol: 'admin' | 'cajero' }
  | { accion: 'blanquear_password'; user_id: string; password_nueva: string }
  | { accion: 'desactivar_usuario'; user_id: string; activo: boolean }

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req) => {
  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return jsonResponse({ error: 'Falta autenticación' }, 401)

  // Cliente "como el usuario que llama" — solo para validar quién es y que sea admin activo.
  const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  })
  const {
    data: { user },
  } = await callerClient.auth.getUser()
  if (!user) return jsonResponse({ error: 'Sesión inválida' }, 401)

  const { data: perfil, error: perfilError } = await callerClient
    .from('perfiles')
    .select('rol, activo')
    .eq('id', user.id)
    .single()

  if (perfilError || !perfil || perfil.rol !== 'admin' || !perfil.activo) {
    return jsonResponse({ error: 'Solo un administrador activo puede gestionar usuarios' }, 403)
  }

  let body: Body
  try {
    body = await req.json()
  } catch {
    return jsonResponse({ error: 'Body inválido' }, 400)
  }

  // Cliente admin — service_role, salta RLS, solo se usa acá adentro tras validar arriba.
  const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY)

  if (body.accion === 'crear_usuario') {
    if (!body.email?.trim() || !body.password || !body.nombre?.trim()) {
      return jsonResponse({ error: 'Email, contraseña y nombre son obligatorios' }, 400)
    }

    const { data: created, error: createError } = await adminClient.auth.admin.createUser({
      email: body.email.trim(),
      password: body.password,
      email_confirm: true,
    })
    if (createError || !created.user) {
      return jsonResponse({ error: createError?.message ?? 'No se pudo crear el usuario' }, 400)
    }

    const { error: perfilInsertError } = await adminClient.from('perfiles').insert({
      id: created.user.id,
      nombre: body.nombre.trim(),
      rol: body.rol,
      activo: true,
    })
    if (perfilInsertError) {
      // Revertir el alta en auth si el perfil no se pudo crear, para no dejar un usuario huérfano.
      await adminClient.auth.admin.deleteUser(created.user.id)
      return jsonResponse({ error: perfilInsertError.message }, 400)
    }

    return jsonResponse({ ok: true, user_id: created.user.id })
  }

  if (body.accion === 'blanquear_password') {
    if (!body.user_id || !body.password_nueva || body.password_nueva.length < 6) {
      return jsonResponse({ error: 'Usuario y contraseña nueva (mínimo 6 caracteres) son obligatorios' }, 400)
    }

    const { error: updateError } = await adminClient.auth.admin.updateUserById(body.user_id, {
      password: body.password_nueva,
    })
    if (updateError) {
      return jsonResponse({ error: updateError.message }, 400)
    }

    return jsonResponse({ ok: true })
  }

  if (body.accion === 'desactivar_usuario') {
    if (!body.user_id || typeof body.activo !== 'boolean') {
      return jsonResponse({ error: 'Usuario y estado (activo/inactivo) son obligatorios' }, 400)
    }
    if (body.user_id === user.id && !body.activo) {
      return jsonResponse({ error: 'No podés desactivar tu propio usuario' }, 400)
    }

    const { error: updateError } = await adminClient
      .from('perfiles')
      .update({ activo: body.activo })
      .eq('id', body.user_id)
    if (updateError) {
      return jsonResponse({ error: updateError.message }, 400)
    }

    return jsonResponse({ ok: true })
  }

  return jsonResponse({ error: 'Acción no reconocida' }, 400)
})
