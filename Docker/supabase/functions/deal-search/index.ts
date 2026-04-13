import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

// ─── Marktguru API helpers ──────────────────────────────────────────────────

interface MarktguruOffer {
  id: number
  description: string
  price: number
  oldPrice: number | null
  referencePrice: number
  brand: { name: string; uniqueName: string }
  advertisers: { name: string; uniqueName: string }[]
  product: { name: string; description: string | null }
  validityDates: { from: string; to: string }[]
  images: { urls: { small: string; medium: string; large: string } }
}

interface MarktguruKeys {
  apiKey: string
  clientKey: string
}

/** Extracts dynamic API keys from the marktguru.de homepage */
async function getMarktguruKeys(): Promise<MarktguruKeys> {
  const res = await fetch('https://marktguru.de', {
    headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; rv:102.0) Gecko/20100101 Firefox/102.0' },
  })
  const html = await res.text()

  const match = html.match(/<script[^>]*type="application\/json"[^>]*>([\s\S]*?)<\/script>/)
  if (!match?.[1]) throw new Error('Could not extract marktguru config')

  const config = JSON.parse(match[1])

  // The keys are nested in the config object — try common paths
  const apiKey = config?.config?.apiKey ?? config?.apiKey
  const clientKey = config?.config?.clientKey ?? config?.clientKey

  if (!apiKey || !clientKey) throw new Error('Could not find marktguru API keys in config')

  return { apiKey, clientKey }
}

/** Searches marktguru offers by query string */
async function searchMarktguru(
  query: string,
  zipCode: string,
  keys: MarktguruKeys,
  limit = 20,
): Promise<MarktguruOffer[]> {
  const params = new URLSearchParams({
    q: query,
    zipCode,
    limit: String(limit),
    offset: '0',
    as: 'web',
  })

  const res = await fetch(`https://api.marktguru.de/api/v1/offers/search?${params}`, {
    headers: {
      'x-apikey': keys.apiKey,
      'x-clientkey': keys.clientKey,
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; rv:102.0) Gecko/20100101 Firefox/102.0',
    },
  })

  if (!res.ok) {
    console.error(`Marktguru API error: ${res.status} ${res.statusText}`)
    return []
  }

  const data = await res.json()
  return data.results ?? []
}

// ─── Fuzzy matching ─────────────────────────────────────────────────────────

/** Normalize string for comparison: lowercase, remove special chars */
function normalize(s: string): string {
  return s
    .toLowerCase()
    .replace(/[^a-zäöüß0-9\s]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
}

/** Extract brand/core name tokens from a product name */
function extractTokens(name: string): string[] {
  return normalize(name).split(' ').filter((t) => t.length > 1)
}

/**
 * Compute a match confidence between a local product name and a marktguru offer.
 *
 * Handles cases like "Red Bull verschiedene Sorten" matching
 * "Red Bull Energy Drink", "Red Bull Sugarfree", etc.
 *
 * Strategy:
 * 1. Check if the core brand/product tokens from our product appear in the offer
 * 2. Check if the offer brand matches our product name
 * 3. Penalize generic terms like "verschiedene Sorten"
 */
function matchConfidence(
  productName: string,
  offerDescription: string,
  offerBrand: string,
): number {
  const productNorm = normalize(productName)
  const offerNorm = normalize(offerDescription)
  const brandNorm = normalize(offerBrand)

  // Exact match
  if (productNorm === offerNorm) return 1.0

  const productTokens = extractTokens(productName)
  if (productTokens.length === 0) return 0

  // Filter out generic filler words from the offer
  const genericTerms = new Set([
    'verschiedene', 'sorten', 'versch', 'diverse', 'oder', 'und', 'z.b',
    'zb', 'jede', 'jeder', 'je', 'stück', 'packung', 'dose', 'flasche',
    'kasten', 'kiste', 'krat', 'tray', 'pack',
  ])

  // Check how many product tokens appear in the offer description
  let tokenMatches = 0
  for (const token of productTokens) {
    if (genericTerms.has(token)) continue
    if (offerNorm.includes(token) || brandNorm.includes(token)) {
      tokenMatches++
    }
  }

  const meaningfulTokens = productTokens.filter((t) => !genericTerms.has(t))
  if (meaningfulTokens.length === 0) return 0

  const tokenScore = tokenMatches / meaningfulTokens.length

  // Bonus: brand name from offer matches first word(s) of product
  let brandBonus = 0
  if (brandNorm && productNorm.startsWith(brandNorm)) {
    brandBonus = 0.15
  } else if (brandNorm && productNorm.includes(brandNorm)) {
    brandBonus = 0.1
  }

  // Check reverse: do offer description tokens appear in product?
  const offerTokens = extractTokens(offerDescription).filter((t) => !genericTerms.has(t))
  let reverseMatches = 0
  for (const token of offerTokens) {
    if (productNorm.includes(token)) reverseMatches++
  }
  const reverseScore = offerTokens.length > 0 ? reverseMatches / offerTokens.length : 0

  // Combined score (weighted)
  const combined = Math.min(1.0, tokenScore * 0.6 + reverseScore * 0.25 + brandBonus)

  return Math.round(combined * 100) / 100
}

// ─── Main handler ───────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders })
  }

  try {
    // Auth
    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    )
    const token = req.headers.get('Authorization')?.replace('Bearer ', '') ?? ''
    const { data: { user }, error: userError } = await adminClient.auth.getUser(token)
    if (userError || !user) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // Get user's company
    const { data: membership } = await adminClient
      .from('organization_members')
      .select('company_id')
      .eq('user_id', user.id)
      .single()

    if (!membership) {
      return new Response(JSON.stringify({ error: 'No organization found' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const companyId = membership.company_id

    // Check if deals feature is enabled
    const { data: company } = await adminClient
      .from('companies')
      .select('deals_enabled, deals_zip_code')
      .eq('id', companyId)
      .single()

    if (!company?.deals_enabled) {
      return new Response(JSON.stringify({ error: 'Deal search is not enabled for this company' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const zipCode = company.deals_zip_code || '60487'

    const body = await req.json().catch(() => ({}))
    const forceRefresh = body.forceRefresh === true
    const minConfidence = typeof body.minConfidence === 'number' ? body.minConfidence : 0.5

    // Check cache age — if we have fresh data (< 12h), return cached
    if (!forceRefresh) {
      const twelveHoursAgo = new Date(Date.now() - 12 * 60 * 60 * 1000).toISOString()
      const { data: cached, count } = await adminClient
        .from('deal_cache')
        .select('*, products(name, image_path, sellprice)', { count: 'exact' })
        .eq('company_id', companyId)
        .gte('fetched_at', twelveHoursAgo)
        .gte('valid_until', new Date().toISOString().split('T')[0])
        .gte('confidence', minConfidence)
        .order('discount_pct', { ascending: false, nullsFirst: false })

      if (count && count > 0) {
        return new Response(JSON.stringify({ deals: cached, fromCache: true }), {
          status: 200,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }
    }

    // Fetch products for this company (non-discontinued only)
    const { data: products } = await adminClient
      .from('products')
      .select('id, name, sellprice, image_path, category:product_category(name)')
      .eq('company', companyId)
      .or('discontinued.is.null,discontinued.eq.false')

    if (!products || products.length === 0) {
      return new Response(JSON.stringify({ deals: [], fromCache: false, message: 'No products found' }), {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // Get marktguru API keys
    let keys: MarktguruKeys
    try {
      keys = await getMarktguruKeys()
    } catch (err) {
      console.error('Failed to get marktguru keys:', err)
      return new Response(JSON.stringify({ error: 'Failed to connect to offer service' }), {
        status: 502,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // Search for each product and collect matches
    const allDeals: any[] = []
    const seen = new Set<string>() // dedup by offer_id + product_id

    // Batch products: extract unique search terms to reduce API calls
    // e.g. "Red Bull Sugarfree" and "Red Bull Energy" → search "Red Bull" once
    const searchQueries = new Map<string, typeof products>()
    for (const product of products) {
      if (!product.name) continue
      // Use the full product name as search query for best matches
      const query = product.name.trim()
      if (!query) continue
      const existing = searchQueries.get(query) ?? []
      existing.push(product)
      searchQueries.set(query, existing)
    }

    // Limit to 30 searches per request to respect rate limits
    const queries = Array.from(searchQueries.entries()).slice(0, 30)

    for (const [query, matchProducts] of queries) {
      try {
        const offers = await searchMarktguru(query, zipCode, keys, 10)

        for (const offer of offers) {
          for (const product of matchProducts) {
            const confidence = matchConfidence(
              product.name,
              offer.description,
              offer.brand?.name ?? '',
            )

            if (confidence < minConfidence) continue

            const dedup = `${offer.id}-${product.id}`
            if (seen.has(dedup)) continue
            seen.add(dedup)

            const retailer = offer.advertisers?.[0]?.uniqueName ?? 'unknown'
            const retailerName = offer.advertisers?.[0]?.name ?? retailer
            const validFrom = offer.validityDates?.[0]?.from ?? null
            const validUntil = offer.validityDates?.[0]?.to ?? null
            const discountPct = offer.oldPrice && offer.price
              ? Math.round((1 - offer.price / offer.oldPrice) * 100)
              : null

            allDeals.push({
              company_id: companyId,
              product_id: product.id,
              retailer: retailerName,
              deal_title: offer.description,
              deal_price: offer.price,
              regular_price: offer.oldPrice,
              discount_pct: discountPct,
              valid_from: validFrom,
              valid_until: validUntil,
              image_url: offer.images?.urls?.medium ?? null,
              matched_by: 'name_fuzzy',
              confidence,
              fetched_at: new Date().toISOString(),
              offer_id: String(offer.id),
            })
          }
        }

        // Also try to match each offer against ALL products (cross-match)
        // This catches "Red Bull versch. Sorten" matching all Red Bull variants
        for (const offer of offers) {
          for (const product of products) {
            const dedup = `${offer.id}-${product.id}`
            if (seen.has(dedup)) continue

            const confidence = matchConfidence(
              product.name,
              offer.description,
              offer.brand?.name ?? '',
            )

            if (confidence < minConfidence) continue
            seen.add(dedup)

            const retailer = offer.advertisers?.[0]?.uniqueName ?? 'unknown'
            const retailerName = offer.advertisers?.[0]?.name ?? retailer
            const validFrom = offer.validityDates?.[0]?.from ?? null
            const validUntil = offer.validityDates?.[0]?.to ?? null
            const discountPct = offer.oldPrice && offer.price
              ? Math.round((1 - offer.price / offer.oldPrice) * 100)
              : null

            allDeals.push({
              company_id: companyId,
              product_id: product.id,
              retailer: retailerName,
              deal_title: offer.description,
              deal_price: offer.price,
              regular_price: offer.oldPrice,
              discount_pct: discountPct,
              valid_from: validFrom,
              valid_until: validUntil,
              image_url: offer.images?.urls?.medium ?? null,
              matched_by: 'name_fuzzy',
              confidence,
              fetched_at: new Date().toISOString(),
              offer_id: String(offer.id),
            })
          }
        }
      } catch (err) {
        console.error(`Search failed for "${query}":`, err)
        // Continue with next product
      }
    }

    // Clear old cache for this company and write new results
    await adminClient
      .from('deal_cache')
      .delete()
      .eq('company_id', companyId)

    if (allDeals.length > 0) {
      await adminClient.from('deal_cache').upsert(allDeals, {
        onConflict: 'company_id,product_id,retailer,offer_id',
        ignoreDuplicates: true,
      })
    }

    // Read back with product joins for the response
    const { data: result } = await adminClient
      .from('deal_cache')
      .select('*, products(name, image_path, sellprice)')
      .eq('company_id', companyId)
      .gte('confidence', minConfidence)
      .order('discount_pct', { ascending: false, nullsFirst: false })

    return new Response(JSON.stringify({
      deals: result ?? [],
      fromCache: false,
      searchedProducts: queries.length,
      totalDeals: allDeals.length,
    }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (err) {
    console.error('deal-search error:', err)
    return new Response(JSON.stringify({ error: err?.message ?? 'Internal error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
