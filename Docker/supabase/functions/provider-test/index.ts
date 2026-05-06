// Provider test endpoint — runs a single webhook provider with a fixed sample
// query so the admin UI can confirm a customer-supplied URL+token is reachable
// and returns a valid shape.
//
// Auth: standard JWT auth via the caller's company. Request body must specify
// extensionPoint and the webhook config. Response surfaces success/failure +
// the decoded sample size so the operator can see "yep, 6 offers came back."

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { callWebhookProvider } from '../_shared/providers/webhook.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

interface TestRequest {
  extensionPoint: 'deal-source'   // expand union as new EPs migrate to the pattern
  url: string
  authToken: string
}

const SAMPLE_PER_EXTENSION_POINT: Record<TestRequest['extensionPoint'], { method: string; args: Record<string, unknown> }> = {
  'deal-source': { method: 'fetchOffers', args: { query: 'Coca Cola', zipCode: '60487' } },
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders })

  const adminClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )
  const token = req.headers.get('Authorization')?.replace('Bearer ', '') ?? ''
  const { data: { user }, error: userErr } = await adminClient.auth.getUser(token)
  if (userErr || !user) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  let body: TestRequest
  try {
    body = await req.json()
  } catch {
    return new Response(JSON.stringify({ error: 'invalid JSON body' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  const sample = SAMPLE_PER_EXTENSION_POINT[body.extensionPoint]
  if (!sample) {
    return new Response(JSON.stringify({ error: `unknown extensionPoint: ${body.extensionPoint}` }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  try {
    const result = await callWebhookProvider({
      url: body.url,
      authToken: body.authToken,
      extensionPoint: body.extensionPoint,
      method: sample.method,
      args: sample.args,
    })
    const sampleSize = Array.isArray(result) ? result.length : 0
    return new Response(JSON.stringify({ ok: true, sampleSize }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (err) {
    return new Response(JSON.stringify({ ok: false, error: err instanceof Error ? err.message : String(err) }), {
      status: 200,  // 200 with ok:false; the call succeeded but the webhook didn't
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
