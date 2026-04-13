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
  requiresLoyalityMembership: boolean
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

// ─── Retailer prospekt URLs ─────────────────────────────────────────────────

/** Direct links to official online leaflets for German retailers */
const RETAILER_PROSPEKT_URLS: Record<string, string> = {
  'lidl': 'https://www.lidl.de/c/online-prospekte/s10005610',
  'kaufland': 'https://www.kaufland.de/angebote/aktuelle-prospekte.html',
  'rewe': 'https://www.rewe.de/angebote/nationale-angebote/',
  'aldi-sued': 'https://www.aldi-sued.de/de/angebote.html',
  'aldi-nord': 'https://www.aldi-nord.de/angebote.html',
  'penny': 'https://www.penny.de/angebote',
  'netto-marken-discount': 'https://www.netto-online.de/angebote',
  'norma': 'https://www.norma-online.de/de/angebote/',
  'edeka': 'https://www.edeka.de/angebote.jsp',
  'rossmann': 'https://www.rossmann.de/de/angebote.html',
  'dm': 'https://www.dm.de/angebote',
  'real': 'https://www.real.de/angebote/',
  'müller': 'https://www.mueller.de/angebote/',
  'globus': 'https://www.globus.de/angebote/',
  'tegut': 'https://www.tegut.com/angebote/aktuelle-angebote.html',
  'hit': 'https://www.hit.de/angebote/',
  'famila': 'https://www.famila-nordost.de/angebote/',
  'metro': 'https://www.metro.de/angebote',
  'selgros': 'https://www.selgros.de/angebote',
}

function getRetailerProspektUrl(slug: string): string | null {
  return RETAILER_PROSPEKT_URLS[slug] ?? null
}

/**
 * Detect app requirement from offer description text.
 * Fallback for when requiresLoyalityMembership is false but the
 * description mentions an app price (e.g. "mit Netto-App nur 0,88€").
 */
function detectAppRequirement(description: string): boolean {
  const lower = description.toLowerCase()
  const patterns = [
    'mit app',
    'in der app',
    'netto-app', 'netto app',
    'lidl plus', 'lidl-plus',
    'rewe bonus', 'rewe-bonus',
    'penny app', 'penny-app',
    'kaufland card', 'kaufland-card',
    'app-preis', 'app preis', 'apppreis',
    'nur mit',
    'app-coupon', 'app coupon',
    'digital-coupon', 'digital coupon',
  ]
  return patterns.some((p) => lower.includes(p))
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

interface MatchResult {
  confidence: number
  matchedTokens: string[]
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
 *
 * Returns both confidence score and list of matched tokens for validation UI.
 */
function matchConfidence(
  productName: string,
  offerDescription: string,
  offerBrand: string,
): MatchResult {
  const productNorm = normalize(productName)
  const offerNorm = normalize(offerDescription)
  const brandNorm = normalize(offerBrand)
  const matchedTokens: string[] = []

  // Exact match
  if (productNorm === offerNorm) {
    return { confidence: 1.0, matchedTokens: extractTokens(productName) }
  }

  const productTokens = extractTokens(productName)
  if (productTokens.length === 0) return { confidence: 0, matchedTokens: [] }

  // Filter out generic filler words that appear in product names but rarely
  // in offer descriptions (or vice versa) and would hurt matching scores.
  const genericTerms = new Set([
    // German offer phrasing
    'verschiedene', 'sorten', 'versch', 'diverse', 'oder', 'und', 'z.b',
    'zb', 'jede', 'jeder', 'je',
    // Packaging / unit
    'stück', 'packung', 'dose', 'flasche', 'dosen', 'flaschen',
    'kasten', 'kiste', 'krat', 'tray', 'pack', 'beutel', 'becher',
    'tafel', 'riegel', 'tube', 'glas',
    // Generic product descriptors
    'drink', 'drinks', 'getränk', 'getränke',
    'light', 'free', 'sugar',
    'bio', 'vegan',
    // Size / weight patterns (commonly in product names but not in offers)
    'ml', 'cl', 'liter', 'kg', 'gr',
  ])

  /** Check if a token appears in text — numeric tokens must match as a
   *  whole word to avoid "50" matching inside "500ml" or "1,50€". */
  function tokenInText(token: string, text: string): boolean {
    const isNumeric = /^\d+$/.test(token)
    if (isNumeric) {
      // Word-boundary match: the token must be surrounded by non-digit chars
      // or be at the start/end of the string
      const re = new RegExp(`(?<![0-9])${token}(?![0-9])`)
      return re.test(text)
    }
    return text.includes(token)
  }

  // Check how many product tokens appear in the offer description
  let tokenMatches = 0
  for (const token of productTokens) {
    if (genericTerms.has(token)) continue
    if (tokenInText(token, offerNorm) || tokenInText(token, brandNorm)) {
      tokenMatches++
      matchedTokens.push(token)
    }
  }

  const meaningfulTokens = productTokens.filter((t) => !genericTerms.has(t))
  // If all tokens are generic, fall back to using all tokens
  const scoringTokens = meaningfulTokens.length > 0 ? meaningfulTokens : productTokens

  const tokenScore = tokenMatches / scoringTokens.length

  // Bonus: brand name from offer matches first word(s) of product
  let brandBonus = 0
  if (brandNorm && productNorm.startsWith(brandNorm)) {
    brandBonus = 0.15
    if (!matchedTokens.includes(brandNorm)) matchedTokens.push(brandNorm)
  } else if (brandNorm && productNorm.includes(brandNorm)) {
    brandBonus = 0.1
    if (!matchedTokens.includes(brandNorm)) matchedTokens.push(brandNorm)
  }

  // Check reverse: do offer description tokens appear in product?
  const offerTokens = extractTokens(offerDescription).filter((t) => !genericTerms.has(t))
  let reverseMatches = 0
  for (const token of offerTokens) {
    if (tokenInText(token, productNorm)) {
      reverseMatches++
      if (!matchedTokens.includes(token)) matchedTokens.push(token)
    }
  }
  const reverseScore = offerTokens.length > 0 ? reverseMatches / offerTokens.length : 0

  // Combined score (weighted)
  const combined = Math.min(1.0, tokenScore * 0.6 + reverseScore * 0.25 + brandBonus)

  return {
    confidence: Math.round(combined * 100) / 100,
    matchedTokens,
  }
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

    // Build search queries: use both the full product name AND shorter
    // brand-level queries (first 1–2 words). This ensures we find generic
    // offers like "Powerade versch. Sorten" even when the product is named
    // "Powerade Sports Mountain Blast".
    const searchQueries = new Map<string, typeof products>()
    for (const product of products) {
      if (!product.name) continue
      const fullName = product.name.trim()
      if (!fullName) continue

      // Full name query → best for exact matches
      const existing = searchQueries.get(fullName) ?? []
      existing.push(product)
      searchQueries.set(fullName, existing)

      // Short brand query (first 1–2 words) → catches generic offers
      const words = fullName.split(/\s+/)
      if (words.length >= 2) {
        // Use first word if long enough (>= 4 chars), else first two words
        const shortQuery = words[0].length >= 4 ? words[0] : words.slice(0, 2).join(' ')
        if (shortQuery !== fullName) {
          const shortExisting = searchQueries.get(shortQuery) ?? []
          // Only add if not already there
          if (!shortExisting.some((p: any) => p.id === product.id)) {
            shortExisting.push(product)
          }
          searchQueries.set(shortQuery, shortExisting)
        }
      }
    }

    // Deduplicate and limit queries to keep API usage reasonable
    const queries = Array.from(searchQueries.entries()).slice(0, 50)

    for (const [query, matchProducts] of queries) {
      try {
        const offers = await searchMarktguru(query, zipCode, keys, 10)

        // Helper to build a deal record from an offer + product match
        function buildDeal(offer: MarktguruOffer, product: any, match: MatchResult) {
          const retailerSlug = offer.advertisers?.[0]?.uniqueName ?? 'unknown'
          const retailerName = offer.advertisers?.[0]?.name ?? retailerSlug
          const validFrom = offer.validityDates?.[0]?.from ?? null
          const validUntil = offer.validityDates?.[0]?.to ?? null
          const discountPct = offer.oldPrice && offer.price
            ? Math.round((1 - offer.price / offer.oldPrice) * 100)
            : null

          // Construct large prospekt image URL from CDN (this IS the leaflet excerpt)
          const imageUrlLarge = `https://mg2de.b-cdn.net/api/v1/offers/${offer.id}/images/default/0/large.jpg`

          // Direct link to official retailer online prospekt (stable, reliable)
          const prospektUrl = getRetailerProspektUrl(retailerSlug)
            ?? `https://www.marktguru.de/rp/${retailerSlug}-prospekte`

          // All offers from this retailer on marktguru
          const retailerPageUrl = `https://www.marktguru.de/r/${retailerSlug}`

          return {
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
            image_url_large: imageUrlLarge,
            source_url: prospektUrl,
            external_url: retailerPageUrl,
            matched_by: 'name_fuzzy',
            confidence: match.confidence,
            matched_tokens: match.matchedTokens,
            requires_app: offer.requiresLoyalityMembership || detectAppRequirement(offer.description),
            fetched_at: new Date().toISOString(),
            offer_id: String(offer.id),
          }
        }

        for (const offer of offers) {
          for (const product of matchProducts) {
            const match = matchConfidence(
              product.name,
              offer.description,
              offer.brand?.name ?? '',
            )

            if (match.confidence < minConfidence) continue

            const dedup = `${offer.id}-${product.id}`
            if (seen.has(dedup)) continue
            seen.add(dedup)

            allDeals.push(buildDeal(offer, product, match))
          }
        }

        // Also try to match each offer against ALL products (cross-match)
        // This catches "Red Bull versch. Sorten" matching all Red Bull variants
        for (const offer of offers) {
          for (const product of products) {
            const dedup = `${offer.id}-${product.id}`
            if (seen.has(dedup)) continue

            const match = matchConfidence(
              product.name,
              offer.description,
              offer.brand?.name ?? '',
            )

            if (match.confidence < minConfidence) continue
            seen.add(dedup)

            allDeals.push(buildDeal(offer, product, match))
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
