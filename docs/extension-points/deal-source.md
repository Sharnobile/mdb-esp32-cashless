# Extension Point: `deal-source`

The `deal-source` extension point provides retailer offers to the `/deals` page in VMflow. A provider implements one method — `fetchOffers(query, ctx)` — and returns a list of normalized offers. Multiple providers can be enabled per company; `deal-search` calls them in parallel and merges the results before running its own matching, scoring, and caching.

## What this is for

VMflow's `/deals` page suggests current retailer offers that match the company's product catalog. Different companies want different upstream sources — Marktguru is bundled, but customers in regions where Marktguru has thin coverage may want kaufDA, REWE-direct, Idealo, or their own internal price feed. Rather than fork the codebase, they contribute a new provider here.

## Interface

The contract is defined in [`Docker/supabase/functions/_shared/providers/deal-source.ts`](../../Docker/supabase/functions/_shared/providers/deal-source.ts). Reproduced inline for orientation:

```ts
export interface DealSourceContext {
  companyId: string
  zipCode: string                        // from companies.deals_zip_code, defaults to '60487'
  config: Record<string, unknown>        // your provider's row in provider_settings.config
}

export interface NormalizedOffer {
  externalId: string                     // stable upstream id, used for dedup
  retailer: string                       // display name, e.g. "REWE"
  retailerSlug: string                   // slug, e.g. "rewe" — must match dealConfig.retailer_prospekt_urls keys
  description: string
  brand: string
  price: number                          // EUR
  oldPrice: number | null
  validFrom: string | null               // ISO 8601
  validUntil: string | null              // ISO 8601
  imageUrl: string | null                // medium-size offer image
  imageUrlLarge: string | null           // large detail-view image
  sourceUrl: string | null               // prospekt URL; consumer may overlay with company config
  externalUrl: string | null             // retailer page URL
  requiresApp?: boolean                  // optional: upstream-flagged loyalty-app requirement
}

export interface DealSourceProvider {
  id: string
  fetchOffers(query: string, ctx: DealSourceContext): Promise<NormalizedOffer[]>
}
```

Failure semantics: throw on transport / parse / upstream errors. The consumer (`deal-search`) wraps each call in `Promise.allSettled` with a 10-second timeout, logs failures, and continues with the remaining providers' results. Returning `[]` on a soft failure is also fine — empty results merge harmlessly.

## Reference implementation

[`Docker/supabase/functions/_shared/providers/deal-source/marktguru.ts`](../../Docker/supabase/functions/_shared/providers/deal-source/marktguru.ts) is the canonical example. It demonstrates:

- HTTP key bootstrap (Marktguru exposes its API keys in the homepage HTML — most providers won't need this, but it shows the shape)
- `searchMarktguru()` HTTP call against the upstream API
- A pure `normalizeOffer()` function that maps the raw upstream shape to `NormalizedOffer`
- Provider export that ties it together

Tests live next to the file as [`marktguru.test.ts`](../../Docker/supabase/functions/_shared/providers/deal-source/marktguru.test.ts) — they cover the pure normalization, which is the most failure-prone seam for a new provider.

## Adding a built-in provider (PR contribution)

1. Create `Docker/supabase/functions/_shared/providers/deal-source/<your-id>.ts` exporting `provider: DealSourceProvider`.
2. Create `Docker/supabase/functions/_shared/providers/deal-source/<your-id>.test.ts` covering the pure normalization at minimum.
3. Register the provider in `Docker/supabase/functions/deal-search/registry.ts`:
   ```ts
   import { provider as yourId } from '../_shared/providers/deal-source/<your-id>.ts'
   export const builtinProviders: Record<string, DealSourceProvider> = { marktguru, '<your-id>': yourId }
   ```
4. Add UI metadata for the admin page in `management-frontend/app/composables/useProviderSettings.ts`'s `BUILTIN_PROVIDERS` map.
5. Run tests: `deno test Docker/supabase/functions/_shared/providers/deal-source/<your-id>.test.ts`.
6. Open a PR.

## Adding a webhook provider (no code in the VMflow repo)

You run the endpoint, VMflow calls it. Stand up an HTTPS service that accepts:

```http
POST /your-endpoint
Authorization: Bearer <token-you-chose>
Content-Type: application/json

{
  "version": 1,
  "extensionPoint": "deal-source",
  "method": "fetchOffers",
  "args": { "query": "Monster", "zipCode": "60487" }
}
```

And responds with a JSON `NormalizedOffer[]`:

```json
[
  {
    "externalId": "your-stable-id-1",
    "retailer": "Aldi",
    "retailerSlug": "aldi-sued",
    "description": "Monster Energy 0,5l zzgl. Pfand",
    "brand": "Monster",
    "price": 0.95,
    "oldPrice": 1.49,
    "validFrom": "2026-05-05T00:00:00Z",
    "validUntil": "2026-05-12T00:00:00Z",
    "imageUrl": "https://your.cdn/monster.jpg",
    "imageUrlLarge": "https://your.cdn/monster-large.jpg",
    "sourceUrl": "https://your.aggregator/offers/123",
    "externalUrl": "https://your.aggregator/r/aldi-sued",
    "requiresApp": false
  }
]
```

Trust model:
- The auth token is yours. VMflow stores it encrypted-at-rest in `provider_settings.config.authToken` and forwards it as `Authorization: Bearer ...`.
- VMflow does **not** sign request bodies and does **not** include nonces or replay protection. Your endpoint runs on your infrastructure under your trust boundary.
- VMflow does **not** authenticate responses. Use HTTPS — VMflow rejects `http://` URLs at config time and at runtime.
- Per-call timeout: 10 seconds. No retry — VMflow logs failures and continues with the remaining providers' results.

Configure the webhook in **Settings → Extensions → Deal sources → Add webhook**.

## Local testing

Bring up the local Supabase stack and exercise the function:

```bash
cd Docker/supabase
supabase start
supabase functions serve deal-search --no-verify-jwt
```

In another terminal, hit the endpoint with a dev JWT (use the local-dev credentials from your team's onboarding doc):

```bash
JWT=$(curl -s -X POST "http://localhost:54321/auth/v1/token?grant_type=password" \
  -H "apikey: $(supabase status -o json | jq -r .ANON_KEY)" \
  -H "Content-Type: application/json" \
  -d '{"email":"<dev>","password":"<dev>"}' | jq -r .access_token)

curl -s -X POST http://localhost:54321/functions/v1/deal-search \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"forceRefresh": true}' | jq '.deals | length'
```

Run the provider-pattern unit tests:

```bash
cd Docker/supabase/functions
deno test _shared/providers/ deal-search/ --allow-net
```

## Contributing with Claude Code

Open Claude Code in the repo root and paste:

> Write a new deal-source provider for **REPLACE_WITH_RETAILER**.
>
> Read these three files first for context:
> - `Docker/supabase/functions/_shared/providers/deal-source.ts` (interface)
> - `Docker/supabase/functions/_shared/providers/deal-source/marktguru.ts` (reference implementation)
> - `docs/extension-points/deal-source.md` (this spec)
>
> Then create:
> - `Docker/supabase/functions/_shared/providers/deal-source/<retailer-slug>.ts` exporting `provider: DealSourceProvider`
> - `Docker/supabase/functions/_shared/providers/deal-source/<retailer-slug>.test.ts` with at least normalization tests
>
> Register the import in `Docker/supabase/functions/deal-search/registry.ts` and add UI metadata to `management-frontend/app/composables/useProviderSettings.ts`'s `BUILTIN_PROVIDERS` map. Run the tests with `deno test Docker/supabase/functions/_shared/providers/deal-source/<retailer-slug>.test.ts` and confirm they pass.

The reference implementation plus this doc is everything Claude Code needs to scaffold a working provider in a single shot.
