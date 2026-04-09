import { createClient } from '@supabase/supabase-js'
import Stripe from 'stripe'

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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS })
  }

  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Method not allowed' }, 405)
  }

  let body: { subdomain?: number; product_id?: string; slot?: number }
  try {
    body = await req.json()
  } catch {
    return jsonResponse({ error: 'Invalid JSON' }, 400)
  }

  const { subdomain, product_id, slot } = body

  if (!subdomain || !product_id || slot === undefined || slot === null) {
    return jsonResponse({ error: 'subdomain, product_id, and slot are required' }, 400)
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  // 1. Find device by subdomain
  const { data: embedded } = await supabase
    .from('embeddeds')
    .select('id, company')
    .eq('subdomain', subdomain)
    .single()

  if (!embedded) {
    return jsonResponse({ error: 'Machine not found' }, 404)
  }

  // 2. Find vending machine
  const { data: machine } = await supabase
    .from('vendingMachine')
    .select('id, name')
    .eq('embedded', embedded.id)
    .single()

  if (!machine) {
    return jsonResponse({ error: 'Machine not found' }, 404)
  }

  // 3. Find product + price via tray
  const { data: tray } = await supabase
    .from('machine_trays')
    .select('item_number, current_stock, products(id, name, sellprice)')
    .eq('machine_id', machine.id)
    .eq('item_number', slot)
    .eq('product_id', product_id)
    .single()

  if (!tray || !tray.products) {
    return jsonResponse({ error: 'Product not found in this slot' }, 404)
  }

  const product = tray.products as unknown as { id: string; name: string; sellprice: number | null }

  if (!product.sellprice || product.sellprice <= 0) {
    return jsonResponse({ error: 'Product has no price configured' }, 400)
  }

  if (tray.current_stock <= 0) {
    return jsonResponse({ error: 'Product is out of stock' }, 409)
  }

  // 4. Get company Stripe keys
  const { data: company } = await supabase
    .from('companies')
    .select('stripe_secret_key, stripe_publishable_key')
    .eq('id', embedded.company)
    .single()

  if (!company?.stripe_secret_key || !company?.stripe_publishable_key) {
    return jsonResponse({ error: 'Payment is not available for this machine' }, 503)
  }

  // 5. Create Stripe PaymentIntent
  const stripe = new Stripe(company.stripe_secret_key)
  const amountCents = Math.round(product.sellprice * 100)

  try {
    const paymentIntent = await stripe.paymentIntents.create({
      amount: amountCents,
      currency: 'eur',
      metadata: {
        machine_id: machine.id,
        machine_name: machine.name,
        product_id: product.id,
        product_name: product.name,
        slot: String(slot),
        subdomain: String(subdomain),
        company_id: embedded.company,
        embedded_id: embedded.id,
      },
    })

    return jsonResponse({
      clientSecret: paymentIntent.client_secret,
      paymentIntentId: paymentIntent.id,
      publishableKey: company.stripe_publishable_key,
      amount: amountCents,
      currency: 'eur',
    })
  } catch (err: unknown) {
    console.error('Stripe PaymentIntent creation failed:', err)
    const message = err instanceof Error ? err.message : 'Payment creation failed'
    return jsonResponse({ error: message }, 500)
  }
})
