import { createClient, type SupabaseClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined

export const isSupabaseConfigured = Boolean(url && anonKey)

// Apenas a chave anon é usada no navegador. A service_role fica restrita ao worker.
export const supabase: SupabaseClient = isSupabaseConfigured
  ? createClient(url!, anonKey!, { auth: { persistSession: true, autoRefreshToken: true } })
  : (null as unknown as SupabaseClient)
