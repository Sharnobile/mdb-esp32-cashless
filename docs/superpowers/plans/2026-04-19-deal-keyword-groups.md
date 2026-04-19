# Deal Keyword Groups Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users define named keyword groups on `/deals` with multiple search terms and linked products (M:N), so brand-wide offers (e.g. *"Haribo Fruchtgummis versch. Sorten"*) produce one deal card covering all linked products instead of N duplicated product cards — while preserving the existing product-name fuzzy-match pass.

**Architecture:** Hybrid matching in the `deal-search` edge function. Two new tables (`deal_keywords`, `deal_keyword_products`) plus additive `deal_cache` columns (`keyword_id`, `matched_term`). Keyword pass runs first; product-pass writes are suppressed for any product covered by a keyword hit on the same offer. All changes additive + backward-compatible; existing product-name matches are untouched.

**Tech Stack:** PostgreSQL 15.8 + Supabase RLS, Deno edge functions, Nuxt 4 + Vue 3 + shadcn-nuxt + TailwindCSS 4 + `@nuxtjs/i18n`, Vitest for frontend tests, Deno test for edge functions.

**Spec:** [docs/superpowers/specs/2026-04-19-deal-keyword-groups-design.md](../specs/2026-04-19-deal-keyword-groups-design.md)

**Skills to apply:** @superpowers:test-driven-development (where unit-testable) · @superpowers:verification-before-completion (before claiming a chunk done)

---

## Working rules for this plan

- **Never run `supabase db reset`** — it wipes the dev database. ABSOLUTE RULE. For migration verification use `supabase migration up` on the existing dev DB, or spin up a throwaway Supabase project in a scratch dir.
- **Migrations are immutable** — do NOT edit existing migration files. New migration only.
- **Commit after each green test / working step.** Small commits > big commits.
- Run frontend from `management-frontend/`. Run Supabase CLI from `Docker/supabase/`.

---

## Chunk 1: Database migration

### Task 1.1: Create migration file

**Files:**
- Create: `Docker/supabase/migrations/20260419000000_deal_keyword_groups.sql`

- [ ] **Step 1: Verify no later migration already uses this timestamp**

Run: `ls Docker/supabase/migrations/ | sort | tail -5`
Expected: The latest file is `20260413400000_deal_config_jsonb.sql` (or later, but none with timestamp `20260419*`).

- [ ] **Step 2: Create the migration file with full DDL**

Content — copy exactly:

```sql
-- =========================================================
-- Deal Keyword Groups
--
-- Hybrid matching layer on top of the existing product-name
-- fuzzy-match. Users define keyword groups on /deals with:
--   - optional display label
--   - one or more search terms (text[])
--   - a set of linked products (M:N)
--
-- One deal_cache row is written per (offer, keyword_group)
-- hit, so brand-wide offers (e.g. "Haribo versch. Sorten")
-- no longer duplicate across every catalog variant.
-- =========================================================


-- ─── A. deal_keywords (keyword groups) ─────────────────────

CREATE TABLE IF NOT EXISTS public.deal_keywords (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id  uuid        NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  label       text        NULL,
  terms       text[]      NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT deal_keywords_terms_not_empty
    CHECK (array_length(terms, 1) >= 1)
);

CREATE INDEX IF NOT EXISTS idx_deal_keywords_company ON public.deal_keywords(company_id);

CREATE OR REPLACE FUNCTION public.tg_deal_keywords_set_updated_at()
  RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS deal_keywords_set_updated_at ON public.deal_keywords;
CREATE TRIGGER deal_keywords_set_updated_at
  BEFORE UPDATE ON public.deal_keywords
  FOR EACH ROW EXECUTE FUNCTION public.tg_deal_keywords_set_updated_at();

ALTER TABLE public.deal_keywords ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "deal_keywords_select" ON public.deal_keywords;
CREATE POLICY "deal_keywords_select" ON public.deal_keywords
  FOR SELECT TO authenticated
  USING (company_id = public.my_company_id());

DROP POLICY IF EXISTS "deal_keywords_insert" ON public.deal_keywords;
CREATE POLICY "deal_keywords_insert" ON public.deal_keywords
  FOR INSERT TO authenticated
  WITH CHECK (company_id = public.my_company_id());

DROP POLICY IF EXISTS "deal_keywords_update" ON public.deal_keywords;
CREATE POLICY "deal_keywords_update" ON public.deal_keywords
  FOR UPDATE TO authenticated
  USING (company_id = public.my_company_id())
  WITH CHECK (company_id = public.my_company_id());

DROP POLICY IF EXISTS "deal_keywords_delete" ON public.deal_keywords;
CREATE POLICY "deal_keywords_delete" ON public.deal_keywords
  FOR DELETE TO authenticated
  USING (company_id = public.my_company_id());


-- ─── B. deal_keyword_products (M:N join) ───────────────────

CREATE TABLE IF NOT EXISTS public.deal_keyword_products (
  keyword_id  uuid        NOT NULL REFERENCES public.deal_keywords(id) ON DELETE CASCADE,
  product_id  uuid        NOT NULL REFERENCES public.products(id)      ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (keyword_id, product_id)
);

CREATE INDEX IF NOT EXISTS idx_deal_keyword_products_product
  ON public.deal_keyword_products(product_id);

ALTER TABLE public.deal_keyword_products ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "deal_keyword_products_select" ON public.deal_keyword_products;
CREATE POLICY "deal_keyword_products_select" ON public.deal_keyword_products
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.deal_keywords k
    WHERE k.id = deal_keyword_products.keyword_id
      AND k.company_id = public.my_company_id()
  ));

DROP POLICY IF EXISTS "deal_keyword_products_insert" ON public.deal_keyword_products;
CREATE POLICY "deal_keyword_products_insert" ON public.deal_keyword_products
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.deal_keywords k
    WHERE k.id = deal_keyword_products.keyword_id
      AND k.company_id = public.my_company_id()
  ));

DROP POLICY IF EXISTS "deal_keyword_products_delete" ON public.deal_keyword_products;
CREATE POLICY "deal_keyword_products_delete" ON public.deal_keyword_products
  FOR DELETE TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.deal_keywords k
    WHERE k.id = deal_keyword_products.keyword_id
      AND k.company_id = public.my_company_id()
  ));


-- ─── C. deal_cache extensions ──────────────────────────────

-- Drop the old single unique constraint; we replace it with two partial indexes below.
ALTER TABLE public.deal_cache DROP CONSTRAINT IF EXISTS deal_cache_unique;

-- New nullable columns for keyword-match rows.
ALTER TABLE public.deal_cache
  ADD COLUMN IF NOT EXISTS keyword_id   uuid NULL REFERENCES public.deal_keywords(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS matched_term text NULL;

-- product_id becomes nullable. DROP NOT NULL is idempotent (no-op if already nullable).
ALTER TABLE public.deal_cache ALTER COLUMN product_id DROP NOT NULL;

-- XOR: exactly one of product_id / keyword_id is set.
-- PostgreSQL has no "ADD CONSTRAINT IF NOT EXISTS" for CHECK, so DROP+ADD.
ALTER TABLE public.deal_cache DROP CONSTRAINT IF EXISTS deal_cache_product_xor_keyword;
ALTER TABLE public.deal_cache
  ADD CONSTRAINT deal_cache_product_xor_keyword
  CHECK ((product_id IS NOT NULL) <> (keyword_id IS NOT NULL));

-- Two partial unique indexes — back the two upsert conflict targets in the
-- edge function (split upsert pattern).
CREATE UNIQUE INDEX IF NOT EXISTS uq_deal_cache_product
  ON public.deal_cache (company_id, product_id, retailer, offer_id)
  WHERE product_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_deal_cache_keyword
  ON public.deal_cache (company_id, keyword_id, retailer, offer_id)
  WHERE keyword_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_deal_cache_keyword ON public.deal_cache(keyword_id);
```

- [ ] **Step 3: Apply migration to dev DB (existing data preserved)**

From `Docker/supabase/`:
```bash
supabase migration up
```
Expected: output ends with `Finished supabase migration up.` Look for `Applying migration 20260419000000_deal_keyword_groups.sql...`.

- [ ] **Step 4: Verify schema changes landed**

Run:
```bash
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -c "\d public.deal_keywords"
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -c "\d public.deal_keyword_products"
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -c "\d public.deal_cache"
```
Expected: `deal_keywords` table with `terms text[]`, `deal_keyword_products` with compound PK, `deal_cache` shows `keyword_id`, `matched_term`, `product_id` nullable, and the `deal_cache_product_xor_keyword` check.

- [ ] **Step 5: Functional smoke-check of the XOR constraint**

Before inserting, inventory the existing NOT NULL columns on `deal_cache` so
the test INSERT doesn't fail on something unrelated:
```bash
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -c "\d public.deal_cache"
```
Then pipe a transactional test via heredoc to `psql` (one `psql` invocation,
stdin from heredoc — the constraint test expects the INSERT itself to fail
and the ROLLBACK then keeps `deal_cache` untouched either way):
```bash
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres <<'SQL'
BEGIN;
-- Both product_id and keyword_id NULL — must violate deal_cache_product_xor_keyword.
-- Fill any OTHER NOT NULL columns discovered in the \d output above with dummy values.
INSERT INTO public.deal_cache (company_id, retailer, deal_title, matched_by, offer_id)
VALUES ('00000000-0000-0000-0000-000000000000', 'test', 'xor-test', 'test', 'test-offer');
ROLLBACK;
SQL
```
Expected output line: `ERROR:  new row for relation "deal_cache" violates check constraint "deal_cache_product_xor_keyword"`. If instead the INSERT succeeds, the constraint wasn't applied — re-check the migration.

- [ ] **Step 6: Commit**

```bash
git add Docker/supabase/migrations/20260419000000_deal_keyword_groups.sql
git commit -m "feat(db): add deal_keywords + deal_keyword_products + deal_cache XOR

Additive migration for hybrid product/keyword matching. Two new tables
with RLS via my_company_id(), plus nullable keyword_id/matched_term on
deal_cache guarded by an XOR CHECK. Replaces the single unique
constraint with two partial unique indexes backing the split upsert in
deal-search."
```

---

## Chunk 2: Edge function — keyword matching pass

The current `deal-search/index.ts` has `matchConfidence(productName, offerDescription, offerBrand, config)` at line 243 — signature unchanged, we feed a keyword `term` instead of `product.name`. The cache-refresh pattern (DELETE + upsert) at lines 570–581 stays; we only change the write shape.

**Pre-existing symbols used below** (do NOT redefine them — they already exist in the file):
- `MarktguruOffer` interface (line 11)
- `MatchResult` interface (line 225)
- `matchConfidence(name, description, brand, config)` (line 243)
- `detectAppRequirement(description, patterns)` (line 200)
- `allDeals: any[]` at line 441 — declared outside the queries loop
- `seen: Set<string>` at line 442 — declared outside the queries loop

**Note on conflict targets.** The spec's Data Model section describes the two
partial unique indexes as a "defensive guard" and says the cache refresh is a
DELETE-then-INSERT. This plan uses those partial indexes **as** `onConflict`
targets in the split upsert (Task 2.3). Both approaches work — PostgREST
supports partial unique indexes as conflict targets when the builder's
`onConflict` column list matches the index columns. The deviation is
intentional: it keeps the edge function's upsert pattern consistent with how
`deal_cache` has always been written (DELETE-then-upsert with `ignoreDuplicates`).

### Task 2.1: Add keyword fetch to edge function

**Files:**
- Modify: `Docker/supabase/functions/deal-search/index.ts`

- [ ] **Step 1: Add `DealKeyword` type and fetch**

After the existing `products` fetch (look for the block where `products` is pulled via `adminClient.from('products')`), add a keyword fetch:

```ts
interface DealKeyword {
  id: string
  label: string | null
  terms: string[]
  product_ids: string[]
}

const { data: keywordRows, error: keywordErr } = await adminClient
  .from('deal_keywords')
  .select('id, label, terms, deal_keyword_products(product_id)')
  .eq('company_id', companyId)

if (keywordErr) {
  console.error('[deal-search] failed to load keywords:', keywordErr)
}

const keywords: DealKeyword[] = (keywordRows ?? []).map((row: any) => ({
  id: row.id,
  label: row.label,
  terms: row.terms ?? [],
  product_ids: (row.deal_keyword_products ?? []).map((kp: any) => kp.product_id),
}))
```

- [ ] **Step 2: Syntax-check by running the Deno typecheck**

From `Docker/supabase/functions/deal-search/`:
```bash
deno check index.ts
```
Expected: no output on success, or only pre-existing warnings from the rest of the file.

- [ ] **Step 3: Commit**

```bash
git add Docker/supabase/functions/deal-search/index.ts
git commit -m "feat(deal-search): load deal_keywords with linked product_ids"
```

### Task 2.2: Keyword matching pass + covered-products set

- [ ] **Step 1: Declare `keywordCovered` at the TOP LEVEL (outside the queries loop)**

The queries loop at line 478 runs up to 50 times. Each iteration fetches a
fresh `offers` array (up to 10 offers each, possibly overlapping across
iterations). Both the keyword pass and its suppression side-effect must
accumulate across all iterations — so the Map declaration must live alongside
`const seen` and `const allDeals` (already at lines 441–442), **before** the
queries loop starts.

Add, immediately after line 442 (`const seen = new Set<string>()`):

```ts
// Per-offer set of products covered by a keyword-group hit. Populated inside
// the queries loop (Step 2) and read by the suppression gate (Step 3).
const keywordCovered = new Map<string | number, Set<string>>()
```

- [ ] **Step 2: Inside the queries loop, run the keyword pass on each offers batch**

The keyword pass stays **inside** the `for (const [query, matchProducts] of queries)`
block so it can operate on the `offers` array that was just fetched. The
`seen` set catches repeated `(offer, keyword)` pairs across batches, and the
top-level `keywordCovered` Map accumulates. Helper function `buildKeywordDeal`
is declared inside the queries loop (same pattern as the existing `buildDeal`
at line 483 — closes over `companyId`, `dealConfig`).

Insert the following block **inside** the queries loop, immediately after
`const offers = await searchMarktguru(query, zipCode, keys, 10)` and **before**
the existing `function buildDeal(...)` declaration:

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

// Keyword matching pass — one row per (offer, keyword_group).
for (const offer of offers) {
  for (const keyword of keywords) {
    let best: { term: string; match: MatchResult } | null = null
    for (const term of keyword.terms) {
      const m = matchConfidence(
        term,
        offer.description,
        offer.brand?.name ?? '',
        dealConfig,
      )
      if (m.confidence >= minConfidence && (!best || m.confidence > best.match.confidence)) {
        best = { term, match: m }
      }
    }
    if (!best) continue

    // Prefix the dedup key with `kw-` so it cannot collide with the existing
    // product-pass dedup keys (`${offer.id}-${product.id}`).
    const dedup = `kw-${offer.id}-${keyword.id}`
    if (seen.has(dedup)) continue
    seen.add(dedup)

    allDeals.push(buildKeywordDeal(offer, keyword, best))

    // Mark the keyword's products as covered for this offer. Union with any
    // existing set so repeated offer IDs across query batches accumulate.
    const covered = keywordCovered.get(offer.id) ?? new Set<string>()
    for (const pid of keyword.product_ids) covered.add(pid)
    keywordCovered.set(offer.id, covered)
  }
}
```

- [ ] **Step 3: Apply the suppression gate to BOTH product loops**

In the same outer `for (const [query, matchProducts] of queries)` block, find both `allDeals.push(buildDeal(offer, product, match))` call sites (there are two: the query-driven loop around line 540 and the cross-match-all-products loop around line 561). In **each** loop, before the `allDeals.push(...)`, add:

```ts
const coveredByKeyword = keywordCovered.get(offer.id)
if (coveredByKeyword?.has(product.id)) continue
```

This goes immediately after `seen.add(dedup)` and before `allDeals.push(...)` in BOTH loops. Do not refactor — just add the same two lines in two places to keep the diff obvious.

- [ ] **Step 4: Run Deno check**

```bash
cd Docker/supabase/functions/deal-search
deno check index.ts
```
Expected: clean or only pre-existing messages.

- [ ] **Step 5: Commit**

```bash
git add Docker/supabase/functions/deal-search/index.ts
git commit -m "feat(deal-search): keyword matching pass + product suppression gate

For each offer, iterate keyword groups and take the highest-confidence
term >= min_confidence. Track the union of linked product_ids per offer
in keywordCovered (declared at top level alongside seen/allDeals so it
accumulates across query batches), and suppress product-match writes
for any product already covered by a keyword hit on the same offer."
```

### Task 2.3: Split upsert + extended read-back

- [ ] **Step 1: Replace single upsert with split upsert**

Locate (around line 576):

```ts
if (allDeals.length > 0) {
  await adminClient.from('deal_cache').upsert(allDeals, {
    onConflict: 'company_id,product_id,retailer,offer_id',
    ignoreDuplicates: true,
  })
}
```

Replace with:

```ts
const productRows = allDeals.filter((d) => d.product_id !== null && d.product_id !== undefined)
const keywordRows = allDeals.filter((d) => d.keyword_id !== null && d.keyword_id !== undefined)

if (productRows.length > 0) {
  const { error: puErr } = await adminClient.from('deal_cache').upsert(productRows, {
    onConflict: 'company_id,product_id,retailer,offer_id',
    ignoreDuplicates: true,
  })
  if (puErr) console.error('[deal-search] product upsert failed:', puErr)
}

if (keywordRows.length > 0) {
  const { error: kuErr } = await adminClient.from('deal_cache').upsert(keywordRows, {
    onConflict: 'company_id,keyword_id,retailer,offer_id',
    ignoreDuplicates: true,
  })
  if (kuErr) console.error('[deal-search] keyword upsert failed:', kuErr)
}

console.log(`[deal-search] wrote ${productRows.length} product + ${keywordRows.length} keyword deals`)
```

- [ ] **Step 2: Extend the read-back select to hydrate keywords**

Replace the read-back block (around line 584):

```ts
const { data: result } = await adminClient
  .from('deal_cache')
  .select('*, products(name, image_path, sellprice)')
  .eq('company_id', companyId)
  .gte('confidence', minConfidence)
  .order('discount_pct', { ascending: false, nullsFirst: false })
```

with:

```ts
const { data: result } = await adminClient
  .from('deal_cache')
  .select(`
    *,
    products(id, name, image_path, sellprice),
    deal_keywords(
      id,
      label,
      terms,
      deal_keyword_products(products(id, name, image_path, sellprice))
    )
  `)
  .eq('company_id', companyId)
  .gte('confidence', minConfidence)
  .order('discount_pct', { ascending: false, nullsFirst: false })
```

- [ ] **Step 3: Deno check**

```bash
cd Docker/supabase/functions/deal-search
deno check index.ts
```

- [ ] **Step 4: Manual smoke test — serve function, trigger a refresh**

If not already running:
```bash
cd Docker/supabase
supabase functions serve deal-search --no-verify-jwt
```
In another terminal, trigger with no keywords yet to confirm the baseline still works:
```bash
curl -X POST http://127.0.0.1:54321/functions/v1/deal-search \
  -H "Authorization: Bearer $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"forceRefresh": true}'
```
Expected: JSON with `deals: [...]` — no keyword-match rows yet (because no keywords defined), but existing product matches should still work.

- [ ] **Step 5: Commit**

```bash
git add Docker/supabase/functions/deal-search/index.ts
git commit -m "feat(deal-search): split upsert + extended read-back for keywords

Two partial unique indexes back two upsert targets (one per match type).
Read-back hydrates deal_keywords + joined products in one query so the
frontend doesn't need a second round-trip to render keyword cards."
```

---

## Chunk 3: Frontend composable — keyword CRUD

**TDD ordering:** Task 3.1 writes the failing tests first, Task 3.2 implements the composable methods to make them pass. See @superpowers:test-driven-development.

### Task 3.1: Write failing tests for `useDeals` keyword methods

**Files:**
- Create: `management-frontend/app/composables/__tests__/useDeals.keywords.test.ts`

- [ ] **Step 1: Write the tests (see block below). Do NOT implement the composable methods yet — the tests MUST fail first.**

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest'

const mockSupabase = {
  from: vi.fn(),
}

vi.mock('#imports', () => ({
  useSupabaseClient: () => mockSupabase,
  useSupabaseUser: () => ({ value: { id: 'user-1' } }),
  useState: (_key: string, init: () => unknown) => ({ value: init() }),
}))

// Nuxt auto-imports don't always route through the `#imports` alias at test
// time, so mock useOrganization directly as well. Mirrors the known-working
// pattern in `useWarehouse.test.ts`.
vi.mock('../useOrganization', () => ({
  useOrganization: () => ({ organization: { value: { id: 'company-1' } } }),
}))

import { useDeals } from '../useDeals'

function makeFromChain(overrides: Record<string, any> = {}) {
  const chain: any = {
    select: vi.fn(() => chain),
    insert: vi.fn(() => chain),
    update: vi.fn(() => chain),
    delete: vi.fn(() => chain),
    eq: vi.fn(() => chain),
    order: vi.fn(() => chain),
    single: vi.fn(() => Promise.resolve({ data: null, error: null })),
    ...overrides,
  }
  chain.then = (resolve: any) => resolve({ data: overrides.__data ?? [], error: null })
  return chain
}

describe('useDeals — keywords', () => {
  beforeEach(() => {
    mockSupabase.from.mockReset()
  })

  it('createKeyword inserts the group and links products', async () => {
    const insertedGroup = { id: 'kw-1', label: 'Haribo', terms: ['Haribo Fruchtgummis'], created_at: 't', updated_at: 't' }
    mockSupabase.from.mockImplementation((table: string) => {
      if (table === 'deal_keywords') {
        return makeFromChain({ single: () => Promise.resolve({ data: insertedGroup, error: null }), __data: [insertedGroup] })
      }
      if (table === 'deal_keyword_products') {
        return makeFromChain({ __data: [] })
      }
      return makeFromChain()
    })

    const { createKeyword } = useDeals()
    await createKeyword({ label: 'Haribo', terms: ['Haribo Fruchtgummis'], product_ids: ['p-1', 'p-2'] })

    const tables = mockSupabase.from.mock.calls.map((c: any[]) => c[0])
    expect(tables).toContain('deal_keywords')
    expect(tables).toContain('deal_keyword_products')
  })

  it('deleteKeyword cascades via DB (just deletes the group)', async () => {
    mockSupabase.from.mockImplementation(() => makeFromChain({ __data: [] }))

    const { deleteKeyword } = useDeals()
    await deleteKeyword('kw-1')

    const tables = mockSupabase.from.mock.calls.map((c: any[]) => c[0])
    expect(tables).toContain('deal_keywords')
  })

  it('setKeywordProducts deletes old links and inserts new ones', async () => {
    mockSupabase.from.mockImplementation(() => makeFromChain({ __data: [] }))

    const { setKeywordProducts } = useDeals()
    await setKeywordProducts('kw-1', ['p-3', 'p-4'])

    const tables = mockSupabase.from.mock.calls.map((c: any[]) => c[0])
    const linkCalls = tables.filter((t: string) => t === 'deal_keyword_products')
    expect(linkCalls.length).toBeGreaterThanOrEqual(2) // one delete + one insert
  })
})
```

- [ ] **Step 2: Run and confirm the tests FAIL**

```bash
cd management-frontend
npx vitest run app/composables/__tests__/useDeals.keywords.test.ts
```
Expected: FAIL — the reason will be that `createKeyword`, `deleteKeyword`, `setKeywordProducts` are `undefined` on the `useDeals()` return object (TypeError on destructuring, or the methods are simply missing). This is the desired red state; proceed to Task 3.2 to make them green.

- [ ] **Step 3: Commit the failing test**

```bash
git add management-frontend/app/composables/__tests__/useDeals.keywords.test.ts
git commit -m "test(useDeals): red — failing tests for keyword CRUD methods"
```

### Task 3.2: Implement the keyword methods to make the tests pass

**Files:**
- Modify: `management-frontend/app/composables/useDeals.ts`

- [ ] **Step 1: Add `DealKeyword` type near the top of the file**

After the existing `Deal` interface, add:

```ts
export interface DealKeyword {
  id: string
  label: string | null
  terms: string[]
  product_ids: string[]
  created_at: string
  updated_at: string
}
```

Also extend the `Deal` interface to carry the hydrated keyword payload:

```ts
export interface Deal {
  id: string
  product_id: string | null
  keyword_id: string | null
  matched_term: string | null
  // ... (existing fields unchanged) ...
  products: {
    id: string
    name: string
    image_path: string | null
    sellprice: number | null
  } | null
  deal_keywords: {
    id: string
    label: string | null
    terms: string[]
    deal_keyword_products: Array<{
      products: { id: string; name: string; image_path: string | null; sellprice: number | null }
    }>
  } | null
}
```

Make `product_id` nullable (was `string` — must become `string | null`) and add `keyword_id`, `matched_term`, nullable `products`, and `deal_keywords`.

- [ ] **Step 2: Add CRUD methods to the composable**

At the end of `useDeals()` body, before the final `return { ... }`, add:

```ts
const keywords = useState<DealKeyword[]>('deal-keywords', () => [])

async function fetchKeywords() {
  const { data, error: err } = await supabase
    .from('deal_keywords')
    .select('id, label, terms, created_at, updated_at, deal_keyword_products(product_id)')
    .order('label', { ascending: true, nullsFirst: false })

  if (err) {
    console.error('[useDeals] fetchKeywords failed:', err)
    keywords.value = []
    return
  }
  keywords.value = (data ?? []).map((row: any) => ({
    id: row.id,
    label: row.label,
    terms: row.terms ?? [],
    product_ids: (row.deal_keyword_products ?? []).map((kp: any) => kp.product_id),
    created_at: row.created_at,
    updated_at: row.updated_at,
  }))
}

async function createKeyword(input: {
  label?: string | null
  terms: string[]
  product_ids: string[]
}): Promise<DealKeyword | null> {
  // Reuse the already-captured `organization` ref at the top of `useDeals()` —
  // do NOT call useOrganization() again inside this function (existing pattern
  // in this composable is to destructure once at the top).
  if (!organization.value) return null

  const { data, error: err } = await supabase
    .from('deal_keywords')
    .insert({
      company_id: organization.value.id,
      label: input.label ?? null,
      terms: input.terms,
    })
    .select('id, label, terms, created_at, updated_at')
    .single()

  if (err || !data) {
    console.error('[useDeals] createKeyword failed:', err)
    return null
  }

  if (input.product_ids.length > 0) {
    const { error: linkErr } = await supabase
      .from('deal_keyword_products')
      .insert(input.product_ids.map((pid) => ({ keyword_id: data.id, product_id: pid })))
    if (linkErr) console.error('[useDeals] createKeyword link failed:', linkErr)
  }

  await fetchKeywords()
  return keywords.value.find((k) => k.id === data.id) ?? null
}

async function updateKeyword(
  id: string,
  patch: { label?: string | null; terms?: string[] },
) {
  const { error: err } = await supabase
    .from('deal_keywords')
    .update(patch)
    .eq('id', id)
  if (err) {
    console.error('[useDeals] updateKeyword failed:', err)
    return
  }
  await fetchKeywords()
}

async function setKeywordProducts(id: string, productIds: string[]) {
  // Simple strategy: delete all + insert fresh. deal_keyword_products is
  // a PK-only junction, so no lost metadata.
  const { error: delErr } = await supabase
    .from('deal_keyword_products')
    .delete()
    .eq('keyword_id', id)
  if (delErr) {
    console.error('[useDeals] setKeywordProducts delete failed:', delErr)
    return
  }
  if (productIds.length > 0) {
    const { error: insErr } = await supabase
      .from('deal_keyword_products')
      .insert(productIds.map((pid) => ({ keyword_id: id, product_id: pid })))
    if (insErr) console.error('[useDeals] setKeywordProducts insert failed:', insErr)
  }
  await fetchKeywords()
}

async function deleteKeyword(id: string) {
  const { error: err } = await supabase
    .from('deal_keywords')
    .delete()
    .eq('id', id)
  if (err) {
    console.error('[useDeals] deleteKeyword failed:', err)
    return
  }
  await fetchKeywords()
}
```

- [ ] **Step 3: Extend the return block**

Add `keywords`, `fetchKeywords`, `createKeyword`, `updateKeyword`, `setKeywordProducts`, `deleteKeyword` to the object returned from `useDeals()`.

- [ ] **Step 4: Run the tests — expect GREEN**

```bash
cd management-frontend
npx vitest run app/composables/__tests__/useDeals.keywords.test.ts
```
Expected: all 3 tests PASS. If mock chain issues surface (PostgREST thenable semantics can be finicky), iterate on the mock helpers in the test file — the composable impl should stay as-is unless a real defect is found.

- [ ] **Step 5: Run type check**

```bash
cd management-frontend
npx nuxi typecheck 2>&1 | grep -E "useDeals|deal_keyword" || echo "OK"
```
Expected: `OK` or no new errors referencing these files.

- [ ] **Step 6: Commit**

```bash
git add management-frontend/app/composables/useDeals.ts \
        management-frontend/app/composables/__tests__/useDeals.keywords.test.ts
git commit -m "feat(useDeals): green — keyword CRUD methods

fetchKeywords / createKeyword / updateKeyword / setKeywordProducts /
deleteKeyword using RLS-protected Supabase client calls. Extends Deal
type with keyword_id + deal_keywords hydration for one-query rendering.
Mock-chain iterations (if any) committed together with the impl to keep
the red→green transition on a single commit."
```

---

## Chunk 4: MultiProductCombobox component

### Task 4.1: Create the component

**Files:**
- Create: `management-frontend/app/components/MultiProductCombobox.vue`

- [ ] **Step 1: Write the component**

```vue
<script setup lang="ts">
import { ref, computed } from 'vue'
import { Check, ChevronsUpDown, X } from 'lucide-vue-next'
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from '@/components/ui/command'
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from '@/components/ui/popover'
import Badge from '@/components/ui/badge/Badge.vue'
import { cn } from '@/lib/utils'

const { t } = useI18n()

interface Product {
  id: string
  name: string
  image_path?: string | null
  image_url?: string | null
}

const props = withDefaults(
  defineProps<{
    modelValue: string[]
    products: Product[]
    placeholder?: string
    disabled?: boolean
  }>(),
  { placeholder: '', disabled: false },
)

const emit = defineEmits<{
  'update:modelValue': [ids: string[]]
}>()

const open = ref(false)

const selectedSet = computed(() => new Set(props.modelValue))
const selectedProducts = computed(() =>
  props.products.filter((p) => selectedSet.value.has(p.id)),
)

function toggle(id: string) {
  const next = new Set(selectedSet.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  emit('update:modelValue', Array.from(next))
}

function removeAt(id: string, event: Event) {
  event.stopPropagation()
  emit('update:modelValue', props.modelValue.filter((v) => v !== id))
}
</script>

<template>
  <Popover v-model:open="open">
    <PopoverTrigger as-child>
      <button
        type="button"
        role="combobox"
        :aria-expanded="open"
        :disabled="disabled"
        :class="cn(
          'flex min-h-9 w-full items-center justify-between gap-2 rounded-md border border-input bg-background px-3 py-1.5 text-sm shadow-sm hover:bg-accent/50 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50',
        )"
      >
        <div class="flex flex-1 flex-wrap gap-1">
          <template v-if="selectedProducts.length === 0">
            <span class="text-muted-foreground">{{ placeholder }}</span>
          </template>
          <template v-else>
            <Badge
              v-for="product in selectedProducts"
              :key="product.id"
              variant="secondary"
              class="gap-1"
            >
              {{ product.name }}
              <span
                role="button"
                tabindex="-1"
                class="ml-1 rounded-sm opacity-70 hover:opacity-100"
                @click="(e) => removeAt(product.id, e)"
              >
                <X class="size-3" />
              </span>
            </Badge>
          </template>
        </div>
        <ChevronsUpDown class="size-4 shrink-0 opacity-50" />
      </button>
    </PopoverTrigger>
    <PopoverContent class="w-[--reka-popover-trigger-width] p-0" align="start">
      <Command>
        <CommandInput :placeholder="placeholder" />
        <CommandList>
          <CommandEmpty>
            <span class="text-muted-foreground text-sm">{{ t('common.noResults') }}</span>
          </CommandEmpty>
          <CommandGroup>
            <CommandItem
              v-for="product in products"
              :key="product.id"
              :value="product.name"
              @select="toggle(product.id)"
            >
              <Check
                :class="cn('mr-2 size-4', selectedSet.has(product.id) ? 'opacity-100' : 'opacity-0')"
              />
              <img
                v-if="product.image_url"
                :src="product.image_url"
                :alt="product.name"
                class="mr-2 h-6 w-6 shrink-0 rounded object-cover"
              />
              <div v-else class="mr-2 h-6 w-6 shrink-0 rounded bg-muted" />
              {{ product.name }}
            </CommandItem>
          </CommandGroup>
        </CommandList>
      </Command>
    </PopoverContent>
  </Popover>
</template>
```

- [ ] **Step 2: Manual smoke — import into a dev route**

Not committed yet — quickly sanity-check by adding a temporary `<MultiProductCombobox>` usage to `/deals/index.vue` (remove before commit), run `npm run dev`, verify chips render and toggle on click.

- [ ] **Step 3: Commit**

```bash
git add management-frontend/app/components/MultiProductCombobox.vue
git commit -m "feat(ui): add MultiProductCombobox for multi-select with chips"
```

---

## Chunk 5: Keyword management UI (modal + list)

### Task 5.1: Create `DealKeywordModal.vue`

**Files:**
- Create: `management-frontend/app/components/DealKeywordModal.vue`

- [ ] **Step 1: Write the component**

```vue
<script setup lang="ts">
import { ref, watch } from 'vue'
import { X } from 'lucide-vue-next'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import Badge from '@/components/ui/badge/Badge.vue'
import MultiProductCombobox from './MultiProductCombobox.vue'
import type { DealKeyword } from '@/composables/useDeals'

const { t } = useI18n()

const props = defineProps<{
  open: boolean
  editing: DealKeyword | null
}>()

const emit = defineEmits<{
  'update:open': [value: boolean]
  save: [payload: { id?: string; label: string | null; terms: string[]; product_ids: string[] }]
}>()

const { products, getProductImageUrl, fetchProducts } = useProducts()

const label = ref('')
const termDraft = ref('')
const terms = ref<string[]>([])
const productIds = ref<string[]>([])
const submitting = ref(false)

// Hydrate form when the modal opens (or when editing target changes)
watch(
  () => [props.open, props.editing] as const,
  async ([open, editing]) => {
    if (!open) return
    if (!products.value.length) await fetchProducts()
    if (editing) {
      label.value = editing.label ?? ''
      terms.value = [...editing.terms]
      productIds.value = [...editing.product_ids]
    } else {
      label.value = ''
      terms.value = []
      productIds.value = []
    }
    termDraft.value = ''
  },
  { immediate: true },
)

const productsForCombobox = computed(() =>
  products.value.map((p: any) => ({
    id: p.id,
    name: p.name,
    image_url: p.image_path ? getProductImageUrl(p.image_path) : null,
  })),
)

function addTerm() {
  const t = termDraft.value.trim()
  if (!t) return
  if (!terms.value.includes(t)) terms.value.push(t)
  termDraft.value = ''
}

function onTermKeydown(e: KeyboardEvent) {
  if (e.key === 'Enter' || e.key === ',') {
    e.preventDefault()
    addTerm()
  }
}

function removeTerm(t: string) {
  terms.value = terms.value.filter((x) => x !== t)
}

async function onSave() {
  if (terms.value.length === 0) return
  submitting.value = true
  try {
    emit('save', {
      id: props.editing?.id,
      label: label.value.trim() || null,
      terms: [...terms.value],
      product_ids: [...productIds.value],
    })
    emit('update:open', false)
  } finally {
    submitting.value = false
  }
}
</script>

<template>
  <Dialog :open="open" @update:open="(v) => emit('update:open', v)">
    <DialogContent class="sm:max-w-lg">
      <DialogHeader>
        <DialogTitle>
          {{ editing ? t('deals.keywords.editGroup') : t('deals.keywords.newGroup') }}
        </DialogTitle>
        <DialogDescription>{{ t('deals.keywords.modalHint') }}</DialogDescription>
      </DialogHeader>

      <div class="grid gap-4 py-2">
        <div class="grid gap-2">
          <Label for="kw-label">{{ t('deals.keywords.label') }}</Label>
          <Input id="kw-label" v-model="label" :placeholder="t('deals.keywords.labelPlaceholder')" />
        </div>

        <div class="grid gap-2">
          <Label for="kw-terms">{{ t('deals.keywords.terms') }}</Label>
          <Input
            id="kw-terms"
            v-model="termDraft"
            :placeholder="t('deals.keywords.termsHint')"
            @keydown="onTermKeydown"
            @blur="addTerm"
          />
          <div v-if="terms.length" class="flex flex-wrap gap-1">
            <Badge v-for="term in terms" :key="term" variant="secondary" class="gap-1">
              {{ term }}
              <span
                role="button"
                class="ml-1 rounded-sm opacity-70 hover:opacity-100"
                @click="removeTerm(term)"
              >
                <X class="size-3" />
              </span>
            </Badge>
          </div>
        </div>

        <div class="grid gap-2">
          <Label>{{ t('deals.keywords.products') }}</Label>
          <MultiProductCombobox
            v-model="productIds"
            :products="productsForCombobox"
            :placeholder="t('deals.keywords.productsPlaceholder')"
          />
        </div>
      </div>

      <DialogFooter>
        <Button variant="outline" @click="emit('update:open', false)">{{ t('common.cancel') }}</Button>
        <Button :disabled="terms.length === 0 || submitting" @click="onSave">
          {{ t('common.save') }}
        </Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>
```

- [ ] **Step 2: Commit**

```bash
git add management-frontend/app/components/DealKeywordModal.vue
git commit -m "feat(ui): add DealKeywordModal with label + chips + multi-product picker"
```

### Task 5.2: Create `DealKeywordList.vue`

**Files:**
- Create: `management-frontend/app/components/DealKeywordList.vue`

- [ ] **Step 1: Write the component**

```vue
<script setup lang="ts">
import { ref } from 'vue'
import { Plus, Pencil, Trash2 } from 'lucide-vue-next'
import { Button } from '@/components/ui/button'
import Badge from '@/components/ui/badge/Badge.vue'
import DealKeywordModal from './DealKeywordModal.vue'
import type { DealKeyword } from '@/composables/useDeals'

const { t } = useI18n()
const { keywords, fetchKeywords, createKeyword, updateKeyword, setKeywordProducts, deleteKeyword } = useDeals()

const open = ref(false)
const editing = ref<DealKeyword | null>(null)

onMounted(() => { fetchKeywords() })

function openNew() {
  editing.value = null
  open.value = true
}

function openEdit(k: DealKeyword) {
  editing.value = k
  open.value = true
}

async function onSave(payload: { id?: string; label: string | null; terms: string[]; product_ids: string[] }) {
  if (payload.id) {
    await updateKeyword(payload.id, { label: payload.label, terms: payload.terms })
    await setKeywordProducts(payload.id, payload.product_ids)
  } else {
    await createKeyword({ label: payload.label, terms: payload.terms, product_ids: payload.product_ids })
  }
}

async function onDelete(k: DealKeyword) {
  if (!confirm(t('deals.keywords.deleteConfirm', { label: k.label ?? k.terms[0] }))) return
  await deleteKeyword(k.id)
}

function displayName(k: DealKeyword): string {
  return k.label?.trim() || k.terms[0] || '—'
}

function termsPreview(k: DealKeyword): string {
  const first = k.terms.slice(0, 3).join(', ')
  const extra = k.terms.length - 3
  return extra > 0 ? `${first} +${extra}` : first
}
</script>

<template>
  <div class="space-y-4">
    <div class="flex items-center justify-between">
      <h2 class="text-lg font-semibold">{{ t('deals.keywords.title') }}</h2>
      <Button @click="openNew">
        <Plus class="mr-1 size-4" />
        {{ t('deals.keywords.newGroup') }}
      </Button>
    </div>

    <div v-if="!keywords.length" class="rounded-md border border-dashed p-8 text-center text-muted-foreground">
      <p class="mb-1 font-medium">{{ t('deals.keywords.emptyTitle') }}</p>
      <p class="text-sm">{{ t('deals.keywords.emptyHint') }}</p>
    </div>

    <ul v-else class="divide-y rounded-md border">
      <li
        v-for="k in keywords"
        :key="k.id"
        class="flex items-center justify-between gap-3 p-3"
      >
        <div class="min-w-0 flex-1">
          <div class="font-medium">{{ displayName(k) }}</div>
          <div class="truncate text-sm text-muted-foreground">{{ termsPreview(k) }}</div>
        </div>
        <Badge variant="secondary">
          {{ t('deals.keywords.productsCount', { n: k.product_ids.length }) }}
        </Badge>
        <Button variant="ghost" size="icon" @click="openEdit(k)">
          <Pencil class="size-4" />
        </Button>
        <Button variant="ghost" size="icon" @click="onDelete(k)">
          <Trash2 class="size-4 text-destructive" />
        </Button>
      </li>
    </ul>

    <DealKeywordModal v-model:open="open" :editing="editing" @save="onSave" />
  </div>
</template>
```

- [ ] **Step 2: Commit**

```bash
git add management-frontend/app/components/DealKeywordList.vue
git commit -m "feat(ui): add DealKeywordList with inline edit/delete + empty state"
```

### Task 5.3: i18n keys (de + en)

**Files:**
- Modify: `management-frontend/i18n/locales/de.json`
- Modify: `management-frontend/i18n/locales/en.json`

- [ ] **Step 1: Locate the `"deals"` block in de.json (line 1047)**

Inside the `"deals"` object, add a new child `"keywords"`:

The spec (lines 447–461) listed a representative but non-exhaustive set of
keys. The plan adds a few more concrete strings (`tabLabel`, `editGroup`,
`productsPlaceholder`, `modalHint`, `emptyTitle`, `emptyHint`) to cover the
UI components built in Chunks 4–5. Intentional expansion, not scope drift.

```json
"keywords": {
  "title": "Schlagwörter",
  "tabLabel": "Schlagwörter",
  "newGroup": "Neue Schlagwort-Gruppe",
  "editGroup": "Schlagwort-Gruppe bearbeiten",
  "label": "Anzeigename",
  "labelPlaceholder": "z.B. Haribo",
  "terms": "Suchbegriffe",
  "termsHint": "Enter oder Komma drücken um hinzuzufügen",
  "products": "Verknüpfte Produkte",
  "productsPlaceholder": "Produkte auswählen…",
  "productsCount": "{n} Produkte verknüpft",
  "matchedVia": "erkannt via „{term}\"",
  "modalHint": "Wenn einer der Suchbegriffe in einem Angebot auftaucht, wird eine Deal-Karte für alle verknüpften Produkte angezeigt.",
  "emptyTitle": "Noch keine Schlagwort-Gruppen",
  "emptyHint": "Beispiel: Gruppe „Haribo\" mit Begriffen „Haribo Fruchtgummis\", „Haribo versch. Sorten\" und allen Haribo-Produkten verknüpfen — Angebote über alle Haribo-Sorten erscheinen dann als eine Karte.",
  "deleteConfirm": "Schlagwort-Gruppe \"{label}\" wirklich löschen?"
}
```

- [ ] **Step 2: Mirror keys in en.json under the corresponding `"deals"` block**

```json
"keywords": {
  "title": "Keywords",
  "tabLabel": "Keywords",
  "newGroup": "New keyword group",
  "editGroup": "Edit keyword group",
  "label": "Label",
  "labelPlaceholder": "e.g. Haribo",
  "terms": "Search terms",
  "termsHint": "Press Enter or comma to add",
  "products": "Linked products",
  "productsPlaceholder": "Select products…",
  "productsCount": "{n} linked products",
  "matchedVia": "matched via \"{term}\"",
  "modalHint": "When any of the search terms appears in an offer, one deal card is shown covering all linked products.",
  "emptyTitle": "No keyword groups yet",
  "emptyHint": "Example: a \"Haribo\" group with terms \"Haribo Fruchtgummis\", \"Haribo versch. Sorten\" linked to every Haribo product — brand-wide offers then show up as a single card.",
  "deleteConfirm": "Delete keyword group \"{label}\"?"
}
```

- [ ] **Step 3: Verify JSON parses**

```bash
cd management-frontend
node -e "JSON.parse(require('fs').readFileSync('i18n/locales/de.json','utf8')); JSON.parse(require('fs').readFileSync('i18n/locales/en.json','utf8')); console.log('OK')"
```
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add management-frontend/i18n/locales/de.json management-frontend/i18n/locales/en.json
git commit -m "i18n(deals): add deals.keywords.* strings for de + en"
```

---

## Chunk 6: `/deals` page integration

### Task 6.1: Add "Schlagwörter" tab to `/deals/index.vue`

**Files:**
- Modify: `management-frontend/app/pages/deals/index.vue`

The current template (verified 2026-04-19):
- Line 213: outer `<div class="flex flex-1 flex-col gap-6 p-4 md:p-6">`
- Lines 214–227: page header (h1 + refresh button)
- Lines 230–244: `<div v-if="!dealsEnabled">` feature-gate block
- Line 247: `<template v-else>` opens, wrapping everything deal-related (error block, KPI cards, search/grouping controls, deal-list rendering)
- `</template>` for the `v-else` closes before line 566's outer `</template>`

We insert the `<Tabs>` INSIDE the `<template v-else>` so the feature-gate still shows when deals are disabled. The header stays above the tabs. Both tabs are only visible after deals are enabled.

- [ ] **Step 1: Import the new list component and Tabs primitives**

Add to the script block (after existing imports at the top of the file):
```ts
import DealKeywordList from '@/components/DealKeywordList.vue'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
```

- [ ] **Step 2: Insert Tabs inside `<template v-else>`**

Find the existing `<template v-else>` at line 247. Immediately inside it (before the `<!-- Error -->` comment at line 248), open a Tabs block. All existing content between line 248 and the end of the `</template>` that closes `v-else` moves INSIDE `<TabsContent value="deals">`. Add a second `<TabsContent value="keywords">` after the first, containing `<DealKeywordList />`.

Concretely — replace lines 247 through the closing `</template>` of `v-else` with:

```vue
<template v-else>
  <Tabs default-value="deals" class="w-full">
    <TabsList>
      <TabsTrigger value="deals">{{ t('deals.title') }}</TabsTrigger>
      <TabsTrigger value="keywords">{{ t('deals.keywords.tabLabel') }}</TabsTrigger>
    </TabsList>

    <TabsContent value="deals" class="space-y-6">
      <!-- PASTE HERE: the existing block that runs from the `<!-- Error -->`
           comment through the final `</div>` that corresponds to line 315's
           `<div v-else class="space-y-6">`. Indentation shifts two levels in. -->
    </TabsContent>

    <TabsContent value="keywords">
      <DealKeywordList />
    </TabsContent>
  </Tabs>
</template>
```

**Important:** do not try to express this as one giant string replacement. Do the move in two Edit operations if using an editing tool: (1) add the Tabs scaffold around the existing content, (2) delete the old `<template v-else>` opening tag that has been displaced. Visual-diff the file afterward to confirm no orphan tags.

- [ ] **Step 3: Typecheck + dev-server render-check**

```bash
cd management-frontend
npm run dev
```
Open http://localhost:3000/deals. Expected: two tabs render (Deals, Schlagwörter). The Deals tab shows everything that was there before (KPI cards, search, grouping, deal list). The Schlagwörter tab shows the empty-state from `DealKeywordList`. The feature-gate (when `deals_enabled = false`) still hides both tabs entirely and shows the old "Go to settings" block.

- [ ] **Step 4: Commit**

```bash
git add management-frontend/app/pages/deals/index.vue
git commit -m "feat(deals): tab bar separating deals list from keyword management"
```

### Task 6.2: Render keyword-matched deals

**Files:**
- Modify: `management-frontend/app/pages/deals/index.vue`

- [ ] **Step 1: Update the deal card rendering to branch on `keyword_id`**

`IconTag` is already imported at the top of the file (line 2). No new import needed — reuse that symbol.

In the deal card template, before rendering product-specific fields, branch:
```vue
<template v-if="deal.keyword_id && deal.deal_keywords">
  <Badge variant="secondary" class="gap-1">
    <IconTag class="size-3" />
    {{ deal.deal_keywords.label ?? deal.deal_keywords.terms[0] }}
  </Badge>
  <p v-if="deal.matched_term" class="text-xs text-muted-foreground">
    {{ t('deals.keywords.matchedVia', { term: deal.matched_term }) }}
  </p>
  <div class="mt-2 space-y-1">
    <p class="text-xs font-medium">
      {{ t('deals.keywords.productsCount', { n: deal.deal_keywords.deal_keyword_products.length }) }}
    </p>
    <ul
      v-if="deal.deal_keywords.deal_keyword_products.length > 0"
      class="text-sm text-muted-foreground"
    >
      <li v-for="kp in deal.deal_keywords.deal_keyword_products" :key="kp.products.id">
        {{ kp.products.name }}
      </li>
    </ul>
    <p v-else class="text-sm italic text-muted-foreground">
      {{ t('deals.keywords.emptyHint') }}
    </p>
  </div>
</template>
<template v-else>
  <!-- existing product-based rendering unchanged -->
</template>
```

The empty-products branch covers the spec's edge case "user defined a keyword
group but has not linked any products yet" — the card is still shown (the deal
matched the terms) but with a gentle "add products" nudge instead of a blank
list.

- [ ] **Step 2: Update `groupedFiltered` grouping key to handle keyword matches**

In the script block, change the grouping computation so `groupBy === 'product'` uses `deal_keywords.label` when `keyword_id` is set:
```ts
const key = groupBy.value === 'retailer'
  ? deal.retailer
  : (deal.keyword_id
      ? (deal.deal_keywords?.label ?? deal.deal_keywords?.terms?.[0] ?? 'keyword')
      : (deal.products?.name ?? deal.product_id ?? 'product'))
```

- [ ] **Step 3: Update `filteredDeals` search to include keyword label + linked products**

```ts
return deals.value.filter((d) => {
  const hay = [
    d.deal_title,
    d.retailer,
    d.products?.name ?? '',
    d.deal_keywords?.label ?? '',
    ...(d.deal_keywords?.terms ?? []),
    ...(d.deal_keywords?.deal_keyword_products?.map((kp) => kp.products.name) ?? []),
  ].join(' ').toLowerCase()
  return hay.includes(q)
})
```

- [ ] **Step 4: Dev-server smoke-test the full flow**

```bash
cd management-frontend
npm run dev
```

Open http://localhost:3000/deals (log in via the dev credentials stored in auto-memory). Acceptance criteria — each must hold:

| # | Observable | Expected |
|---|------------|----------|
| 1 | Tab bar | Two tabs visible: "Angebote" / "Deals" and "Schlagwörter" / "Keywords" |
| 2 | Deals tab, no keyword groups yet | Identical to pre-change page — KPI cards, search, grouping, cards render unchanged |
| 3 | Schlagwörter tab, initial visit | Empty state with "Noch keine Schlagwort-Gruppen" + hint text |
| 4 | Click "Neue Schlagwort-Gruppe" | Modal opens with empty label + terms + products fields |
| 5 | Type "Haribo Fruchtgummis" + Enter | Chip with that text appears; input clears |
| 6 | Product combobox | Search filters the dropdown; clicking toggles chip in/out |
| 7 | Save with ≥1 term + ≥1 product | Modal closes; row appears in list with "X Produkte verknüpft" badge |
| 8 | Pencil icon | Reopens modal with prefilled fields |
| 9 | Trash icon | Confirms, then row disappears |
| 10 | Browser devtools Network | `deal_keywords` and `deal_keyword_products` calls return 200 (not 401/403 — RLS is OK) |

If any of these fail, fix before proceeding.

- [ ] **Step 5: Commit**

```bash
git add management-frontend/app/pages/deals/index.vue
git commit -m "feat(deals): render keyword-matched cards with badge + linked product list"
```

---

## Chunk 7: End-to-end verification

### Task 7.1: Edge function integration check

- [ ] **Step 1: Create one keyword group in the UI** — e.g. label "Haribo", terms `["Haribo Fruchtgummis", "Haribo versch. Sorten"]`, link 2–3 Haribo products.

- [ ] **Step 2: Trigger a fresh deal-search run**

Click the "Aktualisieren" / refresh button on `/deals` (or call the edge function via curl as in Task 2.3 step 4 with `{"forceRefresh": true}`).

- [ ] **Step 3: Inspect `deal_cache` rows**

```bash
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -c "
SELECT matched_by, matched_term, keyword_id, product_id, retailer, offer_id
FROM public.deal_cache
WHERE matched_by = 'keyword_fuzzy'
ORDER BY fetched_at DESC
LIMIT 10;"
```
Expected: at least one row with `matched_by = 'keyword_fuzzy'`, `keyword_id` set, `product_id` NULL, `matched_term` populated.

- [ ] **Step 4: Verify dedup — keyword hit suppresses per-product rows**

```bash
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -c "
SELECT matched_by, COUNT(*)
FROM public.deal_cache
GROUP BY matched_by;"
```

If the keyword group's products were previously producing deal rows on the same offers, those product rows should now be absent (keyword-wins dedup). Cross-check against yesterday's count if available.

- [ ] **Step 5: Browser verification**

Reload `/deals`. One card per matching offer, with Schlagwort-Badge, matched term, and expandable product list. No duplicate cards for the same offer.

- [ ] **Step 6: Commit any fixes found during verification, then mark the feature done**

```bash
git log --oneline -20
```
Expected: clean chain of small commits covering migration → edge function → composable → components → page → i18n.

---

## Rollback note

If anything goes sideways and the feature needs to be disabled without reverting:
- Setting `companies.deals_enabled = false` turns off the whole pipeline (existing toggle, no change needed).
- Rolling back the migration is possible but not recommended (existing `deal_cache` data uses the new XOR constraint). Prefer a forward-fix.
