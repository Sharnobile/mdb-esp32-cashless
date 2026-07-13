import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

async function hashKey(key: string): Promise<string> {
  const encoded = new TextEncoder().encode(key)
  const hash = await crypto.subtle.digest('SHA-256', encoded)
  return Array.from(new Uint8Array(hash)).map(b => b.toString(16).padStart(2, '0')).join('')
}

const CACHE_TTL_MS = 6 * 60 * 60 * 1000 // 6 hours
const JSON_HEADER = { 'Content-Type': 'application/json' }

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADER })
}

function parseClaudeJson(rawText: string): { recommendations: unknown[]; summary: string } {
  // Strip ALL markdown code fences
  let cleanText = rawText.replace(/```(?:json)?\s*/g, '').trim()

  try {
    return JSON.parse(cleanText)
  } catch {
    // Extract outermost JSON object with string-aware brace matching
    const start = cleanText.indexOf('{')
    if (start !== -1) {
      let depth = 0, end = start, inString = false, escape = false
      for (let i = start; i < cleanText.length; i++) {
        const ch = cleanText[i]
        if (escape) { escape = false; continue }
        if (ch === '\\' && inString) { escape = true; continue }
        if (ch === '"') { inString = !inString; continue }
        if (inString) continue
        if (ch === '{') depth++
        else if (ch === '}') { depth--; if (depth === 0) { end = i; break } }
      }
      try { return JSON.parse(cleanText.slice(start, end + 1)) }
      catch { return { recommendations: [], summary: rawText } }
    }
    return { recommendations: [], summary: rawText }
  }
}

async function callAnthropic(apiKey: string, prompt: string) {
  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({
      model: 'claude-haiku-4-5-20251001',
      max_tokens: 2048,
      messages: [{ role: 'user', content: prompt }],
    }),
  })

  if (!res.ok) {
    const errBody = await res.json().catch(() => ({}))
    throw new Error(errBody?.error?.message ?? `Anthropic API error: ${res.status}`)
  }

  const data = await res.json()
  return data.content?.[0]?.type === 'text' ? data.content[0].text : ''
}

// ── Auth helper ──────────────────────────────────────────────────────────────

async function resolveCompanyId(
  req: Request,
  adminClient: ReturnType<typeof createClient>
): Promise<string> {
  const apiKey = req.headers.get('X-API-Key')
  const authHeader = req.headers.get('Authorization')

  if (apiKey) {
    const keyHash = await hashKey(apiKey)
    const { data: keyData, error: keyError } = await adminClient
      .from('api_keys')
      .select('id, company_id, revoked_at')
      .eq('key_hash', keyHash)
      .maybeSingle()

    if (keyError || !keyData) throw new Error('Invalid API key')
    if (keyData.revoked_at) throw new Error('API key has been revoked')

    adminClient
      .from('api_keys')
      .update({ last_used_at: new Date().toISOString() })
      .eq('id', keyData.id)
      .then()

    return keyData.company_id
  }

  if (authHeader) {
    const token = authHeader.replace('Bearer ', '')
    const { data: { user }, error: userError } = await adminClient.auth.getUser(token)
    if (userError || !user) throw new Error('Unauthorized')

    const { data: membership } = await adminClient
      .from('organization_members')
      .select('company_id')
      .eq('user_id', user.id)
      .maybeSingle()

    if (!membership) throw new Error('Unauthorized')
    return membership.company_id
  }

  throw new Error('Unauthorized')
}

// ── Prompt builders ──────────────────────────────────────────────────────────

function buildMachinePrompt(kpis: Record<string, unknown>, days: number, lang: string): string {
  return `You are an AI assistant helping vending machine operators optimize their machines.

Analyze the following ${days}-day performance data for machine "${(kpis.machine as any).name}" and provide actionable recommendations.

MACHINE DATA:
${JSON.stringify(kpis, null, 2)}

KPI DEFINITIONS:
- sell_through_pct: % of theoretical weekly capacity sold. <30% = underperforming, >80% = strong
- is_dead_stock: true if 0 sales in the period — consider replacing this product
- avg_daily_units: average units sold per day
- conversion_rate: sales / foot traffic. <0.05 = very low (pricing or product issue)
- warehouse_stock: available inventory in warehouses for products in this machine
- trends: compares current period vs previous period. revenue_change_pct and units_change_pct show growth or decline
- refill_history: recent refill events for this machine
- day_of_week_distribution: sales count and revenue per weekday (dow 0=Sun, 6=Sat). Identify best/worst days.
- hourly_distribution: sales count and revenue per hour (0-23). Identify peak selling hours.
- peak_hours: top 3 hours by sales volume with their % share of total sales

IMPORTANT: Do NOT recommend urgent restocking or flag low current machine stock levels. Current tray stock is a transient snapshot that changes with each refill visit and is NOT meaningful for strategic recommendations. Focus exclusively on sell-through rates, trends, product performance, and optimization opportunities.

Return a JSON object with exactly this structure (no markdown, no code fences, raw JSON only):
{
  "recommendations": [
    {
      "type": "product_swap" | "capacity_increase" | "remove_slot" | "refill_optimization" | "conversion_alert" | "pricing_strategy" | "cross_selling" | "peak_hour_strategy" | "day_pattern" | "general",
      "priority": "high" | "medium" | "low",
      "title": "Short actionable title (max 60 chars)",
      "detail": "Specific detail with numbers (1-2 sentences)",
      "item_number": <integer or null>
    }
  ],
  "summary": "One paragraph narrative summary of overall machine performance, trends vs previous period, and top 2-3 actions to take."
}

Rules:
- Only recommend product_swap for slots where is_dead_stock=true or sell_through_pct < 20
- Recommend capacity_increase for slots with sell_through_pct > 80 and high avg_daily_units
- Flag conversion_alert if conversion_rate < 0.03
- Recommend refill_optimization based on sell-through patterns and refill history (NOT based on current stock levels)
- Recommend pricing_strategy when conversion_rate is low but foot traffic is high, or when a product's price-per-unit is an outlier
- Recommend cross_selling when complementary product patterns emerge from sales data
- Recommend peak_hour_strategy when clear peak hours exist — suggest stocking fast-moving items for peak times or adjusting product mix for off-peak hours
- Recommend day_pattern when significant weekday vs weekend differences exist — suggest different strategies for strong vs weak days
- Use trends data: highlight improving or declining performance vs previous period
- Reference warehouse_stock when relevant
- Maximum 6 recommendations. Prioritize high-impact ones.
- Include trend context and time patterns in the summary
- If data is missing or machine has no sales, say so clearly in summary.

IMPORTANT: Write ALL text output (titles, details, summary) in ${lang}. Keep JSON keys in English.`
}

function buildCompanyPrompt(kpis: Record<string, unknown>, days: number, lang: string): string {
  return `You are an AI assistant helping vending machine operators optimize their fleet of vending machines.

Analyze the following ${days}-day company-wide performance data and provide actionable recommendations.

COMPANY DATA:
${JSON.stringify(kpis, null, 2)}

KPI DEFINITIONS:
- summary: total revenue, units, machine count, and average revenue per machine across the entire fleet
- machines: per-machine breakdown with revenue and units sold
- top_machines: the 3 best-performing machines by revenue
- bottom_machines: the 3 worst-performing machines (with sales > 0)
- day_of_week_distribution: company-wide sales pattern by weekday. Identify best/worst days.
- hourly_distribution: company-wide sales pattern by hour. Identify peak selling hours.
- trends: company-wide current vs previous period comparison

Return a JSON object with exactly this structure (no markdown, no code fences, raw JSON only):
{
  "recommendations": [
    {
      "type": "product_swap" | "capacity_increase" | "remove_slot" | "refill_optimization" | "conversion_alert" | "pricing_strategy" | "cross_selling" | "peak_hour_strategy" | "day_pattern" | "general",
      "priority": "high" | "medium" | "low",
      "title": "Short actionable title (max 60 chars)",
      "detail": "Specific detail with numbers and machine names (1-2 sentences)",
      "item_number": null
    }
  ],
  "summary": "One paragraph narrative summary of overall fleet performance, trends, and top 2-3 actions."
}

Rules:
- Compare top vs bottom machines — what makes top performers succeed?
- Identify underperforming machines and suggest concrete actions (product mix changes, relocation)
- Analyze day_of_week and hourly patterns — are there fleet-wide trends (e.g., all machines peak at the same time)?
- Use trends to highlight whether the fleet is growing or declining
- Recommend peak_hour_strategy if clear peak hours exist across the fleet
- Recommend day_pattern if weekday/weekend differences are significant
- Maximum 6 recommendations. Prioritize fleet-level insights over individual machine issues.
- Include trend context and time patterns in the summary
- If data is limited, say so clearly.

IMPORTANT: Write ALL text output (titles, details, summary) in ${lang}. Keep JSON keys in English.`
}

// ── Main handler ─────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  try {
    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    let companyId: string
    try {
      companyId = await resolveCompanyId(req, adminClient)
    } catch (e) {
      const msg = e instanceof Error ? e.message : 'Unauthorized'
      return jsonResponse({ error: msg }, msg === 'Unauthorized' ? 401 : 401)
    }

    const body = await req.json()
    const { machine_id, days = 30, force_refresh = false, locale = 'en', type = 'machine' } = body

    const lang = locale === 'de' ? 'German' : locale === 'fr' ? 'French' : 'English'

    // ── Type: history — return past insights ──────────────────────────────────
    if (type === 'history') {
      const query = adminClient
        .from('machine_insights_history')
        .select('id, machine_id, period_days, locale, recommendations, summary, trends, generated_at, created_at')
        .eq('company_id', companyId)
        .order('created_at', { ascending: false })
        .limit(20)

      if (machine_id) {
        query.eq('machine_id', machine_id)
      } else {
        query.is('machine_id', null)
      }

      const { data, error } = await query
      if (error) return jsonResponse({ error: error.message }, 500)
      return jsonResponse({ history: data ?? [] })
    }

    // ── Validate machine_id for machine type ─────────────────────────────────
    if (type === 'machine' && !machine_id) {
      return jsonResponse({ error: 'machine_id required' }, 400)
    }

    // ── Cache key: machine_id for machine, company_id for company ────────────
    const cacheId = type === 'company' ? companyId : machine_id

    // ── Check cache (unless force_refresh) ───────────────────────────────────
    if (!force_refresh) {
      const { data: cached } = await adminClient
        .from('machine_insights_cache')
        .select('response, created_at')
        .eq('machine_id', cacheId)
        .eq('period_days', days)
        .eq('locale', locale)
        .maybeSingle()

      if (cached) {
        const cacheAge = Date.now() - new Date(cached.created_at).getTime()
        if (cacheAge < CACHE_TTL_MS) {
          return jsonResponse({ ...(cached.response as Record<string, unknown>), cached: true })
        }
      }
    }

    // ── Fetch per-company Anthropic API key ──────────────────────────────────
    const { data: company } = await adminClient
      .from('companies')
      .select('anthropic_api_key')
      .eq('id', companyId)
      .single()

    if (!company?.anthropic_api_key) {
      return jsonResponse({ error: 'No Anthropic API key configured for this organization. Add one in Settings.' }, 400)
    }

    // ── Call RPC + build prompt based on type ────────────────────────────────
    let kpis: Record<string, unknown>
    let prompt: string

    if (type === 'company') {
      const { data, error } = await adminClient
        .rpc('get_company_insights_kpis', { p_company_id: companyId, p_days: days })
      if (error) {
        console.error('[machine-insights] Company RPC error:', error)
        return jsonResponse({ error: error.message }, 500)
      }
      if (!data) return jsonResponse({ error: 'Company not found' }, 404)
      kpis = data
      prompt = buildCompanyPrompt(kpis, days, lang)
    } else {
      const { data, error } = await adminClient
        .rpc('get_machine_insights_kpis_v2', {
          p_machine_id: machine_id,
          p_company_id: companyId,
          p_days: days,
        })
      if (error) {
        console.error('[machine-insights] RPC error:', error)
        return jsonResponse({ error: error.message }, 500)
      }
      if (!data) return jsonResponse({ error: 'Machine not found' }, 404)
      kpis = data
      prompt = buildMachinePrompt(kpis, days, lang)
    }

    // ── Call Anthropic API ───────────────────────────────────────────────────
    let rawText: string
    try {
      rawText = await callAnthropic(company.anthropic_api_key, prompt)
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      return jsonResponse({ error: msg }, 502)
    }

    const parsed = parseClaudeJson(rawText)

    // ── Build final response ────────────────────────────────────────────────
    const finalResponse: Record<string, unknown> = {
      generated_at: new Date().toISOString(),
      period_days: days,
      type,
      recommendations: parsed.recommendations ?? [],
      summary: parsed.summary ?? '',
      trends: kpis.trends ?? null,
      cached: false,
    }

    if (type === 'company') {
      finalResponse.company = kpis.company
      finalResponse.machines = kpis.machines
    } else {
      finalResponse.machine = kpis.machine
    }

    // ── Write to cache (fire-and-forget) ────────────────────────────────────
    adminClient
      .from('machine_insights_cache')
      .upsert({
        machine_id: cacheId,
        company_id: companyId,
        period_days: days,
        locale,
        response: finalResponse,
        created_at: new Date().toISOString(),
      }, { onConflict: 'machine_id,period_days,locale' })
      .then()

    // ── Write to history (fire-and-forget) ──────────────────────────────────
    adminClient
      .from('machine_insights_history')
      .insert({
        machine_id: type === 'company' ? null : machine_id,
        company_id: companyId,
        period_days: days,
        locale,
        recommendations: parsed.recommendations ?? [],
        summary: parsed.summary ?? '',
        trends: kpis.trends ?? null,
        generated_at: new Date().toISOString(),
      })
      .then()

    return jsonResponse(finalResponse)

  } catch (err) {
    console.error('[machine-insights]', err)
    return jsonResponse({ error: err?.message ?? String(err) }, 500)
  }
})
