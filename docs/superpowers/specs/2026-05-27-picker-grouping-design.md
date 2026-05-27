# Replacement Picker — Stock & Category Grouping

**Date**: 2026-05-27
**Status**: Design — pending user review
**Scope**: iOS native app (`ios/VMflow/`), Refill wizard's `ReplacementProductPicker`

## Problem

In the Refill wizard's Review step, tapping **Replace** on a tray opens `ReplacementProductPicker` — a flat list of all available products. The list shows pills for warehouse stock count and "already in slot X" badges, but the ordering is just the order products come back from the database. The user has to visually scan to find good replacement candidates.

In practice, four relevance signals matter for picking a replacement:

1. **Stock** — products with non-zero warehouse stock are good candidates; out-of-stock products are dead weight.
2. **Category** — a like-for-like replacement (same category as the discontinued product) is usually preferred.
3. **Already in machine** — a product already placed elsewhere in the same machine is a worse replacement choice (creates a duplicate slot) than a fresh product.
4. **Search match** — when actively searching, the fuzzy match score is the user's intent.

The current flat list expresses (1) and (3) only as visual pills with no sort impact. (2) is not surfaced at all.

## Goals

- Order and group products in the picker by the four signals above.
- Make the most relevant candidates visible at the top without scrolling.
- Keep existing visual cues (stock pill, "already in slot X" pill, OOS fade) — this is a re-ordering + sub-headers change, not a row-redesign.
- Preserve the fuzzy-search behavior when the user types into the search bar.

## Non-goals

- No DB schema changes, no migration.
- No changes to other refill steps (Packing, Refill, Summary).
- No changes to the PWA or Android client.
- No new sorting toggles or user settings (the order is fixed by the rules below).
- No reorder of the existing product row contents (image, name, pills, checkmark).
- No "collapsed by default" behavior on the OOS section — the user explicitly chose direct-expanded.

## Sorting rules

The picker computes the visible row order from a single deterministic pipeline:

### Step 1 — Filter
If `searchText` is non-empty: run the existing `fuzzyMatch` filter. Keep the per-product score for later. If `searchText` is empty: keep all products.

### Step 2 — Partition by stock
Split into two buckets:
- **In Stock**: `remainingStock(id) == nil` (no warehouse data) **or** `remainingStock(id) > 0`.
- **Out of Stock**: `remainingStock(id) == 0`.

Buckets that end up empty are dropped from the rendered output.

### Step 3 — Group by category within each bucket
Within each stock bucket, group products by `Product.category` (UUID? — `nil` = uncategorized).

Order the category groups:
1. The **current category** first (the category of the product being replaced — derived from the picker's `currentCategoryId` parameter; `nil` means no current category, skip this step).
2. Remaining **named** categories (excluding the uncategorized group) alphabetically by `ProductCategory.name`.
3. Uncategorized products (`category == nil`) **always last**, regardless of whether step 1 was skipped.

### Step 4 — Sort within each (stock × category) group
Multi-key sort, ascending. The fuzzy-score key is **only present when `searchText` is non-empty**; when search is empty, the sort is `(not-in-machine, alphabetical)`:

1. **Not-in-machine first** — products whose ID is not a key in `existingSlotsByProduct` come before those that are.
2. **Fuzzy score** (search-active only) — lower score wins (existing behavior).
3. **Alphabetical** — by `Product.name` using `localizedCaseInsensitiveCompare`. Both `name == nil` and `name?.isEmpty == true` sort to the end of their group (the row UI already renders `"Unnamed"` for these).

## UI rendering

### Structure

One outer SwiftUI `Section` (the existing "Products" section under the Machine Layout section). Inside, the rows are emitted in this order:

**Why one Section, not Section-per-group:** an alternative is to emit `Section(header: Text("In Stock — Snacks (current)"))` etc. — one Section per `(stock × category)` pair. That gives free header rendering and free separator suppression at section boundaries. We reject it because (a) the mega-header / sub-header visual hierarchy requested in the brainstorm doesn't compose well into a single Section-header `Text` view, and (b) iOS would render each Section with grouped-list styling (rounded corner clipping per Section), which fragments the visual rhythm of the list. The single-Section + manual-header approach keeps all rows in one continuous visual frame.

```
[stock-mega-header "In Stock" — only if Out of Stock bucket is also non-empty]
[category-sub-header "Snacks · current"]
[product row]
[product row]
[category-sub-header "Drinks"]
[product row]
…
[stock-mega-header "Out of Stock"]
[category-sub-header "Snacks · current"]
[product row]
…
```

### Stock mega-header

- Shown **only when both buckets have content**. With only "In Stock" (typical case when no warehouse is selected) the mega-header is suppressed and the category sub-headers stand alone.
- Visual: 13pt semibold uppercase, secondary color, with a small count badge on the right (e.g. `"In Stock"  ·  8`).
- Non-interactive — `.selectionDisabled()` + `.listRowSeparator(.hidden)`.
- Background: `listRowBackground(Color(.systemGroupedBackground))` so it blends with the iOS list separator zone.

**Separator suppression (applies to ALL header rows — mega and sub):**

iOS 17 draws hairline separators between every list row by default. Without explicit suppression, you'll see a separator between mega-header → sub-header → first-product-row, which looks like UI corruption. Each header row MUST set `.listRowSeparator(.hidden)`. The row directly **above** a header (last product of the previous group) should also set `.listRowSeparator(.hidden, edges: .bottom)` so the gap reads cleanly. The grouping helper or the rendering loop must track this — easiest implementation is a `isLastInGroup` flag on each product row.

### Category sub-header

- 11pt semibold, secondary color (`.foregroundStyle(.secondary)`). Current category: `.foregroundStyle(Color.accentColor)` plus a small "· current" suffix in the same color.
- Padding: `.padding(.top, 4).padding(.bottom, 2)`.
- Non-interactive.
- Uppercased text-transform via `.textCase(.uppercase)` to match iOS section-header conventions.

### Product row

Unchanged from today's implementation:
- 36pt `ProductImage` thumbnail (opacity 0.45 when OOS)
- Product name (secondary color when OOS)
- Stock pill — blue when `count > 0`, grey when `count == 0`
- "Already in slot X, Y" orange pill when applicable
- Blue checkmark when selected
- Tap → `onSelect(product.id)`
- `.id(product.id)` for `ScrollViewReader` scroll-to-product (existing)
- `.listRowBackground(...)` for the highlight-on-grid-tap pulse (existing)

### Empty states

- Search active, no matches anywhere: existing `ContentUnavailableView.search(text: searchText)` — unchanged.
- No products at all (degenerate case): empty list; both mega-headers and all category sub-headers are skipped because their bucket arrays are empty.

## Data model and view-model changes

### `RefillWizardViewModel`

Add:
```swift
@Published var productCategories: [ProductCategory] = []
```

In `loadData()` (the existing initial-load entry point), fetch categories alongside products. Mirror `ProductsViewModel.loadCategories()` exactly — explicit column list + alphabetical order — so the decoder doesn't break if the schema gains columns later:

```swift
let cats: [ProductCategory] = try await client
    .from("product_category")
    .select("id, name, company")
    .order("name", ascending: true)
    .execute()
    .value
self.productCategories = cats
```

No new RPC, no new edge function.

### `ReplacementProductPicker`

Two new parameters (both with sensible defaults so previews and unrelated callers keep working):

```swift
struct ReplacementProductPicker: View {
    let products: [Product]
    let selectedProductId: UUID?
    let existingSlotsByProduct: [UUID: [Int]]
    let machineLayout: MachineGridLayout
    var remainingStock: (UUID) -> Int? = { _ in nil }
    /// Category UUID of the product currently in the tray being replaced.
    /// `nil` if the tray is unassigned or the current product is uncategorized.
    /// When non-nil, that category is rendered first in each stock bucket.
    var currentCategoryId: UUID? = nil
    /// Category catalogue for name lookup. Empty array is valid — uncategorized
    /// products will still render; products whose `category` UUID is not
    /// present in the array fall back to the "Uncategorized" group.
    var categories: [ProductCategory] = []
    let onSelect: (UUID) -> Void
    ...
}
```

### Call site in `ReviewStepView.body`

Add a small helper on `RefillWizardViewModel` to keep the call site clean and to centralize the "look up the category of the product currently in this tray" semantics in one place:

```swift
// in RefillWizardViewModel
func currentCategoryId(forTrayId trayId: UUID) -> UUID? {
    guard let pid = replacements.first(where: { $0.trayId == trayId })?.currentProductId
    else { return nil }
    return availableProducts.first(where: { $0.id == pid })?.category
}
```

The `.sheet(item: $pickerTrayId)` call site wires up the new parameters from the existing view model:

```swift
ReplacementProductPicker(
    products: viewModel.availableProducts,
    selectedProductId: ...,
    existingSlotsByProduct: existingSlots(forTrayId: trayId),
    machineLayout: machineLayout(forTrayId: trayId),
    remainingStock: { id in
        guard viewModel.selectedWarehouseId != nil,
              !viewModel.warehouseStock.isEmpty
        else { return nil }
        return viewModel.remainingWarehouseStock(productId: id)
    },
    currentCategoryId: viewModel.currentCategoryId(forTrayId: trayId),
    categories: viewModel.productCategories,
    onSelect: { productId in
        viewModel.setReplacement(trayId: trayId, productId: productId)
        pickerTrayId = nil
    }
)
```

## Grouping helper

A pure function inside `ReplacementProductPicker` that takes the visible products + lookup closures and returns the rendered structure:

```swift
private struct StockBucket: Identifiable {
    enum Status: String { case inStock, outOfStock }
    let status: Status
    let categories: [CategoryGroup]
    var id: String { status.rawValue }
}

private struct CategoryGroup: Identifiable {
    let category: ProductCategory?   // nil = uncategorized
    let isCurrent: Bool
    let products: [Product]          // already sorted
    var id: String { category?.id.uuidString ?? "uncategorized" }
}

private var stockBuckets: [StockBucket] {
    // 1. filter by search → [(Product, fuzzyScore?)]
    // 2. partition by stock → (inStock, outOfStock)
    // 3. for each, groupByCategory + sortWithinGroup
    // 4. return only non-empty buckets
}
```

The function is deterministic and depends only on `searchText`, `products`, `remainingStock`, `existingSlotsByProduct`, `currentCategoryId`, `categories`. No side effects, no async work — safe to call as a computed property.

## Search interaction

When `searchText` is non-empty:

1. Apply the existing `fuzzyMatch` filter to drop non-matching products.
2. Apply the SAME grouping pipeline (steps 2–4 above) to the filtered set.
3. Within each (stock × category) group, the fuzzy score becomes the secondary sort key (after not-in-machine first, before alphabetical).
4. Empty groups are pruned from the output.
5. If no group has any product, fall through to the existing `ContentUnavailableView.search` empty state.

The user gets a grouped view of their search results — same mental model as the empty-search view, just filtered.

## Edge cases

| Case | Behavior |
|---|---|
| No warehouse selected → all `remainingStock` return nil | All products land in "In Stock" bucket. Out-of-stock bucket is empty → its mega-header is suppressed. With only one bucket and no need for separation, the "In Stock" mega-header is also suppressed; only category sub-headers render. |
| Current tray is unassigned (no `currentProductId`) | `currentCategoryId == nil`. No "· current" suffix shows; categories sort alphabetically. |
| Current product's category is unknown (race or stale data) | Same as above — no current-category highlight, alphabetical fallback. |
| Product has `category` UUID not present in `categories` array | Group under "Uncategorized" as a safe fallback. In `#if DEBUG` blocks emit a one-time `print("[RefillWizard] unknown category UUID: …")` (matches the `[RefillWizard]` log-tag convention already used in `loadData()`). |
| Single in-stock product, no warehouse | Renders as: category sub-header + one row. No mega-headers. |
| All products out of stock | Only "Out of Stock" bucket has content → no mega-header (only one bucket). Category sub-headers render. |
| Many uncategorized products | "Uncategorized" group renders last within its stock bucket, in alphabetical order. |
| Category name with diacritics | `localizedCaseInsensitiveCompare` for alphabetical sort. |

## Files affected

| File | Change |
|---|---|
| `ios/VMflow/ViewModels/RefillWizardViewModel.swift` | + `@Published productCategories: [ProductCategory]`; load from `product_category` table inside `loadData()`. ~15 lines. |
| `ios/VMflow/Views/Refill/ReviewStepView.swift` | + Two new picker parameters; rewrite picker `body` Section content to render mega-headers + category sub-headers + product rows; + `stockBuckets` computed property; + two row-style helpers. ~120 lines net. |
| `ios/VMflow/Resources/Localizable.xcstrings` | + `"In Stock"`, `"Out of Stock"`, `"current"`, `"Uncategorized"`. EN + DE. 4 new keys. |

No new files. `ReviewStepView.swift` is currently **665 lines** after the previous Task 8 extraction; this change brings it to ~785 lines. Still under the established 800-line "must extract" threshold from the prior milestone, but tight — if the implementation runs longer than projected and crosses 800, extract `ReplacementProductPicker` into its own file as part of the same change.

## Accessibility

- Stock mega-header: `.accessibilityLabel("In Stock, \(count) products")` / `"Out of Stock, \(count) products"`.
- Category sub-header: `.accessibilityLabel("\(name)\(isCurrent ? ", current category" : "")")`.
- Both headers `.accessibilityAddTraits(.isHeader)` so VoiceOver users can navigate by heading.
- Product rows: unchanged.

## Testing

iOS project has no unit-test target. Verification path:

1. **Compile-check**: `xcodebuild build` must succeed.
2. **Existing previews**: `"Picker with existing slots"` and `"Picker with grid (typical)"` continue to render (with empty `categories`/`currentCategoryId` defaults).
3. **New preview**: `"Picker with grouping (typical)"` — exercises both stock buckets, three categories with one marked current, and a mix of in-machine and not-in-machine products. Manual visual verification in Xcode canvas.
4. **On-device manual**: open the Refill wizard with a warehouse selected, tap Replace on a discontinued product, confirm:
   - "In Stock" mega-header at top, "Out of Stock" at bottom
   - Current category appears first in each, with blue "· current" suffix
   - Search filtering keeps the grouping
   - Empty warehouse case: no mega-headers, category headers only

## Risks

1. **Visual clutter on tall lists**: many categories × two stock sections could feel busy. Mitigation: category headers are intentionally small (11pt); mega-header suppressed when only one bucket has content.
2. **Sort stability across re-renders**: SwiftUI re-computes `stockBuckets` on every state change. The sort uses `localizedCaseInsensitiveCompare` which is stable. `Product` is `Identifiable` — row identity preserved across re-renders.
3. **`productCategories` not loaded yet**: during initial `loadData()`, categories may briefly be empty. Picker handles this gracefully — falls back to "Uncategorized" for everything until the next render after categories arrive.
4. **Search performance with grouping**: O(n) filter + O(n log n) sort within groups. For typical product catalogs (<200 products) this is sub-millisecond.
5. **Search doesn't collapse the grouping**: if the user types `"co"` and there are two Coke entries — one in `Snacks` and one in `Drinks` — they will see two separate category groups each with one row. The grouping wins over the global fuzzy ranking. This is intentional (preserves the mental model from empty-search) but worth noting; a user expecting a single ranked list of matches may briefly find it surprising.

## Out of scope

- Pre-fetching `productCategories` outside the refill wizard (other surfaces that need them already load via `ProductsViewModel`).
- Multi-category products (the schema is one-to-one).
- User-configurable sort order or filter toggles.
- Pinning recently-used or favorite products at the top.
- Same feature in the PWA / Android.

## Effort estimate

~120 lines of Swift across two files plus four xcstrings keys. Single implementation session.
