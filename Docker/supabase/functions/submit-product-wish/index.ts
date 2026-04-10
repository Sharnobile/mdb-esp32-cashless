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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS })
  }

  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Method not allowed' }, 405)
  }

  let body: { machine_id?: string; wish_text?: string; email?: string }
  try {
    body = await req.json()
  } catch {
    return jsonResponse({ error: 'Invalid JSON' }, 400)
  }

  const { machine_id, wish_text, email } = body

  if (!machine_id || !wish_text) {
    return jsonResponse({ error: 'machine_id and wish_text are required' }, 400)
  }

  const trimmedWish = wish_text.trim()
  if (trimmedWish.length === 0 || trimmedWish.length > 500) {
    return jsonResponse({ error: 'wish_text must be 1-500 characters' }, 400)
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

  // Rate limit: max 10 wishes per machine per hour
  const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString()
  const { count } = await supabase
    .from('product_wishes')
    .select('id', { count: 'exact', head: true })
    .eq('machine_id', machine_id)
    .gte('created_at', oneHourAgo)

  if (count !== null && count >= 10) {
    return jsonResponse({ error: 'Too many wishes submitted recently. Please try again later.' }, 429)
  }

  const { error: insertErr } = await supabase
    .from('product_wishes')
    .insert({
      machine_id,
      company_id: machine.company,
      wish_text: trimmedWish,
      email: email ? email.toLowerCase().trim() : null,
    })

  if (insertErr) {
    console.error('Failed to insert product wish:', insertErr)
    return jsonResponse({ error: 'Failed to submit wish' }, 500)
  }

  // Fire push notification — same shared helper as submit-machine-feedback.
  await notifyInbox({
    adminClient: supabase,
    companyId: machine.company,
    machineId: machine_id,
    kind: 'wish',
    preview: trimmedWish,
  })

  return jsonResponse({ success: true })
})
