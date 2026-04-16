import { createClient } from '@supabase/supabase-js'
import type { H3Event } from 'h3'

/**
 * Server-side Supabase client using the anon key.
 * For public-read endpoints only (RLS controls access).
 */
export function useServerSupabaseAnon(event: H3Event) {
  const config = useRuntimeConfig(event)
  const url = config.public.supabase?.url || process.env.SUPABASE_URL || ''
  const key = config.public.supabase?.key || process.env.SUPABASE_KEY || ''
  return createClient(url, key)
}
