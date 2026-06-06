# Suppressed Sales — Product Snapshot + Image/Name Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Snapshot an immutable `product_id` onto each `suppressed_sales` row (copied from the matched sale, backfilled for existing rows), and show the product image + name in the PWA and iOS "auto-removed duplicates" lists — frozen to the product at suppression time (tray reassignment doesn't change it).

**Architecture:** `suppressed_sales` gains a `product_id` FK (snapshot). The webhook copies it from the matched sale at suppression time. Both clients join `products(name, image_path)` via that `product_id` (like the Sales view) and render image+name, falling back to the current tray only for legacy null-snapshot rows.

**Tech Stack:** Supabase Postgres + RLS, Deno edge function, Nuxt 4 + Vue 3 + TS (PWA), SwiftUI + supabase-swift (iOS).

**Spec:** `docs/superpowers/specs/2026-06-02-suppressed-sales-product-snapshot-design.md`

**Skills:** @superpowers:verification-before-completion before claiming done.

---

## File Structure

| File | Change |
|------|--------|
| `Docker/supabase/migrations/20260602140000_suppressed_sales_product_id.sql` | NEW: add `product_id` + backfill |
| `Docker/supabase/functions/mqtt-webhook/index.ts` | candidate select/cast += `product_id`; insert snapshot |
| `management-frontend/app/composables/useSuppressedSales.ts` | join `products`; interface += `product_id`/`products` |
| `management-frontend/app/pages/machines/[id].vue` | `suppressedProduct()` resolver + image/name in the card rows |
| `ios/VMflow/Models/SuppressedSale.swift` | += `productId` + `products: SaleProduct?` |
| `ios/VMflow/ViewModels/MachineDetailViewModel.swift` | `loadSuppressedSales` select += product join |
| `ios/VMflow/Views/Machines/MachineDetailView.swift` | `SuppressedSaleRow` image+name + `trays` param |

**Commit scoping (every task):** stage ONLY the files that task changes — **never `git add -A`**. Unrelated working-tree files (`README.md`, `docs/screenshots/`, `MMM-VMflow/`, `tmp/`, any in-flight `ios/` work) must not be swept in. Branch: stay on `main`.

---

## Chunk 1: Backend (migration + webhook snapshot)

### Task 1.1: `product_id` migration + backfill

**Files:** Create `Docker/supabase/migrations/20260602140000_suppressed_sales_product_id.sql`

- [ ] **Step 1: Create the migration:**

```sql
-- =========================================================
-- suppressed_sales.product_id: immutable product snapshot
--
-- The product that was in the slot at suppression time, copied from the
-- matched sale's own immutable product_id snapshot. Independent of later
-- tray reassignment. Additive/idempotent.
-- =========================================================
alter table public.suppressed_sales
  add column if not exists product_id uuid references public.products(id) on delete set null;

create index if not exists suppressed_sales_product_id_idx
  on public.suppressed_sales (product_id);

-- Backfill existing rows from their matched sale's product snapshot.
update public.suppressed_sales s
set product_id = sa.product_id
from public.sales sa
where sa.id = s.matched_sale_id
  and s.product_id is null
  and sa.product_id is not null;

comment on column public.suppressed_sales.product_id is
  'Immutable snapshot of the product sold, copied from the matched sale at suppression time. Independent of later tray reassignment.';
```

- [ ] **Step 2: Apply to dev** — `supabase --workdir Docker migration up` (per memory: `--workdir Docker`, NOT `cd`; NEVER `db reset`). If it errors, report BLOCKED with the error.

- [ ] **Step 3: Verify column + backfill via psql:**

```bash
docker exec -i supabase_db_mdb-esp32-cashless psql -U postgres -d postgres -c "\d public.suppressed_sales" -c "SELECT count(*) AS total, count(product_id) AS with_product FROM public.suppressed_sales;"
```
Expected: `product_id uuid` column present + FK; `with_product` ≥ the number of existing rows whose matched sale has a product (if there are existing suppressed rows; 0/0 is fine on a fresh dev DB).

- [ ] **Step 4: Immutability check (rolled back — proves snapshot is tray-independent).** Only meaningful if a suppressed row with a product + a matching tray exists; if none exist in dev, note "no data to exercise" and skip:

```bash
docker exec -i supabase_db_mdb-esp32-cashless psql -U postgres -d postgres <<'SQL'
\set ON_ERROR_STOP on
BEGIN;
SELECT s.id AS sid, s.product_id AS pid, s.embedded_id AS eid, s.item_number AS itm
FROM public.suppressed_sales s WHERE s.product_id IS NOT NULL LIMIT 1 \gset
-- flip the tray's product for that slot to a DIFFERENT product
UPDATE public.machine_trays mt
SET product_id = (SELECT id FROM public.products WHERE id <> :'pid' LIMIT 1)
WHERE mt.item_number = :itm
  AND mt.machine_id = (SELECT id FROM public."vendingMachine" WHERE embedded = :'eid' LIMIT 1);
-- the suppressed row's snapshot must be unchanged
SELECT (product_id = :'pid') AS snapshot_unchanged
FROM public.suppressed_sales WHERE id = :'sid';
ROLLBACK;
SQL
```
Expected: `snapshot_unchanged = t` (the suppressed row still points at its snapshot product even though the tray now holds a different one).

- [ ] **Step 5: Commit**

```bash
git add Docker/supabase/migrations/20260602140000_suppressed_sales_product_id.sql
git commit -m "feat(db): snapshot product_id on suppressed_sales (+ backfill)"
```

### Task 1.2: Webhook writes the snapshot

**Files:** Modify `Docker/supabase/functions/mqtt-webhook/index.ts` (the suppression guard block, ~lines 431-467)

- [ ] **Step 1: Add `product_id` to the candidate query + its row type.** In the candidate select, change `'id, created_at'` → `'id, created_at, product_id'`. Update the `.map`/`.find` row type annotation from `{ id: string; created_at: string }` to `{ id: string; created_at: string; product_id: string | null }` so the snapshot value isn't dropped by the cast.

- [ ] **Step 2: Snapshot it on the insert.** After `matchedId` is computed and before/at the `suppressed_sales` insert, resolve the matched row's product and add the field:
```ts
const matchedRow = (candRows ?? []).find((r) => r.id === matchedId);
// in the .insert([{ … }]) object, add:
product_id: matchedRow?.product_id ?? null,
```
Leave the time_uncertain gate, ±30s window, and fail-safe fall-through unchanged.

- [ ] **Step 3: Verify** the webhook still type-checks / the existing Deno tests pass (decideSuppress is unchanged):

Run: `cd Docker/supabase/functions/mqtt-webhook && deno test suppress.test.ts`
Expected: 6 passed.

- [ ] **Step 4: End-to-end snapshot simulation (rolled back):** simulate a suppression and confirm the inserted `suppressed_sales` row carries the matched sale's `product_id`:

```bash
docker exec -i supabase_db_mdb-esp32-cashless psql -U postgres -d postgres <<'SQL'
\set ON_ERROR_STOP on
BEGIN;
SELECT id AS mid, embedded_id AS eid, item_number AS itm, item_price AS prc, channel AS chn, product_id AS pid
FROM public.sales WHERE product_id IS NOT NULL AND embedded_id IS NOT NULL ORDER BY created_at DESC LIMIT 1 \gset
INSERT INTO public.suppressed_sales (embedded_id, item_number, item_price, channel, reason, matched_sale_id, product_id)
VALUES (:'eid', :itm, :prc, :'chn', 'time_uncertain_duplicate', :'mid', :'pid');
SELECT (product_id = :'pid') AS product_snapshotted FROM public.suppressed_sales WHERE matched_sale_id = :'mid' ORDER BY received_at DESC LIMIT 1;
ROLLBACK;
SQL
```
Expected: `product_snapshotted = t`. (Validates the table accepts + stores the snapshot; the webhook code path is a straight field copy verified by reading.)

- [ ] **Step 5: Commit**

```bash
git add Docker/supabase/functions/mqtt-webhook/index.ts
git commit -m "feat(webhook): snapshot matched sale's product_id onto suppressed_sales"
```

> **Chunk 1 gate:** migration applied + immutability psql check passes; deno test 6/6; snapshot simulation passes.

---

## Chunk 2: PWA — image + name on the suppressed card

### Task 2.1: Composable joins products

**Files:** Modify `management-frontend/app/composables/useSuppressedSales.ts`

- [ ] **Step 1:** In BOTH `fetchRows` and `fetchMore`, change `.select('*')` → `.select('*, products(name, image_path)')`.
- [ ] **Step 2:** Extend the `SuppressedSale` interface:
```ts
  product_id: string | null
  products?: { name: string; image_path: string | null } | null
```
- [ ] **Step 3:** `cd management-frontend && npx vitest run` → green (no logic test; guards against type/syntax regression).
- [ ] **Step 4:** Commit — `git add app/composables/useSuppressedSales.ts` → `feat(pwa): join product on useSuppressedSales`.

### Task 2.2: Resolver + card row layout

**Files:** Modify `management-frontend/app/pages/machines/[id].vue`

- [ ] **Step 1: Add a `suppressedProduct(row)` resolver** next to `saleProduct` (~line 387), mirroring it (snapshot join first, tray fallback for null-snapshot rows):
```ts
function suppressedProduct(row: any): { name: string; image_url: string | null } | null {
  if (row.products?.name) {
    const imagePath = row.products.image_path
    return { name: row.products.name, image_url: imagePath ? getProductImageUrl(imagePath) : null }
  }
  const tray = trayProductMap.value.get(row.item_number)
  if (tray) return { name: tray.name, image_url: tray.image_url }
  return null
}
```
- [ ] **Step 2: Render image + name in the suppressed card rows.** Read how the Sales-tab rows render the product thumbnail + name, and restructure the suppressed rows to match: a **leading product thumbnail** (use `suppressedProduct(row)?.image_url`; same placeholder the Sales rows use when null) and the **product name** as the primary text, with the existing slot/channel/reason as secondary and price/time trailing. Use the same image element + classes the Sales rows use. When `suppressedProduct(row)` is null, show `Slot {{ row.item_number }}` + the placeholder (mirrors Sales' `Item #N`).
- [ ] **Step 3:** `npx vitest run` → green; `npx nuxi typecheck 2>&1 | grep -E "useSuppressedSales|machines/\[id\]"` → no NEW errors vs the known pre-existing ones.
- [ ] **Step 4:** Commit — `git add app/pages/machines/[id].vue` → `feat(pwa): show product image + name on auto-removed duplicates`.

> **Chunk 2 gate:** vitest green; no new typecheck errors. Card shows the snapshot product image+name.

---

## Chunk 3: iOS — image + name on `SuppressedSaleRow` (additive)

> **iOS commit handling:** `MachineDetailView.swift` / `MachineDetailViewModel.swift` are committed at HEAD now. **First run `git status -s` on them.** If they have NO uncommitted changes, commit this round's edits normally (per-file, scoped). If they DO have new in-flight changes (the user resumed iOS work), make additive edits and leave them UNSTAGED for the user (report the diffs) — same discipline as the prior iOS chunk. The new model file commits normally either way. Never `git add -A`.

### Task 3.1: Model gains the product

**Files:** Modify `ios/VMflow/Models/SuppressedSale.swift`

- [ ] **Step 1:** Add `let productId: UUID?` and `let products: SaleProduct?` (reuse the `SaleProduct` struct from `Sale.swift`), and the `CodingKeys`: `case productId = "product_id"`, `case products`.
- [ ] **Step 2:** Commit — `git add ios/VMflow/Models/SuppressedSale.swift` → `feat(ios): SuppressedSale carries snapshot product`.

### Task 3.2: ViewModel selects the product join

**Files:** Modify `ios/VMflow/ViewModels/MachineDetailViewModel.swift` (`loadSuppressedSales`)

- [ ] **Step 1:** Append `product_id, products(name, image_path)` to the `loadSuppressedSales` `.select(...)` column list.
- [ ] **Step 2:** Commit-or-leave per the iOS commit-handling note (commit if the file is otherwise clean; else leave unstaged + report).

### Task 3.3: Row shows image + name

**Files:** Modify `ios/VMflow/Views/Machines/MachineDetailView.swift`

- [ ] **Step 1:** Give `SuppressedSaleRow` a `let trays: [Tray]` parameter (like `SaleRow`). Resolve, mirroring `SaleRow`'s `productName`/`productImagePath`:
  - `productName = sale.products?.name ?? trays.first { $0.itemNumber == sale.itemNumber }?.productName ?? "Slot \(sale.itemNumber ?? 0)"`
  - `productImagePath = sale.products?.imagePath ?? trays.first { $0.itemNumber == sale.itemNumber }?.products?.imagePath`
  - Render a leading `ProductImage(imagePath: productImagePath, size: 44)` and the `productName` as the primary text (keep the channel/slot/"likely brownout re-report" caption + price/time).
- [ ] **Step 2:** Update the call site in `suppressedTab`: `SuppressedSaleRow(sale: sale, trays: viewModel.trays)`.
- [ ] **Step 3:** Commit-or-leave per the iOS commit-handling note. (No iOS build harness — note the user verifies in Xcode.)

> **Chunk 3 gate:** model committed; VM/View per the commit-handling note; symbols line up (`SuppressedSale.products`/`productId` defined, View references them, `SaleProduct` reused).

---

## Done criteria
- Migration applied; `product_id` column + backfill; immutability psql check shows the snapshot is unaffected by a tray product change.
- deno test 6/6; webhook writes the matched sale's `product_id`.
- `npx vitest run` green; no new typecheck errors in the touched PWA files; the PWA card shows snapshot product image+name.
- iOS: model carries the snapshot product; VM joins it; `SuppressedSaleRow` shows image+name; committed (or left unstaged for the user) per the in-flight-work check; builds in Xcode.
- Immutable: reassigning a slot's product does not change what the suppressed list shows. Tray fallback applies only to legacy null-`product_id` rows.
- Unrelated working-tree files untouched; commits scoped.
