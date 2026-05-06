/**
 * Tests for the Marktguru provider's pure offer normalization.
 *
 * Run: deno test Docker/supabase/functions/_shared/providers/deal-source/marktguru.test.ts
 */

import { assertEquals } from 'jsr:@std/assert'
import { normalizeOffer, type MarktguruOffer } from './marktguru.ts'

function fixture(overrides: Partial<MarktguruOffer> = {}): MarktguruOffer {
  return {
    id: 12345,
    description: 'HINWEIS: MIT APP 0,20€ REWE BONUS versch. Sorten',
    price: 0.99,
    oldPrice: 1.49,
    referencePrice: 1.98,
    requiresLoyalityMembership: false,
    brand: { name: 'Monster Energy', uniqueName: 'monster-energy' },
    advertisers: [{ name: 'REWE', uniqueName: 'rewe' }],
    product: { name: 'Monster Energy 0,5l', description: null },
    validityDates: [{ from: '2026-05-03T22:00:00Z', to: '2026-05-09T21:59:00Z' }],
    images: {
      urls: {
        small:  'https://example/small.jpg',
        medium: 'https://example/medium.jpg',
        large:  'https://example/large.jpg',
      },
    },
    ...overrides,
  }
}

Deno.test('normalizeOffer maps Marktguru fields to NormalizedOffer', () => {
  const out = normalizeOffer(fixture())
  assertEquals(out.externalId, '12345')
  assertEquals(out.retailer, 'REWE')
  assertEquals(out.retailerSlug, 'rewe')
  assertEquals(out.brand, 'Monster Energy')
  assertEquals(out.price, 0.99)
  assertEquals(out.oldPrice, 1.49)
  assertEquals(out.validFrom, '2026-05-03T22:00:00Z')
  assertEquals(out.validUntil, '2026-05-09T21:59:00Z')
  assertEquals(out.imageUrl, 'https://example/medium.jpg')
  assertEquals(out.requiresApp, false)
})

Deno.test('normalizeOffer builds Marktguru CDN large image URL from offer id', () => {
  const out = normalizeOffer(fixture({ id: 999 }))
  assertEquals(
    out.imageUrlLarge,
    'https://mg2de.b-cdn.net/api/v1/offers/999/images/default/0/large.jpg',
  )
})

Deno.test('normalizeOffer builds Marktguru source + external URLs from slug', () => {
  const out = normalizeOffer(fixture())
  assertEquals(out.sourceUrl,   'https://www.marktguru.de/rp/rewe-prospekte')
  assertEquals(out.externalUrl, 'https://www.marktguru.de/r/rewe')
})

Deno.test('normalizeOffer falls back to "unknown" when advertiser missing', () => {
  const out = normalizeOffer(fixture({ advertisers: [] }))
  assertEquals(out.retailer,     'unknown')
  assertEquals(out.retailerSlug, 'unknown')
  assertEquals(out.sourceUrl,    'https://www.marktguru.de/rp/unknown-prospekte')
})

Deno.test('normalizeOffer treats missing brand as empty string', () => {
  // Simulate Marktguru returning a payload without brand. Partial<> accepts undefined,
  // so no @ts-expect-error needed (Deno's strict checker would flag it as unused).
  const out = normalizeOffer(fixture({ brand: undefined }))
  assertEquals(out.brand, '')
})

Deno.test('normalizeOffer carries requiresLoyalityMembership through to requiresApp', () => {
  const out = normalizeOffer(fixture({ requiresLoyalityMembership: true }))
  assertEquals(out.requiresApp, true)
})

Deno.test('normalizeOffer survives null oldPrice and missing validityDates', () => {
  const out = normalizeOffer(fixture({ oldPrice: null, validityDates: [] }))
  assertEquals(out.oldPrice, null)
  assertEquals(out.validFrom, null)
  assertEquals(out.validUntil, null)
})
