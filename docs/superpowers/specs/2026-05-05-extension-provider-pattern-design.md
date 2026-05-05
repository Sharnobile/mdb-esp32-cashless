# Extension Provider Pattern — Design

**Date:** 2026-05-05
**Status:** Draft
**Owner:** Lucien Kerl

## Summary

Introduce a lightweight **provider pattern** at specific extension points in
VMflow where a feature inherently has multiple possible backends. Each
extension point exposes a stable TypeScript interface; multiple implementations
("providers") can coexist; each company picks which providers are active. New
providers can be contributed two ways: as a TypeScript module in this repo
(community PR), or as an external HTTP webhook the user runs themselves
(no code in our repo, no sandboxing).

This is **not** a plugin framework, marketplace, or paid-extension system.
It is a contained adapter convention applied to features that genuinely have
multiple sensible backends. The first concrete adopter is `deal-search`, which
today hardcodes Marktguru.

## Problem

Several VMflow features have the same shape — *one function, multiple possible
providers* — yet today each has the first provider hardcoded:

| Feature | Current hardcoded provider | Likely additional providers |
|---|---|---|
| Deal search ([`deal-search`](../../Docker/supabase/functions/deal-search/index.ts)) | Marktguru | kaufDA, REWE-direct, Idealo |
| Product image search (`search-product-images`) | DuckDuckGo | Google CSE, Bing, Pixabay |
| AI insights (`machine-insights`) | Anthropic | OpenAI, Gemini, local Ollama |
| Product import (`import-products`) | Nayax Excel | Vendon, Cantaloupe, generic CSV |
| Push notifications | Web Push only | Slack, Telegram, email, Teams |
| Firmware import (`import-github-release`) | GitHub Releases | GitLab, S3, local build server |

Adding a second provider today means modifying the consuming edge function
inline and shipping it through our release process. Companies cannot run
proprietary providers without forking the codebase. Community contribution has
no clean entry point.

## Goals

- Provide a reusable convention for extension points so adding a new provider
  to a participating feature is a single-file change.
- Make community code contributions natural: drop one TypeScript file in a
  conventional directory and open a PR.
- Allow private/proprietary providers via HTTP webhook so customers can plug
  in their own services (any language, any host) without modifying our repo.
- Per-company activation: every company chooses which providers are enabled
  and supplies provider-specific config (API keys, webhook URLs, etc.).
- Documentation per extension point shaped so Claude Code (or a developer
  unfamiliar with VMflow) can scaffold a new provider from the interface +
  one reference implementation in a single shot.
- v1 deliverable: deal-search migrated to this pattern, with Marktguru as the
  first built-in provider.

## Non-Goals

- **No marketplace.** No central listing, discovery, or distribution
  infrastructure.
- **No paid plugins.** No revenue share, license server, or payment flow.
- **No plugin signing or trust review pipeline.** Built-in providers are
  reviewed via normal repo PR review; webhook providers are the customer's
  own infrastructure and trust responsibility.
- **No capability manifest with sandboxing.** Built-in providers run in our
  edge function runtime with the same trust as the rest of our code; webhook
  providers run in the customer's own stack and never execute code in ours.
- **No generic "plugin" extension surface.** This convention applies to the
  extension points listed above. UI extensions, MQTT handlers, frontend
  pages, and other plugin-framework concerns are explicitly out of scope.
- **No automatic provider discovery from npm or external registries.** Built-in
  providers ship with our release; webhook providers are configured manually.
- **No MQTT, firmware, or other side-effect plug-points.** Providers are
  request/response only — they fetch data and return it. They do not publish
  to MQTT, write to the firmware OTA topic, or trigger device-side actions.
  The MQTT bus and OTA pipeline keep their existing trust model.
- **No JSON-Schema-driven admin UI form rendering in v1.** Each built-in
  provider ships with a hand-written admin UI snippet for its config (typically
  none; Marktguru has no configurable knobs in v1). Webhook providers have a
  single shared form (URL + auth token + free-form JSON config). Schema-driven
  rendering may be added later when a built-in provider needs structured config.

## Architecture

### Per-Extension-Point Convention

Every participating extension point follows the same four-part structure:

**1. TypeScript interface** in `Docker/supabase/functions/_shared/providers/<extension-point>.ts`.
Each extension point owns its own *context* type — fields differ
(`zipCode` only makes sense for `deal-source`, `prompt` only for a future
`ai-backend`). The provider-pattern itself does not define a generic context.

```ts
// _shared/providers/deal-source.ts
export interface DealSourceContext {
  companyId: string
  zipCode: string                  // sourced from companies.deals_zip_code,
                                   // defaults to '60487' if null (existing behavior)
  config: Record<string, unknown>  // contents of provider_settings.config for this row
}

export interface DealSourceProvider {
  id: string
  fetchOffers(query: string, ctx: DealSourceContext): Promise<NormalizedOffer[]>
}

export interface NormalizedOffer {
  externalId: string         // stable id for dedup across calls
  retailer: string
  description: string
  brand: string
  price: number
  oldPrice: number | null
  validFrom: string | null
  validUntil: string | null
  imageUrl: string | null
  sourceUrl: string | null
}
```

**2. Built-in providers** as TypeScript modules, one file per provider, in
`Docker/supabase/functions/_shared/providers/<extension-point>/<provider-id>.ts`:

```
Docker/supabase/functions/_shared/providers/deal-source/
├── marktguru.ts
├── kaufda.ts          ← future PR
└── rewe-direct.ts     ← future PR
```

Each file exports a single provider object:

```ts
import type { DealSourceProvider } from "../deal-source.ts"

export const provider: DealSourceProvider = {
  id: "marktguru",
  async fetchOffers(query, ctx) {
    /* implementation */
  },
}
```

The consuming edge function maintains a static registry imported via explicit
imports (Deno's lack of glob-import in production prevents auto-discovery):

```ts
// deal-search/registry.ts
import { provider as marktguru } from "../_shared/providers/deal-source/marktguru.ts"
// import { provider as kaufda } from "../_shared/providers/deal-source/kaufda.ts"

export const builtinProviders: DealSourceProvider[] = [marktguru]
```

Adding a new built-in provider = create the file + add the import. The PR
diff for the registry edit is the single canonical "register your provider"
step.

**3. Webhook providers** for proprietary or out-of-tree implementations.
A single generic webhook caller in `_shared/providers/webhook.ts` handles the
HTTP contract:

```
POST {webhook_url}
Authorization: Bearer {auth_token}
Content-Type: application/json

{
  "version": 1,
  "extensionPoint": "deal-source",
  "method": "fetchOffers",
  "args": { "query": "Monster", "zipCode": "60487" }
}
```

The webhook caller adapts itself to whichever extension point's interface it's
playing — for `deal-source` it returns `NormalizedOffer[]`. The shape of `args`
and the response is determined by the extension point's interface; the webhook
implementer only needs to honor that interface.

The body's `args` carry only the call-specific inputs from the per-extension-
point context — `query` and `zipCode` for `deal-source`. **`companyId` is
deliberately not included** (a webhook serving multiple VMflow installations
has no business knowing the calling tenant's UUID, and it removes a
cross-tenant leak vector). **Provider config is also not echoed back** in
`args`; the webhook owner already knows their own configuration.

`version: 1` lives in the body so future interface changes can be detected and
backwards-compatible defaults applied.

**Webhook trust model in v1:**
- The auth token is chosen by the customer when they configure the webhook
  (we do not issue tokens). Stored in `provider_settings.config.authToken`.
- VMflow includes the token as `Authorization: Bearer ...` on outbound calls.
  No HMAC body signing, no per-request nonce, no replay protection.
- The webhook owner is responsible for their own auth verification and
  rate-limiting. Webhooks live on the customer's trust boundary, not ours.
- Per-call timeout: 10 seconds. No automatic retry — failures log and the
  consuming function continues with the remaining providers' results.
- Response-side: VMflow does not authenticate the response (no signature
  check); customers running webhooks should use HTTPS for the URL to prevent
  in-flight tampering. The admin UI form will require `https://`.

**4. Per-company activation** in a generic table. Per the project's immutable-
migration rule (CLAUDE.md), the migration uses idempotent operations
throughout so that any later fix-migrations can also be idempotent:

```sql
create table if not exists provider_settings (
  company_id      uuid not null references companies(id) on delete cascade,
  extension_point text not null,                  -- 'deal-source', 'image-search', ...
  provider_id     text not null,                  -- 'marktguru' or 'webhook-{uuid}'
  enabled         boolean not null default false,
  config          jsonb not null default '{}',    -- provider-specific
  display_name    text,                           -- user-facing for webhooks
  created_at      timestamptz not null default now(),
  primary key (company_id, extension_point, provider_id)
);

-- Used by every consuming edge function on every request:
create index if not exists idx_provider_settings_active
  on provider_settings (company_id, extension_point)
  where enabled = true;

alter table provider_settings enable row level security;

drop policy if exists provider_settings_read  on provider_settings;
drop policy if exists provider_settings_write on provider_settings;

create policy provider_settings_read on provider_settings
  for select using (company_id = my_company_id());

create policy provider_settings_write on provider_settings
  for all using (company_id = my_company_id() and i_am_admin())
  with check (company_id = my_company_id() and i_am_admin());
```

For webhook providers, `provider_id` follows the format `webhook-{uuid}` and
`config` carries `{ url: string, authToken: string, ...userSettings }`.

### Runtime Resolution

When the consuming edge function (e.g. `deal-search`) handles a request:

1. Load all rows from `provider_settings` where
   `company_id = caller AND extension_point = 'deal-source' AND enabled = true`.
2. For each row:
   - If `provider_id` matches a built-in, use that built-in module.
   - Else if `provider_id` starts with `webhook-`, use the generic webhook caller
     with `config.url` and `config.authToken`.
   - Else log a warning and skip (provider was removed from the codebase but
     left enabled in settings).
3. Call all active providers concurrently (`Promise.allSettled`) with a
   per-call 10-second timeout. Failed providers log and are skipped; surviving
   results merge.
4. Merge logic is **extension-point-specific** and lives in the consuming edge
   function — for `deal-source`, dedup by `(retailer, externalId)` and rank by
   discount percent. The provider pattern itself is agnostic to merging.

### Admin UI

A new section under `/settings`:

- `/settings/extensions` — landing page listing all extension points (deal-source
  for v1; future ones added as they migrate to the pattern).
- `/settings/extensions/[extension-point]` — per-extension-point page showing:
  - **Built-in providers** with toggle. For v1 each built-in provider's config
    form is hand-written in the admin page (Marktguru has no configurable
    knobs, so its row is just a toggle).
  - **Custom webhook providers**: list of configured webhooks with edit/delete;
    a single shared "Add webhook" form with display name, URL (must be
    `https://`), auth token, and a free-form JSON config textarea.
  - **"Test call" button — v1 must-have for webhook providers** so customers
    can verify their webhook is reachable and returns valid shape at config
    time. Built-in providers don't need it (they're testable by re-running
    the consuming feature itself, e.g. clicking "Refresh" on `/deals`).

The consuming feature pages (e.g. `/deals`) need no UI changes for the v1
migration — the existing UX continues to work, the data source just becomes
plural.

### Documentation

One markdown file per extension point at `docs/extension-points/<extension-point>.md`,
with a fixed structure:

- **What this is for** — one paragraph on the extension point's purpose and
  what consumers expect from a provider.
- **Interface** — the TypeScript interface inline, with comments on each field.
- **Reference implementation** — link to the simplest built-in provider's file
  with a note that it works as a copy-paste starting point.
- **Webhook contract** — full example HTTP request and response.
- **Local testing** — three commands: write the file, run the consuming edge
  function locally, observe the result.
- **Contributing with Claude Code** — copy-paste prompt template:

  ```
  Write a new deal-source provider for $RETAILER.

  Read these three files first for context:
  - Docker/supabase/functions/_shared/providers/deal-source.ts (interface)
  - Docker/supabase/functions/_shared/providers/deal-source/marktguru.ts (reference)
  - docs/extension-points/deal-source.md (this spec)

  Then create Docker/supabase/functions/_shared/providers/deal-source/$RETAILER.ts
  following the same structure, and add the import to deal-search/registry.ts.
  ```

The documentation file is the SDK. There is no separate "plugin SDK" project,
no scaffolding CLI, and no template generator — the reference implementation
plus the doc file is sufficient context for either a human or Claude Code to
produce a working provider.

## v1 Implementation Scope

The first concrete adopter validates the convention. Implementation steps:

1. **Define the interface** — `_shared/providers/deal-source.ts` with
   `DealSourceProvider`, `DealSourceContext`, `NormalizedOffer`.
2. **Extract Marktguru** — move only the *fetch + normalize* phase out of
   [`deal-search/index.ts`](../../Docker/supabase/functions/deal-search/index.ts)
   into `_shared/providers/deal-source/marktguru.ts`. Concretely: the
   `getMarktguruKeys()` helper, the `searchMarktguru()` HTTP call, and the
   shape transformation from `MarktguruOffer` to `NormalizedOffer` move into
   the provider. **Matching, fuzzy-scoring, keyword expansion, dedup, and
   `deal_cache` writes stay in `deal-search/index.ts`** — those operate on
   normalized offers from any provider.
3. **Generic webhook caller** — `_shared/providers/webhook.ts` with a single
   `callWebhookProvider(extensionPoint, method, args, providerConfig)`
   function reused by any extension point. Honors the trust model documented
   in §Architecture: 10s timeout, no retry, no body signing.
4. **Database migration** — `YYYYMMDDHHMMSS_provider_settings.sql` creates the
   `provider_settings` table, the `idx_provider_settings_active` index, and
   the RLS policies. Includes a data migration that inserts
   `(company_id, 'deal-source', 'marktguru', enabled=true, config='{}')` for
   every company with `companies.deals_enabled = true`, preserving current
   behavior. All operations idempotent per CLAUDE.md's immutable-migration
   rule.
5. **Refactor `deal-search/index.ts`** — replace direct Marktguru calls with
   provider-registry resolution. The cache logic, `deals_config` consumption,
   matching, scoring, and `deal_cache` writes are unchanged. The request shape
   (`forceRefresh`, `minConfidence`) and response shape (`{ deals, fromCache,
   ... }`) are unchanged so the existing
   [`useDeals`](../../management-frontend/app/composables/useDeals.ts) composable
   works without modification.
6. **Admin UI** — `/settings/extensions/deal-source` page using existing
   shadcn-nuxt components. Reuses `useModalForm` for the webhook dialog.
7. **Tests** — at minimum:
   - Vitest unit tests for the registry resolver (lookup by id, webhook
     fallback, missing-provider warning) in `management-frontend/`.
   - Deno tests for `_shared/providers/webhook.ts` covering happy path,
     timeout, non-2xx response, malformed body.
   - Deno test for `_shared/providers/deal-source/marktguru.ts` covering
     normalization shape (mock the upstream HTTP call).
   - Deno test for the refactored `deal-search/index.ts` confirming behavior
     is byte-for-byte identical when only Marktguru is enabled (regression
     guard for the extraction).
8. **Documentation** — `docs/extension-points/deal-source.md` following the
   structure above. Marktguru is the documented reference implementation.

**Release sequencing**: the migration, refactored edge function, and admin
UI ship together. In this codebase the `Docker/` stack and
`management-frontend/` are deployed as a single unit (one docker-compose up,
one frontend image rebuild), so there is no inter-service deploy-skew window
to manage. The `useDeals` composable's request and response shapes are
unchanged so old browser sessions loaded just before the deploy continue to
work without a refresh.

## Backward Compatibility

- Existing companies with `deals_enabled = true` get an automatic
  `provider_settings` row enabling Marktguru, so the deals page shows the same
  results as before.
- `companies.deals_zip_code` stays unchanged and is read by the consumer
  (`deal-search`), then passed to the provider as `DealSourceContext.zipCode`.
- `companies.deals_config` stays unchanged. Its current contents
  (`generic_terms`, `wildcard_phrases`, `app_detection_patterns`,
  `retailer_prospekt_urls`) are **consumer-side concerns** — they govern fuzzy
  matching, app-detection, and prospekt-URL resolution, all of which run
  against normalized offers from any provider. They do not move into
  `provider_settings.config`.
- For Marktguru in v1 there are no per-provider knobs exposed to users —
  `provider_settings.config` is `{}` for the seeded row. The internal
  `searchMarktguru` limit (50) stays a constant inside the provider module.
  Future built-in providers may add structured config; webhook providers carry
  their `url` and `authToken` plus any provider-specific values the webhook
  owner needs.
- The `deal_cache` table schema is unaffected. The cache still keys on
  `(company_id, product_id, retailer, offer_id)`; rows from different providers
  coexist naturally because they have distinct `retailer` and `offer_id`
  values.
- The existing `forceRefresh` and `minConfidence` request parameters keep
  working unchanged. The response shape `{ deals, fromCache, searchedProducts,
  totalDeals }` is unchanged so the
  [`useDeals`](../../management-frontend/app/composables/useDeals.ts) composable
  needs no edits.

## Future Extension Points

These are documented here to confirm the convention generalizes, but **none are
in v1's scope** — each will get its own design doc and migration when adopted:

- `image-search` — backends for product image lookup
- `ai-backend` — LLM provider for `machine-insights` (Anthropic / OpenAI / local)
- `import-format` — file-format adapters for `import-products`
- `notification-channel` — push / email / Slack / Telegram for stock alerts.
  Note: this one will need to negotiate with existing schema
  (`low_stock_notifications` queue, `push_subscriptions` registry, the
  trigger-based enqueueing in the database). The provider pattern adds new
  *delivery* backends; the queueing/dispatch flow stays as-is. Future spec
  will detail.
- `firmware-source` — sources for OTA firmware artifacts

## Open Questions

These are not blockers for the design but need decisions during planning:

- **Concurrency policy beyond v1.** For `deal-source`, parallel calls with
  result merging is the right default. For `ai-backend`, calling multiple LLMs
  in parallel is wasteful — likely seriell with explicit fallback ordering. The
  per-extension-point edge function owns this policy; the provider pattern
  doesn't dictate it. We confirm this when migrating the second extension point.
- **Provider-failure visibility.** Failed provider calls are logged but not
  surfaced to end users today. A future "provider health" badge in the admin
  UI is desirable but deferred.
- **Webhook "test call" payload.** Resolved: the test button sends a fixed
  sample (`query: "Coca Cola"`, `zipCode` from `companies.deals_zip_code` or
  the `'60487'` default) — lowest-risk default that doesn't depend on
  `deal_cache` having any rows yet for new companies. Mentioned here for
  visibility; treat as a planning input, not an open question.

## Risks

- **Interface evolution.** Adding fields to `DealSourceProvider` is
  backward-compatible; renaming or removing fields is not. Mitigation:
  webhook bodies carry `version: 1`; built-in providers fail at compile time on
  breaking changes. Deliberate breaking changes get a coordinated release.
- **Built-in provider list bloat.** Long-tail provider PRs each add a file plus
  a registry import. After ~10 providers per extension point, registry
  bookkeeping starts to feel manual. Acceptable for v1; revisit if/when an
  extension point exceeds ~10 active built-in providers.
- **Webhook reliability.** A misbehaving webhook (slow, returning bad data)
  degrades the consuming feature for that company. Mitigation: 10s timeout,
  `Promise.allSettled` so one failure doesn't kill the merge, and the planned
  "test call" button surfaces broken webhooks at config time.
- **Shared helper drift.** As multiple built-in providers emerge, common
  utilities (HTTP client, normalization helpers) will accumulate. Mitigation:
  reserve `_shared/providers/_lib/` for cross-provider helpers; keep
  per-provider files focused on the provider-specific logic.
