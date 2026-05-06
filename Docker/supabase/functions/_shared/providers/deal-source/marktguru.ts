// Marktguru provider for the deal-source extension point.
//
// Two halves:
//   1) HTTP — bootstrap API keys from marktguru.de, then call /api/v1/offers/search
//   2) Pure — normalizeOffer() maps the raw Marktguru shape to NormalizedOffer
//
// The HTTP key bootstrap caches the keys for the lifetime of the edge-function
// instance (Marktguru rotates them rarely; refetch happens on cold-start).
//
// Reference for the upstream shape:
//   https://api.marktguru.de/api/v1/offers/search?q=...&zipCode=...&limit=...

import type {
  DealSourceProvider,
  DealSourceContext,
  NormalizedOffer,
} from '../deal-source.ts'

// ── Upstream shape ────────────────────────────────────────────────────────────

export interface MarktguruOffer {
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

// ── HTTP ──────────────────────────────────────────────────────────────────────

let cachedKeys: MarktguruKeys | null = null

async function getMarktguruKeys(): Promise<MarktguruKeys> {
  if (cachedKeys) return cachedKeys

  const res = await fetch('https://marktguru.de', {
    headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; rv:102.0) Gecko/20100101 Firefox/102.0' },
  })
  const html = await res.text()

  const match = html.match(/<script[^>]*type="application\/json"[^>]*>([\s\S]*?)<\/script>/)
  if (!match?.[1]) throw new Error('Could not extract marktguru config')

  const config = JSON.parse(match[1])
  const apiKey = config?.config?.apiKey ?? config?.apiKey
  const clientKey = config?.config?.clientKey ?? config?.clientKey

  if (!apiKey || !clientKey) throw new Error('Could not find marktguru API keys in config')

  cachedKeys = { apiKey, clientKey }
  return cachedKeys
}

async function searchMarktguru(
  query: string,
  zipCode: string,
  limit: number,
): Promise<MarktguruOffer[]> {
  const keys = await getMarktguruKeys()
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

// ── Normalization (pure) ──────────────────────────────────────────────────────

/**
 * Maps a raw MarktguruOffer to NormalizedOffer.
 *
 * Behavior preserved from the pre-refactor inline mapping in
 * deal-search/index.ts:
 *   - retailerSlug from advertisers[0].uniqueName, "unknown" fallback
 *   - retailer name from advertisers[0].name, slug fallback
 *   - imageUrlLarge built from the b-cdn template using offer.id
 *   - sourceUrl built as https://www.marktguru.de/rp/{slug}-prospekte
 *   - externalUrl built as https://www.marktguru.de/r/{slug}
 */
export function normalizeOffer(raw: MarktguruOffer): NormalizedOffer {
  const slug = raw.advertisers?.[0]?.uniqueName ?? 'unknown'
  const retailer = raw.advertisers?.[0]?.name ?? slug
  return {
    externalId: String(raw.id),
    retailer,
    retailerSlug: slug,
    description: raw.description,
    brand: raw.brand?.name ?? '',
    price: raw.price,
    oldPrice: raw.oldPrice,
    validFrom: raw.validityDates?.[0]?.from ?? null,
    validUntil: raw.validityDates?.[0]?.to ?? null,
    imageUrl: raw.images?.urls?.medium ?? null,
    imageUrlLarge: `https://mg2de.b-cdn.net/api/v1/offers/${raw.id}/images/default/0/large.jpg`,
    sourceUrl: `https://www.marktguru.de/rp/${slug}-prospekte`,
    externalUrl: `https://www.marktguru.de/r/${slug}`,
    requiresApp: raw.requiresLoyalityMembership,
  }
}

// ── Provider ──────────────────────────────────────────────────────────────────

const MARKTGURU_LIMIT = 50  // matches the post-2026-05-04 limit raise

export const provider: DealSourceProvider = {
  id: 'marktguru',
  async fetchOffers(query: string, ctx: DealSourceContext): Promise<NormalizedOffer[]> {
    const raw = await searchMarktguru(query, ctx.zipCode, MARKTGURU_LIMIT)
    return raw.map(normalizeOffer)
  },
}
