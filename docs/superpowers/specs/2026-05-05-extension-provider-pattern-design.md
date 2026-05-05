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

## Architecture

### Per-Extension-Point Convention

Every participating extension point follows the same four-part structure:

**1. TypeScript interface** in `Docker/supabase/functions/_shared/providers/<extension-point>.ts`:

```ts
// _shared/providers/deal-source.ts
export interface ProviderContext {
  companyId: string
  zipCode: string
  config: Record<string, unknown>  // per-provider settings (API key, etc.)
}

export interface DealSourceProvider {
  id: string
  fetchOffers(query: string, ctx: ProviderContext): Promise<NormalizedOffer[]>
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

`version: 1` lives in the body so future interface changes can be detected and
backwards-compatible defaults applied.

**4. Per-company activation** in a generic table:

```sql
create table provider_settings (
  company_id      uuid not null references companies(id) on delete cascade,
  extension_point text not null,                  -- 'deal-source', 'image-search', ...
  provider_id     text not null,                  -- 'marktguru' or 'webhook-{uuid}'
  enabled         boolean not null default false,
  config          jsonb not null default '{}',    -- provider-specific
  display_name    text,                           -- user-facing for webhooks
  created_at      timestamptz not null default now(),
  primary key (company_id, extension_point, provider_id)
);

alter table provider_settings enable row level security;

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
  - **Built-in providers** with toggle and per-provider config form. The form
    is rendered from a `configSchema` (JSON Schema) the provider exports
    alongside its implementation.
  - **Custom webhook providers**: list of configured webhooks with edit/delete;
    "Add webhook" form (display name, URL, auth token, free-form config JSON).
  - "Test call" button per row that invokes the provider with a fixed sample
    query and shows the result/error inline.

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
   `DealSourceProvider`, `ProviderContext`, `NormalizedOffer`.
2. **Extract Marktguru** — move existing Marktguru-specific logic from
   [`deal-search/index.ts`](../../Docker/supabase/functions/deal-search/index.ts)
   into `_shared/providers/deal-source/marktguru.ts`. The existing API key
   extraction and search logic moves verbatim; the function signature changes
   to match the interface.
3. **Generic webhook caller** — `_shared/providers/webhook.ts` with a single
   `callWebhookProvider(extensionPoint, method, args, config)` function used by
   any extension point.
4. **Database migration** — `YYYYMMDDHHMMSS_provider_settings.sql` creates the
   `provider_settings` table with RLS policies and indexes. Includes a data
   migration that inserts `(company_id, 'deal-source', 'marktguru', enabled=true)`
   for every company with `companies.deals_enabled = true`, preserving current
   behavior.
5. **Refactor `deal-search/index.ts`** — replace direct Marktguru calls with
   provider-registry resolution. The existing matching, caching, and database
   write logic stays unchanged.
6. **Admin UI** — `/settings/extensions/deal-source` page using existing
   shadcn-nuxt components. Reuses `useModalForm` for config dialogs.
7. **Documentation** — `docs/extension-points/deal-source.md` following the
   structure above. Marktguru becomes the documented reference implementation.

The migration plus refactor must ship in a single release: the `provider_settings`
table is required by the refactored `deal-search`, and the data migration must
run before the new code reads from the table on first request.

## Backward Compatibility

- Existing companies with `deals_enabled = true` get an automatic
  `provider_settings` row enabling Marktguru, so the deals page shows the same
  results as before.
- The `companies.deals_zip_code` and `companies.deals_config` columns stay
  unchanged — they describe the *consuming feature's* config, not the
  provider's. Per-provider config (e.g. Marktguru's API limit) lives in
  `provider_settings.config`.
- The `deal_cache` table schema is unaffected. The cache still keys on
  `(company_id, product_id, retailer, offer_id)`; rows from different providers
  coexist naturally because they have distinct `retailer` and `offer_id`
  values.
- The existing `forceRefresh` and `minConfidence` request parameters keep
  working unchanged.

## Future Extension Points

These are documented here to confirm the convention generalizes, but **none are
in v1's scope** — each will get its own design doc and migration when adopted:

- `image-search` — backends for product image lookup
- `ai-backend` — LLM provider for `machine-insights` (Anthropic / OpenAI / local)
- `import-format` — file-format adapters for `import-products`
- `notification-channel` — push / email / Slack / Telegram for stock alerts
- `firmware-source` — sources for OTA firmware artifacts

## Open Questions

These are not blockers for the design but need decisions during planning:

- **Provider config schema validation.** Built-in providers export a JSON
  Schema describing their config shape; the admin UI renders from it and
  validates on submit. Webhook providers have free-form config since the schema
  is owned by the webhook implementer. Detail (which JSON-Schema dialect, how
  the UI renders nested objects) belongs in the implementation plan.
- **Concurrency policy beyond v1.** For `deal-source`, parallel calls with
  result merging is the right default. For `ai-backend`, calling multiple LLMs
  in parallel is wasteful — likely seriell with explicit fallback ordering. The
  per-extension-point edge function owns this policy; the provider pattern
  doesn't dictate it. We confirm this when migrating the second extension point.
- **Provider-failure visibility.** Failed provider calls are logged but not
  surfaced to end users today. A future "provider health" badge in the admin
  UI is desirable but deferred.
- **Webhook provider testing UX.** "Test call" button mechanics — does it use
  a static fixture query, the user's last real query, or a user-supplied input?
  Decided in the implementation plan.

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
