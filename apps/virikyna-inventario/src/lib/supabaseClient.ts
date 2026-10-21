import { createClient } from '@supabase/supabase-js'
import { fetchConApp } from '@virikyna/shared'

const url = import.meta.env.VITE_SUPABASE_URL
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

if (!url || !anonKey) {
  throw new Error(
    'Faltan VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY — copiá .env.example a .env.local con los datos del ' +
      'MISMO proyecto Supabase que usa Virikyna Local.',
  )
}

// x-virikyna-app en cada llamada a la base: la RLS de borradores sabe desde qué sistema se escribe
// (docs/54). fetchConApp no lo manda a las Edge Functions (su CORS no lo acepta).
export const supabase = createClient(url, anonKey, { global: { fetch: fetchConApp('inventario') } })
