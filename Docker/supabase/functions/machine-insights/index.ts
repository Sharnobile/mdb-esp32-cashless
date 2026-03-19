import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

async function hashKey(key: string): Promise<string> {
  const encoded = new TextEncoder().encode(key)
  const hash = await crypto.subtle.digest('SHA-256', encoded)
  return Array.from(new Uint8Array(hash)).map(b => b.toString(16).padStart(2, '0')).join('')
}

Deno.serve(async (req) => {
  try {
    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    // ── Auth ──────────────────────────────────────────────────────────────────
    const apiKey = req.headers.get('X-API-Key')
    const authHeader = req.headers.get('Authorization')
    let companyId: string | null = null

    if (apiKey) {
      // --- API key authentication ---
      const keyHash = await hashKey(apiKey)
      const { data: keyData, error: keyError } = await adminClient
        .from('api_keys')
        .select('id, company_id, revoked_at')
        .eq('key_hash', keyHash)
        .maybeSingle()

      if (keyError || !keyData) {
        return new Response(JSON.stringify({ error: 'Invalid API key' }), {
          status: 401, headers: { 'Content-Type': 'application/json' },
        })
      }
      if (keyData.revoked_at) {
        return new Response(JSON.stringify({ error: 'API key has been revoked' }), {
          status: 401, headers: { 'Content-Type': 'application/json' },
        })
      }

      companyId = keyData.company_id

      // Update last_used_at (fire-and-forget)
      adminClient
        .from('api_keys')
        .update({ last_used_at: new Date().toISOString() })
        .eq('id', keyData.id)
        .then()
    } else if (authHeader) {
      // --- JWT authentication ---
      const token = authHeader.replace('Bearer ', '')
      const { data: { user }, error: userError } = await adminClient.auth.getUser(token)
      if (userError || !user) {
        return new Response(JSON.stringify({ error: 'Unauthorized' }), {
          status: 401, headers: { 'Content-Type': 'application/json' },
        })
      }

      const { data: membership } = await adminClient
        .from('organization_members')
        .select('company_id')
        .eq('user_id', user.id)
        .maybeSingle()

      if (!membership) {
        return new Response(JSON.stringify({ error: 'Unauthorized' }), {
          status: 401, headers: { 'Content-Type': 'application/json' },
        })
      }

      companyId = membership.company_id
    } else {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401, headers: { 'Content-Type': 'application/json' },
      })
    }

    // ── Parse request body ────────────────────────────────────────────────────
    const { machine_id, days = 30 } = await req.json()
    if (!machine_id) {
      return new Response(JSON.stringify({ error: 'machine_id required' }), {
        status: 400, headers: { 'Content-Type': 'application/json' },
      })
    }

    // ── Fetch per-company Anthropic API key ────────────────────────────────────
    const { data: company } = await adminClient
      .from('companies')
      .select('anthropic_api_key')
      .eq('id', companyId)
      .single()

    if (!company?.anthropic_api_key) {
      return new Response(JSON.stringify({ error: 'No Anthropic API key configured for this organization. Add one in Settings.' }), {
        status: 400, headers: { 'Content-Type': 'application/json' },
      })
    }
    const anthropicKey = company.anthropic_api_key

    // ── Call RPC ──────────────────────────────────────────────────────────────
    const { data: kpis, error: rpcError } = await adminClient
      .rpc('get_machine_insights_kpis', {
        p_machine_id: machine_id,
        p_company_id: companyId,
        p_days: days
      })

    if (rpcError) {
      console.error('[machine-insights] RPC error:', rpcError)
      return new Response(JSON.stringify({ error: rpcError.message }), {
        status: 500, headers: { 'Content-Type': 'application/json' },
      })
    }
    if (!kpis) {
      return new Response(JSON.stringify({ error: 'Machine not found' }), {
        status: 404, headers: { 'Content-Type': 'application/json' },
      })
    }

    // ── Build Claude prompt ───────────────────────────────────────────────────
    const prompt = `You are an AI assistant helping vending machine operators optimize their machines.

Analyze the following ${days}-day performance data for machine "${kpis.machine.name}" and provide actionable recommendations.

MACHINE DATA:
${JSON.stringify(kpis, null, 2)}

KPI DEFINITIONS:
- sell_through_pct: % of theoretical weekly capacity sold. <30% = underperforming, >80% = strong
- is_dead_stock: true if 0 sales in the period — consider replacing this product
- days_until_empty: estimated days until this tray runs out at current rate
- conversion_rate: sales / foot traffic. <0.05 = very low (pricing or product issue)
- avg_daily_units: average units sold per day

Return a JSON object with exactly this structure (no markdown, raw JSON only):
{
  "recommendations": [
    {
      "type": "product_swap" | "capacity_increase" | "remove_slot" | "refill_optimization" | "conversion_alert" | "general",
      "priority": "high" | "medium" | "low",
      "title": "Short actionable title (max 60 chars)",
      "detail": "Specific detail with numbers (1-2 sentences)",
      "item_number": <integer or null>
    }
  ],
  "summary": "One paragraph narrative summary of overall machine performance and top 2-3 actions to take."
}

Rules:
- Only recommend product_swap for slots where is_dead_stock=true or sell_through_pct < 20
- Recommend capacity_increase for slots where days_until_empty < 5 and sell_through_pct > 70
- Flag conversion_alert if conversion_rate < 0.03
- Recommend refill_optimization if any tray has days_until_empty < 3
- Maximum 6 recommendations. Prioritize high-impact ones.
- If data is missing or machine has no sales, say so clearly in summary.`

    // ── Call Anthropic API (direct fetch — no SDK needed) ─────────────────────
    const anthropicRes = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': anthropicKey,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001',
        max_tokens: 1024,
        messages: [{ role: 'user', content: prompt }],
      }),
    })

    if (!anthropicRes.ok) {
      const errBody = await anthropicRes.json().catch(() => ({}))
      const errMsg = errBody?.error?.message ?? `Anthropic API error: ${anthropicRes.status}`
      return new Response(JSON.stringify({ error: errMsg }), {
        status: anthropicRes.status, headers: { 'Content-Type': 'application/json' },
      })
    }

    const anthropicData = await anthropicRes.json()
    const rawText = anthropicData.content?.[0]?.type === 'text' ? anthropicData.content[0].text : ''

    // ── Parse response ────────────────────────────────────────────────────────
    let parsed: { recommendations: unknown[]; summary: string }
    // Strip markdown code fences if present (```json ... ``` or ``` ... ```)
    let cleanText = rawText.replace(/^```(?:json)?\s*\n?/gm, '').replace(/\n?```\s*$/gm, '').trim()
    try {
      parsed = JSON.parse(cleanText)
    } catch {
      // Fallback: extract the outermost JSON object by matching balanced braces
      const start = cleanText.indexOf('{')
      if (start !== -1) {
        let depth = 0
        let end = start
        for (let i = start; i < cleanText.length; i++) {
          if (cleanText[i] === '{') depth++
          else if (cleanText[i] === '}') { depth--; if (depth === 0) { end = i; break } }
        }
        try {
          parsed = JSON.parse(cleanText.slice(start, end + 1))
        } catch {
          parsed = { recommendations: [], summary: rawText }
        }
      } else {
        parsed = { recommendations: [], summary: rawText }
      }
    }

    // ── Return final response ─────────────────────────────────────────────────
    return new Response(JSON.stringify({
      generated_at: new Date().toISOString(),
      period_days: days,
      machine: kpis.machine,
      recommendations: parsed.recommendations ?? [],
      summary: parsed.summary ?? ''
    }), { status: 200, headers: { 'Content-Type': 'application/json' } })

  } catch (err) {
    console.error('[machine-insights]', err)
    return new Response(JSON.stringify({ error: err?.message ?? String(err) }), {
      status: 500, headers: { 'Content-Type': 'application/json' },
    })
  }
})
