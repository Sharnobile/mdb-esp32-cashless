import { createClient } from '@supabase/supabase-js'
import Stripe from 'stripe'
import { deliverCredit } from '../_shared/deliver-credit.ts'

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 })
  }

  const url = new URL(req.url)
  const companyId = url.searchParams.get('company_id')

  if (!companyId) {
    return new Response('company_id query parameter required', { status: 400 })
  }

  const signature = req.headers.get('stripe-signature')
  if (!signature) {
    return new Response('Missing Stripe-Signature header', { status: 400 })
  }

  const rawBody = await req.text()

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  // 1. Get company webhook secret
  const { data: company } = await supabase
    .from('companies')
    .select('stripe_secret_key, stripe_webhook_secret')
    .eq('id', companyId)
    .single()

  if (!company?.stripe_webhook_secret || !company?.stripe_secret_key) {
    console.error(`Webhook: company ${companyId} has no webhook secret configured`)
    return new Response('Webhook not configured', { status: 400 })
  }

  // 2. Verify webhook signature
  const stripe = new Stripe(company.stripe_secret_key)
  let event: Stripe.Event

  try {
    event = await stripe.webhooks.constructEventAsync(
      rawBody,
      signature,
      company.stripe_webhook_secret,
    )
  } catch (err: unknown) {
    console.error('Webhook signature verification failed:', err)
    return new Response('Invalid signature', { status: 400 })
  }

  // 3. Handle payment_intent.succeeded
  if (event.type === 'payment_intent.succeeded') {
    const pi = event.data.object as Stripe.PaymentIntent

    // Verify this payment belongs to the correct company
    if (pi.metadata.company_id !== companyId) {
      console.error(`Webhook: PI company_id mismatch: ${pi.metadata.company_id} vs ${companyId}`)
      return new Response('OK', { status: 200 }) // Don't retry
    }

    // Check if already processed (idempotent)
    const { data: existing } = await supabase
      .from('payments')
      .select('id, credit_delivered')
      .eq('stripe_payment_intent_id', pi.id)
      .maybeSingle()

    if (existing?.credit_delivered) {
      return new Response('OK', { status: 200 }) // Already handled
    }

    // Get device info for credit delivery
    const embeddedId = pi.metadata.embedded_id
    if (!embeddedId) {
      console.error('Webhook: PI missing embedded_id metadata')
      return new Response('OK', { status: 200 })
    }

    const { data: embedded } = await supabase
      .from('embeddeds')
      .select('id, company, passkey')
      .eq('id', embeddedId)
      .single()

    if (!embedded) {
      console.error(`Webhook: embedded ${embeddedId} not found`)
      return new Response('OK', { status: 200 })
    }

    // Deliver credit
    const amountEur = pi.amount / 100
    let creditDelivered = false

    try {
      await deliverCredit(embedded.company, embedded.id, embedded.passkey, amountEur)
      creditDelivered = true
    } catch (err: unknown) {
      console.error('Webhook: credit delivery failed:', err)
      // Record payment without credit — will retry on next webhook attempt
    }

    // Record/update payment
    await supabase.from('payments').upsert({
      stripe_payment_intent_id: pi.id,
      company_id: companyId,
      machine_id: pi.metadata.machine_id,
      embedded_id: embeddedId,
      product_name: pi.metadata.product_name || 'Unknown',
      slot: parseInt(pi.metadata.slot || '0', 10),
      amount_cents: pi.amount,
      currency: pi.currency,
      status: 'succeeded',
      credit_delivered: creditDelivered,
      credit_delivered_at: creditDelivered ? new Date().toISOString() : null,
    }, { onConflict: 'stripe_payment_intent_id' })

    if (!creditDelivered) {
      // Return 500 so Stripe retries the webhook
      return new Response('Credit delivery failed', { status: 500 })
    }
  }

  return new Response('OK', { status: 200 })
})
