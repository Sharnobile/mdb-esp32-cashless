# Analysis tab: replace a product via full-catalogue search

**Date:** 2026-06-12
**Area:** `management-frontend` (PWA only)
**Type:** Small additive UI change — add a product search to the Analysis-tab replace sheet so any catalogue product can be swapped in, not only the ~5 curated suggestions

## Goal

In the machine detail page's **Analysis** tab, clicking a slot (or a "Products to review" entry) opens a side sheet that today offers only **max 5 curated suggestions** (3 fleet bestsellers + 2 never-sold newcomers) to swap into the slot. The user wants to replace a slot's product with **any** product from the catalogue, via a search field — not just the suggested ones.

Chosen approach (**Variante A**, user-approved): keep the curated suggestions as a "quick pick" list, and add a search field **below** it that live-filters the entire product catalogue. Each search result reuses the existing result-row markup and the existing `applySwap` path. (Alternatives considered and rejected: B — replace the list with a single `ProductCombobox` dropdown, loses the rich suggestion cards and adds a step; C — two tabs "Suggestions" / "All products", heavier in a narrow side sheet.)

## Scope

PWA only. Two files carry the logic change (`useMachineAnalysis.ts`, `MachineAnalysisPanel.vue`) plus i18n (`en.json`, `de.json`) and one unit test. No backend, DB, edge-function, MQTT, or firmware change. No change to `applySwap`'s write behaviour. iOS/Android are out of scope (the user said "Maschinen Seite … Analyze Tab", which is the PWA `/machines/[id]` Analysis tab).

## Existing pattern (what we build on)

- `MachineAnalysisPanel.vue` — the detail `Sheet` (line ~243). It already renders a list of `sheetSuggestions` rows: image (or icon placeholder) + name + a context sub-line (`perDay` for bestsellers, `neverSold` for newcomers) + an admin-only "Use" button calling `handleApply(sug)` → `applySwap(targetTrayId, sug.product_id)`. State: `sheetOpen`, `selectedProductId`, `targetTrayId`, `applyingProductId`.
- `useMachineAnalysis.ts::analyze()` — **already fetches the full `products` catalogue** (`id, name, image_path, discontinued`) and a fleet-wide `velocity` map, and already computes `productsInMachine` and per-product tray groupings. These are consumed to build the suggestion pool but **not exposed**. The composable's established style is to export **pure, unit-tested helpers** (`scoreProduct`, `buildSuggestionPool`, `computeSlotWidths`).
- `applySwap(trayId, productId)` — sets `product_id` + `current_stock = 0`, writes a `product_swapped` `activity_log` row, re-runs `analyze()`. Reused unchanged.

## Design

### 1. Composable: expose an enriched, searchable catalogue (`useMachineAnalysis.ts`)

Add a new exported type and pure helper, plus a new returned ref.

```ts
export interface SearchableProduct {
  product_id: string
  name: string
  image_url: string | null
  /** Fleet-wide avg daily units; 0 if the product has never sold anywhere. */
  velocity: number
  /** item_numbers where this product currently sits in THIS machine (empty if absent). */
  inMachineSlots: number[]
}

/**
 * Filter the searchable catalogue for the replace sheet. Empty/whitespace query
 * returns no results (type-to-search). Case-insensitive substring match on name.
 * Excludes `excludeProductId` (you can't replace a slot with the product already
 * in it). Caps at `limit`; `truncated` signals more matches exist.
 */
export function filterSearchableProducts(
  products: SearchableProduct[],
  query: string,
  opts?: { excludeProductId?: string | null; limit?: number },
): { results: SearchableProduct[]; truncated: boolean }
```

Filter semantics:
- `const q = query.trim().toLowerCase(); if (!q) return { results: [], truncated: false }`
- match: `p.name.toLowerCase().includes(q)`
- exclude: `p.product_id !== opts.excludeProductId`
- limit: default 30; `truncated = matched.length > limit`; return first `limit`.

In `analyze()`, after `catalogue`, `velocity`, and `trays` are built, assemble and store the list (mirrors how `fillSuggestions` is set inside `analyze`):
- Build `itemNumbersByProduct: Map<string, number[]>` from `trays` (parallel to the existing `trayIdsByProduct`).
- ```ts
  searchableProducts.value = catalogue
    .filter(p => !p.discontinued)                       // discontinued excluded
    .map(p => ({
      product_id: p.id,
      name: p.name,
      image_url: p.image_url,
      velocity: velocity.get(p.id) ?? 0,
      inMachineSlots: itemNumbersByProduct.get(p.id) ?? [],   // present-in-machine NOT excluded, just flagged
    }))
    .sort((a, b) => a.name.localeCompare(b.name))
  ```
- Add `const searchableProducts = ref<SearchableProduct[]>([])` and return it from the composable.

Rationale for the flags:
- **Discontinued excluded** — you don't swap in a dead SKU.
- **Already-in-machine kept (not hidden)** — a product legitimately occupying multiple slots is valid (the analysis already aggregates a product across slots); hiding them would block intentional duplication. They're rendered with an "In machine · slot N" badge instead.

### 2. Component: search field + results in the sheet (`MachineAnalysisPanel.vue`)

- Pull `searchableProducts` from the composable.
- New state: `const productQuery = ref('')`. Reset it whenever the sheet opens or closes: `watch(sheetOpen, () => { productQuery.value = '' })`.
- New computed:
  ```ts
  const searchResults = computed(() =>
    filterSearchableProducts(searchableProducts.value, productQuery.value, {
      excludeProductId: selectedProductId.value, // omit the product being replaced
      limit: 30,
    }),
  )
  ```
  Note: because the product being replaced is excluded entirely, the "In machine · slot N" badge (sub-line rule (a) below) only ever fires for products occupying *other* slots in this machine — it flags an intentional duplicate, not the slot you're editing.
- Generalize the apply handler so search rows and suggestion rows share one path:
  ```ts
  async function applyProduct(productId: string) {
    if (!targetTrayId.value) return
    applyingProductId.value = productId
    try { await applySwap(targetTrayId.value, productId); sheetOpen.value = false }
    catch { /* surfaced via composable */ } finally { applyingProductId.value = null }
  }
  ```
  `handleApply(sug)` becomes `applyProduct(sug.product_id)`.
- **Template** — a **standalone block**, a sibling rendered *after* the `v-if="sheetSuggestions.length > 0"` suggestions block (so suggestions stay the top "quick pick" when present). It is gated on `props.isAdmin && targetTrayId` only — deliberately **decoupled from `sheetSuggestions.length`**, so the search is also available on an empty slot that happens to have zero curated suggestions (exactly when free search is most useful). Non-admins have no apply affordance (matching today), so the whole block is admin-only.
  - A sub-heading `analysis.searchHeading` ("Or any product").
  - The existing **`SearchInput` component** (`@/components/SearchInput.vue`): `<SearchInput v-model="productQuery" :placeholder="t('analysis.searchPlaceholder')" />` — it already provides the leading `IconSearch`, themed focus ring, and a clear (`IconX`) button, matching house style. (No bespoke `<input>`.)
  - `v-for` over `searchResults.results`, each row identical in structure to a suggestion row:
    - image, or a neutral placeholder box (no sparkles/flask icon — those denote suggestion kind).
    - name (truncate).
    - sub-line precedence: **(a)** `inMachineSlots.length > 0` → badge `analysis.alreadyInMachine` with the slot list; else **(b)** `velocity > 0` → `analysis.perDay` ({n} = `velocity.toFixed(1)`); else **(c)** `analysis.neverSold` (blue).
    - "Use" / "Applying…" button → `applyProduct(p.product_id)`, disabled while `applyingProductId !== null`, spinner when `applyingProductId === p.product_id` (reuses existing `apply`/`applying` strings + state).
  - Empty/short states: if `productQuery.trim()` is non-empty and `searchResults.results.length === 0` → `analysis.noProductsFound`. If `searchResults.truncated` → a muted `analysis.moreResults` hint under the list.
- The existing `swapHint` line stays where it is (it explains the reset-to-0 behaviour, true for search swaps too).

### 3. i18n (`i18n/locales/en.json` + `de.json`, `analysis` namespace)

Add (reuse existing `perDay`, `neverSold`, `apply`, `applying`, `slot`):

| key | en | de |
|-----|----|----|
| `searchHeading` | `Or any product` | `Oder beliebiges Produkt` |
| `searchPlaceholder` | `Search products…` | `Produkt suchen…` |
| `alreadyInMachine` | `In machine · slot {slots}` | `In Maschine · Slot {slots}` |
| `noProductsFound` | `No products found` | `Keine Produkte gefunden` |
| `moreResults` | `Refine your search to see more` | `Suche eingrenzen für mehr Treffer` |

`{slots}` is the comma-joined `inMachineSlots`.

## Backward compatibility / risk

- Purely additive frontend change. No payload/schema/contract touched, so the live-device backward-compat rules don't apply.
- `applySwap` is unchanged — same single-slot reassignment + stock-reset + `product_swapped` log as the existing suggestion buttons. Replacing a multi-slot product still targets `trayIds[0]` exactly as today (unchanged behaviour, out of scope to alter).
- Catalogue is already fetched in `analyze()`; no new network request. Client-side filtering of a typically <500-row catalogue per keystroke is trivial; the 30-row render cap bounds DOM growth.
- After an apply, `analyze()` re-runs and the sheet closes, so `searchableProducts` (incl. the new `inMachineSlots` flags) is rebuilt fresh next open.

## Testing

- **Unit (Vitest, `app/composables/__tests__/useMachineAnalysis.test.ts`)** — add cases for `filterSearchableProducts`:
  - empty / whitespace query → `{ results: [], truncated: false }`
  - case-insensitive substring match on name
  - `excludeProductId` removes that product
  - `limit` caps results and sets `truncated` when more match; `truncated:false` at/under limit
- **Manual** — on `/machines/[id]` Analysis tab as admin: open a slot, type in the search field, confirm the full catalogue filters; a product already in the machine shows the "In machine · slot N" badge; discontinued products never appear; "Use" swaps the slot (stock → 0, sheet closes, grid + Trays tab update); non-admins see no search/apply UI.

## Files touched

| File | Change |
|------|--------|
| `app/composables/useMachineAnalysis.ts` | Add `SearchableProduct` type + `filterSearchableProducts` pure helper; build & store `searchableProducts` ref in `analyze()` (enrich catalogue with `velocity` + `inMachineSlots`, exclude discontinued); return it |
| `app/components/analysis/MachineAnalysisPanel.vue` | Consume `searchableProducts`; add `productQuery` state (reset on sheet open/close) + `searchResults` computed via the helper; generalize apply into `applyProduct(productId)`; render a standalone search block (reusing `SearchInput.vue`) + results list as a sibling after the suggestions block, gated on `isAdmin && targetTrayId` (decoupled from `sheetSuggestions.length` so it works on empty slots), with already-in-machine / velocity / never-sold sub-lines and empty/truncated states |
| `app/composables/__tests__/useMachineAnalysis.test.ts` | Unit tests for `filterSearchableProducts` |
| `i18n/locales/en.json`, `i18n/locales/de.json` | 5 new `analysis.*` keys (search heading, placeholder, already-in-machine, no-results, more-results) |
