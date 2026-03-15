# Warehouse-Aware Stock Health Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cross-reference warehouse inventory when calculating machine card stock health, splitting trays into "refillable" (product in warehouse) and "no-stock" (product unavailable), and showing both categories on machine cards.

**Architecture:** Add one additional Supabase query for `warehouse_stock_batches` inside the existing `Promise.all` in `useMachines.fetchMachines()`. Aggregate into a `Map<string, number>` of warehouse stock per product. During the existing tray classification loop, cross-check each low/empty tray's product against this map to split counts. The UI on `/machines` gains two badges and a per-product stock availability list.

**Tech Stack:** Nuxt 4, TypeScript, Supabase client, Vue 3 reactivity, shadcn-nuxt, TailwindCSS 4, vue-i18n

**Spec:** `docs/superpowers/specs/2026-03-15-warehouse-aware-stock-health-design.md`

---

## Chunk 1: Data Layer & Stock Calculation

### Task 1: Add `in_stock` to RefillItem interface

**Files:**
- Modify: `management-frontend/app/composables/useRefillWizard.ts:19-24`

- [ ] **Step 1: Add `in_stock` field to RefillItem**

In `management-frontend/app/composables/useRefillWizard.ts`, add `in_stock?: boolean` to the `RefillItem` interface. It must be optional (`?`) because persisted tour state in localStorage may not have this field.

```ts
export interface RefillItem {
  product_id: string | null
  product_name: string
  deficit: number
  image_path: string | null
  in_stock?: boolean
}
```

- [ ] **Step 2: Verify no type errors**

Run: `cd management-frontend && npx vue-tsc --noEmit 2>&1 | head -30`
Expected: No new errors related to RefillItem

- [ ] **Step 3: Commit**

```bash
git add management-frontend/app/composables/useRefillWizard.ts
git commit -m "feat: add in_stock field to RefillItem interface"
```

---

### Task 2: Update VendingMachine interface & add warehouse query

**Files:**
- Modify: `management-frontend/app/composables/useMachines.ts:14-41` (interface)
- Modify: `management-frontend/app/composables/useMachines.ts:85-133` (Promise.all)

- [ ] **Step 1: Update VendingMachine interface**

In `management-frontend/app/composables/useMachines.ts`, make two changes to the `VendingMachine` interface:

**1a.** Update the existing `tray_summary` type (line 39) to add `in_stock: boolean`:

```ts
  tray_summary?: { product_name: string; product_id: string | null; deficit: number; image_path: string | null; in_stock: boolean }[]
```

**1b.** Add two new fields after `critical_product_ids` (after line 40):

```ts
  no_stock_trays?: number
  no_stock_summary?: { product_name: string; product_id: string | null; deficit: number; image_path: string | null; in_stock: boolean }[]
```

- [ ] **Step 2: Add warehouse_stock_batches query to the Promise.all**

In `fetchMachines()`, add the warehouse query to the existing `Promise.all` destructuring. The current destructure (line 85) is:

```ts
const [todaySalesRes, yesterdaySalesRes, thisMonthSalesRes, lastMonthSalesRes, paxRes, traysRes, ...lastSaleResults] = await Promise.all([
```

Change to:

```ts
const [todaySalesRes, yesterdaySalesRes, thisMonthSalesRes, lastMonthSalesRes, paxRes, traysRes, warehouseStockRes, ...lastSaleResults] = await Promise.all([
```

Add this query **after** the `traysRes` query (after line 122, before the `...machines.value.map` spread):

```ts
        // Warehouse stock for availability check
        supabase
          .from('warehouse_stock_batches')
          .select('product_id, quantity')
          .gt('quantity', 0),
```

- [ ] **Step 3: Build warehouse stock map**

After the existing paxMap aggregation (after line 187), add:

```ts
      // Aggregate warehouse stock per product
      const warehouseStockMap = new Map<string, number>()
      const warehouseBatchRows = (warehouseStockRes.data ?? []) as { product_id: string; quantity: number }[]
      for (const row of warehouseBatchRows) {
        if (!row.product_id) continue
        warehouseStockMap.set(row.product_id, (warehouseStockMap.get(row.product_id) ?? 0) + row.quantity)
      }
      const hasWarehouses = warehouseBatchRows.length > 0
```

`hasWarehouses` is the fallback flag: if no batches exist (no warehouses configured), all trays are treated as refillable.

- [ ] **Step 4: Commit**

```bash
git add management-frontend/app/composables/useMachines.ts
git commit -m "feat: add warehouse stock query and VendingMachine interface fields"
```

---

### Task 3: Update stock health calculation to be warehouse-aware

**Files:**
- Modify: `management-frontend/app/composables/useMachines.ts:227-316` (stock aggregation)

- [ ] **Step 1: Update the stockMap type and Pass 1 logic**

Replace the `stockMap` type definition and Pass 1 loop (lines 227–274). The new type adds `refillableEmpty`, `refillableLow`, `noStockCount`, and `noStockDeficits`:

```ts
      const stockMap = new Map<string, {
        total: number
        refillableEmpty: number
        refillableLow: number
        noStockCount: number
        totalStock: number
        totalCapacity: number
        deficits: Map<string, { product_name: string; product_id: string | null; deficit: number; image_path: string | null; in_stock: boolean }>
        noStockDeficits: Map<string, { product_name: string; product_id: string | null; deficit: number; image_path: string | null; in_stock: boolean }>
        criticalProductIds: Set<string>
        fillBelowPending: { product_id: string | null; capacity: number; current_stock: number; item_number: number; products: { name: string; image_path: string | null } | null }[]
      }>()

      // Pass 1: count low/empty trays, split by warehouse availability
      for (const tray of trayRows) {
        if (!tray.machine_id) continue
        let entry = stockMap.get(tray.machine_id)
        if (!entry) {
          entry = { total: 0, refillableEmpty: 0, refillableLow: 0, noStockCount: 0, totalStock: 0, totalCapacity: 0, deficits: new Map(), noStockDeficits: new Map(), criticalProductIds: new Set(), fillBelowPending: [] }
          stockMap.set(tray.machine_id, entry)
        }
        entry.total++
        entry.totalStock += tray.current_stock
        entry.totalCapacity += tray.capacity

        const isLow = tray.min_stock > 0 && tray.current_stock <= tray.min_stock
        const isEmpty = tray.current_stock === 0
        const isFillBelow = !isLow && !isEmpty && tray.fill_when_below > 0 && tray.current_stock <= tray.fill_when_below

        if (isLow || isEmpty) {
          // Skip unassigned trays — nothing to refill
          if (tray.product_id == null) continue

          const inStock = !hasWarehouses || warehouseStockMap.has(tray.product_id)
          const deficit = tray.capacity - tray.current_stock
          const productName = tray.products?.name ?? `Slot ${tray.item_number}`
          const imagePath = tray.products?.image_path ?? null
          const key = tray.product_id

          if (inStock) {
            if (isEmpty) entry.refillableEmpty++
            else entry.refillableLow++
            const existing = entry.deficits.get(key)
            if (existing) {
              existing.deficit += deficit
            } else {
              entry.deficits.set(key, { product_name: productName, product_id: tray.product_id, deficit, image_path: imagePath, in_stock: true })
            }
            entry.criticalProductIds.add(tray.product_id)
          } else {
            entry.noStockCount++
            const existing = entry.noStockDeficits.get(key)
            if (existing) {
              existing.deficit += deficit
            } else {
              entry.noStockDeficits.set(key, { product_name: productName, product_id: tray.product_id, deficit, image_path: imagePath, in_stock: false })
            }
          }
        }

        if (isFillBelow) {
          entry.fillBelowPending.push(tray)
        }
      }
```

Key changes from existing code:
- Trays with `product_id == null` are skipped when `isLow || isEmpty` (per spec: unassigned trays ignored)
- `isEmpty`/`isLow` trays split into `refillableEmpty`/`refillableLow` vs `noStockCount` based on `warehouseStockMap.has()`
- Fallback: `!hasWarehouses` means all trays are refillable (existing behavior when no warehouses)
- Deficit entries go to `deficits` (refillable) or `noStockDeficits` (no-stock)

- [ ] **Step 2: Update Pass 2 (fill_when_below)**

Replace the existing Pass 2 block (lines 276–292). The logic now checks warehouse availability for `fillBelowPending` trays too, and only triggers when there are refillable low/empty trays:

```ts
      // Pass 2: for machines with refillable critical/low trays, add fill_when_below deficits
      for (const [, entry] of stockMap) {
        if (entry.refillableLow + entry.refillableEmpty === 0) continue
        for (const tray of entry.fillBelowPending) {
          if (tray.product_id == null) continue
          const deficit = tray.capacity - tray.current_stock
          if (deficit <= 0) continue
          const inStock = !hasWarehouses || warehouseStockMap.has(tray.product_id)
          const productName = tray.products?.name ?? `Slot ${tray.item_number}`
          const imagePath = tray.products?.image_path ?? null
          const key = tray.product_id
          const targetMap = inStock ? entry.deficits : entry.noStockDeficits
          const existing = targetMap.get(key)
          if (existing) {
            existing.deficit += deficit
          } else {
            targetMap.set(key, { product_name: productName, product_id: tray.product_id, deficit, image_path: imagePath, in_stock: inStock })
          }
        }
      }
```

- [ ] **Step 3: Update "Apply stock stats to machines" block**

Replace lines 294–316. Now uses `refillableEmpty`/`refillableLow` for `stock_health` and adds `no_stock_trays`/`no_stock_summary`:

```ts
      // Apply stock stats to machines
      for (const machine of machines.value) {
        const stock = stockMap.get(machine.id)
        if (stock) {
          machine.total_trays = stock.total
          machine.low_trays = stock.refillableLow + stock.refillableEmpty
          machine.empty_trays = stock.refillableEmpty
          machine.stock_health = stock.refillableEmpty > 0 ? 'critical' : (stock.refillableLow > 0 ? 'low' : 'ok')
          machine.stock_percent = stock.totalCapacity > 0
            ? Math.round((stock.totalStock / stock.totalCapacity) * 100)
            : 0
          machine.tray_summary = Array.from(stock.deficits.values()).sort((a, b) => b.deficit - a.deficit)
          machine.critical_product_ids = stock.criticalProductIds
          machine.no_stock_trays = stock.noStockCount
          machine.no_stock_summary = Array.from(stock.noStockDeficits.values()).sort((a, b) => b.deficit - a.deficit)
        } else {
          machine.total_trays = 0
          machine.low_trays = 0
          machine.empty_trays = 0
          machine.stock_health = 'ok'
          machine.stock_percent = 0
          machine.tray_summary = []
          machine.critical_product_ids = new Set()
          machine.no_stock_trays = 0
          machine.no_stock_summary = []
        }
      }
```

- [ ] **Step 4: Verify no type errors**

Run: `cd management-frontend && npx vue-tsc --noEmit 2>&1 | head -40`
Expected: No new errors in useMachines.ts

- [ ] **Step 5: Commit**

```bash
git add management-frontend/app/composables/useMachines.ts
git commit -m "feat: warehouse-aware stock health calculation

Split low/empty trays into refillable vs no-stock based on
warehouse_stock_batches availability. Unassigned trays (no product)
are skipped entirely."
```

---

## Chunk 2: UI & i18n

### Task 4: Add i18n keys

**Files:**
- Modify: `management-frontend/i18n/locales/en.json:132` (after `ofTrays`)
- Modify: `management-frontend/i18n/locales/de.json:132` (after `ofTrays`)

- [ ] **Step 1: Add English keys**

In `management-frontend/i18n/locales/en.json`, add these keys inside the `"machines"` object, after the `"ofTrays"` line (line 132):

```json
    "refillNeeded": "{count} refill needed",
    "noWarehouseStock": "{count} no stock",
    "inStock": "in stock",
    "noStock": "no stock",
```

- [ ] **Step 2: Add German keys**

In `management-frontend/i18n/locales/de.json`, add at the same position after `"ofTrays"`:

```json
    "refillNeeded": "{count} Refill nötig",
    "noWarehouseStock": "{count} kein Lager",
    "inStock": "auf Lager",
    "noStock": "kein Lager",
```

- [ ] **Step 3: Commit**

```bash
git add management-frontend/i18n/locales/en.json management-frontend/i18n/locales/de.json
git commit -m "feat: add i18n keys for warehouse-aware stock badges"
```

---

### Task 5: Update machine card UI

**Files:**
- Modify: `management-frontend/app/pages/machines/index.vue` (stock section in template, ~lines 109–146)

- [ ] **Step 1: Replace the stock display section**

In `management-frontend/app/pages/machines/index.vue`, replace the entire stock section (the `<!-- Healthy machine -->` template through the end of the `<!-- Machine needing refill -->` template, including the stock bar). This is the `<template v-if="(machine.stock_health ?? 'ok') === 'ok'">` block through the closing `</template>` of the `v-else` block (approximately lines 109–146).

Replace with this new stock section:

```vue
                <!-- Healthy machine with no stock issues at all -->
                <template v-if="(machine.stock_health ?? 'ok') === 'ok' && (machine.no_stock_trays ?? 0) === 0">
                  <p class="text-sm text-muted-foreground">
                    <template v-if="(machine.total_trays ?? 0) > 0">
                      {{ t('machines.allStocked', { count: machine.total_trays }) }}
                    </template>
                    <template v-else>
                      {{ t('machines.noTraysConfigured') }}
                    </template>
                  </p>
                </template>

                <!-- Machine has stock issues (refillable and/or no-stock) -->
                <template v-else>
                  <!-- "All stocked" context when only no-stock issues remain -->
                  <p v-if="(machine.stock_health ?? 'ok') === 'ok'" class="text-sm text-muted-foreground">
                    {{ t('machines.allStocked', { count: machine.total_trays }) }}
                  </p>

                  <!-- Badges row -->
                  <div class="flex flex-wrap items-center gap-1.5">
                    <span
                      v-if="(machine.low_trays ?? 0) > 0"
                      class="inline-flex items-center gap-1 rounded-md bg-red-500/10 px-2 py-0.5 text-xs font-semibold text-red-500"
                    >
                      {{ t('machines.refillNeeded', { count: machine.low_trays }) }}
                    </span>
                    <span
                      v-if="(machine.no_stock_trays ?? 0) > 0"
                      class="inline-flex items-center rounded-md bg-muted px-2 py-0.5 text-xs text-muted-foreground"
                    >
                      {{ t('machines.noWarehouseStock', { count: machine.no_stock_trays }) }}
                    </span>
                  </div>

                  <!-- Product list -->
                  <div v-if="(machine.tray_summary?.length ?? 0) > 0 || (machine.no_stock_summary?.length ?? 0) > 0" class="space-y-0.5 text-xs">
                    <!-- Refillable products -->
                    <div
                      v-for="item in machine.tray_summary"
                      :key="'refill-' + item.product_id"
                      class="flex items-center justify-between"
                    >
                      <span :class="item.deficit >= (machine.tray_summary?.[0]?.deficit ?? 0) ? 'text-red-500' : 'text-amber-500'">
                        {{ item.product_name }} <span class="text-muted-foreground">(-{{ item.deficit }})</span>
                      </span>
                      <span class="text-green-500 text-[10px]">{{ t('machines.inStock') }}</span>
                    </div>
                    <!-- No-stock products (dimmed, sorted to bottom) -->
                    <div
                      v-for="item in machine.no_stock_summary"
                      :key="'nostock-' + item.product_id"
                      class="flex items-center justify-between opacity-50"
                    >
                      <span>
                        {{ item.product_name }} <span class="text-muted-foreground">(-{{ item.deficit }})</span>
                      </span>
                      <span class="text-muted-foreground text-[10px]">{{ t('machines.noStock') }}</span>
                    </div>
                  </div>

                  <!-- Stock bar (only when there are refillable issues) -->
                  <div v-if="(machine.stock_health ?? 'ok') !== 'ok'" class="flex items-center gap-2">
                    <div class="h-2 flex-1 overflow-hidden rounded-full bg-muted">
                      <div
                        class="h-full rounded-full transition-all"
                        :class="{
                          'bg-red-500': (machine.stock_percent ?? 0) < 20,
                          'bg-amber-500': (machine.stock_percent ?? 0) >= 20 && (machine.stock_percent ?? 0) < 50,
                          'bg-green-500': (machine.stock_percent ?? 0) >= 50,
                        }"
                        :style="{ width: `${machine.stock_percent ?? 0}%` }"
                      />
                    </div>
                    <span class="text-xs font-medium text-muted-foreground w-8 text-right">{{ machine.stock_percent ?? 0 }}%</span>
                  </div>
                </template>
```

Key UI behaviors:
- **Fully ok + no no-stock:** Shows existing "All stocked" message (unchanged)
- **Fully ok + has no-stock:** Falls into the `v-else` block, shows "All stocked" text + gray "X kein Lager" badge + dimmed product list (no red badge since `low_trays` is 0)
- **Critical/low:** Shows red refill badge + optional gray no-stock badge + product list + stock bar
- The product list shows refillable items first (colored) then no-stock items (dimmed)
- Stock bar only shows when `stock_health !== 'ok'` (not for no-stock-only machines)

- [ ] **Step 2: Verify the dev server builds**

Run: `cd management-frontend && npx nuxi build 2>&1 | tail -20`
Expected: Build succeeds with no errors

- [ ] **Step 3: Commit**

```bash
git add management-frontend/app/pages/machines/index.vue
git commit -m "feat: warehouse-aware stock badges and product list on machine cards

Show separate refillable vs no-stock counts with colored badges.
Product list indicates per-product warehouse availability."
```

---

### Task 6: Final verification

- [ ] **Step 1: Run type check**

Run: `cd management-frontend && npx vue-tsc --noEmit 2>&1 | tail -20`
Expected: No type errors

- [ ] **Step 2: Run existing tests**

Run: `cd management-frontend && npx vitest run 2>&1 | tail -30`
Expected: All existing tests pass (no regressions)

- [ ] **Step 3: Dev server smoke test**

Run: `cd management-frontend && npx nuxi build 2>&1 | tail -5`
Expected: Build completes successfully
