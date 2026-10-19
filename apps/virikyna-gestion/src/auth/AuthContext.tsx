import { createAuthController } from '@virikyna/shared'
import { supabase } from '../lib/supabaseClient'

// Misma fábrica de auth que Local e Inventario (packages/shared/auth/createAuthController.tsx), con
// una regla más: Virikyna Gestión es exclusiva de Admin (docs/02_roles_y_permisos.md). Un cajero que
// inicia sesión con credenciales válidas igual queda afuera, con mensaje claro, en vez de solo
// ocultarle rutas en el router.
export const { AuthProvider, useAuth, usePerfil, RequireAuth } = createAuthController(supabase, '/login', {
  validarPerfil: (perfil) =>
    perfil.rol !== 'admin'
      ? 'Virikyna Gestión es exclusiva para administradores. Usá Virikyna Local para operar el mostrador.'
      : null,
})
