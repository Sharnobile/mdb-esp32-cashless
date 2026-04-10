import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

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

  let body: { machine_id?: string; product_id?: string; email?: string }
  try {
    body = await req.json()
  } catch {
    return jsonResponse({ error: 'Invalid JSON' }, 400)
  }

  const { machine_id, product_id, email } = body

  if (!machine_id || !product_id || !email) {
    return jsonResponse({ error: 'machine_id, product_id, and email are required' }, 400)
  }

  if (!EMAIL_RE.test(email)) {
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

  // Verify product exists
  const { data: product, error: productErr } = await supabase
    .from('products')
    .select('id')
    .eq('id', product_id)
    .single()

  if (productErr || !product) {
    return jsonResponse({ error: 'Product not found' }, 404)
  }

  // Insert subscription (ON CONFLICT DO NOTHING for duplicates)
  const { error: insertErr } = await supabase
    .from('restock_subscriptions')
    .upsert(
      {
        machine_id,
        product_id,
        email: email.toLowerCase().trim(),
        company_id: machine.company,
      },
      { onConflict: 'machine_id,product_id,email', ignoreDuplicates: true },
    )

  if (insertErr) {
    console.error('Failed to insert restock subscription:', insertErr)
    return jsonResponse({ error: 'Failed to subscribe' }, 500)
  }

  return jsonResponse({ success: true })
})
