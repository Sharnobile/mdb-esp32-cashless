# History Page Detail Enrichment Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `/history` show what an operator actually needs — product name/image on real MDB sales, the actual per-item refill breakdown on tour refills, and an expandable "technical details" panel with sale dedup fields (`sale_seq`, `time_uncertain`) for diagnosing duplicate sales.

**Architecture:** Two small additive backend/composable changes feed richer `jsonb metadata` into the existing `activity_log` table (no schema change). A shared, pure, unit-tested descriptor layer (`activityDescriptor.ts`) turns that metadata into product-reference lists and curated detail rows. The `/history` page consumes the new descriptor functions to render a compact per-row summary plus an optional expand-to-reveal panel.

**Tech Stack:** Nuxt 4 (Vue 3, `<script setup>`), TypeScript, Vitest, Deno edge function (Supabase), `@nuxtjs/i18n`.

**Spec:** `docs/superpowers/specs/2026-07-17-history-page-detail-enrichment-design.md`

---

## Chunk 1: Backend + composable metadata enrichment

### Task 1: Enrich `sale_recorded` activity_log metadata in the MQTT webhook

**Files:**
- Modify: `Docker/supabase/functions/mqtt-webhook/index.ts:620-631`

This is a Deno edge function with no dedicated test harness for this code
path (the only test file, `mdb-log.test.ts`, covers a different topic) —
per the spec, this is a pure additive metadata write inside an existing
best-effort `try/catch`, so there's no new automated test to write here.
Verify manually in Task 10.

- [ ] **Step 1: Read the current insert to confirm exact surrounding code**

Run: `sed -n '610,635p' Docker/supabase/functions/mqtt-webhook/index.ts`

Confirm the block looks like:

```ts
      // ── Activity log (best-effort) ──────────────────────────────────────────
      try {
        await adminClient.from('activity_log').insert({
          company_id: embedded.company,
          entity_type: 'sale',
          entity_id: embedded.id,
          action: 'sale_recorded',
          metadata: {
            item_number: itemNumber,
            price: salePrice,
            channel,
            device_id: embedded.id,
          },
        });
      } catch (logErr) {
        console.error('Activity log error:', logErr);
      }
```

If the surrounding code has drifted from this (line numbers or variable
names differ), re-read a wider range (`sed -n '470,635p' ...`) before
editing — `tray`, `productName`, `saleSeq`, and `timeUncertain` must all
still be in scope at this point in the function.

- [ ] **Step 2: Add the four new metadata fields**

Change the `metadata` object to:

```ts
          metadata: {
            item_number: itemNumber,
            price: salePrice,
            channel,
            device_id: embedded.id,
            product_id: tray?.product_id ?? null,
            product_name: productName ?? null,
            sale_seq: saleSeq,
            time_uncertain: timeUncertain,
          },
```

Do not change anything else in this function — `tray`/`productName` are
already resolved above for the push notification and are null-safe as-is;
`saleSeq`/`timeUncertain` are already resolved above for the dedup/suppress
logic.

- [ ] **Step 3: Sanity-check the file still parses**

Run: `cd Docker/supabase/functions/mqtt-webhook && deno check index.ts`
Expected: no new type errors introduced by this change (pre-existing errors,
if any, are not this task's concern — just confirm nothing new appears
around line 620-635).

- [ ] **Step 4: Commit**

```bash
git add Docker/supabase/functions/mqtt-webhook/index.ts
git commit -m "feat(mqtt-webhook): log product + dedup fields on sale_recorded

sale_recorded activity_log rows were missing product_id/product_name
(so /history couldn't show a thumbnail) and sale_seq/time_uncertain
(so operators had no way to tell a genuine repeat sale from a firmware
double-report). All four values were already resolved a few lines above
for the push notification / dedup logic — just persisting them now."
```

---

### Task 2: Extract a pure, testable refill-snapshot builder in `useRefillWizard.ts`

**Files:**
- Modify: `management-frontend/app/composables/useRefillWizard.ts`
- Test: `management-frontend/app/composables/__tests__/useRefillWizard.refillSnapshot.test.ts`

Mirrors the existing `buildTourStartedEntry` pattern in the same file — a
pure, module-level exported function with no Nuxt runtime dependency, so it
can be unit tested directly (see
`useRefillWizard.tourStarted.test.ts` for the harness pattern this test
file reuses).

- [ ] **Step 1: Read the current `RefillRpcRow` interface and `TrayForRefill` type**

Run: `grep -n "interface RefillRpcRow" -A 8 app/composables/useRefillWizard.ts`
Run: `grep -n "interface TrayForRefill" -A 12 app/composables/useRefillWizard.ts`

Confirm:
```ts
interface RefillRpcRow {
  tray_id: string
  old_stock: number
  new_stock: number
  fill_amount: number
  was_already_applied: boolean
}
```
```ts
export interface TrayForRefill {
  id: string
  item_number: number
  product_id: string | null
  product_name: string | null
  image_path: string | null
  sellprice: number | null
  capacity: number
  current_stock: number
  min_stock: number
  fill_when_below: number
  ...
}
```

- [ ] **Step 2: Write the failing test**

Create `management-frontend/app/composables/__tests__/useRefillWizard.refillSnapshot.test.ts`:

```ts
import { describe, it, expect } from 'vitest'
import { buildRefillSnapshot } from '../useRefillWizard'

describe('buildRefillSnapshot', () => {
  const traysToRefill = [
    { id: 'tray-1', item_number: 3, product_id: 'p-1', product_name: 'Coca-Cola', fill_amount: 5 },
    { id: 'tray-2', item_number: 7, product_id: 'p-2', product_name: 'Sprite', fill_amount: 2 },
  ] as any

  it('joins RPC results with tray metadata by tray_id', () => {
    const results = [
      { tray_id: 'tray-1', old_stock: 3, new_stock: 8, fill_amount: 5, was_already_applied: false },
      { tray_id: 'tray-2', old_stock: 10, new_stock: 12, fill_amount: 2, was_already_applied: false },
    ] as any

    expect(buildRefillSnapshot(results, traysToRefill)).toEqual([
      { id: 'tray-1', item_number: 3, product_name: 'Coca-Cola', product_id: 'p-1', old_stock: 3, new_stock: 8 },
      { id: 'tray-2', item_number: 7, product_name: 'Sprite', product_id: 'p-2', old_stock: 10, new_stock: 12 },
    ])
  })

  it('tolerates a result row whose tray_id has no matching input tray', () => {
    const results = [
      { tray_id: 'tray-missing', old_stock: 1, new_stock: 4, fill_amount: 3, was_already_applied: false },
    ] as any

    expect(buildRefillSnapshot(results, traysToRefill)).toEqual([
      { id: 'tray-missing', item_number: undefined, product_name: undefined, product_id: undefined, old_stock: 1, new_stock: 4 },
    ])
  })

  it('returns an empty array for no results', () => {
    expect(buildRefillSnapshot([], traysToRefill)).toEqual([])
  })
})
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd management-frontend && npx vitest run app/composables/__tests__/useRefillWizard.refillSnapshot.test.ts`
Expected: FAIL — `buildRefillSnapshot` is not exported (module has no such
export yet).

- [ ] **Step 4: Add `buildRefillSnapshot` as a module-level export**

In `app/composables/useRefillWizard.ts`, add this function near
`buildTourStartedEntry` (same file, before `export function
useRefillWizard()`):

```ts
/**
 * Join the refill RPC's authoritative per-tray stock deltas with the
 * tray metadata (product) known client-side, producing the same shape
 * `useMachineTrays.ts`'s "refill all" snapshot uses — so both actions
 * render identically in the /history product-refill list.
 */
export function buildRefillSnapshot(
  results: { tray_id: string; old_stock: number; new_stock: number }[],
  traysToRefill: { id: string; item_number: number; product_id: string | null; product_name: string | null }[],
) {
  return results.map(r => {
    const tray = traysToRefill.find(t => t.id === r.tray_id)
    return {
      id: r.tray_id,
      item_number: tray?.item_number,
      product_name: tray?.product_name ?? undefined,
      product_id: tray?.product_id ?? undefined,
      old_stock: r.old_stock,
      new_stock: r.new_stock,
    }
  })
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd management-frontend && npx vitest run app/composables/__tests__/useRefillWizard.refillSnapshot.test.ts`
Expected: PASS (3 tests)

- [ ] **Step 6: Wire it into `confirmMachineRefill`**

Run: `grep -n "trays_refilled: results.length" app/composables/useRefillWizard.ts`

Replace the `activity_log` insert's metadata (around line 863-884) from:

```ts
          metadata: {
            tour_id: tourId.value,
            machine_id: machine.id,
            machine_name: machine.name,
            warehouse_id: selectedWarehouseId.value,
            trays_refilled: results.length,
            total_added: totalAdded,
            products: traysToRefill.map(t => ({
              product_id: t.product_id,
              product_name: t.product_name,
              quantity: t.fill_amount,
            })),
            _user_email: u?.email ?? null,
            _user_display: userDisplay,
          },
```

to:

```ts
          metadata: {
            tour_id: tourId.value,
            machine_id: machine.id,
            machine_name: machine.name,
            warehouse_id: selectedWarehouseId.value,
            trays_refilled: buildRefillSnapshot(results, traysToRefill),
            total_added: totalAdded,
            _user_email: u?.email ?? null,
            _user_display: userDisplay,
          },
```

Note: the flat `products` field is intentionally dropped — `trays_refilled`
is now a strict superset (it carries the same `product_id`/`product_name`
plus authoritative `old_stock`/`new_stock`, which also reflects any
capacity clamp the RPC applied). Existing historical rows keep whatever
shape they already have; `activityProductRefs` (Task 5) explicitly handles
both the legacy flat `products` shape and this new array shape, so nothing
needs to change about how old rows are read.

- [ ] **Step 7: Run the full useRefillWizard test suite**

Run: `cd management-frontend && npx vitest run app/composables/__tests__/useRefillWizard.tourStarted.test.ts app/composables/__tests__/useRefillWizard.refillSnapshot.test.ts`
Expected: PASS, no regressions in the existing `tourStarted` tests.

- [ ] **Step 8: Commit**

```bash
git add app/composables/useRefillWizard.ts app/composables/__tests__/useRefillWizard.refillSnapshot.test.ts
git commit -m "feat(refill-wizard): snapshot per-tray old/new stock on tour refills

stock_refill_tour previously logged only a flat quantity per product,
discarding the RPC's authoritative old_stock/new_stock per tray. Extract
buildRefillSnapshot (mirrors useMachineTrays.ts's 'refill all' snapshot
shape) so /history can show what was actually applied, not just what
was requested."
```

---

### Task 2b: Fix `useTourHistory.ts` regression from the new `trays_refilled` shape

**Discovered during Task 2 implementation, not anticipated by the original
spec/plan.** `/tour-history` (`useTourHistory.ts`) reads the exact same
`stock_refill_tour` metadata fields Task 2 just changed:

```ts
trays_refilled: isSkip ? 0 : Number(m.trays_refilled ?? 0),
products: isSkip ? [] : (Array.isArray(m.products) ? m.products.map(...) : []),
```

After Task 2, `m.trays_refilled` is an array (not a count) for every new
tour refill — `Number(array)` is `NaN` — and `m.products` no longer exists
at all. This is not just a historical-rows concern; it's an immediate
regression on `/tour-history` for every refill confirmed after Task 2's
commit lands. Fix it the same way `activityProductRefs` (Task 5) will
handle the descriptor side: derive from the new array shape when present,
fall back to the legacy flat `products` shape for historical rows.

**Files:**
- Modify: `management-frontend/app/composables/useTourHistory.ts:65-84`
- Test: `management-frontend/app/composables/__tests__/useTourHistory.test.ts` (create if it doesn't exist; check first)

- [ ] **Step 1: Check for an existing test file**

Run: `find app/composables/__tests__ -iname "*TourHistory*"`

If a test file already exists for `useTourHistory.ts`, add to it. If not,
create `app/composables/__tests__/useTourHistory.test.ts` — but first check
whether `buildMachineEntry` is exported; if it isn't, export it (it's
already a pure function of `RawLogEntry`, no Nuxt dependency at call time)
so it can be unit tested directly, matching the `buildTourStartedEntry`
pattern in `useRefillWizard.ts`.

- [ ] **Step 2: Write the failing tests**

```ts
import { describe, it, expect } from 'vitest'
import { buildMachineEntry } from '../useTourHistory'

describe('buildMachineEntry', () => {
  it('derives trays_refilled count and products from the new trays_refilled array shape', () => {
    const entry = buildMachineEntry({
      id: 'e1', created_at: '2026-07-17T00:00:00Z', user_id: null,
      action: 'stock_refill_tour',
      metadata: {
        machine_id: 'm1', machine_name: 'Automat 1', total_added: 7,
        trays_refilled: [
          { id: 't1', item_number: 3, product_id: 'p1', product_name: 'Coca-Cola', old_stock: 2, new_stock: 7 },
          { id: 't2', item_number: 5, product_id: 'p2', product_name: 'Sprite', old_stock: 0, new_stock: 2 },
        ],
      },
    })
    expect(entry.trays_refilled).toBe(2)
    expect(entry.products).toEqual([
      { product_id: 'p1', product_name: 'Coca-Cola', quantity: 5 },
      { product_id: 'p2', product_name: 'Sprite', quantity: 2 },
    ])
  })

  it('falls back to the legacy flat products array for historical rows', () => {
    const entry = buildMachineEntry({
      id: 'e1', created_at: '2026-07-01T00:00:00Z', user_id: null,
      action: 'stock_refill_tour',
      metadata: {
        machine_id: 'm1', machine_name: 'Automat 1', total_added: 5,
        trays_refilled: 2, // legacy plain-number shape
        products: [{ product_id: 'p1', product_name: 'Coca-Cola', quantity: 5 }],
      },
    })
    expect(entry.trays_refilled).toBe(2)
    expect(entry.products).toEqual([{ product_id: 'p1', product_name: 'Coca-Cola', quantity: 5 }])
  })

  it('returns zero/empty for a skipped machine', () => {
    const entry = buildMachineEntry({
      id: 'e1', created_at: '2026-07-17T00:00:00Z', user_id: null,
      action: 'stock_refill_tour_skip',
      metadata: { machine_id: 'm1', machine_name: 'Automat 1' },
    })
    expect(entry.trays_refilled).toBe(0)
    expect(entry.products).toEqual([])
  })
})
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd management-frontend && npx vitest run app/composables/__tests__/useTourHistory.test.ts`
Expected: FAIL on the first test (old code computes `NaN`/`[]` instead of
`2`/the product list) — confirms this is a real, reproducible regression,
not a hypothetical one.

- [ ] **Step 4: Fix `buildMachineEntry`**

Change:

```ts
  function buildMachineEntry(entry: RawLogEntry): TourMachineEntry {
    const m = entry.metadata ?? {}
    const isSkip = entry.action === 'stock_refill_tour_skip'
    return {
      machine_id: String(m.machine_id ?? ''),
      machine_name: String(m.machine_name ?? 'Unknown'),
      skipped: isSkip,
      trays_refilled: isSkip ? 0 : Number(m.trays_refilled ?? 0),
      total_added: isSkip ? 0 : Number(m.total_added ?? 0),
      products: isSkip
        ? []
        : (Array.isArray(m.products)
            ? m.products.map((p: any) => ({
                product_id: p.product_id ? String(p.product_id) : null,
                product_name: String(p.product_name ?? ''),
                quantity: Number(p.quantity ?? 0),
              }))
            : []),
    }
  }
```

to:

```ts
  export function buildMachineEntry(entry: RawLogEntry): TourMachineEntry {
    const m = entry.metadata ?? {}
    const isSkip = entry.action === 'stock_refill_tour_skip'
    // trays_refilled became an array of {id, item_number, product_name,
    // product_id, old_stock, new_stock} snapshots; historical rows still
    // have the legacy plain-number shape (with a separate flat `products`
    // array carrying only product_id/product_name/quantity, no deltas).
    const trays = Array.isArray(m.trays_refilled) ? (m.trays_refilled as any[]) : []
    return {
      machine_id: String(m.machine_id ?? ''),
      machine_name: String(m.machine_name ?? 'Unknown'),
      skipped: isSkip,
      trays_refilled: isSkip
        ? 0
        : (trays.length ? trays.length : Number(m.trays_refilled ?? 0)),
      total_added: isSkip ? 0 : Number(m.total_added ?? 0),
      products: isSkip
        ? []
        : (trays.length
            ? trays.map((tr: any) => ({
                product_id: tr.product_id ? String(tr.product_id) : null,
                product_name: tr.product_name ? String(tr.product_name) : '',
                quantity: (tr.new_stock != null && tr.old_stock != null)
                  ? Math.max(0, Number(tr.new_stock) - Number(tr.old_stock))
                  : 0,
              }))
            : (Array.isArray(m.products)
                ? m.products.map((p: any) => ({
                    product_id: p.product_id ? String(p.product_id) : null,
                    product_name: String(p.product_name ?? ''),
                    quantity: Number(p.quantity ?? 0),
                  }))
                : [])),
    }
  }
```

(Also add the `export` keyword to the function declaration if it wasn't
already exported, so the new test file can import it.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd management-frontend && npx vitest run app/composables/__tests__/useTourHistory.test.ts`
Expected: PASS (3 tests)

- [ ] **Step 6: Run the full frontend test suite to check for regressions**

Run: `cd management-frontend && npx vitest run`
Expected: PASS, all green.

- [ ] **Step 7: Commit**

```bash
git add app/composables/useTourHistory.ts app/composables/__tests__/useTourHistory.test.ts
git commit -m "fix(tour-history): read the new trays_refilled array shape

Task 2 changed stock_refill_tour's activity_log metadata from a flat
{trays_refilled: number, products: [...]} shape to an array of
per-tray old/new-stock snapshots, but /tour-history (useTourHistory.ts)
still read the old shape directly — new tours would show NaN trays and
an empty product list. Derive from the new shape, falling back to the
legacy shape for historical rows."
```

---

## Chunk 2: Descriptor layer (`activityDescriptor.ts`)

### Task 3: Extend `activityProductRef` to cover `sale_recorded`

**Files:**
- Modify: `management-frontend/app/lib/activityDescriptor.ts:112-128`
- Test: `management-frontend/app/lib/__tests__/activityDescriptor.test.ts`

- [ ] **Step 1: Write the failing test**

Add to the `describe('activityProductRef — drives the row thumbnail', ...)`
block in `app/lib/__tests__/activityDescriptor.test.ts`:

```ts
  it('returns the product for a real MDB sale (sale_recorded)', () => {
    expect(activityProductRef({
      action: 'sale_recorded',
      metadata: { product_id: 'p1', product_name: 'Coca-Cola', item_number: 12 },
    })).toEqual({ productId: 'p1', productName: 'Coca-Cola' })
  })

  it('returns null for a sale_recorded row predating this field (no product_id/name)', () => {
    expect(activityProductRef({
      action: 'sale_recorded',
      metadata: { item_number: 12, price: 2.5, channel: 'cash', device_id: 'dev-1' },
    })).toBeNull()
  })
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd management-frontend && npx vitest run app/lib/__tests__/activityDescriptor.test.ts -t "sale_recorded"`
Expected: FAIL — first case returns `null` instead of the product ref.

- [ ] **Step 3: Add `sale_recorded` to the existing switch case group**

In `app/lib/activityDescriptor.ts`, change:

```ts
  switch (entry.action) {
    case 'sale_deleted':
    case 'sale_inserted':
    case 'sale_restored':
    case 'stock_updated': {
```

to:

```ts
  switch (entry.action) {
    case 'sale_recorded':
    case 'sale_deleted':
    case 'sale_inserted':
    case 'sale_restored':
    case 'stock_updated': {
```

(the case body already reads `m.product_id`/`m.product_name` generically —
no other change needed).

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd management-frontend && npx vitest run app/lib/__tests__/activityDescriptor.test.ts -t "sale_recorded"`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add app/lib/activityDescriptor.ts app/lib/__tests__/activityDescriptor.test.ts
git commit -m "feat(activity-descriptor): show product thumbnail on sale_recorded rows"
```

---

### Task 4: Add `sale_recorded` chips for the new dedup fields (chip-level, non-debug)

This task only concerns the always-visible chip line staying accurate — the
actual debug surfacing is `activityDetails` (Task 6). No new chip is added
here for `sale_seq`/`time_uncertain` (those are debug-only, per spec); this
task exists solely to confirm the existing `sale_recorded` chip case still
works unchanged with the new metadata fields present (it reads
`item_number`/`price`/`channel`, none of which changed).

- [ ] **Step 1: Add a regression test confirming extra metadata fields don't break existing chips**

Add to the `describe('activityChips — sale_recorded', ...)` block in
`app/lib/__tests__/activityDescriptor.test.ts` (the file has three blocks
whose names start with `activityChips —`: `sale_deleted`, `sale_recorded`,
and `other actions` — use the `sale_recorded` one; confirm with
`grep -n "describe('activityChips" app/lib/__tests__/activityDescriptor.test.ts`):

```ts
  it('sale_recorded chips are unaffected by the new product/dedup metadata fields', () => {
    const chips = activityChips({
      action: 'sale_recorded',
      metadata: {
        item_number: 12, price: 2.5, channel: 'cash', device_id: 'dev-embedded-1',
        product_id: 'p1', product_name: 'Coca-Cola', sale_seq: 42, time_uncertain: false,
      },
    }, ctx)
    expect(valueOf(chips, 'activity.field.machine')).toBe('Snackautomat 3')
    expect(valueOf(chips, 'activity.field.slot')).toBe('#12')
    expect(valueOf(chips, 'activity.field.price')).toBe('€2.50')
    expect(valueOf(chips, 'activity.field.channel')).toBe('cash')
    // sale_seq / time_uncertain must NOT appear as chips — they're debug-only (activityDetails)
    expect(chips.some(c => c.label.includes('saleSeq'))).toBe(false)
  })
```

- [ ] **Step 2: Run it**

Run: `cd management-frontend && npx vitest run app/lib/__tests__/activityDescriptor.test.ts -t "unaffected"`
Expected: PASS immediately — no implementation change needed, this is a
regression guard. If it fails, the `sale_recorded` chip case in
`activityChips` needs no modification per spec; investigate why extra keys
are leaking into chips before proceeding.

- [ ] **Step 3: Commit**

```bash
git add app/lib/__tests__/activityDescriptor.test.ts
git commit -m "test(activity-descriptor): guard sale_recorded chips against new metadata fields"
```

---

### Task 5: Add `activityProductRefs` (multi-item product list)

**Files:**
- Modify: `management-frontend/app/lib/activityDescriptor.ts`
- Test: `management-frontend/app/lib/__tests__/activityDescriptor.test.ts`

- [ ] **Step 1: Write the failing tests**

Add a new `describe` block to `app/lib/__tests__/activityDescriptor.test.ts`
(after the `activityProductRef` block):

```ts
describe('activityProductRefs — multi-item refill breakdown', () => {
  it('reads the new trays_refilled array shape (stock_refill_all)', () => {
    const refs = activityProductRefs({
      action: 'stock_refill_all',
      metadata: {
        trays_refilled: [
          { id: 't1', item_number: 3, product_name: 'Coca-Cola', product_id: 'p1', old_stock: 2, new_stock: 10 },
          { id: 't2', item_number: 7, product_name: null, product_id: null, old_stock: 0, new_stock: 5 },
        ],
      },
    })
    expect(refs).toEqual([
      { productId: 'p1', productName: 'Coca-Cola', oldStock: 2, newStock: 10 },
      { productId: undefined, productName: '#7', oldStock: 0, newStock: 5 },
    ])
  })

  it('reads the new trays_refilled array shape (stock_refill_tour)', () => {
    const refs = activityProductRefs({
      action: 'stock_refill_tour',
      metadata: {
        trays_refilled: [
          { id: 't1', item_number: 3, product_name: 'Sprite', product_id: 'p2', old_stock: 1, new_stock: 6 },
        ],
      },
    })
    expect(refs).toEqual([{ productId: 'p2', productName: 'Sprite', oldStock: 1, newStock: 6 }])
  })

  it('falls back to the legacy flat products array (historical stock_refill_tour rows)', () => {
    const refs = activityProductRefs({
      action: 'stock_refill_tour',
      metadata: {
        trays_refilled: 3, // legacy plain-number shape
        products: [
          { product_id: 'p1', product_name: 'Coca-Cola', quantity: 5 },
          { product_id: 'p2', product_name: 'Sprite', quantity: 2 },
        ],
      },
    })
    expect(refs).toEqual([
      { productId: 'p1', productName: 'Coca-Cola', quantity: 5 },
      { productId: 'p2', productName: 'Sprite', quantity: 2 },
    ])
  })

  it('returns an empty array for actions with no refill breakdown', () => {
    expect(activityProductRefs({ action: 'sale_recorded', metadata: { item_number: 3 } })).toEqual([])
  })

  it('returns an empty array when metadata is null', () => {
    expect(activityProductRefs({ action: 'stock_refill_tour', metadata: null })).toEqual([])
  })
})
```

- [ ] **Step 2: Add `activityProductRefs` to the test file's import block**

The test file's top-of-file import (currently
`import { activityActionLabel, activityChips, activityIcon,
activityProductRef, activitySummary } from '../activityDescriptor'`) does
not yet include `activityProductRefs` — without this, the test block just
added fails with a `ReferenceError`, not the "not exported" failure the
next step expects. Change it to:

```ts
import {
  activityActionLabel,
  activityChips,
  activityIcon,
  activityProductRef,
  activityProductRefs,
  activitySummary,
} from '../activityDescriptor'
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd management-frontend && npx vitest run app/lib/__tests__/activityDescriptor.test.ts -t "activityProductRefs"`
Expected: FAIL — `activityProductRefs` is not exported from `../activityDescriptor` yet (a real "no exported member" failure now that the import is in place).

- [ ] **Step 4: Add the `ProductRefWithStock` type and `activityProductRefs` function**

In `app/lib/activityDescriptor.ts`, add after the existing `ProductRef`
interface (around line 40):

```ts
/**
 * A product entry within a multi-item refill breakdown. `oldStock`/`newStock`
 * are present for rows written after this feature shipped; `quantity` is the
 * legacy fallback for historical `stock_refill_tour` rows that only ever
 * logged a flat requested amount, not an authoritative before/after delta.
 */
export interface ProductRefWithStock {
  productId?: string
  productName?: string
  oldStock?: number
  newStock?: number
  quantity?: number
}
```

Add the function after `activityProductRef` (around line 128):

```ts
/**
 * The full list of products behind a multi-item refill entry, for the
 * /history expandable product-refill list. Only `stock_refill_all` and
 * `stock_refill_tour` carry this; everything else returns `[]`.
 */
export function activityProductRefs(entry: ActivityEntryLike): ProductRefWithStock[] {
  const m = entry.metadata
  if (!m) return []
  if (entry.action !== 'stock_refill_all' && entry.action !== 'stock_refill_tour') return []

  const trays = Array.isArray(m.trays_refilled) ? (m.trays_refilled as any[]) : []
  if (trays.length) {
    return trays.map(tr => ({
      productId: tr.product_id ?? undefined,
      productName: tr.product_name
        ? String(tr.product_name)
        : (tr.item_number != null ? `#${tr.item_number}` : undefined),
      oldStock: tr.old_stock != null ? Number(tr.old_stock) : undefined,
      newStock: tr.new_stock != null ? Number(tr.new_stock) : undefined,
    }))
  }

  // Legacy stock_refill_tour rows: flat `products` array, no stock deltas.
  const products = Array.isArray(m.products) ? (m.products as any[]) : []
  return products.map(p => ({
    productId: p.product_id ?? undefined,
    productName: p.product_name ? String(p.product_name) : undefined,
    quantity: p.quantity != null ? Number(p.quantity) : undefined,
  }))
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd management-frontend && npx vitest run app/lib/__tests__/activityDescriptor.test.ts -t "activityProductRefs"`
Expected: PASS (5 tests)

- [ ] **Step 6: Remove the now-redundant per-item chip loops**

These loops are superseded by `activityProductRefs` (Task 8 wires the view
to render the new list instead). Run:
`grep -n "case 'stock_refill_all'" -A 15 app/lib/activityDescriptor.ts`
and
`grep -n "case 'stock_refill_tour'" -A 15 app/lib/activityDescriptor.ts`

Change the `stock_refill_all` case from:

```ts
    case 'stock_refill_all': {
      pushMachine()
      const trays = Array.isArray(m.trays_refilled) ? (m.trays_refilled as any[]) : []
      if (trays.length) {
        push(F('trays'), `${trays.length} ${t('activity.refilled')}`, { icon: 'LayoutGrid' })
        for (const tr of trays) {
          const name = tr.product_name ? String(tr.product_name) : `#${tr.item_number}`
          chips.push(stockChangeChip(name, Number(tr.old_stock), Number(tr.new_stock)))
        }
      }
      break
    }
```

to:

```ts
    case 'stock_refill_all': {
      // Per-product breakdown is rendered from activityProductRefs, not chips.
      pushMachine()
      const trays = Array.isArray(m.trays_refilled) ? (m.trays_refilled as any[]) : []
      if (trays.length) {
        push(F('trays'), `${trays.length} ${t('activity.refilled')}`, { icon: 'LayoutGrid' })
      }
      break
    }
```

Change the `stock_refill_tour` case from:

```ts
    case 'stock_refill_tour': {
      pushMachine()
      if (m.warehouse_name) push(F('warehouse'), m.warehouse_name, { icon: 'Warehouse' })
      if (m.trays_refilled != null) {
        const n = Array.isArray(m.trays_refilled) ? m.trays_refilled.length : m.trays_refilled
        push(F('trays'), n, { icon: 'LayoutGrid' })
      }
      if (m.total_added != null) push(F('totalAdded'), `+${m.total_added}`, { variant: 'increase', icon: 'Plus' })
      const products = Array.isArray(m.products) ? (m.products as any[]) : []
      for (const p of products.slice(0, 6)) {
        if (p?.product_name) push(String(p.product_name), `×${p.quantity ?? '?'}`)
      }
      break
    }
```

to:

```ts
    case 'stock_refill_tour': {
      // Per-product breakdown is rendered from activityProductRefs, not chips.
      pushMachine()
      if (m.warehouse_name) push(F('warehouse'), m.warehouse_name, { icon: 'Warehouse' })
      if (m.trays_refilled != null) {
        const n = Array.isArray(m.trays_refilled) ? m.trays_refilled.length : m.trays_refilled
        push(F('trays'), n, { icon: 'LayoutGrid' })
      }
      if (m.total_added != null) push(F('totalAdded'), `+${m.total_added}`, { variant: 'increase', icon: 'Plus' })
      break
    }
```

- [ ] **Step 7: Run the full descriptor test file to check for regressions**

Run: `cd management-frontend && npx vitest run app/lib/__tests__/activityDescriptor.test.ts`
Expected: PASS, all tests green (no test previously asserted on the removed
per-item chips per the earlier grep check — confirm no failures appear).

- [ ] **Step 8: Commit**

```bash
git add app/lib/activityDescriptor.ts app/lib/__tests__/activityDescriptor.test.ts
git commit -m "feat(activity-descriptor): add activityProductRefs for multi-item refills

stock_refill_all and stock_refill_tour rendered their per-product
breakdown as chips whose label (the product name) the view never
displays — so users saw bare '×4 ×3 ×1' numbers with no way to tell
which product was which. activityProductRefs replaces those chip loops
with a proper list the view can render with images + old/new stock."
```

---

### Task 6: Add `activityDetails` (technical/debug panel)

**Files:**
- Modify: `management-frontend/app/lib/activityDescriptor.ts`
- Test: `management-frontend/app/lib/__tests__/activityDescriptor.test.ts`

- [ ] **Step 1: Write the failing tests**

Add a new `describe` block:

```ts
describe('activityDetails — technical/debug panel', () => {
  it('surfaces sale_seq when present', () => {
    const details = activityDetails({
      action: 'sale_recorded',
      metadata: { item_number: 3, sale_seq: 42, time_uncertain: false },
    }, ctx)
    expect(details).toContainEqual({ label: 'activity.field.saleSeq', value: '42' })
  })

  it('surfaces sale_seq 0 (falsy but valid)', () => {
    const details = activityDetails({
      action: 'sale_recorded',
      metadata: { item_number: 3, sale_seq: 0, time_uncertain: false },
    }, ctx)
    expect(details).toContainEqual({ label: 'activity.field.saleSeq', value: '0' })
  })

  it('adds a warning detail when time_uncertain is true', () => {
    const details = activityDetails({
      action: 'sale_recorded',
      metadata: { item_number: 3, sale_seq: 42, time_uncertain: true },
    }, ctx)
    expect(details).toContainEqual({
      label: 'activity.field.timeUncertain',
      value: 'activity.timeUncertainWarning',
      variant: 'warning',
    })
  })

  it('omits the warning when time_uncertain is false or absent', () => {
    const details = activityDetails({
      action: 'sale_recorded',
      metadata: { item_number: 3, sale_seq: 42, time_uncertain: false },
    }, ctx)
    expect(details.some(d => d.variant === 'warning')).toBe(false)
  })

  it('returns an empty array for older sale_recorded rows with no dedup fields', () => {
    expect(activityDetails({
      action: 'sale_recorded',
      metadata: { item_number: 3, price: 2.5, channel: 'cash', device_id: 'dev-1' },
    }, ctx)).toEqual([])
  })

  it('returns an empty array for actions with no curated details', () => {
    expect(activityDetails({ action: 'stock_refill_tour', metadata: { trays_refilled: 3 } }, ctx)).toEqual([])
  })
})
```

- [ ] **Step 2: Add `activityDetails` to the test file's import block**

By this point (after Task 5) the import block reads
`import { activityActionLabel, activityChips, activityIcon,
activityProductRef, activityProductRefs, activitySummary } from
'../activityDescriptor'`. Add `activityDetails` to it:

```ts
import {
  activityActionLabel,
  activityChips,
  activityDetails,
  activityIcon,
  activityProductRef,
  activityProductRefs,
  activitySummary,
} from '../activityDescriptor'
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd management-frontend && npx vitest run app/lib/__tests__/activityDescriptor.test.ts -t "activityDetails"`
Expected: FAIL — `activityDetails` is not exported from `../activityDescriptor` yet.

- [ ] **Step 4: Add the `ActivityDetail` type and `activityDetails` function**

In `app/lib/activityDescriptor.ts`, add after `ProductRefWithStock`:

```ts
export type ActivityDetailVariant = 'default' | 'warning'

/** A single row in the /history "technical details" expand panel. */
export interface ActivityDetail {
  label: string
  value: string
  variant?: ActivityDetailVariant
}
```

Add the function after `activityChips` (before the "compact single-line
summary" section):

```ts
// ── technical/debug details (expand panel) ──────────────────────────────────

/**
 * Curated, operator-useful fields not shown as chips — a deliberate
 * whitelist (not a raw metadata dump) so the expand panel stays readable.
 * Extend this per-action as new debugging needs come up.
 */
export function activityDetails(entry: ActivityEntryLike, ctx: DescriptorCtx): ActivityDetail[] {
  const m = entry.metadata
  if (!m) return []
  const { t } = ctx
  const F = (k: string) => t(`activity.field.${k}`)
  const details: ActivityDetail[] = []

  switch (entry.action) {
    case 'sale_recorded': {
      if (m.sale_seq != null) details.push({ label: F('saleSeq'), value: String(m.sale_seq) })
      if (m.time_uncertain === true) {
        details.push({ label: F('timeUncertain'), value: t('activity.timeUncertainWarning'), variant: 'warning' })
      }
      break
    }
    default:
      break
  }

  return details
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd management-frontend && npx vitest run app/lib/__tests__/activityDescriptor.test.ts -t "activityDetails"`
Expected: PASS (6 tests)

- [ ] **Step 6: Run the full descriptor test file**

Run: `cd management-frontend && npx vitest run app/lib/__tests__/activityDescriptor.test.ts`
Expected: PASS, all green.

- [ ] **Step 7: Commit**

```bash
git add app/lib/activityDescriptor.ts app/lib/__tests__/activityDescriptor.test.ts
git commit -m "feat(activity-descriptor): add activityDetails for sale dedup debugging

sale_seq and time_uncertain existed on the sales table but never reached
activity_log, so operators had no way to tell whether a suspicious
duplicate-looking sale was a genuine repeat purchase or a firmware
double-report after a reboot. activityDetails surfaces both in a
curated (not raw-dump) expand panel."
```

---

## Chunk 3: i18n + composable wiring + UI

### Task 7: Add new i18n keys

**Files:**
- Modify: `management-frontend/i18n/locales/de.json`
- Modify: `management-frontend/i18n/locales/en.json`

- [ ] **Step 1: Add German keys**

In `i18n/locales/de.json`, inside the top-level `"activity"` object, add
after `"sourceSuppressedRestore"`:

```json
    "technicalDetails": "Technische Details",
    "showMore": "Mehr anzeigen",
    "showLess": "Weniger anzeigen",
    "moreItems": "+{count} weitere",
    "timeUncertainWarning": "Zeitstempel unsicher — möglicherweise ein Doppel-Report nach einem Geräte-Neustart",
```

Inside `"activity.field"`, add after `"capacity"`:

```json
    "saleSeq": "Sequenznummer",
    "timeUncertain": "Zeitstempel-Status"
```

(Remember to add a trailing comma after `"capacity": "Kapazität"` since it's
no longer the last key.)

- [ ] **Step 2: Add matching English keys**

In `i18n/locales/en.json`, inside `"activity"`, add after
`"sourceSuppressedRestore"`:

```json
    "technicalDetails": "Technical details",
    "showMore": "Show more",
    "showLess": "Show less",
    "moreItems": "+{count} more",
    "timeUncertainWarning": "Timestamp uncertain — may be a duplicate report after a device restart",
```

Inside `"activity.field"`, add after `"capacity"`:

```json
    "saleSeq": "Sequence number",
    "timeUncertain": "Timestamp status"
```

- [ ] **Step 3: Validate both files are still valid JSON**

Run: `cd management-frontend && python3 -c "import json; json.load(open('i18n/locales/de.json')); json.load(open('i18n/locales/en.json')); print('OK')"`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add i18n/locales/de.json i18n/locales/en.json
git commit -m "i18n: add history detail-enrichment strings (de/en)"
```

---

### Task 8: Expose the new descriptor functions from `useActivityDescriptor`

**Files:**
- Modify: `management-frontend/app/composables/useActivityDescriptor.ts`

- [ ] **Step 1: Update the imports**

Change:

```ts
import {
  activityActionLabel,
  activityChips,
  activityIcon,
  activityProductRef,
  activitySummary,
} from '@/lib/activityDescriptor'
```

to:

```ts
import {
  activityActionLabel,
  activityChips,
  activityDetails,
  activityIcon,
  activityProductRef,
  activityProductRefs,
  activitySummary,
} from '@/lib/activityDescriptor'
```

- [ ] **Step 2: Expose the two new functions from the returned object**

Change the `return { ... }` block from:

```ts
  return {
    actionLabel: (action: string) => activityActionLabel(action, tt),
    actionIcon: (action: string) => activityIcon(action),
    productRef: (entry: ActivityEntryLike) => activityProductRef(entry),
    metadataChips: (entry: ActivityEntryLike) => activityChips(entry, ctx()),
    activitySummary: (entry: ActivityEntryLike) => activitySummary(entry, ctx()),
  }
```

to:

```ts
  return {
    actionLabel: (action: string) => activityActionLabel(action, tt),
    actionIcon: (action: string) => activityIcon(action),
    productRef: (entry: ActivityEntryLike) => activityProductRef(entry),
    productRefs: (entry: ActivityEntryLike) => activityProductRefs(entry),
    metadataChips: (entry: ActivityEntryLike) => activityChips(entry, ctx()),
    activityDetailsFor: (entry: ActivityEntryLike) => activityDetails(entry, ctx()),
    activitySummary: (entry: ActivityEntryLike) => activitySummary(entry, ctx()),
  }
```

- [ ] **Step 3: Type-check the frontend**

Run: `cd management-frontend && npx vue-tsc --noEmit -p tsconfig.json 2>&1 | head -50`
Expected: no new errors referencing `useActivityDescriptor.ts` (pre-existing
unrelated errors, if any, are not this task's concern).

- [ ] **Step 4: Commit**

```bash
git add app/composables/useActivityDescriptor.ts
git commit -m "feat(activity-descriptor): expose productRefs + activityDetailsFor"
```

---

### Task 9: Render the product-refill list + expand panel on `/history`

**Files:**
- Modify: `management-frontend/app/pages/history/index.vue`

- [ ] **Step 1: Add the `ChevronDown` icon import and destructure the new descriptor functions**

Change the lucide import block (around line 8-13) to add `ChevronDown`:

```ts
import {
  ShoppingCart, Trash2, PlusCircle, RotateCcw, CircleDollarSign, Settings,
  Package, PackagePlus, Truck, Repeat, Wallet, Coins, Link as LinkIcon, Unlink,
  Activity, MapPin, Hash, Euro, CreditCard, Clock, Cpu, Warehouse, Boxes,
  LayoutGrid, Plus, Tag, StickyNote, RefreshCw, ArrowUpRight, ArrowDownRight, ArrowRight,
  ChevronDown,
} from 'lucide-vue-next'
```

Change the descriptor destructure (around line 74-77) from:

```ts
const { actionLabel, actionIcon, metadataChips, productRef } = useActivityDescriptor({
  machineName: resolveMachineName,
  machineNameByDevice: resolveMachineNameByDevice,
})
```

to:

```ts
const { actionLabel, actionIcon, metadataChips, productRef, productRefs, activityDetailsFor } = useActivityDescriptor({
  machineName: resolveMachineName,
  machineNameByDevice: resolveMachineNameByDevice,
})
```

- [ ] **Step 2: Add expand/collapse state + helpers**

Add after the `groupedLogs` computed (near the end of the `<script setup>`
block, before the closing `</script>`):

```ts
// ── Expandable rows (product-refill breakdown + technical details) ─────────
const expandedIds = ref<Set<string>>(new Set())
function isExpanded(id: string): boolean {
  return expandedIds.value.has(id)
}
function toggleExpanded(id: string) {
  const next = new Set(expandedIds.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  expandedIds.value = next
}
function visibleProductRefs(entry: { id: string; action: string; metadata: Record<string, unknown> | null }) {
  const refs = productRefs(entry)
  return isExpanded(entry.id) ? refs : refs.slice(0, 3)
}
function hasExpandableContent(entry: { id: string; action: string; metadata: Record<string, unknown> | null }): boolean {
  return productRefs(entry).length > 3 || activityDetailsFor(entry).length > 0
}
```

- [ ] **Step 3: Update the row template**

Find the row body block (the `<!-- Body: title + meta line -->` comment,
currently around line 246-281). Replace the entire block, from
`<!-- Body: title + meta line -->` through its closing `</div>`, with:

```html
              <!-- Body: title + meta line -->
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-1.5">
                  <span class="text-sm font-medium">{{ actionLabel(entry.action) }}</span>
                  <button
                    v-if="hasExpandableContent(entry)"
                    type="button"
                    class="inline-flex h-5 w-5 shrink-0 items-center justify-center rounded text-muted-foreground hover:bg-muted"
                    :aria-label="isExpanded(entry.id) ? t('activity.showLess') : t('activity.showMore')"
                    @click="toggleExpanded(entry.id)"
                  >
                    <ChevronDown class="h-3.5 w-3.5 transition-transform" :class="{ 'rotate-180': isExpanded(entry.id) }" />
                  </button>
                </div>
                <div class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-[13px] text-muted-foreground">
                  <!-- Product thumbnail + name (single-product entries) -->
                  <span
                    v-if="productRef(entry)"
                    class="inline-flex items-center gap-1.5 rounded-md bg-muted/60 py-0.5 pl-0.5 pr-2"
                  >
                    <img
                      v-if="resolveProductImage(productRef(entry))"
                      :src="resolveProductImage(productRef(entry))!"
                      class="h-5 w-5 rounded object-cover"
                      alt=""
                    />
                    <span v-else class="flex h-5 w-5 items-center justify-center rounded bg-muted">
                      <Package class="h-3 w-3" />
                    </span>
                    <span class="text-foreground">{{ productRef(entry)?.productName || '—' }}</span>
                  </span>

                  <!-- Meta chips (icon + value) -->
                  <span
                    v-for="chip in metadataChips(entry)"
                    :key="chip.label + chip.value"
                    class="inline-flex items-center gap-1.5"
                    :class="{
                      'text-emerald-600 dark:text-emerald-400': chip.variant === 'increase',
                      'text-red-600 dark:text-red-400': chip.variant === 'decrease',
                    }"
                  >
                    <component :is="iconComp(chip.icon)" v-if="chip.icon" class="h-[15px] w-[15px] opacity-70" />
                    <span>{{ chip.value }}</span>
                  </span>
                </div>

                <!-- Multi-item refill breakdown (stock_refill_all / stock_refill_tour) -->
                <div v-if="productRefs(entry).length" class="mt-2 flex flex-wrap items-center gap-1.5">
                  <span
                    v-for="(p, i) in visibleProductRefs(entry)"
                    :key="(p.productId || p.productName || i) + ''"
                    class="inline-flex items-center gap-1.5 rounded-md bg-muted/60 py-0.5 pl-0.5 pr-2 text-[13px]"
                  >
                    <img
                      v-if="resolveProductImage(p)"
                      :src="resolveProductImage(p)!"
                      class="h-5 w-5 rounded object-cover"
                      alt=""
                    />
                    <span v-else class="flex h-5 w-5 items-center justify-center rounded bg-muted">
                      <Package class="h-3 w-3" />
                    </span>
                    <span class="text-foreground">{{ p.productName || '—' }}</span>
                    <span
                      v-if="p.oldStock != null && p.newStock != null"
                      class="tabular-nums"
                      :class="p.newStock > p.oldStock ? 'text-emerald-600 dark:text-emerald-400' : 'text-muted-foreground'"
                    >
                      {{ p.oldStock }} → {{ p.newStock }}
                    </span>
                    <span v-else-if="p.quantity != null" class="tabular-nums text-muted-foreground">×{{ p.quantity }}</span>
                  </span>
                  <button
                    v-if="!isExpanded(entry.id) && productRefs(entry).length > 3"
                    type="button"
                    class="text-[13px] text-muted-foreground underline-offset-2 hover:underline"
                    @click="toggleExpanded(entry.id)"
                  >
                    {{ t('activity.moreItems', { count: productRefs(entry).length - 3 }) }}
                  </button>
                </div>

                <!-- Technical details (expand panel) -->
                <div
                  v-if="isExpanded(entry.id) && activityDetailsFor(entry).length"
                  class="mt-2 rounded-md border border-dashed p-2 text-[13px]"
                >
                  <div class="mb-1 font-medium text-muted-foreground">{{ t('activity.technicalDetails') }}</div>
                  <div
                    v-for="d in activityDetailsFor(entry)"
                    :key="d.label"
                    class="flex items-center gap-2"
                    :class="{ 'text-amber-600 dark:text-amber-400': d.variant === 'warning' }"
                  >
                    <span class="text-muted-foreground">{{ d.label }}:</span>
                    <span>{{ d.value }}</span>
                  </div>
                </div>
              </div>
```

- [ ] **Step 4: Confirm the file still type-checks**

Run: `cd management-frontend && npx vue-tsc --noEmit -p tsconfig.json 2>&1 | grep -i "history/index.vue" || echo "no errors in history/index.vue"`
Expected: `no errors in history/index.vue`

- [ ] **Step 5: Commit**

```bash
git add app/pages/history/index.vue
git commit -m "feat(history): render multi-item refill breakdown + expand panel

Sale rows now show the product thumbnail (via the already-generic
productRef rendering). Refill rows show the full per-product old→new
stock breakdown (capped at 3 inline, expandable), and rows with sale
dedup info get an expandable technical-details panel."
```

---

### Task 10: Manual verification against local Supabase

**Files:** none (manual verification only)

- [ ] **Step 1: Start the local stack**

Run: `cd Docker/supabase && supabase start`
(Skip if already running.)

Run: `cd management-frontend && npm run dev`

- [ ] **Step 2: Verify a real sale renders with a product thumbnail**

Trigger a test MDB sale (via the mdb-master-esp32s3 simulator, or by
POSTing a synthetic MQTT payload to the local broker if that's the
project's existing test method — check `Docker/mqtt/forwarder/` for a
manual-test script if one exists). Confirm on `/history`:
- The "Verkauf erfasst" row shows a product thumbnail + name (or the
  fallback package icon + '—' if the slot has no assigned product).
- Expanding the row (if `sale_seq`/`time_uncertain` are present) shows the
  sequence number, and a warning line if `time_uncertain` is true.

- [ ] **Step 3: Verify a tour refill renders the full breakdown**

Run through `/refill` for a machine with 4+ trays needing stock, confirm on
`/history`:
- The "Tour-Befüllung" row shows up to 3 products inline with images +
  old→new stock.
- A "+N weitere" link appears if more than 3 products were refilled;
  clicking it (or the chevron) reveals the rest.

- [ ] **Step 4: Verify historical rows still render without errors**

Scroll `/history` back to entries created before this change (or check the
browser console for errors). Confirm:
- Old `sale_recorded` rows (no `product_id`) show no thumbnail, no crash.
- Old `stock_refill_tour` rows (flat `products` array, no stock deltas)
  show product name + `×quantity`, no crash.
- Old `stock_refill_all` rows (array `trays_refilled` with `old_stock`/
  `new_stock` — this shape hasn't changed) show the same as before, now
  with images.

- [ ] **Step 5: Run the full frontend test suite**

Run: `cd management-frontend && npx vitest run`
Expected: all tests pass, including the new ones added in Chunks 1-2.

- [ ] **Step 6: Report back to the user**

No commit for this task. Summarize what was verified (or any issue found
and how it was fixed, with a fixup commit) before considering the plan
complete.
