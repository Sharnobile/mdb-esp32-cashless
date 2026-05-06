// Interface for the `deal-source` extension point.
//
// A provider produces normalized retailer offers for a query in a region.
// The consuming edge function (deal-search/index.ts) does the matching,
// scoring, and cache writes — providers are pure data sources.
//
// See docs/extension-points/deal-source.md for contributor docs.

export interface DealSourceContext {
  /** Calling company's UUID. NEVER forwarded to webhook providers. */
  companyId: string
  /**
   * Postal code from companies.deals_zip_code. Defaults to '60487' when null,
   * matching existing deal-search behavior (Frankfurt central, Marktguru-friendly).
   */
  zipCode: string
  /**
   * The provider_settings.config jsonb for this row. Free-form per provider.
   * Built-in providers should treat this as `Record<string, unknown>` and read
   * only the keys they document.
   */
  config: Record<string, unknown>
}

export interface NormalizedOffer {
  /** Stable identifier from the upstream source — used for dedup across calls. */
  externalId: string
  /** Retailer display name, e.g. "REWE", "Lidl", "ALDI SÜD". */
  retailer: string
  /**
   * Slug for the retailer used by the consuming function to look up
   * `companies.deals_config.retailer_prospekt_urls[slug]`. Lower-case, no
   * spaces. Marktguru's `advertisers[0].uniqueName` maps directly.
   */
  retailerSlug: string
  /** Offer description as published by the retailer. */
  description: string
  /** Brand name as parsed from the upstream offer (may be empty). */
  brand: string
  /** Sale price in EUR. */
  price: number
  /** Original price in EUR before the discount, or null if not provided. */
  oldPrice: number | null
  /** ISO 8601 timestamp when the offer becomes valid; null if always-valid. */
  validFrom: string | null
  /** ISO 8601 timestamp when the offer expires; null if open-ended. */
  validUntil: string | null
  /** Medium-sized image URL for offer cards, or null. */
  imageUrl: string | null
  /**
   * Large image URL for the detail UI (typically a leaflet excerpt CDN URL).
   * For Marktguru, this is the `mg2de.b-cdn.net/.../large.jpg` template.
   */
  imageUrlLarge: string | null
  /**
   * Default prospekt / source URL for the offer. The consumer may override
   * with `companies.deals_config.retailer_prospekt_urls[retailerSlug]` if
   * a mapping exists. Null if the upstream source has no such URL.
   */
  sourceUrl: string | null
  /** Retailer page URL on the provider site (e.g. marktguru.de/r/{slug}). */
  externalUrl: string | null
  /**
   * Optional machine-readable hint that the offer requires a loyalty app.
   * Built-in providers populate it when the upstream API exposes it (Marktguru:
   * `requiresLoyalityMembership`); deal-search's text-based detector still
   * runs over `description` regardless.
   */
  requiresApp?: boolean
}

export interface DealSourceProvider {
  /** Stable provider id, matching `provider_settings.provider_id`. */
  id: string
  /** Fetch normalized offers for `query` in `ctx.zipCode`. */
  fetchOffers(query: string, ctx: DealSourceContext): Promise<NormalizedOffer[]>
}
