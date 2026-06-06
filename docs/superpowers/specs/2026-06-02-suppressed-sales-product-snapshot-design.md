# Suppressed sales: snapshot product + show image/name (PWA + iOS)

**Date:** 2026-06-02
**Area:** `Docker/supabase` (migration + `mqtt-webhook`), `management-frontend` (PWA), `ios/VMflow`
**Type:** Additive — snapshot `product_id` on suppression + surface product image/name in both clients

## Problem / goal

The per-machine "auto-removed duplicates" list (PWA Device Health card + iOS Duplicates tab) currently shows time / slot / price / channel / reason. The user wants it to also show the **product image + name**, like the Sales view — but **immutably snapshotted to the product that was in the slot at suppression time**. If a tray is later reassigned to a different product, the suppressed list must keep showing the original product.

The `suppressed_sales` table has no product reference, so resolving by the *current* tray (`item_number → machine_trays.product_id`) would change retroactively — exactly what must not happen. This mirrors why `sales.product_id` is snapshotted at INSERT rather than joined live through trays.

## Approach (chosen: A)

Snapshot `product_id` onto each `suppressed_sales` row at suppression time, copied from the **matched original sale** (`matched_sale_id → sales.product_id`) — which already carries an immutable product snapshot stamped by the sales trigger at vend time. Clients then join `products(name, image_path)` directly (one level), exactly like the Sales view. Durable: survives tray reassignment **and** later deletion of the matched sale (the `product_id` lives on the suppressed row itself).

Rejected: joining live through `matched_sale_id → sales → products` at read time (no migration, but two-level embed in both clients and it breaks if the matched sale is later deleted, e.g. via the Nayax ghost-delete).

## Design

### 1. DB — new migration `20260602140000_suppressed_sales_product_id.sql`

`suppressed_sales` (added in `20260602130000`) is already on `main` → immutable → new migration. Idempotent/additive:

```sql
alter table public.suppressed_sales
  add column if not exists product_id uuid references public.products(id) on delete set null;

create index if not exists suppressed_sales_product_id_idx
  on public.suppressed_sales (product_id);

-- Backfill existing rows from their matched sale's immutable product snapshot.
update public.suppressed_sales s
set product_id = sa.product_id
from public.sales sa
where sa.id = s.matched_sale_id
  and s.product_id is null
  and sa.product_id is not null;

comment on column public.suppressed_sales.product_id is
  'Immutable snapshot of the product sold, copied from the matched sale at suppression time. Independent of later tray reassignment.';
```
No RLS change (column on an already-RLS'd table; the existing `suppressed_sales_select_own` policy governs the row, and `products` has its own company-scoped RLS for the join).

### 2. Webhook — snapshot `product_id` from the matched sale

In `mqtt-webhook/index.ts`, the existing suppression guard already runs a candidate query and `decideSuppress` returns the matched row's `id`. Two minimal changes:
- Extend the candidate `select` from `'id, created_at'` to `'id, created_at, product_id'`.
- After `matchedId` is determined, look up that row's `product_id` and include it in the `suppressed_sales` insert:
  ```ts
  const matchedRow = (candRows ?? []).find((r) => r.id === matchedId);
  // … insert: product_id: matchedRow?.product_id ?? null
  ```
  Also update the candidate-row TS type used in the `.find`/map (currently `{ id: string; created_at: string }`) to include `product_id: string | null`, so the snapshot value isn't dropped by the cast.
Everything else (the time_uncertain gate, ±30s window, fail-safe fall-through on insert error) is unchanged.

### 3. PWA — image + name on the suppressed card

- `app/composables/useSuppressedSales.ts`: change `select('*')` → `select('*, products(name, image_path)')` (the FK now exists). Extend the `SuppressedSale` interface with `product_id: string | null` and `products?: { name: string; image_path: string | null } | null`.
- `app/pages/machines/[id].vue`: add a `suppressedProduct(row)` resolver mirroring the existing `saleProduct(sale)` (lines ~376-387): prefer the joined product (`row.products?.name` + `getProductImageUrl(row.products.image_path)`), fall back to `trayProductMap.get(row.item_number)` only when `product_id`/`products` is null (legacy rows). Restructure the suppressed row to mirror a Sales row: **leading product thumbnail + product name** primary line; channel / slot / "likely brownout re-report" secondary; price + time trailing. Reuse the same image/name markup the Sales rows use.

### 4. iOS — image + name on `SuppressedSaleRow`

- `ios/VMflow/Models/SuppressedSale.swift`: add `let productId: UUID?` and `let products: SaleProduct?` (reuse the existing `SaleProduct` struct from `Sale.swift` — `name` + `image_path`), with matching `CodingKeys` (`product_id`, `products`).
- `ios/VMflow/ViewModels/MachineDetailViewModel.swift`: extend the `loadSuppressedSales` select to `… , product_id, products(name, image_path)`.
- `ios/VMflow/Views/Machines/MachineDetailView.swift`: `SuppressedSaleRow` takes `trays: [Tray]` (like `SaleRow`); resolve name = `sale.products?.name ?? trays.first { $0.itemNumber == sale.itemNumber }?.productName ?? "Slot N"`, image = `sale.products?.imagePath ?? <that tray>.products?.imagePath` → `ProductImage(imagePath:, size: 44)` — mirroring `SaleRow`'s `productName`/`productImagePath`. Pass `viewModel.trays` at the call site (`ForEach … SuppressedSaleRow(sale:, trays: viewModel.trays)`).

## Resolution precedence (both clients)
1. **Snapshot** — the row's `product_id` join (`products.name` + `image_path`). Immutable; the intended source.
2. **Tray fallback** — by `item_number`, only when `product_id` is null (legacy pre-snapshot rows the backfill couldn't fill because their matched sale was already deleted). Mutable, but only for those rare rows.
3. **"Slot N"** + image placeholder when neither resolves.

## Backward compatibility / scope
- Additive column (nullable) + backfill; existing webhook behavior unchanged except the added snapshot. v1 firmware / normal sales unaffected (the guard is still `time_uncertain`-gated).
- Migration auto-applies to prod via `update.sh` and to dev via `supabase --workdir Docker migration up`. No new env vars / edge functions / config.toml.
- No change to the suppression decision logic, the audit semantics, or any other surface.

## Testing / verification
- **Migration:** apply to dev; psql — column exists; backfill populated `product_id` on existing rows that have a matched sale with a product (`SELECT count(*) FILTER (WHERE product_id IS NOT NULL) …`).
- **Immutability check (psql, rolled back):** pick a suppressed row with a product; change the corresponding tray's `product_id`; re-read the suppressed row's joined product → confirm it is **unchanged** (proves the snapshot is independent of the tray). ROLLBACK.
- **Webhook:** existing Deno tests stay green (the `decideSuppress` pure logic is unchanged); the `product_id` wiring is a straight field copy (verified by reading + the psql immutability check).
- **PWA:** `npx vitest run` green; the card shows image+name; verified via preview if reachable.
- **iOS:** manual Xcode build (no harness). Re-check for in-flight `ios/` changes before committing (the View file is committed at HEAD now, so this round's edits should commit cleanly — confirm at execution).

## Files touched
| File | Change |
|------|--------|
| `Docker/supabase/migrations/20260602140000_suppressed_sales_product_id.sql` | NEW: add `product_id` + backfill |
| `Docker/supabase/functions/mqtt-webhook/index.ts` | candidate select += `product_id`; insert += snapshot `product_id` |
| `management-frontend/app/composables/useSuppressedSales.ts` | join `products`; interface += `product_id`/`products` |
| `management-frontend/app/pages/machines/[id].vue` | `suppressedProduct` resolver + image/name row layout |
| `ios/VMflow/Models/SuppressedSale.swift` | += `productId` + `products: SaleProduct?` |
| `ios/VMflow/ViewModels/MachineDetailViewModel.swift` | `loadSuppressedSales` select += product join |
| `ios/VMflow/Views/Machines/MachineDetailView.swift` | `SuppressedSaleRow` image+name + `trays` param |
