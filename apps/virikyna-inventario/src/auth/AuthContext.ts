import { createAuthController } from '@virikyna/shared'
import { supabase } from '../lib/supabaseClient'

// Misma fábrica de auth que usa Virikyna Local (packages/shared/auth/createAuthController.tsx),
// instanciada con el cliente de Supabase de esta app — login compartido, cero lógica duplicada.
export const { AuthProvider, useAuth, usePerfil, RequireAuth } = createAuthController(supabase, '/login')
