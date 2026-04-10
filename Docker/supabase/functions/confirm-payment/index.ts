import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import Stripe from 'npm:stripe@^17'
import { deliverCredit } from '../_shared/deliver-credit.ts'

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

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

  let body: { payment_intent_id?: string; machine_id?: string }
  try {
    body = await req.json()
  } catch {
    return jsonResponse({ error: 'Invalid JSON' }, 400)
  }

  const { payment_intent_id, machine_id } = body

  if (!payment_intent_id || !machine_id) {
    return jsonResponse({ error: 'payment_intent_id and machine_id are required' }, 400)
  }

  if (!UUID_RE.test(machine_id)) {
    return jsonResponse({ error: 'machine_id must be a valid UUID' }, 400)
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  // 1. Check if already processed (idempotent)
  const { data: existing } = await supabase
    .from('payments')
    .select('id, credit_delivered')
    .eq('stripe_payment_intent_id', payment_intent_id)
    .maybeSingle()

  if (existing?.credit_delivered) {
    return jsonResponse({ success: true, status: 'already_processed' })
  }

  // 2. Find vending machine by UUID
  const { data: machine } = await supabase
    .from('vendingMachine')
    .select('id, company, embedded')
    .eq('id', machine_id)
    .single()

  if (!machine) {
    return jsonResponse({ error: 'Machine not found' }, 404)
  }

  if (!machine.embedded) {
    return jsonResponse({ error: 'Machine has no device for credit delivery' }, 503)
  }

  // 3. Fetch device passkey for XOR encryption
  const { data: embedded } = await supabase
    .from('embeddeds')
    .select('id, passkey')
    .eq('id', machine.embedded)
    .single()

  if (!embedded) {
    return jsonResponse({ error: 'Device not found' }, 404)
  }

  // 4. Get company Stripe key and verify payment
  const { data: company } = await supabase
    .from('companies')
    .select('stripe_secret_key')
    .eq('id', machine.company)
    .single()

  if (!company?.stripe_secret_key) {
    return jsonResponse({ error: 'Payment not configured' }, 503)
  }

  const stripe = new Stripe(company.stripe_secret_key)
  let paymentIntent: Stripe.PaymentIntent

  try {
    paymentIntent = await stripe.paymentIntents.retrieve(payment_intent_id)
  } catch (err: unknown) {
    console.error('Failed to retrieve PaymentIntent:', err)
    return jsonResponse({ error: 'Invalid payment reference' }, 400)
  }

  // 5. Verify payment succeeded
  if (paymentIntent.status !== 'succeeded') {
    return jsonResponse({ error: 'Payment has not succeeded', status: paymentIntent.status }, 400)
  }

  // 6. Verify machine matches (prevent cross-machine abuse)
  if (paymentIntent.metadata.machine_id !== machine.id) {
    return jsonResponse({ error: 'Payment does not belong to this machine' }, 403)
  }

  // 7. Deliver credit via MQTT
  const amountEur = paymentIntent.amount / 100
  try {
    await deliverCredit(machine.company, embedded.id, embedded.passkey, amountEur)
  } catch (err: unknown) {
    console.error('Credit delivery failed:', err)
    // Record payment but mark credit as not delivered
    await supabase.from('payments').upsert({
      stripe_payment_intent_id: payment_intent_id,
      company_id: machine.company,
      machine_id: machine.id,
      embedded_id: embedded.id,
      product_name: paymentIntent.metadata.product_name || 'Unknown',
      slot: parseInt(paymentIntent.metadata.slot || '0', 10),
      amount_cents: paymentIntent.amount,
      currency: paymentIntent.currency,
      status: 'succeeded',
      credit_delivered: false,
    }, { onConflict: 'stripe_payment_intent_id', ignoreDuplicates: true })

    return jsonResponse({ error: 'Payment succeeded but credit delivery failed. Please contact operator.' }, 502)
  }

  // 8. Record payment with credit delivered
  await supabase.from('payments').upsert({
    stripe_payment_intent_id: payment_intent_id,
    company_id: machine.company,
    machine_id: machine.id,
    embedded_id: embedded.id,
    product_name: paymentIntent.metadata.product_name || 'Unknown',
    slot: parseInt(paymentIntent.metadata.slot || '0', 10),
    amount_cents: paymentIntent.amount,
    currency: paymentIntent.currency,
    status: 'succeeded',
    credit_delivered: true,
    credit_delivered_at: new Date().toISOString(),
  }, { onConflict: 'stripe_payment_intent_id', ignoreDuplicates: false })

  return jsonResponse({ success: true, status: 'credit_delivered' })
})
