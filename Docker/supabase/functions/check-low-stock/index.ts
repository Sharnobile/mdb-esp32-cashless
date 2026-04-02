import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { sendPushToUsers } from '../_shared/web-push.ts'

/**
 * check-low-stock
 *
 * Reads unsent rows from `low_stock_notifications`, groups by company,
 * sends push notifications via the existing web-push infrastructure,
 * then marks rows as sent.
 *
 * Can be called periodically (e.g. via cron) or triggered after stock changes.
 * Uses service_role — no user auth required.
 */
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

    // Optional: verify caller is authenticated (user or webhook)
    const token = req.headers.get('Authorization')?.replace('Bearer ', '') ?? ''
    if (token) {
      const { data: { user }, error: userError } = await adminClient.auth.getUser(token)
      if (userError || !user) {
        return new Response(JSON.stringify({ error: 'unauthorized' }), {
          status: 401,
          headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
        })
      }
    }

    // Fetch unsent low-stock notifications
    const { data: notifications, error: fetchError } = await adminClient
      .from('low_stock_notifications')
      .select('id, company_id, product_name, current_quantity, min_quantity')
      .is('sent_at', null)
      .order('created_at')
      .limit(100)

    if (fetchError) throw fetchError

    if (!notifications || notifications.length === 0) {
      return new Response(JSON.stringify({ ok: true, sent: 0, notifications: 0 }), {
        status: 200,
        headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
      })
    }

    // Group by company
    const byCompany = new Map<string, typeof notifications>()
    for (const n of notifications) {
      const list = byCompany.get(n.company_id) ?? []
      list.push(n)
      byCompany.set(n.company_id, list)
    }

    let totalSent = 0

    // Send one notification per company (batch product names)
    for (const [companyId, items] of byCompany) {
      const productList = items.map(i =>
        `${i.product_name}: ${i.current_quantity}/${i.min_quantity}`
      ).join(', ')

      const title = items.length === 1
        ? `Low stock: ${items[0].product_name}`
        : `Low stock: ${items.length} products`

      const result = await sendPushToUsers(adminClient, companyId, 'low_stock', {
        title,
        body: productList,
        data: {
          type: 'low_stock',
          products: items.map(i => ({
            product_name: i.product_name,
            current_quantity: i.current_quantity,
            min_quantity: i.min_quantity,
          })),
        },
      })

      totalSent += result.sent
    }

    // Mark all as sent
    const ids = notifications.map(n => n.id)
    const { error: updateError } = await adminClient
      .from('low_stock_notifications')
      .update({ sent_at: new Date().toISOString() })
      .in('id', ids)

    if (updateError) {
      console.error('Failed to mark notifications as sent:', updateError)
    }

    return new Response(JSON.stringify({
      ok: true,
      notifications: notifications.length,
      sent: totalSent,
    }), {
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
