import { createAuthController } from '@virikyna/shared'
import { supabase } from '../lib/supabaseClient'

// Instancia única de la fábrica de auth compartida (packages/shared/auth/createAuthController.tsx),
// atada al cliente de Supabase de esta app. Virikyna Inventario instancia la misma fábrica con el
// suyo — mismo Supabase Auth, misma regla de perfil, sin duplicar la lógica.
export const { AuthProvider, useAuth, usePerfil, RequireAuth } = createAuthController(supabase, '/login')
