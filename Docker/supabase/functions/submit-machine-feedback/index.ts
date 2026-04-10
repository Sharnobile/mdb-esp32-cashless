// Public endpoint for end-customers to submit a problem report or general
// feedback about a specific vending machine. No auth required — rate-limited
// per machine to prevent spam. Mirrors the submit-product-wish pattern.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { notifyInbox } from '../_shared/inbox-notify.ts'

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
  })
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
const VALID_TYPES = new Set(['problem', 'feedback'])

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS })
  }

  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Method not allowed' }, 405)
  }

  let body: { machine_id?: string; type?: string; message?: string; email?: string }
  try {
    body = await req.json()
  } catch {
    return jsonResponse({ error: 'Invalid JSON' }, 400)
  }

  const { machine_id, type, message, email } = body

  if (!machine_id || !type || !message) {
    return jsonResponse({ error: 'machine_id, type and message are required' }, 400)
  }

  if (!VALID_TYPES.has(type)) {
    return jsonResponse({ error: 'type must be "problem" or "feedback"' }, 400)
  }

  const trimmedMessage = message.trim()
  if (trimmedMessage.length === 0 || trimmedMessage.length > 2000) {
    return jsonResponse({ error: 'message must be 1-2000 characters' }, 400)
  }

  if (email && !EMAIL_RE.test(email)) {
    return jsonResponse({ error: 'Invalid email format' }, 400)
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  // Verify machine exists and get company_id
  const { data: machine, error: machineErr } = await supabase
    .from('vendingMachine')
    .select('id, company')
    .eq('id', machine_id)
    .single()

  if (machineErr || !machine) {
    return jsonResponse({ error: 'Machine not found' }, 404)
  }

  // Rate limit: max 10 submissions per machine per hour (same as product wishes)
  const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString()
  const { count } = await supabase
    .from('machine_feedback')
    .select('id', { count: 'exact', head: true })
    .eq('machine_id', machine_id)
    .gte('created_at', oneHourAgo)

  if (count !== null && count >= 10) {
    return jsonResponse({ error: 'Too many submissions recently. Please try again later.' }, 429)
  }

  const { error: insertErr } = await supabase
    .from('machine_feedback')
    .insert({
      machine_id,
      company_id: machine.company,
      type,
      message: trimmedMessage,
      email: email ? email.toLowerCase().trim() : null,
    })

  if (insertErr) {
    console.error('Failed to insert machine feedback:', insertErr)
    return jsonResponse({ error: 'Failed to submit' }, 500)
  }

  // Fire push notification to all operators of this company. Awaited so the
  // open-count badge is up-to-date in the same response, but failures are
  // swallowed inside notifyInbox so the customer-facing submit always succeeds.
  await notifyInbox({
    adminClient: supabase,
    companyId: machine.company,
    machineId: machine_id,
    kind: type as 'problem' | 'feedback',
    preview: trimmedMessage,
  })

  return jsonResponse({ success: true })
})
