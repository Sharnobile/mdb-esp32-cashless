import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { sendPushToUsers } from '../_shared/web-push.ts'

Deno.serve(async (req) => {
  // CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Authorization, Content-Type, apikey, x-client-info',
      },
    })
  }

  try {
    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    )

    // Verify user identity
    const token = req.headers.get('Authorization')?.replace('Bearer ', '') ?? ''
    const { data: { user }, error: userError } = await adminClient.auth.getUser(token)
    if (userError || !user) {
      return new Response(JSON.stringify({ error: 'unauthorized' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
      })
    }

    // Get user's company
    const { data: membership } = await adminClient
      .from('organization_members')
      .select('company_id')
      .eq('user_id', user.id)
      .maybeSingle()

    if (!membership) {
      return new Response(JSON.stringify({ error: 'no organization' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
      })
    }

    // Pick any product in the caller's company with an image so the push
    // carries an `image` field for the iOS Notification Service Extension
    // and the web/Android native image renderers to display. If no product
    // has an image yet, the payload stays text-only — still a valid test.
    let testImageUrl: string | undefined
    try {
      const { data: product } = await adminClient
        .from('products')
        .select('image_path')
        .eq('company_id', membership.company_id)
        .not('image_path', 'is', null)
        .limit(1)
        .maybeSingle()

      if (product?.image_path) {
        const supabaseUrl = Deno.env.get('SUPABASE_PUBLIC_URL') ?? Deno.env.get('SUPABASE_URL')
        testImageUrl = `${supabaseUrl}/storage/v1/object/public/product-images/${product.image_path}`
      }
    } catch (err) {
      console.warn('[test-push] product image lookup failed:', err)
      // proceed without image
    }

    // Send a test notification — use type '_test' which is never in the
    // disabled preferences list, so it always reaches the device regardless
    // of which notification types the user has toggled off.
    const result = await sendPushToUsers(adminClient, membership.company_id, '_test', {
      title: '🔔 Test Notification',
      body: 'Push notifications are working! This is a test from VMflow.',
      image: testImageUrl,
      data: { type: 'test' },
    })

    return new Response(JSON.stringify({ ok: true, ...result }), {
      status: 200,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
    })
  } catch (err) {
    return new Response(JSON.stringify({ error: err?.message ?? String(err) }), {
      status: 500,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
    })
  }
})
