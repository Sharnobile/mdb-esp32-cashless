# Warehouse-Aware Stock Health on Machine Cards

## Problem

The `/machines` page shows stock urgency badges (critical/low/ok) based purely on tray stock levels vs. min_stock thresholds. A tray marked "1 low" might contain a product that is no longer in warehouse stock, making a refill impossible. Operators waste time planning refill tours for products they can't actually restock.

## Solution

Enhance the stock health calculation in `useMachines` to cross-reference warehouse inventory. Trays with low/empty stock are split into two categories: **refillable** (product available in at least one warehouse) and **no-stock** (product unavailable). The machine card UI shows both counts separately, with a product list indicating per-product warehouse availability.

### 1. Data: Warehouse Stock Lookup

In `useMachines.fetchMachines()`, add a single additional query:

```ts
const { data: stockBatches } = await supabase
  .from('warehouse_stock_batches')
  .select('product_id, quantity')
  .gt('quantity', 0)
```

Aggregate into a `Map<string, number>` summing `quantity` per `product_id` across all warehouses for the company (RLS already scopes to company). The `.gt('quantity', 0)` filter matches the existing pattern in `useRefillWizard.ts` and avoids fetching depleted batch rows.

### 2. Stock Health Calculation Changes

Currently (Pass 1 in `fetchMachines`), each tray is classified as `isEmpty`, `isLow`, or `isFillBelow`. The change adds a warehouse check to `isEmpty` and `isLow` classifications:

```
For each tray where isEmpty OR isLow:
  If tray.product_id == null:
    → skip (unassigned trays are ignored entirely)

  in_stock = warehouseStock.has(tray.product_id)

  If in_stock:
    → count toward refillable_empty / refillable_low
  Else:
    → count toward no_stock_empty / no_stock_low
```

`isFillBelow` trays follow existing Pass 2 logic — they are only added to the packing list when the machine already has refillable low/empty trays (`low + empty > 0`). The warehouse check for `isFillBelow` entries uses the same `in_stock` lookup but these trays do not independently trigger stock_health changes.

**`stock_health` is determined only by refillable trays:**
- `'critical'` if `refillable_empty > 0`
- `'low'` if `refillable_low > 0`
- `'ok'` otherwise

**Fallback when no warehouses exist:** If `warehouse_stock_batches` returns empty (no warehouses configured), all trays are treated as refillable — identical to current behavior.

### 3. Machine Data Shape Changes

The per-machine object gains new fields:

```ts
// Existing (unchanged)
stock_health: 'critical' | 'low' | 'ok'
stock_percent: number
low_trays: number        // refillable low + empty count
empty_trays: number      // refillable empty count
tray_summary: TrayItem[]

// New
no_stock_trays: number   // count of low/empty trays with no warehouse stock
no_stock_summary: TrayItem[]  // product names for no-stock trays
```

`tray_summary` entries gain an `in_stock: boolean` field.

The `VendingMachine` interface in `useMachines.ts` must be updated with these new fields. The `RefillItem` interface in `useRefillWizard.ts` must also gain `in_stock?: boolean` (optional for backward compatibility with persisted tour state in localStorage).

### 4. UI on Machine Card (Ansatz A: Badges + Product List)

**Stock section on each card (when stock_health !== 'ok' OR no_stock_trays > 0):**

Two badges in a row:
- Red badge: `"X refill nötig"` (refillable low/empty count) — only shown if > 0
- Gray badge: `"Y kein Lager"` (no-stock count) — only shown if > 0

Below badges, a product list (from `tray_summary`):
- Refillable products: colored text (red if empty, amber if low) with deficit number, green "auf Lager" label on right
- No-stock products: dimmed (opacity-50), gray "kein Lager" label on right, sorted to bottom of list

Stock percentage bar remains unchanged.

**When machine is fully ok AND no_stock_trays === 0:** Show existing "All stocked" message.

**When machine is fully ok BUT no_stock_trays > 0:** Show green "All stocked" for refillable context, plus gray "Y kein Lager" badge with dimmed product names.

### 5. Sorting

Machine card sort order remains based on refillable urgency:
1. Critical (refillable empty > 0) — sorted by refillable low_trays desc
2. Low (refillable low > 0) — sorted by refillable low_trays desc
3. Ok — sorted by name

No-stock-only machines are NOT promoted to critical/low. They stay in the "ok" group.

### 6. Files Changed

| File | Change |
|------|--------|
| `management-frontend/app/composables/useMachines.ts` | Add warehouse query, split stock counts, update `VendingMachine` interface, add `no_stock_trays`/`no_stock_summary`/`in_stock` fields |
| `management-frontend/app/composables/useRefillWizard.ts` | Add `in_stock?: boolean` to `RefillItem` interface |
| `management-frontend/app/pages/machines/index.vue` | Update stock section: two badges, product list with in_stock indicator |
| `management-frontend/i18n/locales/en.json` | New keys: `machines.refillNeeded`, `machines.noWarehouseStock`, `machines.inStock`, `machines.noStock` |
| `management-frontend/i18n/locales/de.json` | German translations |

### 7. What Does NOT Change

- No database migrations
- No new API endpoints or edge functions
- No changes to warehouse composable or tray composable (except `RefillItem` type addition)
- Backward-compatible: if no warehouses exist, behavior is identical to current
- `stock_percent` calculation unchanged (still based on all trays)

**Intentional behavior changes to refill tour:**
- `machinesNeedingRefill` in the refill wizard filters by `stock_health !== 'ok'`. Machines where ALL low/empty trays are no-stock will now have `stock_health = 'ok'` and will be excluded from refill tours. This is intentional — there is nothing to refill.
- The "Start Refill Tour" button on `/machines` uses the same `stock_health` check and will also exclude no-stock-only machines. This is correct because the tour should only include actionable refills.

### 8. Edge Cases

- **No warehouses configured:** All trays treated as refillable. UI looks identical to current.
- **Product has 0 warehouse stock across all warehouses:** Tray classified as no-stock.
- **Tray with no product assigned (`product_id = null`):** Ignored entirely — does not count toward any stock health category. There is nothing to refill without a product assignment.
- **Product exists in warehouse but quantity is 0:** Classified as no-stock (sum is 0).
- **All low trays are no-stock:** Machine shows `stock_health = 'ok'` with gray "X kein Lager" badge. Not promoted to critical/low since nothing can be refilled.

### 9. Performance

One additional query (`warehouse_stock_batches` select) runs in the existing `Promise.all` batch. The aggregation to a Map is O(n) where n = number of batches. No additional queries per machine or per tray.
