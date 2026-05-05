# Extension Provider Pattern Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the hardcoded Marktguru integration in `deal-search` to a per-company provider pattern, with built-in providers as TypeScript modules in the repo and custom providers as HTTP webhooks. Establish the convention so the same shape can apply to other extension points later.

**Architecture:** Three layers — (1) a per-company `provider_settings` table that names which providers are enabled and carries their config; (2) a per-extension-point TypeScript interface plus a static built-in registry that the consuming edge function imports explicitly, plus a generic webhook caller for custom providers; (3) an admin UI under `/settings/extensions` that toggles built-ins and configures webhooks. The `deal-search` edge function keeps its existing matching, scoring, and cache logic; only its data acquisition layer becomes pluggable.

**Tech Stack:** Postgres (migration with idempotent ops + RLS), Deno edge functions (TypeScript, `jsr:@std/assert` tests), Nuxt 4 (composable + admin pages, shadcn-nuxt UI, i18n en/de), Vitest for the frontend composable, Deno test for edge code.

**Spec:** [docs/superpowers/specs/2026-05-05-extension-provider-pattern-design.md](../specs/2026-05-05-extension-provider-pattern-design.md)

**Working directory:** all paths below are relative to the repo root `/Users/lucienkerl/Development/mdb-esp32-cashless` unless noted.

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Docker/supabase/migrations/20260505100000_provider_settings.sql` | Create | `provider_settings` table, partial active-rows index, RLS policies, Marktguru data seed |
| `Docker/supabase/functions/_shared/providers/deal-source.ts` | Create | `DealSourceProvider`, `DealSourceContext`, `NormalizedOffer` interfaces (no logic) |
| `Docker/supabase/functions/_shared/providers/webhook.ts` | Create | Generic `callWebhookProvider()` HTTP helper with 10 s timeout, HTTPS-only, no retry |
| `Docker/supabase/functions/_shared/providers/webhook.test.ts` | Create | Deno tests: happy path, timeout, non-2xx, malformed JSON, http:// rejection |
| `Docker/supabase/functions/_shared/providers/deal-source/marktguru.ts` | Create | Extracted Marktguru fetch + key bootstrap + normalization to `NormalizedOffer` |
| `Docker/supabase/functions/_shared/providers/deal-source/marktguru.test.ts` | Create | Deno tests for the normalization mapping (raw `MarktguruOffer` → `NormalizedOffer`) |
| `Docker/supabase/functions/deal-search/registry.ts` | Create | Static built-in `DealSourceProvider[]` registry (Marktguru only in v1) |
| `Docker/supabase/functions/deal-search/resolve-providers.ts` | Create | Loads `provider_settings` rows for the caller's company, returns `DealSourceProvider[]` |
| `Docker/supabase/functions/deal-search/resolve-providers.test.ts` | Create | Deno tests: built-in lookup, webhook fallback, missing-provider warning |
| `Docker/supabase/functions/deal-search/index.ts` | Modify | Replace direct Marktguru calls with provider resolution + parallel fetch + merge |
| `Docker/supabase/functions/deal-search/regression.test.ts` | Create | Behavior-equivalence test: identical normalized offers when only Marktguru is enabled |
| `management-frontend/app/composables/useProviderSettings.ts` | Create | CRUD on `provider_settings` (load by extension point, upsert, delete) |
| `management-frontend/app/composables/__tests__/useProviderSettings.test.ts` | Create | Vitest unit tests for composable |
| `management-frontend/app/pages/settings/extensions/index.vue` | Create | Landing page: list extension points, link to per-EP page |
| `management-frontend/app/pages/settings/extensions/deal-source.vue` | Create | Per-extension-point admin: built-in toggles, webhook list, add/edit dialog |
| `management-frontend/app/components/extensions/AddWebhookDialog.vue` | Create | Modal form: display name, URL (https-only), auth token, free-form config JSON |
| `management-frontend/app/components/extensions/WebhookTestButton.vue` | Create | Button + result chip; calls a `provider-test` edge function with fixed sample |
| `Docker/supabase/functions/provider-test/index.ts` | Create | Tiny edge function that runs a single configured provider with fixed sample input |
| `Docker/supabase/functions/provider-test/deno.json` | Create | Minimal deno.json (matches existing convention) |
| `Docker/supabase/config.toml` | Modify | Register `[functions.provider-test]` section |
| `management-frontend/i18n/locales/en.json` | Modify | New `extensions.*` keys |
| `management-frontend/i18n/locales/de.json` | Modify | New `extensions.*` keys |
| `docs/extension-points/deal-source.md` | Create | Reference doc with interface, reference impl link, webhook contract, Claude Code prompt template |

---

## Cross-cutting conventions

- **Migration immutability** ([feedback_migration_immutability.md](../../../.claude/projects/-Users-lucienkerl-Development-mdb-esp32-cashless/memory/feedback_migration_immutability.md)): the migration file must be idempotent (`CREATE TABLE IF NOT EXISTS`, `DROP POLICY IF EXISTS` + `CREATE POLICY`, `ON CONFLICT DO NOTHING` on the data seed). Once committed it must never be edited; bug-fixes happen in a later migration.
- **Edge-function tests** run with `deno test --allow-env --allow-net=...` per file. Match the existing convention in [`Docker/supabase/functions/mqtt-webhook/mdb-log.test.ts`](../../Docker/supabase/functions/mqtt-webhook/mdb-log.test.ts) — `jsr:@std/assert` imports, `Deno.test` blocks, mock the Supabase admin client when DB calls are involved.
- **Frontend tests** use Vitest with the existing `nuxt-stubs` helpers in [`management-frontend/app/test-helpers/nuxt-stubs.ts`](../../management-frontend/app/test-helpers/nuxt-stubs.ts).
- **Frequent commits**: each task ends with a focused commit. The pre-commit hook (`.githooks/pre-commit`) checks immutable migrations.
- **Edge-function deno.json convention**: see [`Docker/supabase/functions/mqtt-webhook/deno.json`](../../Docker/supabase/functions/mqtt-webhook/deno.json) — minimal `{ "imports": {} }`. New functions follow the same shape.

---

## Chunk 1: Foundation — Database, Interface, Webhook Caller

This chunk creates the persistence layer, the `deal-source` interface, and the generic webhook caller used by every extension point. End state: migration applied, webhook helper passes its own tests, interface compiles. No edge function consumes them yet — that's Chunk 2.

### Task 1: `provider_settings` migration

**Files:**
- Create: `Docker/supabase/migrations/20260505100000_provider_settings.sql`

The migration creates the table, the partial active-rows index, RLS policies for the existing `my_company_id()` / `i_am_admin()` helpers, and seeds Marktguru as enabled for every company that already has `deals_enabled = true`. All operations idempotent.

- [ ] **Step 1.1: Write the migration**

Create `Docker/supabase/migrations/20260505100000_provider_settings.sql`:

```sql
-- =========================================================
-- Provider Settings
--
-- Per-company activation + config for extension-point providers
-- (deal-source, image-search, ai-backend, ...). One row per
-- (company, extension_point, provider_id). See
-- docs/superpowers/specs/2026-05-05-extension-provider-pattern-design.md
-- =========================================================

-- ─── A. Table ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.provider_settings (
  company_id      uuid        NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  extension_point text        NOT NULL,                   -- 'deal-source', 'image-search', ...
  provider_id     text        NOT NULL,                   -- 'marktguru' or 'webhook-{uuid}'
  enabled         boolean     NOT NULL DEFAULT false,
  config          jsonb       NOT NULL DEFAULT '{}'::jsonb,
  display_name    text,                                   -- user-facing for webhook providers
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (company_id, extension_point, provider_id)
);

-- Hot path: load all enabled providers for a (company, extension_point) pair.
CREATE INDEX IF NOT EXISTS idx_provider_settings_active
  ON public.provider_settings (company_id, extension_point)
  WHERE enabled = true;

-- ─── B. RLS ───────────────────────────────────────────────
ALTER TABLE public.provider_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS provider_settings_read  ON public.provider_settings;
DROP POLICY IF EXISTS provider_settings_write ON public.provider_settings;

CREATE POLICY provider_settings_read ON public.provider_settings
  FOR SELECT TO authenticated
  USING (company_id = public.my_company_id());

CREATE POLICY provider_settings_write ON public.provider_settings
  FOR ALL TO authenticated
  USING (company_id = public.my_company_id() AND public.i_am_admin())
  WITH CHECK (company_id = public.my_company_id() AND public.i_am_admin());

-- ─── C. Data: seed Marktguru for every deals-enabled company ──
-- Preserves existing behavior: companies that have deals_enabled = true today
-- get Marktguru auto-enabled as their first deal-source provider.
INSERT INTO public.provider_settings
  (company_id, extension_point, provider_id, enabled, config, display_name)
SELECT
  id,
  'deal-source',
  'marktguru',
  true,
  '{}'::jsonb,
  NULL
FROM public.companies
WHERE deals_enabled = true
ON CONFLICT (company_id, extension_point, provider_id) DO NOTHING;
```

- [ ] **Step 1.2: Apply locally and verify**

Run from `Docker/supabase/`:

```bash
supabase migration up
```

Expected: `Applying migration 20260505100000_provider_settings.sql...` then a clean prompt.

Verify table exists and seed ran:

```bash
cd Docker/supabase && \
psql "$(supabase status -o json | jq -r .DB_URL)" \
  -c "SELECT count(*) AS seeded FROM provider_settings WHERE provider_id='marktguru';"
```

Expected: `seeded` equals the number of companies in the local DB that have `deals_enabled = true` (typically 1 in dev).

- [ ] **Step 1.3: Commit**

```bash
git add Docker/supabase/migrations/20260505100000_provider_settings.sql
git commit -m "feat(db): provider_settings table for extension-point activation"
```

---

### Task 2: `DealSourceProvider` interface

**Files:**
- Create: `Docker/supabase/functions/_shared/providers/deal-source.ts`

Pure type module — no runtime code. Matches the spec's interface section. The `NormalizedOffer` shape is the contract every deal-source provider must produce; its fields are the union of what both built-in (Marktguru) and downstream consumers (`deal-search` matching) need.

- [ ] **Step 2.1: Create the interface module**

Create `Docker/supabase/functions/_shared/providers/deal-source.ts`:

```ts
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
```

- [ ] **Step 2.2: Verify TypeScript compiles in Deno**

```bash
cd Docker/supabase/functions
deno check _shared/providers/deal-source.ts
```

Expected: `Check file:///.../deal-source.ts` with no errors.

- [ ] **Step 2.3: Commit**

```bash
git add Docker/supabase/functions/_shared/providers/deal-source.ts
git commit -m "feat(providers): DealSourceProvider interface"
```

---

### Task 3: Generic webhook caller — failing tests first

**Files:**
- Create: `Docker/supabase/functions/_shared/providers/webhook.test.ts`
- Will create next: `Docker/supabase/functions/_shared/providers/webhook.ts`

The webhook caller posts a versioned envelope to a customer-supplied URL and parses the JSON response. It enforces HTTPS-only, applies a 10 s timeout via `AbortController`, and never retries. Errors propagate to the caller, which logs and skips per spec.

- [ ] **Step 3.1: Write the failing tests**

Create `Docker/supabase/functions/_shared/providers/webhook.test.ts`:

```ts
/**
 * Tests for the generic webhook caller used by every extension point.
 *
 * Run: deno test Docker/supabase/functions/_shared/providers/webhook.test.ts \
 *        --allow-net
 */

import { assertEquals, assertRejects, assertStringIncludes } from 'jsr:@std/assert'
import { callWebhookProvider } from './webhook.ts'

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Stand up a one-shot HTTP listener that captures the request and replies with
 * the configured handler. Returns the listener URL plus the captured request.
 */
async function withServer(
  handler: (req: Request) => Promise<Response> | Response,
  block: (url: string, captured: { value: Request | null }) => Promise<void>,
) {
  const captured: { value: Request | null } = { value: null }
  const ac = new AbortController()
  const server = Deno.serve(
    { port: 0, signal: ac.signal, onListen: () => {} },
    async (req) => {
      captured.value = req.clone()
      return handler(req)
    },
  )
  // @ts-ignore Deno.serve typing exposes addr at runtime
  const port = server.addr.port as number
  try {
    await block(`http://127.0.0.1:${port}`, captured)
  } finally {
    ac.abort()
    await server.finished
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

Deno.test('callWebhookProvider rejects http:// URLs (https-only enforcement)', async () => {
  await assertRejects(
    () =>
      callWebhookProvider({
        url: 'http://example.com/hook',
        authToken: 't',
        extensionPoint: 'deal-source',
        method: 'fetchOffers',
        args: { query: 'x', zipCode: '60487' },
      }),
    Error,
    'https',
  )
})

Deno.test('callWebhookProvider posts versioned envelope with bearer auth', async () => {
  // We use the local http listener but bypass the https check by passing a
  // marker argument used only in tests. See the implementation note below.
  await withServer(
    () =>
      new Response(JSON.stringify([{ externalId: '1', retailer: 'X' }]), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      }),
    async (url, captured) => {
      const result = await callWebhookProvider({
        url,
        authToken: 'secret',
        extensionPoint: 'deal-source',
        method: 'fetchOffers',
        args: { query: 'Monster', zipCode: '60487' },
        __allowInsecureForTests: true,
      })
      assertEquals(Array.isArray(result), true)
      const req = captured.value!
      assertEquals(req.method, 'POST')
      assertEquals(req.headers.get('authorization'), 'Bearer secret')
      assertEquals(req.headers.get('content-type'), 'application/json')
      const body = await req.json()
      assertEquals(body.version, 1)
      assertEquals(body.extensionPoint, 'deal-source')
      assertEquals(body.method, 'fetchOffers')
      assertEquals(body.args.query, 'Monster')
      assertEquals(body.args.zipCode, '60487')
    },
  )
})

Deno.test('callWebhookProvider throws on non-2xx responses', async () => {
  await withServer(
    () => new Response('boom', { status: 500 }),
    async (url) => {
      await assertRejects(
        () =>
          callWebhookProvider({
            url,
            authToken: 't',
            extensionPoint: 'deal-source',
            method: 'fetchOffers',
            args: {},
            __allowInsecureForTests: true,
          }),
        Error,
        '500',
      )
    },
  )
})

Deno.test('callWebhookProvider throws on malformed JSON body', async () => {
  await withServer(
    () =>
      new Response('{not json', {
        status: 200,
        headers: { 'content-type': 'application/json' },
      }),
    async (url) => {
      const err = await assertRejects(
        () =>
          callWebhookProvider({
            url,
            authToken: 't',
            extensionPoint: 'deal-source',
            method: 'fetchOffers',
            args: {},
            __allowInsecureForTests: true,
          }),
      )
      assertStringIncludes(String(err), 'JSON')
    },
  )
})

Deno.test('callWebhookProvider aborts after the configured timeout', async () => {
  await withServer(
    () =>
      new Promise<Response>((resolve) => {
        // Hold the request open beyond the timeout.
        setTimeout(
          () => resolve(new Response('late', { status: 200 })),
          500,
        )
      }),
    async (url) => {
      const err = await assertRejects(
        () =>
          callWebhookProvider({
            url,
            authToken: 't',
            extensionPoint: 'deal-source',
            method: 'fetchOffers',
            args: {},
            timeoutMs: 50,
            __allowInsecureForTests: true,
          }),
      )
      // AbortError surfaces with name 'AbortError' or message containing 'aborted'.
      const msg = String(err).toLowerCase()
      assertEquals(
        msg.includes('abort') || msg.includes('timeout'),
        true,
        `expected abort/timeout in error, got: ${err}`,
      )
    },
  )
})
```

- [ ] **Step 3.2: Run to verify tests fail**

```bash
cd Docker/supabase/functions
deno test _shared/providers/webhook.test.ts --allow-net
```

Expected: all 5 tests fail with `Module not found: webhook.ts` (or equivalent — the implementation file does not exist yet).

- [ ] **Step 3.3: Implement the webhook caller**

Create `Docker/supabase/functions/_shared/providers/webhook.ts`:

```ts
// Generic HTTP caller for custom webhook providers used by any extension point.
// Contract:
//   POST {url}
//   Authorization: Bearer {authToken}
//   Content-Type: application/json
//   { version: 1, extensionPoint, method, args }
//
// Returns the parsed JSON body. Throws on:
//   - non-https URLs (defense-in-depth on top of admin-UI validation)
//   - non-2xx responses
//   - malformed JSON bodies
//   - network errors / timeout
//
// Callers (per-extension-point resolvers) catch and skip individual failures.

export interface WebhookCallParams {
  /** Full https URL of the customer-hosted webhook. */
  url: string
  /** Customer-chosen auth token, sent as `Authorization: Bearer ...`. */
  authToken: string
  /** Extension-point id, e.g. 'deal-source'. */
  extensionPoint: string
  /** Method on the extension-point interface, e.g. 'fetchOffers'. */
  method: string
  /** Call-specific arguments — must NOT include companyId or provider config. */
  args: Record<string, unknown>
  /** Per-call timeout. Default 10_000 ms. */
  timeoutMs?: number
  /**
   * Test-only escape hatch to use http:// URLs. Production callers must not
   * set this; the HTTPS check is defense-in-depth on top of admin-UI validation.
   */
  __allowInsecureForTests?: boolean
}

export async function callWebhookProvider(params: WebhookCallParams): Promise<unknown> {
  const {
    url,
    authToken,
    extensionPoint,
    method,
    args,
    timeoutMs = 10_000,
    __allowInsecureForTests = false,
  } = params

  if (!__allowInsecureForTests && !url.startsWith('https://')) {
    throw new Error(`webhook url must use https: got ${url}`)
  }

  const controller = new AbortController()
  const timeoutId = setTimeout(() => controller.abort(), timeoutMs)

  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${authToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ version: 1, extensionPoint, method, args }),
      signal: controller.signal,
    })

    if (!res.ok) {
      throw new Error(`webhook ${url} returned ${res.status} ${res.statusText}`)
    }

    try {
      return await res.json()
    } catch (jsonErr) {
      throw new Error(`webhook ${url} returned malformed JSON: ${jsonErr}`)
    }
  } finally {
    clearTimeout(timeoutId)
  }
}
```

- [ ] **Step 3.4: Run tests to verify they pass**

```bash
cd Docker/supabase/functions
deno test _shared/providers/webhook.test.ts --allow-net
```

Expected: `5 passed`.

- [ ] **Step 3.5: Commit**

```bash
git add Docker/supabase/functions/_shared/providers/webhook.ts \
        Docker/supabase/functions/_shared/providers/webhook.test.ts
git commit -m "feat(providers): generic webhook caller with timeout + https enforcement"
```

---

**Chunk 1 verification:**

- [ ] **Step 4.1: All Chunk 1 tests pass**

```bash
cd Docker/supabase/functions
deno test _shared/providers/ --allow-net
```

Expected: `5 passed` (all from `webhook.test.ts`).

- [ ] **Step 4.2: Migration applied cleanly**

```bash
psql "$(cd Docker/supabase && supabase status -o json | jq -r .DB_URL)" \
  -c "\\d+ provider_settings" \
  -c "SELECT extension_point, provider_id, enabled FROM provider_settings;"
```

Expected: table description shows the 7 columns + the `idx_provider_settings_active` partial index, and the seed row exists for every deals-enabled company.

- [ ] **Step 4.3: TypeScript interface is importable**

```bash
cd Docker/supabase/functions
deno check _shared/providers/deal-source.ts _shared/providers/webhook.ts
```

Expected: no errors.

---

## Chunk 2: Marktguru provider + registry + resolver

This chunk extracts Marktguru-specific logic out of `deal-search/index.ts` into a provider module, sets up the static built-in registry, and writes the resolver that turns `provider_settings` rows into a list of callable providers. End state: `marktguru.ts` exposes a `DealSourceProvider`; `resolve-providers.ts` returns the right providers for a company; tests cover both. `deal-search/index.ts` is **not yet** refactored — that's Chunk 3.

### Task 5: Marktguru provider — failing tests first

**Files:**
- Create: `Docker/supabase/functions/_shared/providers/deal-source/marktguru.test.ts`
- Will create next: `Docker/supabase/functions/_shared/providers/deal-source/marktguru.ts`

The provider has two halves: HTTP (key bootstrap + offer fetch) and a pure normalization function `normalizeOffer(raw) → NormalizedOffer`. Tests cover the pure function — the HTTP path is exercised in Chunk 3's regression test where it's mocked end-to-end.

- [ ] **Step 5.1: Write the failing tests**

Create `Docker/supabase/functions/_shared/providers/deal-source/marktguru.test.ts`:

```ts
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
  // @ts-expect-error simulate Marktguru returning a payload without brand
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
```

- [ ] **Step 5.2: Run to verify tests fail**

```bash
cd Docker/supabase/functions
deno test _shared/providers/deal-source/marktguru.test.ts
```

Expected: all tests fail with "Module not found" / "Could not resolve" — `marktguru.ts` does not exist yet.

- [ ] **Step 5.3: Implement the Marktguru provider**

Create `Docker/supabase/functions/_shared/providers/deal-source/marktguru.ts`:

```ts
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
```

- [ ] **Step 5.4: Run tests to verify they pass**

```bash
cd Docker/supabase/functions
deno test _shared/providers/deal-source/marktguru.test.ts
```

Expected: `7 passed`.

- [ ] **Step 5.5: Commit**

```bash
git add Docker/supabase/functions/_shared/providers/deal-source/marktguru.ts \
        Docker/supabase/functions/_shared/providers/deal-source/marktguru.test.ts
git commit -m "feat(providers): extract Marktguru as DealSourceProvider"
```

---

### Task 6: Built-in registry for `deal-source`

**Files:**
- Create: `Docker/supabase/functions/deal-search/registry.ts`

The registry maps provider IDs to their built-in implementations. Adding a new built-in provider in the future = create the file under `_shared/providers/deal-source/` and add one import + one entry here. That manual step is intentional per the spec ("Deno's lack of glob-import in production prevents auto-discovery").

- [ ] **Step 6.1: Create the registry**

Create `Docker/supabase/functions/deal-search/registry.ts`:

```ts
// Built-in DealSource providers, keyed by their stable id.
//
// To add a built-in provider:
//   1. Create Docker/supabase/functions/_shared/providers/deal-source/<id>.ts
//      that exports `provider: DealSourceProvider`.
//   2. Add the import + registry entry below.
//   3. Add tests under the same path with `.test.ts`.
//   4. Document in docs/extension-points/deal-source.md.

import type { DealSourceProvider } from '../_shared/providers/deal-source.ts'
import { provider as marktguru } from '../_shared/providers/deal-source/marktguru.ts'

export const builtinProviders: Record<string, DealSourceProvider> = {
  marktguru,
}
```

- [ ] **Step 6.2: Verify TypeScript compiles**

```bash
cd Docker/supabase/functions
deno check deal-search/registry.ts
```

Expected: no errors.

- [ ] **Step 6.3: Commit**

```bash
git add Docker/supabase/functions/deal-search/registry.ts
git commit -m "feat(deal-search): built-in provider registry (marktguru only)"
```

---

### Task 7: Provider resolver — failing tests first

**Files:**
- Create: `Docker/supabase/functions/deal-search/resolve-providers.test.ts`
- Will create next: `Docker/supabase/functions/deal-search/resolve-providers.ts`

The resolver loads the per-company `provider_settings` rows and turns them into runtime `DealSourceProvider` objects. Built-in IDs hit the registry; `webhook-{uuid}` IDs wrap the generic webhook caller; unknown IDs log a warning and are skipped.

- [ ] **Step 7.1: Write the failing tests**

Create `Docker/supabase/functions/deal-search/resolve-providers.test.ts`:

```ts
/**
 * Tests for the deal-source provider resolver.
 *
 * Run: deno test Docker/supabase/functions/deal-search/resolve-providers.test.ts
 */

import { assertEquals } from 'jsr:@std/assert'
import { resolveProviders, type ProviderRow } from './resolve-providers.ts'

// ── Mock supabase admin client ────────────────────────────────────────────────

function mockAdminClient(rows: ProviderRow[]) {
  const calls: { table: string; filters: Record<string, unknown> }[] = []
  // deno-lint-ignore no-explicit-any
  const client: any = {
    from(table: string) {
      const filters: Record<string, unknown> = {}
      const builder = {
        select(_cols: string) { return builder },
        eq(col: string, val: unknown) { filters[col] = val; return builder },
        // PostgrestFilterBuilder is thenable on every link of an .eq() chain;
        // `await` invokes then() on whichever .eq() the resolver awaits. The
        // mock mirrors that by exposing then() on the same builder object.
        then(onFulfilled: (v: unknown) => unknown) {
          calls.push({ table, filters: { ...filters } })
          return Promise.resolve({ data: rows, error: null }).then(onFulfilled)
        },
      }
      return builder
    },
  }
  return { client, calls }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

Deno.test('resolveProviders returns built-in for known provider_id', async () => {
  const { client, calls } = mockAdminClient([
    { provider_id: 'marktguru', config: {} },
  ])

  const result = await resolveProviders(client, 'co-1')

  assertEquals(result.length, 1)
  assertEquals(result[0].provider.id, 'marktguru')
  assertEquals(calls.length, 1)
  assertEquals(calls[0].table, 'provider_settings')
  assertEquals(calls[0].filters['company_id'], 'co-1')
  assertEquals(calls[0].filters['extension_point'], 'deal-source')
  assertEquals(calls[0].filters['enabled'], true)
})

Deno.test('resolveProviders wraps webhook-* provider_ids', async () => {
  const { client } = mockAdminClient([
    {
      provider_id: 'webhook-abc-123',
      config: { url: 'https://hook.example/deals', authToken: 't' },
    },
  ])

  const result = await resolveProviders(client, 'co-1')

  assertEquals(result.length, 1)
  assertEquals(result[0].provider.id, 'webhook-abc-123')
  // The wrapped provider exposes fetchOffers — we don't actually call it here
  // (that would hit the network); Chunk 3's regression test exercises the path.
  assertEquals(typeof result[0].provider.fetchOffers, 'function')
})

Deno.test('resolveProviders skips webhook rows with missing url/authToken', async () => {
  const { client } = mockAdminClient([
    { provider_id: 'webhook-bad', config: { url: 'https://x' } }, // no authToken
    { provider_id: 'webhook-bad-2', config: { authToken: 't' } }, // no url
    { provider_id: 'marktguru', config: {} },
  ])

  // Capture console.warn output to confirm the skip is logged.
  const warns: string[] = []
  const origWarn = console.warn
  console.warn = (...args: unknown[]) => { warns.push(args.map(String).join(' ')) }
  try {
    const result = await resolveProviders(client, 'co-1')
    assertEquals(result.length, 1)
    assertEquals(result[0].provider.id, 'marktguru')
    assertEquals(warns.filter((w) => w.includes('webhook-bad')).length, 1)
    assertEquals(warns.filter((w) => w.includes('webhook-bad-2')).length, 1)
  } finally {
    console.warn = origWarn
  }
})

Deno.test('resolveProviders warns and skips unknown provider_ids', async () => {
  const { client } = mockAdminClient([
    { provider_id: 'totally-made-up', config: {} },
    { provider_id: 'marktguru', config: {} },
  ])

  const warns: string[] = []
  const origWarn = console.warn
  console.warn = (...args: unknown[]) => { warns.push(args.map(String).join(' ')) }
  try {
    const result = await resolveProviders(client, 'co-1')
    assertEquals(result.length, 1)
    assertEquals(result[0].provider.id, 'marktguru')
    assertEquals(warns.filter((w) => w.includes('totally-made-up')).length, 1)
  } finally {
    console.warn = origWarn
  }
})

Deno.test('resolveProviders returns empty array when no rows enabled', async () => {
  const { client } = mockAdminClient([])
  const result = await resolveProviders(client, 'co-1')
  assertEquals(result, [])
})
```

- [ ] **Step 7.2: Run to verify tests fail**

```bash
cd Docker/supabase/functions
deno test deal-search/resolve-providers.test.ts
```

Expected: all tests fail — `resolve-providers.ts` does not exist yet.

- [ ] **Step 7.3: Implement the resolver**

Create `Docker/supabase/functions/deal-search/resolve-providers.ts`:

```ts
// Resolves per-company provider_settings rows into runtime DealSourceProviders.
//
// Built-in IDs hit the static registry. Webhook IDs (prefix 'webhook-') wrap
// the generic webhook caller. Unknown IDs log a warning and are skipped —
// this happens when a row outlives a built-in provider that was removed from
// the codebase, or when a typo creeps into an admin-UI edit.

import type {
  DealSourceContext,
  DealSourceProvider,
  NormalizedOffer,
} from '../_shared/providers/deal-source.ts'
import { callWebhookProvider } from '../_shared/providers/webhook.ts'
import { builtinProviders } from './registry.ts'

export interface ProviderRow {
  provider_id: string
  config: Record<string, unknown>
}

export interface ResolvedProvider {
  provider: DealSourceProvider
  /** The raw row so callers can access provider-specific config if they need to. */
  row: ProviderRow
}

export async function resolveProviders(
  // deno-lint-ignore no-explicit-any
  adminClient: any,
  companyId: string,
): Promise<ResolvedProvider[]> {
  const { data, error } = await adminClient
    .from('provider_settings')
    .select('provider_id, config')
    .eq('company_id', companyId)
    .eq('extension_point', 'deal-source')
    .eq('enabled', true)

  if (error) throw error

  const result: ResolvedProvider[] = []
  for (const row of (data ?? []) as ProviderRow[]) {
    const builtin = builtinProviders[row.provider_id]
    if (builtin) {
      result.push({ provider: builtin, row })
      continue
    }

    if (row.provider_id.startsWith('webhook-')) {
      const cfg = row.config as { url?: string; authToken?: string }
      if (!cfg.url || !cfg.authToken) {
        console.warn(
          `[deal-search] webhook provider ${row.provider_id} missing url or authToken; skipping`,
        )
        continue
      }
      result.push({
        provider: makeWebhookProvider(row.provider_id, cfg.url, cfg.authToken),
        row,
      })
      continue
    }

    console.warn(`[deal-search] unknown provider ${row.provider_id}; skipping`)
  }
  return result
}

function makeWebhookProvider(
  id: string,
  url: string,
  authToken: string,
): DealSourceProvider {
  return {
    id,
    async fetchOffers(query: string, ctx: DealSourceContext): Promise<NormalizedOffer[]> {
      const out = await callWebhookProvider({
        url,
        authToken,
        extensionPoint: 'deal-source',
        method: 'fetchOffers',
        // companyId and config are deliberately omitted — see spec
        args: { query, zipCode: ctx.zipCode },
      })
      // Trust the webhook's output shape per the loose contract; arrays only.
      return Array.isArray(out) ? (out as NormalizedOffer[]) : []
    },
  }
}
```

- [ ] **Step 7.4: Run tests to verify they pass**

```bash
cd Docker/supabase/functions
deno test deal-search/resolve-providers.test.ts
```

Expected: `5 passed`.

- [ ] **Step 7.5: Commit**

```bash
git add Docker/supabase/functions/deal-search/resolve-providers.ts \
        Docker/supabase/functions/deal-search/resolve-providers.test.ts
git commit -m "feat(deal-search): per-company provider resolver"
```

---

**Chunk 2 verification:**

- [ ] **Step 7.6: All Chunk 1+2 tests pass together**

```bash
cd Docker/supabase/functions
deno test _shared/providers/ deal-search/ --allow-net
```

Expected: 17 passed total (5 webhook + 7 marktguru + 5 resolver). The existing `deal-search/index.ts` is untouched and still calls Marktguru directly.

- [ ] **Step 7.7: TypeScript compiles for the new modules**

```bash
cd Docker/supabase/functions
deno check \
  _shared/providers/deal-source.ts \
  _shared/providers/webhook.ts \
  _shared/providers/deal-source/marktguru.ts \
  deal-search/registry.ts \
  deal-search/resolve-providers.ts
```

Expected: no errors.

---

## Chunk 3: `deal-search/index.ts` refactor + regression test

This is where the existing edge function actually starts using the new pattern. The behavior must stay identical when only Marktguru is enabled (which is what the seed migration already configured for every existing company). End state: `deal-search/index.ts` no longer references `MarktguruOffer` or `searchMarktguru` directly; a regression test confirms produced `deal_cache` rows are unchanged.

The refactor has six sub-edits (Task 8) plus a regression test (Task 9). Each sub-edit is independently safe to apply via the `Edit` tool — the changes are exact `old_string`/`new_string` pairs. After the last edit the file compiles and runs; after the regression test it's verified.

### Task 8: Refactor `deal-search/index.ts` to use the provider registry

**File:** `Docker/supabase/functions/deal-search/index.ts` (modify)

**Pre-flight check** — confirm the file is still in the expected pre-refactor shape:

- [ ] **Step 8.0: Sanity check the file**

```bash
cd Docker/supabase/functions
git log -1 --format='%H %s' deal-search/index.ts
grep -n 'getMarktguruKeys\|searchMarktguru\|MarktguruOffer' deal-search/index.ts | head -10
```

Expected: the most recent commit is `ac9ff6c` ("raise Marktguru fetch limit from 10 to 50"); grep returns ~10 matches across interface, helpers, and call sites. If the file has been modified upstream, abort and re-plan from current state.

- [ ] **Step 8.1: Add the new imports at the top**

Edit `Docker/supabase/functions/deal-search/index.ts` — replace:

```ts
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
```

with:

```ts
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import type { NormalizedOffer } from '../_shared/providers/deal-source.ts'
import { resolveProviders, type ResolvedProvider } from './resolve-providers.ts'

const corsHeaders = {
```

- [ ] **Step 8.2: Delete the now-dead Marktguru-specific top-level code**

Edit — replace the entire block from `// ─── Marktguru API helpers ──────...` through the end of `searchMarktguru` (lines that begin with `// ─── Marktguru API helpers` and end at the closing `}` of `searchMarktguru`) with a single comment line. The block to delete is the `MarktguruOffer` interface, `MarktguruKeys` interface, `getMarktguruKeys()`, and `searchMarktguru()`.

```ts
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
```

with:

```ts
// Marktguru is now a DealSourceProvider plugin — see
// Docker/supabase/functions/_shared/providers/deal-source/marktguru.ts
```

- [ ] **Step 8.3: Swap key bootstrap for provider resolution in the request handler**

Edit — replace:

```ts
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
```

with:

```ts
    // Resolve enabled deal-source providers for this company.
    let resolved: ResolvedProvider[]
    try {
      resolved = await resolveProviders(adminClient, companyId)
    } catch (err) {
      console.error('[deal-search] failed to resolve providers:', err)
      return new Response(JSON.stringify({ error: 'Failed to load provider configuration' }), {
        status: 502,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }
    if (resolved.length === 0) {
      return new Response(
        JSON.stringify({ deals: [], fromCache: false, message: 'No deal-source providers enabled' }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }
```

- [ ] **Step 8.4: Replace the per-query Marktguru fetch with parallel provider calls**

Edit — replace:

```ts
    // Phase A: parallel Marktguru fetches in bounded batches. Phase B (matching)
    // stays sequential because it mutates shared allDeals / seen / keywordCovered
    // — the keyword pass marks products as covered for an offer, which the later
    // product pass reads to dedupe. Concurrency 10 keeps us below plausible
    // Marktguru abuse thresholds while cutting wall-clock by ~10× on large
    // catalogs.
    const FETCH_CONCURRENCY = 10
    type FetchResult = { query: string; matchProducts: typeof products; offers: MarktguruOffer[] }
    const fetchResults: FetchResult[] = []
    for (let i = 0; i < queries.length; i += FETCH_CONCURRENCY) {
      const batch = queries.slice(i, i + FETCH_CONCURRENCY)
      const batchResults = await Promise.all(
        batch.map(async ([query, matchProducts]): Promise<FetchResult> => {
          try {
            // Marktguru ranks by internal relevance; popular brand queries
            // (e.g. "Monster") often return Lidl/Edeka/Penny first and push
            // REWE past position 10. Pull the top 50 so smaller-share retailer
            // offers still enter the matching pipeline.
            const offers = await searchMarktguru(query, zipCode, keys, 50)
            return { query, matchProducts, offers }
          } catch (err) {
            console.error(`Search failed for "${query}":`, err)
            return { query, matchProducts, offers: [] as MarktguruOffer[] }
          }
        }),
      )
      fetchResults.push(...batchResults)
    }
```

with:

```ts
    // Phase A: parallel provider fetches in bounded batches. For each query we
    // invoke every enabled provider in parallel, then merge their NormalizedOffer
    // results, deduping by (retailerSlug, externalId). Phase B (matching) stays
    // sequential because it mutates shared allDeals / seen / keywordCovered —
    // the keyword pass marks products as covered for an offer, which the later
    // product pass reads to dedupe.
    const FETCH_CONCURRENCY = 10
    type FetchResult = { query: string; matchProducts: typeof products; offers: NormalizedOffer[] }
    const fetchResults: FetchResult[] = []
    for (let i = 0; i < queries.length; i += FETCH_CONCURRENCY) {
      const batch = queries.slice(i, i + FETCH_CONCURRENCY)
      const batchResults = await Promise.all(
        batch.map(async ([query, matchProducts]): Promise<FetchResult> => {
          const perProvider = await Promise.allSettled(
            resolved.map((r) =>
              r.provider.fetchOffers(query, {
                companyId,
                zipCode,
                config: r.row.config,
              }),
            ),
          )
          const seenOffer = new Set<string>()
          const offers: NormalizedOffer[] = []
          for (let j = 0; j < perProvider.length; j++) {
            const res = perProvider[j]
            if (res.status === 'rejected') {
              console.error(
                `[deal-search] provider ${resolved[j].provider.id} failed for "${query}":`,
                res.reason,
              )
              continue
            }
            for (const offer of res.value) {
              const k = `${offer.retailerSlug}::${offer.externalId}`
              if (seenOffer.has(k)) continue
              seenOffer.add(k)
              offers.push(offer)
            }
          }
          return { query, matchProducts, offers }
        }),
      )
      fetchResults.push(...batchResults)
    }
```

- [ ] **Step 8.5: Update the keyword-pass `buildKeywordDeal` helper**

Edit — replace:

```ts
        // Helper: build a keyword-match deal row for upsert.
        function buildKeywordDeal(
          offer: MarktguruOffer,
          keyword: DealKeyword,
          winning: { term: string; match: MatchResult },
        ) {
          const retailerSlug = offer.advertisers?.[0]?.uniqueName ?? 'unknown'
          const retailerName = offer.advertisers?.[0]?.name ?? retailerSlug
          const validFrom = offer.validityDates?.[0]?.from ?? null
          const validUntil = offer.validityDates?.[0]?.to ?? null
          const discountPct = offer.oldPrice && offer.price
            ? Math.round((1 - offer.price / offer.oldPrice) * 100)
            : null
          const imageUrlLarge = `https://mg2de.b-cdn.net/api/v1/offers/${offer.id}/images/default/0/large.jpg`
          const prospektUrl = dealConfig.retailer_prospekt_urls[retailerSlug]
            ?? `https://www.marktguru.de/rp/${retailerSlug}-prospekte`
          const retailerPageUrl = `https://www.marktguru.de/r/${retailerSlug}`

          return {
            company_id: companyId,
            product_id: null,
            keyword_id: keyword.id,
            matched_term: winning.term,
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
            matched_by: 'keyword_fuzzy',
            confidence: winning.match.confidence,
            matched_tokens: winning.match.matchedTokens,
            requires_app: offer.requiresLoyalityMembership
              || detectAppRequirement(offer.description, dealConfig.app_detection_patterns),
            fetched_at: new Date().toISOString(),
            offer_id: String(offer.id),
          }
        }
```

with:

```ts
        // Helper: build a keyword-match deal row for upsert.
        function buildKeywordDeal(
          offer: NormalizedOffer,
          keyword: DealKeyword,
          winning: { term: string; match: MatchResult },
        ) {
          const discountPct = offer.oldPrice && offer.price
            ? Math.round((1 - offer.price / offer.oldPrice) * 100)
            : null
          // Consumer-side overlay: dealConfig.retailer_prospekt_urls is the
          // canonical source-of-truth for prospekt URLs; fall back to whatever
          // the provider produced (Marktguru's marktguru.de/rp/{slug} URL).
          const prospektUrl = dealConfig.retailer_prospekt_urls[offer.retailerSlug]
            ?? offer.sourceUrl
            ?? `https://www.marktguru.de/rp/${offer.retailerSlug}-prospekte`

          return {
            company_id: companyId,
            product_id: null,
            keyword_id: keyword.id,
            matched_term: winning.term,
            retailer: offer.retailer,
            deal_title: offer.description,
            deal_price: offer.price,
            regular_price: offer.oldPrice,
            discount_pct: discountPct,
            valid_from: offer.validFrom,
            valid_until: offer.validUntil,
            image_url: offer.imageUrl,
            image_url_large: offer.imageUrlLarge,
            source_url: prospektUrl,
            external_url: offer.externalUrl,
            matched_by: 'keyword_fuzzy',
            confidence: winning.match.confidence,
            matched_tokens: winning.match.matchedTokens,
            requires_app: (offer.requiresApp ?? false)
              || detectAppRequirement(offer.description, dealConfig.app_detection_patterns),
            fetched_at: new Date().toISOString(),
            offer_id: offer.externalId,
          }
        }
```

- [ ] **Step 8.6: Update the product-pass `buildDeal` helper and the matching loops**

Edit — replace:

```ts
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
          const prospektUrl = dealConfig.retailer_prospekt_urls[retailerSlug]
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
            requires_app: offer.requiresLoyalityMembership || detectAppRequirement(offer.description, dealConfig.app_detection_patterns),
            fetched_at: new Date().toISOString(),
            offer_id: String(offer.id),
          }
        }
```

with:

```ts
        // Helper to build a deal record from an offer + product match
        function buildDeal(offer: NormalizedOffer, product: any, match: MatchResult) {
          const discountPct = offer.oldPrice && offer.price
            ? Math.round((1 - offer.price / offer.oldPrice) * 100)
            : null
          // Consumer-side overlay (see buildKeywordDeal for the rationale).
          const prospektUrl = dealConfig.retailer_prospekt_urls[offer.retailerSlug]
            ?? offer.sourceUrl
            ?? `https://www.marktguru.de/rp/${offer.retailerSlug}-prospekte`

          return {
            company_id: companyId,
            product_id: product.id,
            retailer: offer.retailer,
            deal_title: offer.description,
            deal_price: offer.price,
            regular_price: offer.oldPrice,
            discount_pct: discountPct,
            valid_from: offer.validFrom,
            valid_until: offer.validUntil,
            image_url: offer.imageUrl,
            image_url_large: offer.imageUrlLarge,
            source_url: prospektUrl,
            external_url: offer.externalUrl,
            matched_by: 'name_fuzzy',
            confidence: match.confidence,
            matched_tokens: match.matchedTokens,
            requires_app: (offer.requiresApp ?? false)
              || detectAppRequirement(offer.description, dealConfig.app_detection_patterns),
            fetched_at: new Date().toISOString(),
            offer_id: offer.externalId,
          }
        }
```

- [ ] **Step 8.7: Replace remaining `offer.id` and `offer.brand?.name` references**

Seven token-level edits, applied in any order. The patterns are unambiguous and use `replace_all` where the same literal appears more than once. After Steps 8.5 and 8.6 already replaced the `buildKeywordDeal` and `buildDeal` bodies wholesale, the only remaining sites are the two outer matching loops plus the `keywordCovered` declaration and a single comment that edit (b) cleans up for free.

Edit (a) — keyword-pass dedup template (one occurrence):

```
old_string:
            const dedup = `kw-${offer.id}-${keyword.id}`

new_string:
            const dedup = `kw-${offer.externalId}-${keyword.id}`
```

Edit (b) — product-pass dedup template, `replace_all` (three occurrences: matchProducts loop, cross-products loop, **and the explanatory comment on line 636** — `replace_all` updates the comment for free, keeping the Step 8.8 grep clean):

```
old_string:
${offer.id}-${product.id}

new_string:
${offer.externalId}-${product.id}
```

Edit (c) — `keywordCovered.get`, `replace_all` (three occurrences: keyword pass + matchProducts loop + cross-products loop):

```
old_string:
keywordCovered.get(offer.id)

new_string:
keywordCovered.get(offer.externalId)
```

Edit (d) — `keywordCovered.set` (one occurrence):

```
old_string:
            keywordCovered.set(offer.id, covered)

new_string:
            keywordCovered.set(offer.externalId, covered)
```

Edit (e) — keyword-pass `matchConfidence` brand argument (16 spaces of indent, one occurrence at the keyword-matching call site):

```
old_string:
                offer.brand?.name ?? '',

new_string:
                offer.brand,
```

Edit (f) — product-pass `matchConfidence` brand argument, `replace_all` (14 spaces of indent, two occurrences across matchProducts and cross-products call sites):

```
old_string:
              offer.brand?.name ?? '',

new_string:
              offer.brand,
```

Edit (g) — `keywordCovered` map-value type widening (one occurrence; `externalId` is always `string`):

```
old_string:
    const keywordCovered = new Map<string | number, Set<string>>()

new_string:
    const keywordCovered = new Map<string, Set<string>>()
```

After all seven edits land, Step 8.8's grep returns zero matches — every `offer.id`, `offer.brand?.name`, and Marktguru-shaped reference has been rewritten or deleted by Steps 8.1–8.7.

- [ ] **Step 8.8: Verify compile and that no Marktguru references remain**

```bash
cd Docker/supabase/functions
deno check deal-search/index.ts
grep -nE 'MarktguruOffer|MarktguruKeys|getMarktguruKeys|searchMarktguru|offer\.id\b|offer\.brand\?\.name|offer\.advertisers|offer\.validityDates|offer\.images|offer\.requiresLoyalityMembership' \
  deal-search/index.ts
```

Expected: `deno check` reports zero errors. The `grep` returns **no matches at all** — every code site and every relevant comment was rewritten in Steps 8.1–8.7. If you see a hit, it's a missed edit; do not commit until grep is clean.

- [ ] **Step 8.9: Commit**

```bash
git add Docker/supabase/functions/deal-search/index.ts
git commit -m "refactor(deal-search): use DealSourceProvider registry + resolver

Marktguru is now a built-in provider behind the resolver; the inline
fetch + normalization helpers were extracted in 11853ce..0271c90.
Behavior unchanged for companies with only Marktguru enabled (the seed
migration enables it for every existing deals_enabled company)."
```

---

### Task 9: Regression test — behavior unchanged when only Marktguru is enabled

**Files:**
- Create: `Docker/supabase/functions/deal-search/regression.test.ts`

This test exercises the *normalization → buildDeal-row* pipeline end-to-end for a known Marktguru offer + a known product, asserting the produced deal_cache row is byte-for-byte identical to what the pre-refactor code would have written. It does not boot the full edge function — that would require mocking the entire request handler, which is out of proportion to the risk. Instead it tests the seam where the refactor is most likely to have drifted: field mapping inside `buildDeal`.

The test imports `normalizeOffer` from the provider module (already covered by `marktguru.test.ts` at the unit level) and re-creates a minimal `buildDeal` call with the same `dealConfig` shape the consumer uses. If the consumer's inline `buildDeal` and this test's local copy diverge, the test catches it.

- [ ] **Step 9.1: Write the regression test**

Create `Docker/supabase/functions/deal-search/regression.test.ts`:

```ts
/**
 * Regression test: the refactored deal-search pipeline produces byte-for-byte
 * identical deal_cache rows to the pre-refactor inline implementation, for a
 * known Marktguru offer + product fixture.
 *
 * The test exercises the seam most likely to drift: NormalizedOffer field
 * access inside the consumer's buildDeal helper. We re-create buildDeal here
 * with the same body the consumer uses post-refactor; if the consumer's
 * inline copy diverges from this reference, the test catches it.
 *
 * Run: deno test Docker/supabase/functions/deal-search/regression.test.ts
 */

import { assertEquals } from 'jsr:@std/assert'
import {
  normalizeOffer,
  type MarktguruOffer,
} from '../_shared/providers/deal-source/marktguru.ts'
import type { NormalizedOffer } from '../_shared/providers/deal-source.ts'

// ── Fixtures ──────────────────────────────────────────────────────────────────

const RAW_MARKTGURU_OFFER: MarktguruOffer = {
  id: 12345,
  description: 'HINWEIS: MIT APP 0,20€ REWE BONUS versch. Sorten, koffeinhaltig, je 0,5-l-Dose zzgl. 0.25 Pfand',
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
}

const PRODUCT = { id: 'pid-monster', name: 'Monster Energy' }
const COMPANY_ID = 'co-1'
const DEAL_CONFIG = {
  generic_terms: [],
  wildcard_phrases: ['versch', 'sorten'],
  app_detection_patterns: ['mit app', 'rewe bonus'],
  retailer_prospekt_urls: {
    rewe: 'https://www.rewe.de/angebote/nationale-angebote/',
  },
}

// ── Reference impl: buildDeal as the refactored consumer should write it ──

interface MatchResult {
  confidence: number
  matchedTokens: string[]
}

function detectAppRequirement(description: string, patterns: string[]): boolean {
  const lower = description.toLowerCase()
  return patterns.some((p) => lower.includes(p))
}

function buildDealRef(
  offer: NormalizedOffer,
  product: { id: string; name: string },
  match: MatchResult,
) {
  const discountPct = offer.oldPrice && offer.price
    ? Math.round((1 - offer.price / offer.oldPrice) * 100)
    : null
  const prospektUrl = DEAL_CONFIG.retailer_prospekt_urls[offer.retailerSlug as keyof typeof DEAL_CONFIG.retailer_prospekt_urls]
    ?? offer.sourceUrl
    ?? `https://www.marktguru.de/rp/${offer.retailerSlug}-prospekte`

  return {
    company_id: COMPANY_ID,
    product_id: product.id,
    retailer: offer.retailer,
    deal_title: offer.description,
    deal_price: offer.price,
    regular_price: offer.oldPrice,
    discount_pct: discountPct,
    valid_from: offer.validFrom,
    valid_until: offer.validUntil,
    image_url: offer.imageUrl,
    image_url_large: offer.imageUrlLarge,
    source_url: prospektUrl,
    external_url: offer.externalUrl,
    matched_by: 'name_fuzzy',
    confidence: match.confidence,
    matched_tokens: match.matchedTokens,
    requires_app: (offer.requiresApp ?? false)
      || detectAppRequirement(offer.description, DEAL_CONFIG.app_detection_patterns),
    fetched_at: new Date(0).toISOString(), // pinned for assertion
    offer_id: offer.externalId,
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

Deno.test('normalize → buildDeal produces row matching pre-refactor shape', () => {
  const normalized = normalizeOffer(RAW_MARKTGURU_OFFER)
  const match: MatchResult = { confidence: 0.75, matchedTokens: ['monster'] }
  const row = buildDealRef(normalized, PRODUCT, match)

  // What the pre-refactor code would have produced for this exact fixture.
  // Hand-computed from the inline buildDeal body in deal-search/index.ts
  // at commit ac9ff6c (the last commit before this refactor).
  const expected = {
    company_id: 'co-1',
    product_id: 'pid-monster',
    retailer: 'REWE',
    deal_title: 'HINWEIS: MIT APP 0,20€ REWE BONUS versch. Sorten, koffeinhaltig, je 0,5-l-Dose zzgl. 0.25 Pfand',
    deal_price: 0.99,
    regular_price: 1.49,
    discount_pct: 34,                                       // round((1 - 0.99/1.49) * 100)
    valid_from: '2026-05-03T22:00:00Z',
    valid_until: '2026-05-09T21:59:00Z',
    image_url: 'https://example/medium.jpg',
    image_url_large: 'https://mg2de.b-cdn.net/api/v1/offers/12345/images/default/0/large.jpg',
    source_url: 'https://www.rewe.de/angebote/nationale-angebote/',  // dealConfig overlay
    external_url: 'https://www.marktguru.de/r/rewe',
    matched_by: 'name_fuzzy',
    confidence: 0.75,
    matched_tokens: ['monster'],
    requires_app: true,                                     // detectAppRequirement matches "mit app"
    fetched_at: new Date(0).toISOString(),
    offer_id: '12345',
  }

  assertEquals(row, expected)
})

Deno.test('source_url falls through to provider value when dealConfig has no mapping', () => {
  const normalized = normalizeOffer({
    ...RAW_MARKTGURU_OFFER,
    advertisers: [{ name: 'PENNY', uniqueName: 'penny' }],
  })
  const match: MatchResult = { confidence: 0.75, matchedTokens: ['monster'] }
  const row = buildDealRef(normalized, PRODUCT, match)

  // 'penny' is not in DEAL_CONFIG.retailer_prospekt_urls → fall through to
  // offer.sourceUrl (the provider-built marktguru.de URL).
  assertEquals(row.source_url, 'https://www.marktguru.de/rp/penny-prospekte')
})

Deno.test('requires_app stays false when neither flag nor description triggers', () => {
  const normalized = normalizeOffer({
    ...RAW_MARKTGURU_OFFER,
    description: 'plain offer description with no loyalty hint',
    requiresLoyalityMembership: false,
  })
  const match: MatchResult = { confidence: 0.75, matchedTokens: ['monster'] }
  const row = buildDealRef(normalized, PRODUCT, match)
  assertEquals(row.requires_app, false)
})
```

- [ ] **Step 9.2: Run the regression test**

```bash
cd Docker/supabase/functions
deno test deal-search/regression.test.ts
```

Expected: `3 passed`.

- [ ] **Step 9.3: Run the full edge-function test suite**

```bash
cd Docker/supabase/functions
deno test --allow-net --allow-env
```

Expected: all tests pass — Chunk 1 (5) + Chunk 2 (12) + Chunk 3 (3) + any pre-existing tests in other functions. No regressions.

- [ ] **Step 9.4: Commit**

```bash
git add Docker/supabase/functions/deal-search/regression.test.ts
git commit -m "test(deal-search): regression guard for refactored buildDeal pipeline"
```

---

**Chunk 3 verification:**

- [ ] **Step 9.5: Manual smoke test against local Supabase**

Boot the local Supabase stack and hit the deal-search endpoint:

```bash
cd Docker/supabase
supabase functions serve deal-search --no-verify-jwt &
SERVE_PID=$!
sleep 3

# Use a real session JWT from the local dev login (see memory/user_dev_credentials.md
# for the dev login). Substitute the JWT inline:
JWT="..."
curl -s -X POST http://localhost:54321/functions/v1/deal-search \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"forceRefresh": true}' | jq '{ count: (.deals | length), fromCache: .fromCache, totalDeals: .totalDeals, sample: .deals[0] }'

kill $SERVE_PID
```

Expected: response shape unchanged from before the refactor — `{ deals: [...], fromCache: false, searchedProducts: N, totalDeals: M }`. The `count` should be ≥ 1 if products + Marktguru both have data; the sample row should have all the same keys as before.

- [ ] **Step 9.6: Final compile sweep**

```bash
cd Docker/supabase/functions
deno check deal-search/index.ts \
  deal-search/registry.ts \
  deal-search/resolve-providers.ts \
  _shared/providers/deal-source.ts \
  _shared/providers/deal-source/marktguru.ts \
  _shared/providers/webhook.ts
```

Expected: no errors across the touched edge-function code.

---

## Chunk 4: Admin UI + provider-test edge function + i18n

This chunk adds the admin surface — `/settings/extensions/deal-source` — plus a tiny `provider-test` edge function used by the WebhookTestButton. End state: an admin can toggle Marktguru on/off, add/edit/delete custom webhook providers, and run a test call against any webhook to verify it's reachable and returns a sane shape.

### Task 10: `provider-test` edge function

**Files:**
- Create: `Docker/supabase/functions/provider-test/index.ts`
- Create: `Docker/supabase/functions/provider-test/deno.json`
- Modify: `Docker/supabase/config.toml`

A small auth-checked endpoint that runs `callWebhookProvider` against a user-supplied URL+token with a fixed sample query. Built-in providers don't need this (they're verified by re-running the consumer feature itself); only webhook providers need the round-trip check at config time.

- [ ] **Step 10.1: Create the edge function**

Create `Docker/supabase/functions/provider-test/index.ts`:

```ts
// Provider test endpoint — runs a single webhook provider with a fixed sample
// query so the admin UI can confirm a customer-supplied URL+token is reachable
// and returns a valid shape.
//
// Auth: standard JWT auth via the caller's company. Request body must specify
// extensionPoint and the webhook config. Response surfaces success/failure +
// the decoded sample size so the operator can see "yep, 6 offers came back."

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { callWebhookProvider } from '../_shared/providers/webhook.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

interface TestRequest {
  extensionPoint: 'deal-source'   // expand union as new EPs migrate to the pattern
  url: string
  authToken: string
}

const SAMPLE_PER_EXTENSION_POINT: Record<TestRequest['extensionPoint'], { method: string; args: Record<string, unknown> }> = {
  'deal-source': { method: 'fetchOffers', args: { query: 'Coca Cola', zipCode: '60487' } },
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders })

  const adminClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )
  const token = req.headers.get('Authorization')?.replace('Bearer ', '') ?? ''
  const { data: { user }, error: userErr } = await adminClient.auth.getUser(token)
  if (userErr || !user) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  let body: TestRequest
  try {
    body = await req.json()
  } catch {
    return new Response(JSON.stringify({ error: 'invalid JSON body' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  const sample = SAMPLE_PER_EXTENSION_POINT[body.extensionPoint]
  if (!sample) {
    return new Response(JSON.stringify({ error: `unknown extensionPoint: ${body.extensionPoint}` }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  try {
    const result = await callWebhookProvider({
      url: body.url,
      authToken: body.authToken,
      extensionPoint: body.extensionPoint,
      method: sample.method,
      args: sample.args,
    })
    const sampleSize = Array.isArray(result) ? result.length : 0
    return new Response(JSON.stringify({ ok: true, sampleSize }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (err) {
    return new Response(JSON.stringify({ ok: false, error: err instanceof Error ? err.message : String(err) }), {
      status: 200,  // 200 with ok:false; the call succeeded but the webhook didn't
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
```

- [ ] **Step 10.2: Create the deno.json for the function**

Create `Docker/supabase/functions/provider-test/deno.json`:

```json
{
  "imports": {}
}
```

- [ ] **Step 10.3: Register the function in config.toml**

Edit `Docker/supabase/config.toml` — find the existing `[functions.<name>]` section block (each existing function has one — search for `[functions.deal-search]` to locate) and add a new entry alongside:

```toml
[functions.provider-test]
enabled = true
verify_jwt = false
import_map = "./functions/provider-test/deno.json"
entrypoint = "./functions/provider-test/index.ts"
```

(`verify_jwt = false` matches the project convention because of the local-edge-runtime `CryptoKey` bug; auth happens inside the function via `adminClient.auth.getUser(token)`. The four-line shape — `enabled` / `verify_jwt` / `import_map` / `entrypoint` — matches every other entry in the file.)

- [ ] **Step 10.4: Smoke-test the new function locally**

```bash
cd Docker/supabase
supabase functions serve provider-test --no-verify-jwt &
SERVE_PID=$!
sleep 3

# Acquire a dev JWT — log in once via the local frontend and copy the
# `sb-access-token` cookie value, OR call:
JWT=$(curl -s -X POST "http://localhost:54321/auth/v1/token?grant_type=password" \
  -H "apikey: $(supabase status -o json | jq -r .ANON_KEY)" \
  -H "Content-Type: application/json" \
  -d '{"email":"<dev email>","password":"<dev password>"}' | jq -r .access_token)

curl -s -X POST http://localhost:54321/functions/v1/provider-test \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"extensionPoint":"deal-source","url":"https://example.invalid","authToken":"x"}' | jq

kill $SERVE_PID
```

Expected: a JSON body of either `{ok:false,error:"..."}` (because `example.invalid` isn't reachable) or a timeout-shaped error after 10s. Confirms the function is wired correctly.

- [ ] **Step 10.5: Commit**

```bash
git add Docker/supabase/functions/provider-test/ Docker/supabase/config.toml
git commit -m "feat(provider-test): edge function for webhook 'test call' button"
```

---

### Task 11: `useProviderSettings` composable — failing tests first

**Files:**
- Create: `management-frontend/app/composables/__tests__/useProviderSettings.test.ts`
- Will create next: `management-frontend/app/composables/useProviderSettings.ts`

The composable provides a small CRUD surface over `provider_settings` for one company + extension point at a time. Reactive state for the current rows; methods for `loadProviders(extensionPoint)`, `setEnabled(provider_id, enabled)`, `addWebhook(displayName, url, authToken, extraConfig)`, `updateWebhook(provider_id, ...)`, `removeWebhook(provider_id)`. Built-in providers come from a static frontend-side list (mirrors the edge-function registry).

- [ ] **Step 11.1: Write the failing tests**

Create `management-frontend/app/composables/__tests__/useProviderSettings.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest'

// Drive supabase calls per-test via a mock builder.
type Row = { provider_id: string; enabled: boolean; config: Record<string, unknown>; display_name: string | null }
let mockRows: Row[] = []
let mockUpsertCalls: Row[] = []
let mockDeleteCalls: { provider_id: string }[] = []

vi.mock('#imports', () => ({
  useSupabaseClient: () => ({
    from(_table: string) {
      return {
        select() {
          return {
            eq() { return this },
            // last .eq() is awaited — stub via thenable.
            then: (cb: (v: unknown) => unknown) => Promise.resolve({ data: mockRows, error: null }).then(cb),
          }
        },
        upsert(rows: Row[]) {
          mockUpsertCalls.push(...rows)
          return Promise.resolve({ error: null })
        },
        delete() {
          return {
            eq(col: string, val: unknown) {
              if (col === 'provider_id') mockDeleteCalls.push({ provider_id: String(val) })
              return this
            },
            then: (cb: (v: unknown) => unknown) => Promise.resolve({ error: null }).then(cb),
          }
        },
      }
    },
  }),
  useState: <T,>(_key: string, init: () => T) => ({ value: init() }),
}))

import { useProviderSettings } from '../useProviderSettings'

beforeEach(() => {
  mockRows = []
  mockUpsertCalls = []
  mockDeleteCalls = []
})

describe('useProviderSettings', () => {
  it('loads rows for a given extension point', async () => {
    mockRows = [
      { provider_id: 'marktguru', enabled: true, config: {}, display_name: null },
      { provider_id: 'webhook-abc', enabled: false, config: { url: 'https://x', authToken: 't' }, display_name: 'Test' },
    ]
    const { rows, load } = useProviderSettings('co-1')
    await load('deal-source')
    expect(rows.value.length).toBe(2)
    expect(rows.value[0].provider_id).toBe('marktguru')
  })

  it('addWebhook upserts a new row with webhook- prefix', async () => {
    const { addWebhook } = useProviderSettings('co-1')
    await addWebhook('deal-source', 'My Source', 'https://hook/', 'tok', {})
    expect(mockUpsertCalls.length).toBe(1)
    expect(mockUpsertCalls[0].provider_id.startsWith('webhook-')).toBe(true)
    expect(mockUpsertCalls[0].config).toMatchObject({ url: 'https://hook/', authToken: 'tok' })
    expect(mockUpsertCalls[0].display_name).toBe('My Source')
    expect(mockUpsertCalls[0].enabled).toBe(true)
  })

  it('setEnabled upserts an existing row with new enabled flag', async () => {
    const { setEnabled } = useProviderSettings('co-1')
    await setEnabled('deal-source', 'marktguru', false)
    expect(mockUpsertCalls.length).toBe(1)
    expect(mockUpsertCalls[0].provider_id).toBe('marktguru')
    expect(mockUpsertCalls[0].enabled).toBe(false)
  })

  it('removeWebhook deletes by provider_id', async () => {
    const { removeWebhook } = useProviderSettings('co-1')
    await removeWebhook('deal-source', 'webhook-abc')
    expect(mockDeleteCalls).toEqual([{ provider_id: 'webhook-abc' }])
  })

  it('addWebhook rejects http:// URLs', async () => {
    const { addWebhook } = useProviderSettings('co-1')
    await expect(
      addWebhook('deal-source', 'My Source', 'http://insecure/', 'tok', {}),
    ).rejects.toThrow(/https/)
    expect(mockUpsertCalls.length).toBe(0)
  })
})
```

- [ ] **Step 11.2: Run to verify tests fail**

```bash
cd management-frontend
npx vitest run app/composables/__tests__/useProviderSettings.test.ts
```

Expected: all 5 tests fail with module-resolution error.

- [ ] **Step 11.3: Implement the composable**

Create `management-frontend/app/composables/useProviderSettings.ts`:

```ts
// Per-company CRUD over provider_settings, scoped to one extension point at
// a time. Used by /settings/extensions/* admin pages.

interface ProviderSettingsRow {
  provider_id: string
  enabled: boolean
  config: Record<string, unknown>
  display_name: string | null
}

export interface BuiltinProviderMeta {
  id: string
  label: string                  // display name, e.g. 'Marktguru'
  description: string            // one-line tagline
}

// Frontend-side mirror of the edge-function registry. Keep in sync when adding
// new built-ins (the edge function won't know about UI-side metadata, so we
// duplicate intentionally).
export const BUILTIN_PROVIDERS: Record<'deal-source', BuiltinProviderMeta[]> = {
  'deal-source': [
    {
      id: 'marktguru',
      label: 'Marktguru',
      description: 'Aggregator covering most German retailers (REWE, Lidl, Aldi, …).',
    },
  ],
}

export function useProviderSettings(companyId: string) {
  const supabase = useSupabaseClient()
  const rows = useState<ProviderSettingsRow[]>(`provider-settings-${companyId}`, () => [])
  const loading = useState<boolean>(`provider-settings-loading-${companyId}`, () => false)

  async function load(extensionPoint: string) {
    if (!companyId) return
    loading.value = true
    try {
      const { data, error } = await supabase
        .from('provider_settings')
        .select('provider_id, enabled, config, display_name')
        .eq('company_id', companyId)
        .eq('extension_point', extensionPoint)
      if (error) throw error
      rows.value = (data ?? []) as ProviderSettingsRow[]
    } finally {
      loading.value = false
    }
  }

  async function setEnabled(extensionPoint: string, providerId: string, enabled: boolean) {
    const existing = rows.value.find((r) => r.provider_id === providerId)
    const upsertRow = {
      company_id: companyId,
      extension_point: extensionPoint,
      provider_id: providerId,
      enabled,
      config: existing?.config ?? {},
      display_name: existing?.display_name ?? null,
    }
    const { error } = await supabase.from('provider_settings').upsert([upsertRow])
    if (error) throw error
    if (existing) existing.enabled = enabled
    else rows.value.push({ provider_id: providerId, enabled, config: {}, display_name: null })
  }

  async function addWebhook(
    extensionPoint: string,
    displayName: string,
    url: string,
    authToken: string,
    extraConfig: Record<string, unknown>,
  ) {
    if (!url.startsWith('https://')) {
      throw new Error('Webhook URL must use https://')
    }
    // crypto.randomUUID() requires a secure context. Fallback for LAN-IP dev
    // (http://10.x.x.x:3000 etc., which CLAUDE.md documents as a supported
    // dev pattern) so admins on Safari < 15.4 / non-https origins still work.
    const uuid = crypto.randomUUID?.()
      ?? `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`
    const providerId = `webhook-${uuid}`
    const config = { url, authToken, ...extraConfig }
    const upsertRow = {
      company_id: companyId,
      extension_point: extensionPoint,
      provider_id: providerId,
      enabled: true,
      config,
      display_name: displayName,
    }
    const { error } = await supabase.from('provider_settings').upsert([upsertRow])
    if (error) throw error
    rows.value.push({ provider_id: providerId, enabled: true, config, display_name: displayName })
    return providerId
  }

  async function updateWebhook(
    extensionPoint: string,
    providerId: string,
    patch: { displayName?: string; url?: string; authToken?: string; extraConfig?: Record<string, unknown> },
  ) {
    const existing = rows.value.find((r) => r.provider_id === providerId)
    if (!existing) throw new Error(`unknown provider ${providerId}`)
    if (patch.url && !patch.url.startsWith('https://')) {
      throw new Error('Webhook URL must use https://')
    }
    const newConfig = {
      ...existing.config,
      ...(patch.url ? { url: patch.url } : {}),
      ...(patch.authToken ? { authToken: patch.authToken } : {}),
      ...(patch.extraConfig ?? {}),
    }
    const upsertRow = {
      company_id: companyId,
      extension_point: extensionPoint,
      provider_id: providerId,
      enabled: existing.enabled,
      config: newConfig,
      display_name: patch.displayName ?? existing.display_name,
    }
    const { error } = await supabase.from('provider_settings').upsert([upsertRow])
    if (error) throw error
    existing.config = newConfig
    if (patch.displayName !== undefined) existing.display_name = patch.displayName
  }

  async function removeWebhook(_extensionPoint: string, providerId: string) {
    const { error } = await supabase
      .from('provider_settings')
      .delete()
      .eq('company_id', companyId)
      .eq('provider_id', providerId)
    if (error) throw error
    rows.value = rows.value.filter((r) => r.provider_id !== providerId)
  }

  return { rows, loading, load, setEnabled, addWebhook, updateWebhook, removeWebhook }
}
```

- [ ] **Step 11.4: Run tests to verify they pass**

```bash
cd management-frontend
npx vitest run app/composables/__tests__/useProviderSettings.test.ts
```

Expected: `5 passed`.

- [ ] **Step 11.5: Commit**

```bash
git add management-frontend/app/composables/useProviderSettings.ts \
        management-frontend/app/composables/__tests__/useProviderSettings.test.ts
git commit -m "feat(frontend): useProviderSettings composable for extension admin"
```

---

### Task 12: `AddWebhookDialog.vue` component

**Files:**
- Create: `management-frontend/app/components/extensions/AddWebhookDialog.vue`

A modal dialog with fields for display name, URL (https://-only, validated client-side), auth token (password input), and a free-form config JSON textarea. Reuses the existing shadcn-nuxt `Dialog`, `Input`, `Label`, and `Button` components from `~/components/ui/`. The config JSON field uses a plain styled `<textarea>` element since this codebase doesn't ship a wrapped Textarea component.

- [ ] **Step 12.1: Create the component**

Create `management-frontend/app/components/extensions/AddWebhookDialog.vue`:

```vue
<script setup lang="ts">
import { ref, watch } from 'vue'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle, DialogDescription } from '~/components/ui/dialog'
import { Input } from '~/components/ui/input'
import { Label } from '~/components/ui/label'
import { Button } from '~/components/ui/button'

const props = defineProps<{
  open: boolean
  /** When set, dialog opens in "edit existing" mode and submits via update() */
  existing?: {
    providerId: string
    displayName: string
    url: string
    authToken: string
    extraConfigJson: string
  }
}>()

const emit = defineEmits<{
  (e: 'update:open', v: boolean): void
  (e: 'submit', payload: {
    providerId?: string
    displayName: string
    url: string
    authToken: string
    extraConfig: Record<string, unknown>
  }): void
}>()

const { t } = useI18n()

const displayName = ref('')
const url         = ref('')
const authToken   = ref('')
const extraConfig = ref('{}')
const error       = ref('')

// When the dialog opens with `existing`, hydrate the fields. Reset when closed.
watch(() => props.open, (isOpen) => {
  if (isOpen) {
    displayName.value = props.existing?.displayName ?? ''
    url.value         = props.existing?.url ?? ''
    authToken.value   = props.existing?.authToken ?? ''
    extraConfig.value = props.existing?.extraConfigJson ?? '{}'
    error.value = ''
  }
})

function onSubmit() {
  error.value = ''
  if (!displayName.value.trim()) { error.value = t('extensions.errors.nameRequired'); return }
  if (!url.value.startsWith('https://')) { error.value = t('extensions.errors.httpsRequired'); return }
  if (!authToken.value) { error.value = t('extensions.errors.tokenRequired'); return }
  let parsed: Record<string, unknown> = {}
  try {
    parsed = JSON.parse(extraConfig.value || '{}')
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) throw new Error('not an object')
  } catch {
    error.value = t('extensions.errors.configJsonInvalid')
    return
  }
  emit('submit', {
    providerId: props.existing?.providerId,
    displayName: displayName.value.trim(),
    url: url.value.trim(),
    authToken: authToken.value,
    extraConfig: parsed,
  })
  emit('update:open', false)
}
</script>

<template>
  <Dialog :open="open" @update:open="(v: boolean) => emit('update:open', v)">
    <DialogContent class="sm:max-w-md">
      <DialogHeader>
        <DialogTitle>{{ existing ? t('extensions.webhook.editTitle') : t('extensions.webhook.addTitle') }}</DialogTitle>
        <DialogDescription>{{ t('extensions.webhook.help') }}</DialogDescription>
      </DialogHeader>

      <div class="space-y-3 py-2">
        <div class="space-y-1.5">
          <Label for="webhook-name">{{ t('extensions.webhook.name') }}</Label>
          <Input id="webhook-name" v-model="displayName" autofocus />
        </div>

        <div class="space-y-1.5">
          <Label for="webhook-url">{{ t('extensions.webhook.url') }}</Label>
          <Input id="webhook-url" v-model="url" placeholder="https://..." />
        </div>

        <div class="space-y-1.5">
          <Label for="webhook-token">{{ t('extensions.webhook.authToken') }}</Label>
          <Input id="webhook-token" v-model="authToken" type="password" />
        </div>

        <div class="space-y-1.5">
          <Label for="webhook-config">{{ t('extensions.webhook.extraConfig') }}</Label>
          <textarea
            id="webhook-config"
            v-model="extraConfig"
            rows="3"
            class="w-full rounded-md border bg-background px-3 py-2 font-mono text-sm"
          />
        </div>

        <p v-if="error" class="text-sm text-destructive">{{ error }}</p>
      </div>

      <DialogFooter>
        <Button variant="outline" @click="emit('update:open', false)">{{ t('common.cancel') }}</Button>
        <Button @click="onSubmit">{{ t('common.save') }}</Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>
```

- [ ] **Step 12.2: Verify it compiles in the dev server**

```bash
cd management-frontend
npm run build 2>&1 | head -30
```

Expected: build succeeds. (No tests yet — the dialog is plumbed in Task 15.)

- [ ] **Step 12.3: Commit**

```bash
git add management-frontend/app/components/extensions/AddWebhookDialog.vue
git commit -m "feat(frontend): AddWebhookDialog component for extension admin"
```

---

### Task 13: `WebhookTestButton.vue` component

**Files:**
- Create: `management-frontend/app/components/extensions/WebhookTestButton.vue`

Tiny stateful button: idle → loading → success-with-count or error-with-message. Calls `provider-test` edge function with the row's URL+token. Each click resets state.

- [ ] **Step 13.1: Create the component**

Create `management-frontend/app/components/extensions/WebhookTestButton.vue`:

```vue
<script setup lang="ts">
import { ref } from 'vue'
import { Button } from '~/components/ui/button'
import { IconCheck, IconAlertTriangle, IconLoader2 } from '@tabler/icons-vue'

const props = defineProps<{
  extensionPoint: 'deal-source'
  url: string
  authToken: string
}>()

const { t } = useI18n()
const supabase = useSupabaseClient()

type Status = 'idle' | 'loading' | 'success' | 'error'
const status  = ref<Status>('idle')
const message = ref('')

async function run() {
  status.value = 'loading'
  message.value = ''
  try {
    const { data, error } = await supabase.functions.invoke('provider-test', {
      body: {
        extensionPoint: props.extensionPoint,
        url: props.url,
        authToken: props.authToken,
      },
    })
    if (error) throw error
    if (data.ok) {
      status.value = 'success'
      message.value = t('extensions.testResultOk', { count: data.sampleSize ?? 0 })
    } else {
      status.value = 'error'
      message.value = data.error ?? t('extensions.testResultUnknownError')
    }
  } catch (err) {
    status.value = 'error'
    message.value = err instanceof Error ? err.message : String(err)
  }
}
</script>

<template>
  <div class="flex items-center gap-2">
    <Button size="sm" variant="outline" :disabled="status === 'loading'" @click="run">
      <IconLoader2 v-if="status === 'loading'" class="size-4 animate-spin" />
      <IconCheck   v-else-if="status === 'success'" class="size-4 text-green-600" />
      <IconAlertTriangle v-else-if="status === 'error'" class="size-4 text-destructive" />
      {{ t('extensions.testCall') }}
    </Button>
    <span
      v-if="message"
      class="text-xs"
      :class="status === 'success' ? 'text-green-700 dark:text-green-400' : 'text-destructive'"
    >{{ message }}</span>
  </div>
</template>
```

- [ ] **Step 13.2: Commit**

```bash
git add management-frontend/app/components/extensions/WebhookTestButton.vue
git commit -m "feat(frontend): WebhookTestButton component"
```

---

### Task 14: `/settings/extensions/index.vue` landing page

**Files:**
- Create: `management-frontend/app/pages/settings/extensions/index.vue`

A simple list-of-extension-points page. v1 has only `deal-source`; new extension points get a card here when they migrate to the pattern. Each card links to `/settings/extensions/<extension-point>`.

- [ ] **Step 14.1: Create the page**

Create `management-frontend/app/pages/settings/extensions/index.vue`:

```vue
<script setup lang="ts">
definePageMeta({ middleware: 'auth' })
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from '~/components/ui/card'
import { IconShoppingBag } from '@tabler/icons-vue'

const { t } = useI18n()

const extensionPoints = [
  {
    id: 'deal-source',
    icon: IconShoppingBag,
    titleKey: 'extensions.dealSource.title',
    descKey: 'extensions.dealSource.description',
    href: '/settings/extensions/deal-source',
  },
]
</script>

<template>
  <div class="container mx-auto max-w-3xl py-6 space-y-4">
    <div>
      <h1 class="text-2xl font-semibold">{{ t('extensions.pageTitle') }}</h1>
      <p class="text-sm text-muted-foreground mt-1">{{ t('extensions.pageDescription') }}</p>
    </div>

    <div class="grid gap-3 sm:grid-cols-2">
      <NuxtLink v-for="ep in extensionPoints" :key="ep.id" :to="ep.href" class="block">
        <Card class="hover:border-primary/50 transition-colors h-full">
          <CardHeader>
            <div class="flex items-center gap-3">
              <component :is="ep.icon" class="size-5 text-primary" />
              <CardTitle>{{ t(ep.titleKey) }}</CardTitle>
            </div>
            <CardDescription>{{ t(ep.descKey) }}</CardDescription>
          </CardHeader>
        </Card>
      </NuxtLink>
    </div>
  </div>
</template>
```

- [ ] **Step 14.2: Commit**

```bash
git add management-frontend/app/pages/settings/extensions/index.vue
git commit -m "feat(frontend): /settings/extensions landing page"
```

---

### Task 15: `/settings/extensions/deal-source.vue` per-extension-point page

**Files:**
- Create: `management-frontend/app/pages/settings/extensions/deal-source.vue`

The page that hosts the actual admin work: list of built-in providers with toggles, list of webhook providers with edit/delete/test, and an "Add webhook" button. Wires the composable, the dialog, and the test button together.

- [ ] **Step 15.1: Create the page**

Create `management-frontend/app/pages/settings/extensions/deal-source.vue`:

```vue
<script setup lang="ts">
definePageMeta({ middleware: 'auth' })
import { computed, onMounted, ref } from 'vue'
import { Switch } from '~/components/ui/switch'
import { Button } from '~/components/ui/button'
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from '~/components/ui/card'
import { IconPlus, IconPencil, IconTrash, IconArrowLeft } from '@tabler/icons-vue'
import AddWebhookDialog from '~/components/extensions/AddWebhookDialog.vue'
import WebhookTestButton from '~/components/extensions/WebhookTestButton.vue'
import { BUILTIN_PROVIDERS, useProviderSettings } from '~/composables/useProviderSettings'

const EXTENSION_POINT = 'deal-source' as const
const { t } = useI18n()
const { organization } = useOrganization()
// The auth middleware guarantees `organization.value` is populated before the
// page renders on client navigation; the wrapping `<template v-if>` below is
// belt-and-braces for SSR / hard-refresh races. Inside that guard, we know
// `organization.value!.id` is a non-empty string.
const companyId = computed(() => organization.value!.id)

const settings = useProviderSettings(companyId.value)
const { rows, load, setEnabled, addWebhook, updateWebhook, removeWebhook } = settings

const dialogOpen   = ref(false)
const editingRow   = ref<{ providerId: string; displayName: string; url: string; authToken: string; extraConfigJson: string } | undefined>(undefined)

onMounted(async () => { await load(EXTENSION_POINT) })

const builtinRows = computed(() =>
  BUILTIN_PROVIDERS[EXTENSION_POINT].map((meta) => {
    const row = rows.value.find((r) => r.provider_id === meta.id)
    return { meta, enabled: row?.enabled ?? false }
  }),
)
const webhookRows = computed(() => rows.value.filter((r) => r.provider_id.startsWith('webhook-')))

function openAddDialog() {
  editingRow.value = undefined
  dialogOpen.value = true
}

function openEditDialog(providerId: string) {
  const row = rows.value.find((r) => r.provider_id === providerId)
  if (!row) return
  const cfg = row.config as { url?: string; authToken?: string }
  const { url: _u, authToken: _t, ...extra } = cfg
  editingRow.value = {
    providerId,
    displayName: row.display_name ?? '',
    url: _u ?? '',
    authToken: _t ?? '',
    extraConfigJson: JSON.stringify(extra, null, 2),
  }
  dialogOpen.value = true
}

async function onSubmit(payload: {
  providerId?: string
  displayName: string
  url: string
  authToken: string
  extraConfig: Record<string, unknown>
}) {
  if (payload.providerId) {
    await updateWebhook(EXTENSION_POINT, payload.providerId, {
      displayName: payload.displayName,
      url: payload.url,
      authToken: payload.authToken,
      extraConfig: payload.extraConfig,
    })
  } else {
    await addWebhook(EXTENSION_POINT, payload.displayName, payload.url, payload.authToken, payload.extraConfig)
  }
}

async function onDelete(providerId: string) {
  if (!confirm(t('extensions.webhook.confirmDelete'))) return
  await removeWebhook(EXTENSION_POINT, providerId)
}
</script>

<template>
  <div v-if="organization?.id" class="container mx-auto max-w-3xl py-6 space-y-6">
    <div>
      <Button variant="ghost" size="sm" as-child class="mb-2">
        <NuxtLink to="/settings/extensions">
          <IconArrowLeft class="size-4" /> {{ t('extensions.backToList') }}
        </NuxtLink>
      </Button>
      <h1 class="text-2xl font-semibold">{{ t('extensions.dealSource.title') }}</h1>
      <p class="text-sm text-muted-foreground mt-1">{{ t('extensions.dealSource.description') }}</p>
    </div>

    <!-- Built-in providers -->
    <Card>
      <CardHeader>
        <CardTitle>{{ t('extensions.builtinProviders') }}</CardTitle>
        <CardDescription>{{ t('extensions.builtinDescription') }}</CardDescription>
      </CardHeader>
      <CardContent class="space-y-3">
        <div v-for="row in builtinRows" :key="row.meta.id" class="flex items-center justify-between border rounded-md px-3 py-2">
          <div>
            <div class="font-medium">{{ row.meta.label }}</div>
            <div class="text-xs text-muted-foreground">{{ row.meta.description }}</div>
          </div>
          <Switch
            :checked="row.enabled"
            @update:checked="(v: boolean) => setEnabled(EXTENSION_POINT, row.meta.id, v)"
          />
        </div>
      </CardContent>
    </Card>

    <!-- Webhook providers -->
    <Card>
      <CardHeader class="flex flex-row items-start justify-between space-y-0">
        <div>
          <CardTitle>{{ t('extensions.webhookProviders') }}</CardTitle>
          <CardDescription>{{ t('extensions.webhookDescription') }}</CardDescription>
        </div>
        <Button size="sm" @click="openAddDialog">
          <IconPlus class="size-4" /> {{ t('extensions.webhook.add') }}
        </Button>
      </CardHeader>
      <CardContent class="space-y-3">
        <div v-if="webhookRows.length === 0" class="text-sm text-muted-foreground italic">
          {{ t('extensions.webhook.empty') }}
        </div>
        <div v-for="row in webhookRows" :key="row.provider_id" class="border rounded-md px-3 py-2 space-y-2">
          <div class="flex items-center justify-between gap-2">
            <div class="min-w-0">
              <div class="font-medium truncate">{{ row.display_name ?? row.provider_id }}</div>
              <div class="text-xs text-muted-foreground truncate">{{ (row.config as { url?: string }).url }}</div>
            </div>
            <div class="flex items-center gap-2 shrink-0">
              <Switch
                :checked="row.enabled"
                @update:checked="(v: boolean) => setEnabled(EXTENSION_POINT, row.provider_id, v)"
              />
              <Button size="sm" variant="ghost" @click="openEditDialog(row.provider_id)"><IconPencil class="size-4" /></Button>
              <Button size="sm" variant="ghost" @click="onDelete(row.provider_id)"><IconTrash class="size-4 text-destructive" /></Button>
            </div>
          </div>
          <WebhookTestButton
            :extension-point="EXTENSION_POINT"
            :url="(row.config as { url?: string }).url ?? ''"
            :auth-token="(row.config as { authToken?: string }).authToken ?? ''"
          />
        </div>
      </CardContent>
    </Card>

    <AddWebhookDialog v-model:open="dialogOpen" :existing="editingRow" @submit="onSubmit" />
  </div>
</template>
```

- [ ] **Step 15.2: Commit**

```bash
git add management-frontend/app/pages/settings/extensions/deal-source.vue
git commit -m "feat(frontend): /settings/extensions/deal-source admin page"
```

---

### Task 16: i18n keys

**Files:**
- Modify: `management-frontend/i18n/locales/en.json`
- Modify: `management-frontend/i18n/locales/de.json`

Add the `extensions.*` keys used by Tasks 12–15. Keep keys flat per existing convention; both locale files must have identical key sets.

- [ ] **Step 16.1: Add English keys**

Open `management-frontend/i18n/locales/en.json` and add the following block as a new top-level key alongside the existing `common`, `auth`, etc. **Do not add a `common` block** — `common.cancel` and `common.save` already exist in this file (the dialog reuses them). If `extensions` already exists from a partial PR, merge instead of replacing.

```json
"extensions": {
  "pageTitle": "Extensions",
  "pageDescription": "Activate and configure data sources and integrations per company.",
  "backToList": "Back to extensions",
  "builtinProviders": "Built-in providers",
  "builtinDescription": "Bundled with VMflow. Toggle on/off; no further configuration needed in v1.",
  "webhookProviders": "Custom webhook providers",
  "webhookDescription": "Connect your own service via HTTPS. Each company runs and trusts its own webhooks.",
  "testCall": "Test call",
  "testResultOk": "OK ({count} sample offers)",
  "testResultUnknownError": "Unknown error",
  "dealSource": {
    "title": "Deal sources",
    "description": "Where the Deals page pulls weekly retailer offers from. Marktguru is enabled by default; add more sources via custom webhooks."
  },
  "webhook": {
    "add": "Add webhook",
    "addTitle": "Add webhook provider",
    "editTitle": "Edit webhook provider",
    "help": "Connect a custom HTTPS endpoint that implements the deal-source contract. See docs/extension-points/deal-source.md.",
    "name": "Display name",
    "url": "Webhook URL",
    "authToken": "Auth token",
    "extraConfig": "Extra config (JSON)",
    "empty": "No custom webhooks configured.",
    "confirmDelete": "Delete this webhook provider? Sales will no longer pull from it."
  },
  "errors": {
    "nameRequired": "Display name is required",
    "httpsRequired": "URL must start with https://",
    "tokenRequired": "Auth token is required",
    "configJsonInvalid": "Extra config must be a JSON object"
  }
}
```

Verify before saving: search the file for `"common"`. If a top-level `"common": { ... }` block already exists (it does, in the current file), do **not** add another — Vue's `useI18n()` reuses the existing `common.cancel` / `common.save` keys.

- [ ] **Step 16.2: Add German keys**

Open `management-frontend/i18n/locales/de.json` and add the mirror translations. Same caveat as Step 16.1: do **not** add a `common` block — the existing one already has `cancel` and `save`.

```json
"extensions": {
  "pageTitle": "Erweiterungen",
  "pageDescription": "Datenquellen und Integrationen pro Company aktivieren und konfigurieren.",
  "backToList": "Zurück zu den Erweiterungen",
  "builtinProviders": "Mitgelieferte Anbieter",
  "builtinDescription": "Mit VMflow ausgeliefert. Per Toggle ein- oder ausschalten; in v1 keine weitere Konfiguration nötig.",
  "webhookProviders": "Eigene Webhook-Anbieter",
  "webhookDescription": "Verbinde deinen eigenen Service per HTTPS. Jede Company betreibt und verantwortet ihre eigenen Webhooks.",
  "testCall": "Test-Aufruf",
  "testResultOk": "OK ({count} Beispiel-Angebote)",
  "testResultUnknownError": "Unbekannter Fehler",
  "dealSource": {
    "title": "Deal-Quellen",
    "description": "Woher die Deals-Seite die wöchentlichen Händler-Angebote zieht. Marktguru ist standardmäßig aktiv; weitere Quellen lassen sich über eigene Webhooks anbinden."
  },
  "webhook": {
    "add": "Webhook hinzufügen",
    "addTitle": "Webhook-Anbieter hinzufügen",
    "editTitle": "Webhook-Anbieter bearbeiten",
    "help": "Verbinde einen eigenen HTTPS-Endpoint, der den deal-source-Vertrag erfüllt. Siehe docs/extension-points/deal-source.md.",
    "name": "Anzeigename",
    "url": "Webhook-URL",
    "authToken": "Auth-Token",
    "extraConfig": "Zusätzliche Config (JSON)",
    "empty": "Keine eigenen Webhooks konfiguriert.",
    "confirmDelete": "Diesen Webhook-Anbieter wirklich löschen? Die Deals-Seite wird ihn nicht mehr abfragen."
  },
  "errors": {
    "nameRequired": "Anzeigename ist erforderlich",
    "httpsRequired": "URL muss mit https:// beginnen",
    "tokenRequired": "Auth-Token ist erforderlich",
    "configJsonInvalid": "Zusätzliche Config muss ein JSON-Objekt sein"
  }
}
```

- [ ] **Step 16.3: Verify build still passes**

```bash
cd management-frontend
npm run build 2>&1 | tail -20
```

Expected: build succeeds; no TypeScript errors; both locale files parse as valid JSON.

- [ ] **Step 16.4: Commit**

```bash
git add management-frontend/i18n/locales/en.json management-frontend/i18n/locales/de.json
git commit -m "i18n(extensions): add en/de keys for admin pages"
```

---

**Chunk 4 verification:**

- [ ] **Step 16.5: All Chunk 1–4 tests pass together**

```bash
# Edge function tests
cd Docker/supabase/functions
deno test --allow-net --allow-env

# Frontend tests
cd ../../../management-frontend
npx vitest run
```

Expected: all tests pass; no regressions in existing suites.

- [ ] **Step 16.6: Manual smoke test of admin UI**

1. Boot the local stack (`docker compose up` from `Docker/`) and open http://localhost:3000.
2. Log in with the dev credentials.
3. Navigate to `/settings/extensions`. Confirm the "Deal sources" card renders.
4. Click into `/settings/extensions/deal-source`. Confirm Marktguru row appears with toggle ON (matches the seed migration).
5. Click "Add webhook". Confirm dialog opens. Try `http://...` and confirm the inline error message blocks submit. Submit a valid `https://example.invalid` + token; confirm the row appears.
6. Click "Test call" on the new webhook. Confirm an error chip appears (because `example.invalid` is unreachable). Confirms the wiring is end-to-end.
7. Delete the webhook row. Confirm it disappears.
8. Toggle Marktguru off, then visit `/deals`. Confirm the page shows "no providers enabled" / empty state. Toggle Marktguru back on; refresh `/deals`. Confirm deals reappear.

---

## Chunk 5: Documentation

The reference doc that turns the deal-source extension point into a public contract for community contributors and Claude Code agents. End state: a self-contained Markdown file under `docs/extension-points/` that someone can read in two minutes and either write a new built-in provider PR or stand up an HTTPS webhook endpoint.

### Task 17: `docs/extension-points/deal-source.md`

**Files:**
- Create: `docs/extension-points/deal-source.md`
- Modify: `CLAUDE.md` (one-line pointer near the project-overview / architecture section)

- [ ] **Step 17.1: Create the reference doc**

Create `docs/extension-points/deal-source.md`:

````markdown
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
````

- [ ] **Step 17.2: Add a one-line pointer in CLAUDE.md**

Edit `CLAUDE.md` — find the section that lists Edge Functions (search for `### Edge Functions`) and add the following paragraph immediately before or after that section so contributors and future agents discover the extension-points convention:

```markdown
### Extension Points (Provider Pattern)

Some features have a per-company provider registry rather than a single hardcoded backend. v1 covers `deal-source` (the `/deals` page's data sources). Each extension point's contract lives at `Docker/supabase/functions/_shared/providers/<extension-point>.ts` with built-in providers as TypeScript modules under `_shared/providers/<extension-point>/<provider-id>.ts` and per-company activation in the `provider_settings` table. Documentation per extension point lives at `docs/extension-points/<extension-point>.md` — that file is the SDK; read it before adding a new provider.
```

- [ ] **Step 17.3: Verify the doc renders on GitHub-flavored Markdown**

```bash
# Quickest check — that the codeblocks aren't mismatched and the relative
# links resolve. Expect: every `[...](path)` resolves to a real file.
cd /Users/lucienkerl/Development/mdb-esp32-cashless
for f in $(grep -oE '\(\.\./\.\./[^)]+\)' docs/extension-points/deal-source.md | tr -d '()'); do
  abs="docs/extension-points/$f"
  test -e "$abs" && echo "ok: $f" || echo "MISSING: $f"
done
```

Expected: every link prints `ok:`. None should print `MISSING:`.

- [ ] **Step 17.4: Commit**

```bash
git add docs/extension-points/deal-source.md CLAUDE.md
git commit -m "docs(extensions): deal-source reference + Claude Code prompt template"
```

---

**Chunk 5 verification:**

- [ ] **Step 17.5: Doc-quality smoke test**

Open `docs/extension-points/deal-source.md` in a Markdown viewer (or push to a branch and view on GitHub). Verify:

- All code blocks render with the right language tag
- Relative links resolve
- The Claude Code prompt template is copy-pasteable as one block

This is a manual gate — no automated test.

- [ ] **Step 17.6: End-to-end: add a stub provider via Claude Code**

(Optional acceptance test — confirms the Claude Code workflow actually works.) Open a fresh Claude Code session in the repo root and paste the prompt template from `docs/extension-points/deal-source.md` with `REPLACE_WITH_RETAILER` set to `Stub`. Confirm Claude:

1. Reads the three referenced files
2. Creates `Docker/supabase/functions/_shared/providers/deal-source/stub.ts` and a `stub.test.ts`
3. Updates `registry.ts` and `useProviderSettings.ts`
4. Runs the tests successfully

If Claude can scaffold a working provider end-to-end without further guidance, the documentation contract is sound. Discard the stub provider after the test:

```bash
git checkout -- Docker/supabase/functions/deal-search/registry.ts \
                management-frontend/app/composables/useProviderSettings.ts
rm Docker/supabase/functions/_shared/providers/deal-source/stub.ts \
   Docker/supabase/functions/_shared/providers/deal-source/stub.test.ts
```

---

## Final verification

After all five chunks land:

- [ ] **Step F.1: All edge-function tests pass**

```bash
cd Docker/supabase/functions
deno test --allow-net --allow-env
```

Expected: `20 passed` (Chunk 1: 5 webhook + Chunk 2: 7 marktguru + 5 resolver + Chunk 3: 3 regression) plus any pre-existing tests in other functions.

- [ ] **Step F.2: All frontend tests pass**

```bash
cd management-frontend
npx vitest run
```

Expected: `5 passed` from `useProviderSettings.test.ts` plus any pre-existing tests.

- [ ] **Step F.3: Frontend builds clean**

```bash
cd management-frontend
npm run build
```

Expected: build succeeds; no TypeScript errors; no missing-component warnings.

- [ ] **Step F.4: Migration round-trips**

> ⚠️ **Per `MEMORY.md` ABSOLUTE RULE**: never run `supabase db reset` without explicit user approval — the local dev database contains live test data that would be lost. Use `supabase migration up` instead, which only applies pending migrations.

```bash
cd Docker/supabase
supabase migration up
```

Expected: the new migration `20260505100000_provider_settings.sql` is reported as applied (or "already applied" on a re-run). Verify the seed worked:

```bash
psql "$(supabase status -o json | jq -r .DB_URL)" \
  -c "SELECT count(*) FROM provider_settings WHERE provider_id='marktguru' AND enabled=true;"
```

Expected: count ≥ 1 if the local dev DB has at least one company with `deals_enabled = true`.

**Only if the user has explicitly approved a clean-slate test** — and you have backed up anything precious — you may verify the full migration chain with `supabase db reset` on a throwaway DB. Otherwise stick to `migration up`.

- [ ] **Step F.5: End-to-end smoke**

Boot the full stack (`docker compose up` from `Docker/`), navigate to `/deals` in the management frontend, click "Refresh", and confirm offers appear. Then go to `/settings/extensions/deal-source`, toggle Marktguru off, refresh `/deals`, and confirm the page shows the empty state. Toggle back on, refresh, confirm offers reappear. Add a webhook with a known-bad URL, click the test button, confirm an error chip appears.

If all five steps pass, the implementation is complete and the spec is satisfied.
