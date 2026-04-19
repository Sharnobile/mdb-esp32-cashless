# Deal Keyword Groups — Design

**Date:** 2026-04-19
**Status:** Draft
**Owner:** Lucien Kerl

## Summary

Add a hybrid matching layer to the `/deals` feature: on top of the existing
product-name fuzzy-match, users can define **keyword groups** — named sets of
search terms (`text[]`) tied to one or more products (M:N). A single offer that
matches a keyword group produces one deal card covering all linked products,
instead of N duplicated product-level cards (today's behavior for brand-wide
offers like *"Haribo versch. Sorten"*, *"alle Monster Energy"*).

## Problem

The `deal-search` edge function fuzzy-matches each Marktguru offer against
`products.name`. Two failure modes:

1. **Missed matches.** Retailers often advertise *"Haribo Fruchtgummis (versch.
   Sorten)"* while the catalog carries *"Haribo Gold Saftbären"*. The existing
   wildcard + brand-bonus heuristic helps but is unreliable, and the user has
   no knob to tell the system *"this brand phrase maps to these products"*.
2. **Duplicate cards.** When a brand-wide offer matches 10 catalog variants (e.g.
   all Haribo, all Monster Energy flavors, all Red Bull SKUs), the UI shows 10
   cards for the same offer — visual noise that also multiplies eventual
   low-stock notifications.

Per-product tags would still require the user to maintain identical term lists
on every SKU. A group-level concept with a shared term list is the minimum
viable structure that fits real-world retailer copy.

## Goals

- Users can define keyword groups on `/deals` with:
  - Optional display label (e.g. *"Haribo"*)
  - One or more search terms (e.g. `["Haribo Fruchtgummis", "Haribo versch. Sorten"]`)
  - A set of linked products (M:N)
- The edge function matches offers against both products *and* keyword groups,
  writing exactly one `deal_cache` row per `(offer, keyword_group)` hit.
- When a product is covered by a keyword-group match on the same offer, the
  direct product-match row is suppressed (keyword wins, dedup at write time).
- Low-stock notifications stay product-accurate: a keyword-match card exposes
  the list of linked products so future notification logic can drill in.
- Backward compatible: existing product-name matching continues unchanged for
  all offers not covered by a keyword group.

## Non-Goals

- Per-keyword matching settings (confidence, generic_terms overrides).
  Reuses the global `companies.deals_config` — YAGNI.
- Low-stock notification wiring. That is a separate future change; this spec
  ensures the data model makes it possible but does not implement it.
- Auto-suggesting keyword groups (e.g. cluster similar product names). Manual
  curation only.
- Editing keyword groups from the `/products` page. Lives on `/deals` only.
- Category-based grouping (using `product_category` as implicit groups).
  Rejected during brainstorming: categories are too coarse (e.g. *"Süßigkeiten"*
  includes non-Haribo brands) and not all products are neatly categorized.

## Data Model

Two new tables plus additive `deal_cache` columns. All changes go in **one new
migration** (`20260419000000_deal_keyword_groups.sql`); existing migrations stay
immutable per project convention.

### `deal_keywords`

```sql
CREATE TABLE public.deal_keywords (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id  uuid        NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  label       text        NULL,                         -- optional display name, e.g. "Haribo"
  terms       text[]      NOT NULL,                     -- ["Haribo Fruchtgummis", "Haribo Tüten"]
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT deal_keywords_terms_not_empty
    CHECK (array_length(terms, 1) >= 1)
);

CREATE INDEX idx_deal_keywords_company ON public.deal_keywords(company_id);
```

RLS: read/write for members of the company via `my_company_id()`.

### `deal_keyword_products`

```sql
CREATE TABLE public.deal_keyword_products (
  keyword_id  uuid NOT NULL REFERENCES public.deal_keywords(id) ON DELETE CASCADE,
  product_id  uuid NOT NULL REFERENCES public.products(id)      ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (keyword_id, product_id)
);

CREATE INDEX idx_deal_keyword_products_product ON public.deal_keyword_products(product_id);
```

RLS: read/write for members of the company. The policy can be derived via
`EXISTS (SELECT 1 FROM deal_keywords k WHERE k.id = keyword_id AND k.company_id = my_company_id())`
so there is no direct `company_id` column on the join (kept normalized).

### `deal_cache` additive changes

```sql
-- Drop old UNIQUE constraint — no longer sufficient (product_id may be NULL)
ALTER TABLE public.deal_cache DROP CONSTRAINT IF EXISTS deal_cache_unique;

-- New nullable columns
ALTER TABLE public.deal_cache
  ADD COLUMN IF NOT EXISTS keyword_id    uuid NULL REFERENCES public.deal_keywords(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS matched_term  text NULL;

-- product_id becomes nullable
ALTER TABLE public.deal_cache ALTER COLUMN product_id DROP NOT NULL;

-- XOR: exactly one of product_id / keyword_id is set
ALTER TABLE public.deal_cache
  ADD CONSTRAINT deal_cache_product_xor_keyword
  CHECK ((product_id IS NOT NULL) <> (keyword_id IS NOT NULL));

-- Replace UNIQUE with two partial unique indexes
CREATE UNIQUE INDEX IF NOT EXISTS uq_deal_cache_product
  ON public.deal_cache (company_id, product_id, retailer, offer_id)
  WHERE product_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_deal_cache_keyword
  ON public.deal_cache (company_id, keyword_id, retailer, offer_id)
  WHERE keyword_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_deal_cache_keyword ON public.deal_cache(keyword_id);
```

`matched_by` column stays `text` (unconstrained). New allowed value:
`'keyword_fuzzy'`. Existing rows all satisfy the new XOR constraint because they
have `product_id` set and `keyword_id` is `NULL` by default.

### Backward compatibility

- Existing `deal_cache` rows satisfy the XOR (`product_id` NOT NULL, `keyword_id`
  NULL).
- Old firmware is not involved — `/deals` is pure frontend + edge function.
- Edge function serves old and new rows uniformly; an older frontend (no
  keyword UI yet) would show keyword-matched rows as "unknown product" and is
  avoided because frontend ships with this change.

## Edge Function Changes (`deal-search`)

Files touched: `Docker/supabase/functions/deal-search/index.ts`.

### Matching order

1. **Fetch offers** from Marktguru (unchanged).
2. **Fetch keyword groups** for the company:
   `SELECT id, label, terms, array_agg(product_id) AS product_ids FROM deal_keywords LEFT JOIN deal_keyword_products ON ... GROUP BY id`.
3. **Keyword matching pass**, per offer:
   - For each `deal_keywords` row: evaluate every `term` in `terms` against the
     offer using the **existing** `matchProductToOffer()` helper (token fuzzy +
     brand bonus + wildcard boost), treating the `term` as the "product name".
   - Take the highest-confidence term; if `>= min_confidence`, record a keyword
     match: `(offer, keyword_id, matched_term, confidence, matched_tokens)`.
   - Also track the set of `product_ids` covered by this keyword hit →
     `keyword_covered_products` (per-offer set).
4. **Product matching pass**, per offer (existing logic):
   - Fuzzy-match against `products.name`.
   - **Before writing**, skip any `(offer, product_id)` where `product_id` is in
     `keyword_covered_products[offer_id]`. This enforces "keyword wins" dedup.
5. **Upsert** to `deal_cache` using the matching partial unique index. Keyword
   matches write `product_id = NULL, keyword_id = <id>, matched_by = 'keyword_fuzzy', matched_term = <term>`.
   Product matches behave as today.

### Reused helpers

No parallel implementation of matching logic. The current
`matchProductToOffer(productName, offer, config)` function is generic over the
reference string — we just feed it `term` instead of `product.name`. If the
function today reads `product.name` directly rather than taking a string param,
a light refactor extracts the string-to-offer comparator.

### Config

Reuses `companies.deals_config` (JSONB): `min_confidence`, `generic_terms`,
`wildcard_phrases`. No per-keyword overrides (Non-Goal).

### Logging

Debug logs prefix `[keyword:<id>]` on match so the existing cache-hit analysis
telemetry distinguishes keyword vs product matches.

## Frontend

### Page: `/deals`

Current layout is a flat list of cached offers. Extend with a tab bar at the
top:

- **Tab 1 — "Deals"** (default): existing deal card list, adapted to render
  both product-match and keyword-match cards (see below).
- **Tab 2 — "Schlagwörter"**: management UI for keyword groups.

### Tab "Schlagwörter"

A simple list view:

- Header: *"Schlagwort-Gruppen"* + *"+ Neue Gruppe"* button.
- Each row: label (or first term if no label), comma-joined terms preview (first
  3, "+N weitere"), "X Produkte verknüpft" badge, Edit / Delete icons.
- Empty state: short explainer with the Haribo example.

### Edit / Create Modal

Three fields:

1. **Anzeigename** (optional) — single text input. Placeholder *"z.B. Haribo"*.
2. **Suchbegriffe** — **chip/tag input** (Enter or comma commits a chip; chips
   are removable). Backed by `terms: string[]`. At least one required.
3. **Verknüpfte Produkte** — **new component** `MultiProductCombobox.vue` (see
   Components). Multi-select with search, shows selected products as removable
   chips below the trigger.

Save calls `useDeals.createKeyword()` / `updateKeyword()` + `setKeywordProducts()`.

### Deal card rendering

- **Product match** (today's behavior): card shows product image + name +
  "Spart X%" + retailer.
- **Keyword match** (new): card shows a "Schlagwort"-Badge with the `label` (or
  first term), the matched term line (*"erkannt via 'Haribo Fruchtgummis'"*),
  and an expandable list of linked products (with image thumbnails). Expansion
  uses the existing `Collapsible` pattern used elsewhere in `/deals`.

Visual distinction is a small icon + badge color — not a separate section, so
all deals stay in one sortable/filterable list.

### Components

- **New**: `MultiProductCombobox.vue` — duplicate-and-adapt of
  `ProductCombobox.vue` (single-select today, lines 28-60). Changes:
  - `modelValue: string[]` instead of `string | null`
  - Clicking an item toggles it instead of closing the popover
  - Selected chips render inside the trigger with a click-to-remove X
  - Keeps the existing `CommandInput` search (already filters by product.name)

  Rationale for a new component over a `multiple` prop: the rendering model
  differs enough (chips vs single label, no close-on-select) that conditional
  logic would muddy both paths. Keep `ProductCombobox` single-purpose.

- **New**: `DealKeywordModal.vue` — the Create/Edit modal described above.
- **New**: `DealKeywordList.vue` — the "Schlagwörter" tab list.
- **Touched**: existing `/deals/index.vue` — add tab bar, render keyword cards.

### Composable

Extend `useDeals.ts` (no new composable file):

```ts
fetchKeywords(): Promise<DealKeyword[]>
createKeyword(input: { label?: string; terms: string[]; product_ids: string[] }): Promise<DealKeyword>
updateKeyword(id: string, patch: Partial<{ label: string; terms: string[] }>): Promise<void>
deleteKeyword(id: string): Promise<void>
setKeywordProducts(id: string, productIds: string[]): Promise<void>
```

Type:
```ts
interface DealKeyword {
  id: string
  label: string | null
  terms: string[]
  product_ids: string[]        // loaded via join
  created_at: string
  updated_at: string
}
```

State is stored in a `useState('deal-keywords')` shared ref for consistency
with the existing organization / machines caching pattern.

### i18n

New keys under `deals.keywords.*` in both `de.json` and `en.json`:

- `deals.keywords.tabLabel` — "Schlagwörter" / "Keywords"
- `deals.keywords.newGroup` — "Neue Schlagwort-Gruppe" / "New Keyword Group"
- `deals.keywords.label` — "Anzeigename" / "Label"
- `deals.keywords.labelPlaceholder` — "z.B. Haribo" / "e.g. Haribo"
- `deals.keywords.terms` — "Suchbegriffe" / "Search terms"
- `deals.keywords.termsHint` — "Enter oder Komma drücken um hinzuzufügen" /
  "Press Enter or comma to add"
- `deals.keywords.products` — "Verknüpfte Produkte" / "Linked products"
- `deals.keywords.productsCount` — "{n} Produkte verknüpft" / "{n} linked products"
- `deals.keywords.matchedVia` — "erkannt via ‚{term}'" / "matched via '{term}'"
- `deals.keywords.emptyState` — short explainer with Haribo example
- `deals.keywords.deleteConfirm` — "Schlagwort-Gruppe '{label}' wirklich löschen?"

## Data flow

```
User enters keyword group "Haribo" with
  terms=["Haribo Fruchtgummis", "Haribo versch. Sorten"]
  products=[Goldbären, Colorado, Tropifrutti, ...]
           │
           ▼
deal_keywords + deal_keyword_products (M:N)
           │
           ▼ (next deal-search run, 12h cache or manual refresh)
Edge function pulls offers from Marktguru
           │
           ▼
For each offer:
  1. Run keyword pass → hit on "Haribo Fruchtgummis (versch. Sorten)"
     → ONE deal_cache row (keyword_id=X, matched_term="Haribo Fruchtgummis")
     → mark Goldbären/Colorado/Tropifrutti as "keyword-covered" for this offer
  2. Run product pass → would match Goldbären directly
     → skipped (product is keyword-covered)
           │
           ▼
Frontend renders ONE card:
  "Haribo · 2,49€ bei Lidl · erkannt via 'Haribo Fruchtgummis'"
  [expand] → Goldbären, Colorado, Tropifrutti
```

## Error handling & edge cases

- **No products linked to a keyword:** allowed (user might define the group
  before adding products). Matches still produce a deal_cache row with
  `product_ids = []`; UI shows the card with an empty "0 Produkte verknüpft"
  note so the user sees their group is incomplete.
- **Product deleted while linked:** `ON DELETE CASCADE` on
  `deal_keyword_products` removes the link. Existing deal_cache rows keep the
  `keyword_id` and are still displayable (the product list is derived at
  read time).
- **Keyword deleted:** cascades to `deal_keyword_products` and to
  `deal_cache.keyword_id` rows (the associated cards disappear).
- **Term duplication across groups:** not prevented. If the user defines
  "Haribo" in two groups with overlapping terms, both will match; UI shows two
  cards (likely desired: they represent different product slices).
- **Empty `terms` array:** blocked by CHECK constraint at DB level and by form
  validation in the modal.
- **Very long term lists:** no hard cap. Expected scale is <50 terms per group
  and <500 groups per company; fine for in-memory matching.

## Testing

- **Unit — edge function**: extend `deal-search` tests to cover:
  - Keyword-only match writes `keyword_id` row with correct `matched_term`.
  - Keyword-covered product match is suppressed.
  - Product-only match (product not in any keyword group) still writes as today.
  - Offer that matches two keyword groups produces two rows.
- **Unit — composable**: `useDeals` keyword CRUD paths against a Supabase stub
  (pattern already established in `__tests__/`).
- **Component**: `MultiProductCombobox` — select/deselect, chip removal, search
  filters list.
- **Migration**: fresh-install + migrate-from-previous path verified by running
  `supabase db reset` on a local branch (NOT the user's main dev DB —
  ABSOLUTE RULE per memory).

## Rollout

- Feature is gated by the existing `companies.deals_enabled` toggle; no new
  flag needed.
- Users who never create a keyword group see no change.
- Edge function is idempotent and handles empty keyword lists cleanly.

## Open questions / follow-ups (out of scope here)

1. **Low-stock-aware notifications** for keyword-matched deals: iterate over
   `deal_keyword_products` and check per-product `fill_when_below` / min-stock
   thresholds. Separate phase.
2. **Auto-suggestion** of keyword groups based on clustering of product names /
   brands. Separate exploration.
3. **Import/export** of keyword groups across companies (e.g. shared
   "industry defaults"). Not requested.
