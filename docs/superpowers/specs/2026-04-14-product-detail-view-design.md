# Product Detail View

**Date:** 2026-04-14
**Status:** Approved design
**Scope:** `management-frontend` only — no firmware, no MQTT, one additive DB migration.

## Problem

Products appear on many screens (dashboard cards, machine sales, machine trays, warehouse stock, tour history, reports, deals, cash-book) but there is no single place where a user can see everything about one product: where it is stocked, how it is selling, recent sales, warehouse history. Today a user who spots a product in a sales list cannot click through to investigate.

## Goals

1. A dedicated route `/products/[id]` that shows one product end-to-end: master data, stock across warehouses and machines, sales, statistics, warehouse transaction history.
2. Click-through navigation from (almost) every surface that names a product.
3. No regressions on existing screens — especially the multi-step `/refill` wizard whose state must not be destroyed by accidental navigation.
4. Backward-compatible: no firmware changes, no breaking DB changes, no MQTT changes.

## Non-Goals

- No modal / drawer variant. One route, one page.
- No realtime subscriptions on the detail page. Pull-to-refresh is enough; a detail view is a snapshot.
- No edit-product-inline: edits happen through the existing product form (reused from `/products`).
- No new mobile-only or desktop-only layouts. Responsive, but one layout.

## Architecture

### New route

`management-frontend/app/pages/products/[id].vue` — single scrollable page, no tabs. Sections stack top-to-bottom and each shows its own empty state rather than disappearing.

Pattern mirrors `/machines/[id]` (definePageMeta middleware `auth`, i18n, `useRoute().params.id`).

### New composable

`management-frontend/app/composables/useProductDetail.ts`

```ts
export function useProductDetail(productId: Ref<string>) {
  // Fans out with Promise.all, populates:
  // product, kpis, warehouseStock, machineTrays, topMachines,
  // recentSales, warehouseTransactions, chartSeries
  return { /* refs + refresh() */ }
}
```

Fetch strategy: one RPC call for aggregates + parallel table reads for lists. Orientation: `useMachines.fetchMachineStats()` already does this pattern.

### New RPC

`get_product_detail_kpis(p_product_id uuid, p_days int)` — returns a jsonb with:

```json
{
  "warehouse_total_qty": 0,
  "tray_total_stock": 0,
  "tray_total_capacity": 0,
  "sales_today_units": 0,
  "sales_today_revenue": 0,
  "sales_7d_units": 0,
  "sales_7d_revenue": 0,
  "velocity_units_per_day": 0,
  "machine_count": 0,
  "warehouse_count": 0
}
```

Added in a new migration `YYYYMMDDHHMMSS_product_detail_kpis.sql` with `CREATE OR REPLACE FUNCTION`. Security: `SECURITY DEFINER`, early check that caller's `my_company_id()` matches the product's company. No data leak across tenants.

Backward compatibility: additive, no existing callers affected.

### Extracted component

`ProductFormModal.vue` — the product add/edit dialog currently lives inline in `/products/index.vue` (1041 LOC). Extracting it is a prerequisite so the detail page can reuse the same edit flow. This is a scoped refactor, not an unrelated cleanup: the feature cannot be delivered without it.

Props: `{ open, productId? }`. Emits: `{ 'update:open', saved }`. State passes through the existing `useProducts()` composable.

## Page layout

Single column, scrollable, no tabs. Order:

1. **Header row**
   - Back button (→ `router.back()` with fallback to `/products`)
   - Product image (or placeholder)
   - Name, category name, barcode chips, "Discontinued" badge if set
   - "Edit" button → opens `ProductFormModal`

2. **KPI row** (4 cards, responsive: 2×2 on mobile, 4×1 on desktop)
   - Warehouse stock total (sum of batch quantities across all warehouses)
   - Machine stock total (`SUM(current_stock)` across trays) + capacity for context
   - Sales today (units + revenue)
   - Sales velocity (units/day over `companies.velocity_days`) + sales 7d

3. **30-day sales chart** — reuses `ChartAreaInteractive.vue`; toggle revenue/units.

4. **Warehouse stock** — per warehouse: warehouse name + total qty → expandable list of FIFO batches (expiry, quantity, intake date). Min-stock alert indicator when below `product_min_stock.min_qty`.

5. **Machine trays** — table: machine name · slot · `current_stock / capacity` · fill_when_below · last sale time-ago. Machine name links to `/machines/[id]?tab=stock`.

6. **Top machines** — ranked by units sold in last 30 days; small sortable table (machine · units · revenue). Links to `/machines/[id]?tab=sales`.

7. **Recent sales** — last 50 sales: time-ago · machine · channel · price. Row links to `/machines/[id]?tab=sales`.

8. **Warehouse history** — last 50 warehouse transactions: timestamp · warehouse · type (intake / refill / adjustment / waste) · qty · user display name.

Each section has an explicit empty state (e.g. "Not listed in any machine yet.") so the page remains self-explanatory for a brand-new product.

## Data queries

| Section | Source | Notes |
|---|---|---|
| Header | `products` + `product_category` + `product_barcodes` | single `.select('*, product_category(name), product_barcodes(barcode)')` |
| KPIs | RPC `get_product_detail_kpis` | one round-trip |
| Chart | `sales` WHERE `product_id = $id` AND `created_at >= now() - 30d` | client-buckets per day |
| Warehouse stock | `warehouse_stock_batches` WHERE `product_id = $id` AND `quantity > 0` | `ORDER BY expiry_date NULLS LAST`, group client-side by `warehouse_id` |
| Machine trays | `machine_trays(*, vendingMachine(name, id))` WHERE `product_id = $id` | left-join vending machine name |
| Top machines | derived from `sales` grouped by `machine_id` over 30d | optional RPC later; for v1 compute client-side from recent sales window |
| Recent sales | `sales(*, vendingMachine(name, id))` WHERE `product_id = $id` ORDER BY created_at DESC LIMIT 50 | |
| Transactions | `warehouse_transactions(*, warehouses(name), users(display_name))` WHERE `product_id = $id` LIMIT 50 | |

All direct reads rely on existing RLS policies (tenant filter via `my_company_id()`).

### sales.product_id

The sales table carries an immutable `product_id` snapshot stamped by the `stamp_machine_and_decrement_stock` BEFORE INSERT trigger (migration `20260412000000_sales_product_id_snapshot.sql`). All product-scoped sales queries use `sales.product_id = $id` directly — no `machine_trays` join needed. Rows with `product_id IS NULL` (rare: old un-backfilled sales, or product deleted since → ON DELETE SET NULL) are simply invisible to the detail page for that product, which is correct.

## Clickability strategy

Mixed: full-row click where no row-level action exists, name/image click where it does. Hover affordance (`cursor: pointer` + subtle background) everywhere a click is active. On Vue `@click.stop` on any action buttons nested inside a clickable row.

| Surface | Click target | Rationale |
|---|---|---|
| `DashboardTopProducts` | full card | no conflicts |
| `DashboardRecentSales` | full row (if `product_id` present) | no conflicts |
| `/machines/[id]` Sales tab | full row (if `product_id` present) | delete button needs `@click.stop` |
| `/machines/[id]` Trays tab | product name/image only | row has edit/refill actions |
| `/products/index.vue` | product name/image only | row click = open edit modal (preserve) |
| `/warehouse` stock + batches | product name/image only | many action buttons per row |
| `/tour-history` | full item row | static display |
| `/reports`, `/cash-book`, `/deals` | product name/image where shown | varies per table |
| `/refill` wizard | **not clickable** | wizard state must not be lost |

A sale row is clickable iff `sales.product_id` resolves. The UI detects this and simply does not apply the clickable class / navigation when null. No tooltip or flash: the absence is silent.

## Routing & navigation

- `<NuxtLink :to="/products/${id}">` everywhere — deep-linkable, browser back works, preserves scroll on the source screen via Nuxt's default behavior.
- Back from detail: `router.back()` if history depth > 1, else `router.push('/products')`.
- Deep-link refresh lands on the detail page; the auth middleware gates it like any other protected route.

## i18n

New keys under `products.detail.*` in `en.json` and `de.json`:

- `header.back`, `header.edit`, `header.discontinued`
- `kpi.warehouse_stock`, `kpi.machine_stock`, `kpi.sales_today`, `kpi.velocity`
- `sections.chart`, `sections.warehouse_stock`, `sections.machine_trays`, `sections.top_machines`, `sections.recent_sales`, `sections.history`
- `empty.no_trays`, `empty.no_stock`, `empty.no_sales`, `empty.no_transactions`

No new languages, no change to locale loading.

## Error handling

- Invalid `id` (not a UUID, or no product found / not in caller's company via RLS): show a full-page "Product not found" state with a link back to `/products`. Matches `/machines/[id]` behavior.
- RPC failure: show a page-level error banner and retry button; sections that loaded successfully still render.
- Individual section fetch failure: inline error in that section, others unaffected.

## Testing

- Unit test for `useProductDetail` with mocked Supabase client (uses `app/test-helpers/nuxt-stubs.ts`) — verifies parallel fetches, empty-state handling for sections that return 0 rows, and `product_id IS NULL` invisibility.
- RPC test (Deno) in `Docker/supabase/tests/` if the project has a test harness; otherwise manual smoke via `curl` + JWT against local Supabase.
- Smoke test: click from each of the listed surfaces lands on `/products/[id]` with the right id; back button returns. No keyboard test — feature is pointer-driven.

## Migration plan

1. Extract `ProductFormModal.vue` from `/products/index.vue`. Existing page keeps working unchanged.
2. New migration file `Docker/supabase/migrations/YYYYMMDDHHMMSS_product_detail_kpis.sql` adds `get_product_detail_kpis`.
3. New composable `useProductDetail.ts`.
4. New page `products/[id].vue`.
5. Wire click-throughs one surface at a time (dashboard cards → machine sales → warehouse → tour-history → reports/cash-book/deals).
6. i18n keys.
7. Tests.

Each step is independently mergeable and leaves the app in a working state.

## Backward compatibility

- DB: new RPC only. `CREATE OR REPLACE FUNCTION`. No column or constraint changes.
- Frontend: all source surfaces remain functional if the detail page is unreachable — clickability is an additive enhancement, not a replacement for existing row actions.
- Firmware / MQTT / Edge functions: untouched.

## Risks & mitigations

- **Wizard state loss on `/refill`**: explicitly excluded from clickability. Enforced by not adding the click handler on those rows.
- **Row click vs action button conflict**: every action button inside a now-clickable row gets `@click.stop`. This is a review-checklist item, not an abstraction.
- **Performance on products that sell a lot**: Recent sales and chart window are both bounded (LIMIT 50, 30 days). KPI aggregates happen server-side.
- **Top machines computed client-side for v1**: acceptable because the dataset is already bounded to one product's sales; if it grows unwieldy later, promote the computation into the same RPC.
- **`ProductFormModal` extraction risk**: the /products page is 1041 LOC with the modal inline — extraction must be a pure refactor with no behavior change. Verified by keeping the /products page's tests green.

## Open questions (resolved during design)

- Route vs modal → **route** (`/products/[id]`)
- Where clickable → **everywhere except `/refill`**
- Layout → **single scrollable page, no tabs**
- Sale → product lookup → **direct via `sales.product_id`**, null means not clickable
- Click UX → **mix**: full-row where no row-level action exists, name/image only where it does
