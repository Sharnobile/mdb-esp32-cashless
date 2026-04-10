import { defineEventHandler, proxyRequest, getQuery, createError } from 'h3'

// Runtime-configurable proxy for Supabase Edge Functions.
//
// Why: the frontend was built to call /functions/v1/* via relative URLs so
// that SSR and CSR use the same path. In production the frontend is at
// app.kerl-handel.de while Supabase is at supabase.kerl-handel.de — there
// is no shared origin, so a relative URL alone cannot reach Supabase.
//
// This handler reads the Supabase URL from runtimeConfig (set at runtime
// from NUXT_PUBLIC_SUPABASE_URL) and proxies the request there. Works in
// both dev (local Supabase CLI on 127.0.0.1:54321) and prod
// (https://supabase.kerl-handel.de) without a rebuild.
export default defineEventHandler(async (event) => {
  const config = useRuntimeConfig(event)
  const base = (config.public as { supabase?: { url?: string } }).supabase?.url
  if (!base) {
    throw createError({ statusCode: 500, statusMessage: 'Supabase URL not configured' })
  }

  const path = (event.context.params?.path as string | undefined) ?? ''
  const query = getQuery(event)
  const qs = new URLSearchParams(query as Record<string, string>).toString()
  const target = `${base.replace(/\/$/, '')}/functions/v1/${path}${qs ? `?${qs}` : ''}`

  return proxyRequest(event, target)
})
