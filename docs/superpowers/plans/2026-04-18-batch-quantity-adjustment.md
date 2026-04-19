# Batch Quantity Adjustment Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let operators adjust the quantity of a specific existing batch — both up and down — without re-typing the batch number or expiration date. Add a first-class "refill return" transaction type for the primary use case (items brought back after a refill overdraw). Ship on web and iOS.

**Architecture:** The existing web `adjustStock()` composable already accepts a signed `quantity_change` — only the UI forces negative. We widen the UI to both directions and add a new transaction type string `adjustment_refill_return` (no DB migration — the column is free text). iOS gets a new Stock-tab drilldown (`ProductBatchesView`) and adjust sheet (`BatchAdjustSheet`), backed by two new `WarehouseViewModel` methods that reuse the existing `WarehouseStockBatch` model.

**Tech Stack:** Vue 3 / Nuxt 4 / TailwindCSS 4 / Vitest (web); SwiftUI / Supabase-Swift (iOS); PostgreSQL via Supabase PostgREST.

**Spec:** `docs/superpowers/specs/2026-04-18-batch-quantity-adjustment-design.md`

---

## File Structure

### Web

- **Modify** `management-frontend/app/composables/useWarehouse.ts`
  - Extend `adjustStock` reason union to include `'adjustment_refill_return'`
  - Extend `transactionTypeLabel` + `transactionTypeBadgeClass` to handle the new type
- **Create** `management-frontend/app/composables/__tests__/useWarehouse.test.ts`
  - Vitest unit test for `adjustStock` positive path
- **Modify** `management-frontend/app/pages/warehouse/index.vue`
  - Add `adjustDirection` ref + direction-aware reason defaults
  - Replace static adjust-modal body with direction toggle, dynamic reason options, dynamic submit button
  - Flip sign of `quantity_change` based on direction
  - Add `adjustment_refill_return` to history filter dropdown
- **Modify** `management-frontend/i18n/locales/en.json`
  - New warehouse keys: `adjustDirectionRemove`, `adjustDirectionAdd`, `refillReturn`, `refillReturnDescription`, `addStock`, `quantityToAdd`, `refillReturnFilter`
- **Modify** `management-frontend/i18n/locales/de.json`
  - Same keys, German strings

### iOS

- **Modify** `ios/VMflow/ViewModels/WarehouseViewModel.swift`
  - New published state for batch drilldown
  - New methods `loadBatchesForProduct(_:)`, `adjustBatch(...)`
- **Modify** `ios/VMflow/Views/Warehouse/WarehouseView.swift`
  - Wrap `StockSummaryRow` in `NavigationLink` to `ProductBatchesView`
- **Create** `ios/VMflow/Views/Warehouse/ProductBatchesView.swift`
  - Batch list for one product in the current warehouse
  - Presents `BatchAdjustSheet` on tap
- **Create** `ios/VMflow/Views/Warehouse/BatchAdjustSheet.swift`
  - Direction segment, reason picker, quantity field with expression evaluator, notes, submit

No DB migrations. No firmware changes. No MQTT changes.

---

## Chunk 1: Web composable + unit test

### Task 1: Extend `adjustStock` reason union and transaction labels

**Files:**
- Modify: `management-frontend/app/composables/useWarehouse.ts:439`
- Modify: `management-frontend/app/composables/useWarehouse.ts:652-676`

- [ ] **Step 1: Widen the `reason` union in `adjustStock`**

Locate the `adjustStock` function signature around line 434–441. Change:

```ts
  async function adjustStock(input: {
    batch_id: string
    warehouse_id: string
    product_id: string
    quantity_change: number
    reason: 'adjustment_damage' | 'adjustment_expired' | 'adjustment_correction'
    notes?: string
  }) {
```

to:

```ts
  async function adjustStock(input: {
    batch_id: string
    warehouse_id: string
    product_id: string
    quantity_change: number
    reason: 'adjustment_damage' | 'adjustment_expired' | 'adjustment_correction' | 'adjustment_refill_return'
    notes?: string
  }) {
```

The function body is unchanged — `Math.max(0, quantityBefore + input.quantity_change)` already handles positive deltas correctly (clamp is a no-op when adding).

- [ ] **Step 2: Extend `transactionTypeLabel` helper**

In `useWarehouse.ts` around line 652–663, update the switch:

```ts
  function transactionTypeLabel(type: string): string {
    switch (type) {
      case 'incoming': return 'Incoming'
      case 'outgoing_refill': return 'Refill'
      case 'adjustment_damage': return 'Damaged'
      case 'adjustment_expired': return 'Expired'
      case 'adjustment_correction': return 'Correction'
      case 'adjustment_refill_return': return 'Refill return'
      case 'transfer_out': return 'Transfer out'
      case 'transfer_in': return 'Transfer in'
      default: return type
    }
  }
```

- [ ] **Step 3: Extend `transactionTypeBadgeClass` helper**

Around line 665–676, add the new case. Style it green (same family as `incoming`):

```ts
  function transactionTypeBadgeClass(type: string): string {
    switch (type) {
      case 'incoming': return 'bg-green-100 text-green-700 dark:bg-green-950/40 dark:text-green-400'
      case 'outgoing_refill': return 'bg-blue-100 text-blue-700 dark:bg-blue-950/40 dark:text-blue-400'
      case 'adjustment_damage': return 'bg-red-100 text-red-700 dark:bg-red-950/40 dark:text-red-400'
      case 'adjustment_expired': return 'bg-red-100 text-red-700 dark:bg-red-950/40 dark:text-red-400'
      case 'adjustment_correction': return 'bg-amber-100 text-amber-700 dark:bg-amber-950/40 dark:text-amber-400'
      case 'adjustment_refill_return': return 'bg-green-100 text-green-700 dark:bg-green-950/40 dark:text-green-400'
      case 'transfer_out': return 'bg-purple-100 text-purple-700 dark:bg-purple-950/40 dark:text-purple-400'
      case 'transfer_in': return 'bg-purple-100 text-purple-700 dark:bg-purple-950/40 dark:text-purple-400'
      default: return 'bg-muted text-muted-foreground'
    }
  }
```

- [ ] **Step 4: Typecheck**

Run:
```bash
cd management-frontend && npx nuxi typecheck 2>&1 | tail -20
```
Expected: no new errors introduced by this change. Pre-existing errors unrelated to `useWarehouse.ts` are acceptable (note them in the commit message if any appear).

- [ ] **Step 5: Commit**

```bash
git add management-frontend/app/composables/useWarehouse.ts
git commit -m "$(cat <<'EOF'
feat(warehouse): allow adjustment_refill_return in adjustStock

Extend the reason union on the adjustStock composable and add the new
transaction type to the label/badge helpers (green badge, same family as
incoming). Function body is unchanged — Math.max(0, ...) already handles
positive deltas correctly.
EOF
)"
```

---

### Task 2: Unit test for `adjustStock` positive path

**Files:**
- Create: `management-frontend/app/composables/__tests__/useWarehouse.test.ts`

- [ ] **Step 1: Write the failing test file**

Create `management-frontend/app/composables/__tests__/useWarehouse.test.ts` using the same mocking pattern as `useProductDetail.test.ts` (thenable chainable builder, `vi.mock('#imports')` shim):

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { ref as vueRef } from 'vue'

;(globalThis as any).ref = vueRef

// Captures of write calls so the test can assert on them
const captured = {
  batchUpdates: [] as { id: string; quantity: number }[],
  transactionInserts: [] as any[],
}

// Fixture for the "fetch current batch" read
const batchFixture = {
  data: null as { quantity: number; batch_number: string | null; expiration_date: string | null } | null,
  error: null as any,
}

// Fixture for the authenticated session
const sessionFixture = {
  data: { session: { user: { id: 'user-1', email: 'tester@example.com' } } },
  error: null as any,
}

function makeBatchBuilder() {
  const b: any = {}
  b.select = vi.fn(() => b)
  b.eq = vi.fn(() => b)
  b.single = vi.fn(() => Promise.resolve(batchFixture))
  // update(...).eq(id) — capture and return { error: null }
  b.update = vi.fn((row: any) => {
    const child: any = {}
    child.eq = vi.fn((_col: string, id: string) => {
      captured.batchUpdates.push({ id, quantity: row.quantity })
      return Promise.resolve({ error: null })
    })
    return child
  })
  return b
}

function makeTransactionBuilder() {
  const b: any = {}
  b.insert = vi.fn((row: any) => {
    captured.transactionInserts.push(row)
    return Promise.resolve({ error: null })
  })
  return b
}

const mockSupabase = {
  from: vi.fn((table: string) => {
    if (table === 'warehouse_stock_batches') return makeBatchBuilder()
    if (table === 'warehouse_transactions') return makeTransactionBuilder()
    // Unused paths in this test
    const passthrough: any = {}
    for (const m of ['select', 'eq', 'gt', 'order']) passthrough[m] = vi.fn(() => passthrough)
    passthrough.then = (resolve: any) => resolve({ data: [], error: null })
    return passthrough
  }),
  auth: {
    getSession: vi.fn(() => Promise.resolve(sessionFixture)),
  },
}

vi.mock('#imports', () => {
  const { ref } = require('vue')
  return {
    ref,
    // useState is used at composable setup for `velocityDays` — must be stubbed
    useState: <T,>(_k: string, init?: () => T) => ref(init?.()),
    useSupabaseClient: () => mockSupabase,
  }
})

vi.mock('../useOrganization', () => ({
  useOrganization: () => ({ organization: { value: { id: 'company-1' } } }),
}))

import { useWarehouse } from '../useWarehouse'

beforeEach(() => {
  vi.clearAllMocks()
  captured.batchUpdates = []
  captured.transactionInserts = []
  batchFixture.data = null
  batchFixture.error = null
})

describe('useWarehouse.adjustStock', () => {
  it('adds quantity for a positive refill-return adjustment', async () => {
    batchFixture.data = { quantity: 10, batch_number: 'LOT-1', expiration_date: '2026-12-31' }

    const { adjustStock } = useWarehouse()
    await adjustStock({
      batch_id: 'batch-1',
      warehouse_id: 'wh-1',
      product_id: 'p-1',
      quantity_change: 3,
      reason: 'adjustment_refill_return',
      notes: 'Brought 3 back from refill',
    })

    expect(captured.batchUpdates).toEqual([{ id: 'batch-1', quantity: 13 }])
    expect(captured.transactionInserts).toHaveLength(1)
    const tx = captured.transactionInserts[0]
    expect(tx.transaction_type).toBe('adjustment_refill_return')
    expect(tx.quantity_change).toBe(3)
    expect(tx.quantity_before).toBe(10)
    expect(tx.quantity_after).toBe(13)
    expect(tx.batch_id).toBe('batch-1')
    expect(tx.company_id).toBe('company-1')
    expect(tx.notes).toBe('Brought 3 back from refill')
  })

  it('subtracts quantity for a negative damage adjustment and clamps at zero', async () => {
    batchFixture.data = { quantity: 2, batch_number: null, expiration_date: null }

    const { adjustStock } = useWarehouse()
    await adjustStock({
      batch_id: 'batch-2',
      warehouse_id: 'wh-1',
      product_id: 'p-1',
      quantity_change: -5, // would be -3, clamped to 0
      reason: 'adjustment_damage',
    })

    expect(captured.batchUpdates).toEqual([{ id: 'batch-2', quantity: 0 }])
    const tx = captured.transactionInserts[0]
    expect(tx.transaction_type).toBe('adjustment_damage')
    expect(tx.quantity_change).toBe(-5)
    expect(tx.quantity_before).toBe(2)
    expect(tx.quantity_after).toBe(0)
  })
})
```

- [ ] **Step 2: Run the test — expect it to pass**

Since Task 1 already widened the union, and the function body was unchanged, this should pass on first run.

```bash
cd management-frontend && npx vitest run app/composables/__tests__/useWarehouse.test.ts
```
Expected: 2 passing tests, 0 failing.

If it fails with a TypeScript complaint about `'adjustment_refill_return'` not being in the union — Task 1 was not completed correctly; re-check `useWarehouse.ts:439`.

- [ ] **Step 3: Commit**

```bash
git add management-frontend/app/composables/__tests__/useWarehouse.test.ts
git commit -m "test(warehouse): cover adjustStock positive (refill return) and clamped negative paths"
```

---

## Chunk 2: Web UI — i18n, adjust modal, history filter

### Task 3: Add i18n keys (en + de)

**Files:**
- Modify: `management-frontend/i18n/locales/en.json` (warehouse section, ~line 630)
- Modify: `management-frontend/i18n/locales/de.json` (warehouse section, ~line 630)

- [ ] **Step 1: Add new English keys**

In `management-frontend/i18n/locales/en.json`, inside the `"warehouse": { ... }` object (around line 630), add the following keys. Place them next to the existing adjust-modal keys (`adjustStockTitle`, `adjustBatchInfo`, `reason`, `damaged`, `expiredDisposed`, `inventoryCorrection`, `quantityToRemove`, `adjusting`, `removeStock`):

```json
    "adjustDirectionRemove": "Remove",
    "adjustDirectionAdd": "Add",
    "refillReturn": "Refill return",
    "refillReturnDescription": "Items returned after a refill took too much",
    "addStockSubmit": "Add stock",
    "quantityToAdd": "Quantity to add",
    "refillReturnFilter": "Refill returns",
```

Place them directly after `"removeStock": "Remove stock",` so related keys stay grouped.

- [ ] **Step 2: Add matching German keys**

In `management-frontend/i18n/locales/de.json`, same location:

```json
    "adjustDirectionRemove": "Abbuchen",
    "adjustDirectionAdd": "Einbuchen",
    "refillReturn": "Rückgabe aus Refill",
    "refillReturnDescription": "Beim Refill zu viel entnommen — wieder eingebucht",
    "addStock": "Bestand einbuchen",
    "quantityToAdd": "Einzubuchende Menge",
    "refillReturnFilter": "Rückgabe aus Refill",
```

- [ ] **Step 3: Verify both JSON files parse**

Run:
```bash
cd management-frontend && node -e "JSON.parse(require('fs').readFileSync('i18n/locales/en.json','utf8')); JSON.parse(require('fs').readFileSync('i18n/locales/de.json','utf8')); console.log('ok')"
```
Expected: `ok` — no syntax errors.

- [ ] **Step 4: Commit**

```bash
git add management-frontend/i18n/locales/en.json management-frontend/i18n/locales/de.json
git commit -m "i18n(warehouse): add direction-toggle and refill-return keys"
```

---

### Task 4: Refactor adjust-modal state (direction, reason, handler)

**Files:**
- Modify: `management-frontend/app/pages/warehouse/index.vue:814–853`

- [ ] **Step 1: Add `adjustDirection` ref and update `openAdjust` / `submitAdjust`**

Replace the block at lines 814–853 (from `const adjustBatch = ref<StockBatch | null>(null)` through the closing brace of `submitAdjust`) with:

```ts
const adjustBatch = ref<StockBatch | null>(null)
const adjustDirection = ref<'remove' | 'add'>('remove')
const adjustQuantity = ref<number | null>(null)
const adjustReason = ref<
  'adjustment_damage' | 'adjustment_expired' | 'adjustment_correction' | 'adjustment_refill_return'
>('adjustment_damage')
const adjustNotes = ref('')
const adjustLoading = ref(false)
const adjustError = ref('')

/** Default reason per direction — must be a valid option for the active direction. */
function defaultReasonFor(direction: 'remove' | 'add') {
  return direction === 'remove' ? 'adjustment_damage' : 'adjustment_refill_return'
}

function openAdjust(batch: StockBatch) {
  adjustBatch.value = batch
  adjustDirection.value = 'remove'
  adjustQuantity.value = null
  adjustReason.value = defaultReasonFor('remove')
  adjustNotes.value = ''
  adjustError.value = ''
  showAdjustModal.value = true
}

/**
 * Called when the direction toggle flips. Always resets to the default reason
 * for the new direction, even though `adjustment_correction` is valid in both
 * — this prevents stale negative-only reasons (Damaged/Expired) leaking into
 * the Add flow. A future polish could be "only reset when current reason is
 * not valid for the new direction."
 */
function onAdjustDirectionChange() {
  adjustReason.value = defaultReasonFor(adjustDirection.value)
}

async function submitAdjust() {
  if (!adjustBatch.value || !adjustQuantity.value) {
    adjustError.value = t('warehouse.enterQuantity')
    return
  }
  adjustLoading.value = true
  adjustError.value = ''
  try {
    const magnitude = Math.abs(adjustQuantity.value)
    const signed = adjustDirection.value === 'remove' ? -magnitude : magnitude
    await adjustStock({
      batch_id: adjustBatch.value.id,
      warehouse_id: adjustBatch.value.warehouse_id,
      product_id: adjustBatch.value.product_id,
      quantity_change: signed,
      reason: adjustReason.value,
      notes: adjustNotes.value.trim() || undefined,
    })
    showAdjustModal.value = false
    await loadWarehouseData()
  } catch (err: any) {
    adjustError.value = err.message ?? t('warehouse.failedToAdjustStock')
  } finally {
    adjustLoading.value = false
  }
}
```

Key changes:
- `adjustDirection` ref added (default `'remove'` → backward-compatible default).
- Reason union widened to include `'adjustment_refill_return'`.
- `defaultReasonFor()` centralizes the per-direction default.
- `onAdjustDirectionChange()` resets the reason when the user flips the toggle (prevents stale reason like "Damaged" while direction is "Add").
- Sign computation lives in `submitAdjust` — `adjustQuantity` is always the positive magnitude.

- [ ] **Step 2: Typecheck**

```bash
cd management-frontend && npx nuxi typecheck 2>&1 | grep -i "warehouse/index" | head
```
Expected: no new errors specific to `warehouse/index.vue`.

- [ ] **Step 3: Commit**

```bash
git add management-frontend/app/pages/warehouse/index.vue
git commit -m "feat(warehouse): add direction state and signed-change handler for adjust modal"
```

---

### Task 5: Replace adjust-modal body with direction-aware UI

**Files:**
- Modify: `management-frontend/app/pages/warehouse/index.vue:2294–2323`

- [ ] **Step 1: Replace the modal body**

Find the `<!-- Adjustment modal -->` block. Replace the entire `<AppModal>` element (lines 2294–2323) with:

```vue
    <!-- Adjustment modal -->
    <AppModal v-model:open="showAdjustModal" :title="t('warehouse.adjustStockTitle')">
      <p class="mb-3 text-sm text-muted-foreground">
        {{ t('warehouse.adjustBatchInfo', { product: adjustBatch?.product_name ?? '', batch: adjustBatch?.batch_number || t('warehouse.noBatchId'), quantity: adjustBatch?.quantity ?? 0 }) }}
      </p>
      <form class="flex flex-col gap-3" @submit.prevent="submitAdjust">
        <!-- Direction toggle -->
        <div class="inline-flex rounded-md border bg-muted/40 p-0.5">
          <button
            type="button"
            class="flex-1 rounded px-3 py-1.5 text-sm font-medium transition-colors"
            :class="adjustDirection === 'remove' ? 'bg-red-600 text-white shadow-sm' : 'text-muted-foreground hover:text-foreground'"
            @click="adjustDirection = 'remove'; onAdjustDirectionChange()"
          >
            − {{ t('warehouse.adjustDirectionRemove') }}
          </button>
          <button
            type="button"
            class="flex-1 rounded px-3 py-1.5 text-sm font-medium transition-colors"
            :class="adjustDirection === 'add' ? 'bg-green-600 text-white shadow-sm' : 'text-muted-foreground hover:text-foreground'"
            @click="adjustDirection = 'add'; onAdjustDirectionChange()"
          >
            + {{ t('warehouse.adjustDirectionAdd') }}
          </button>
        </div>

        <div>
          <label class="mb-1 block text-sm font-medium">{{ t('warehouse.reason') }} *</label>
          <select v-model="adjustReason" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring">
            <template v-if="adjustDirection === 'remove'">
              <option value="adjustment_damage">{{ t('warehouse.damaged') }}</option>
              <option value="adjustment_expired">{{ t('warehouse.expiredDisposed') }}</option>
              <option value="adjustment_correction">{{ t('warehouse.inventoryCorrection') }}</option>
            </template>
            <template v-else>
              <option value="adjustment_refill_return">{{ t('warehouse.refillReturn') }}</option>
              <option value="adjustment_correction">{{ t('warehouse.inventoryCorrection') }}</option>
            </template>
          </select>
          <p v-if="adjustDirection === 'add' && adjustReason === 'adjustment_refill_return'" class="mt-1 text-xs text-muted-foreground">
            {{ t('warehouse.refillReturnDescription') }}
          </p>
        </div>

        <div>
          <label class="mb-1 block text-sm font-medium">
            {{ adjustDirection === 'remove' ? t('warehouse.quantityToRemove') : t('warehouse.quantityToAdd') }} *
          </label>
          <input
            v-model.number="adjustQuantity"
            type="number"
            min="1"
            :max="adjustDirection === 'remove' ? (adjustBatch?.quantity ?? undefined) : undefined"
            class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>

        <div>
          <label class="mb-1 block text-sm font-medium">{{ t('common.notes') }}</label>
          <textarea v-model="adjustNotes" rows="2" class="w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring" :placeholder="t('warehouse.optionalDetails')"></textarea>
        </div>

        <FormError :message="adjustError" />

        <div class="flex justify-end gap-2">
          <button type="button" class="h-9 rounded-md border px-4 text-sm hover:bg-muted" @click="showAdjustModal = false">{{ t('common.cancel') }}</button>
          <button
            type="submit"
            class="h-9 rounded-md px-4 text-sm font-medium text-white disabled:opacity-50"
            :class="adjustDirection === 'remove' ? 'bg-red-600 hover:bg-red-700' : 'bg-green-600 hover:bg-green-700'"
            :disabled="adjustLoading"
          >
            {{ adjustLoading
                ? t('warehouse.adjusting')
                : (adjustDirection === 'remove' ? t('warehouse.removeStock') : t('warehouse.addStockSubmit')) }}
          </button>
        </div>
      </form>
    </AppModal>
```

Key changes vs. the old modal:
- Direction toggle segment at the top. Click handler sets `adjustDirection` and calls `onAdjustDirectionChange()` to reset reason.
- Reason dropdown's options are now direction-aware via `<template v-if>`.
- Helper description (`refillReturnDescription`) appears under the select when the user picks "Refill return".
- Quantity label flips between "Quantity to remove" and "Quantity to add". `max` attribute is only set when removing (prevents overdraft); unbounded when adding.
- Submit button color (red/green) and label ("Remove stock" / "Add stock") derive from `adjustDirection`.

- [ ] **Step 2: Manual verification in dev**

Start the dev server and manually verify both flows:
```bash
cd management-frontend && npm run dev
```

Then in the browser:
1. Log in, navigate to `/warehouse`, pick any warehouse with at least one stocked batch.
2. Expand a product row, click "Adjust" on a batch.
3. Default direction should be "Remove" (red button, "Damaged" reason). Enter quantity, submit — stock decreases, transaction appears in history as "Damaged".
4. Re-open the modal. Click "+ Add". Button turns green, reason dropdown shows "Refill return" / "Inventory correction". Description appears under the select. Enter a quantity greater than current batch (confirm no max cap), submit — stock increases, transaction appears in history as "Refill return" (green badge).

- [ ] **Step 3: Run existing tests to confirm no regression**

```bash
cd management-frontend && npx vitest run
```
Expected: all tests pass, including the two added in Task 2.

- [ ] **Step 4: Commit**

```bash
git add management-frontend/app/pages/warehouse/index.vue
git commit -m "feat(warehouse): bidirectional adjust-stock modal with direction toggle"
```

---

### Task 6: Add `adjustment_refill_return` to history filter dropdown

**Files:**
- Modify: `management-frontend/app/pages/warehouse/index.vue:1677–1683`

- [ ] **Step 1: Add the new filter option**

In the transaction-history filter dropdown (look for `<option value="incoming">` around line 1678), add a new `<option>` directly after `adjustment_correction`:

```vue
              <option value="">{{ t('warehouse.allTypes') }}</option>
              <option value="incoming">{{ t('warehouse.incomingFilter') }}</option>
              <option value="outgoing_refill">{{ t('warehouse.refillFilter') }}</option>
              <option value="adjustment_damage">{{ t('warehouse.damagedFilter') }}</option>
              <option value="adjustment_expired">{{ t('warehouse.expiredFilter') }}</option>
              <option value="adjustment_correction">{{ t('warehouse.correctionFilter') }}</option>
              <option value="adjustment_refill_return">{{ t('warehouse.refillReturnFilter') }}</option>
```

- [ ] **Step 2: Manual verification**

With the dev server running, navigate to the transaction history tab. The filter dropdown should now have a "Refill returns" option. Select it after creating a refill-return transaction in Task 5 — only those transactions appear.

- [ ] **Step 3: Commit**

```bash
git add management-frontend/app/pages/warehouse/index.vue
git commit -m "feat(warehouse): add refill-return option to transaction history filter"
```

---

## Chunk 3: iOS — batch drilldown + adjust sheet

### Task 7: Add `loadBatchesForProduct` and `adjustBatch` to `WarehouseViewModel`

**Files:**
- Modify: `ios/VMflow/ViewModels/WarehouseViewModel.swift`
- Modify: `ios/VMflow/Models/Warehouse.swift` (extend `InsertWarehouseTransaction`)

- [ ] **Step 0: Extend `InsertWarehouseTransaction` with history-parity fields**

In `ios/VMflow/Models/Warehouse.swift`, find `struct InsertWarehouseTransaction: Codable` (line ~92). Extend it so iOS-booked adjustments match what the web writes on `warehouse_transactions`:

```swift
/// Codable wrapper for inserting a warehouse transaction via Supabase.
struct InsertWarehouseTransaction: Codable {
    let warehouseId: UUID
    let productId: UUID
    let transactionType: String
    let quantityChange: Int
    let userId: UUID
    let batchId: UUID?
    let notes: String?
    let companyId: UUID
    // Web-parity columns — optional so existing `bookIntake` call sites work unchanged.
    let quantityBefore: Int?
    let quantityAfter: Int?
    let batchNumber: String?
    let expirationDate: String?

    enum CodingKeys: String, CodingKey {
        case notes
        case warehouseId = "warehouse_id"
        case productId = "product_id"
        case transactionType = "transaction_type"
        case quantityChange = "quantity_change"
        case userId = "user_id"
        case batchId = "batch_id"
        case companyId = "company_id"
        case quantityBefore = "quantity_before"
        case quantityAfter = "quantity_after"
        case batchNumber = "batch_number"
        case expirationDate = "expiration_date"
    }
}
```

Then update the existing `bookIntake` callsite in `WarehouseViewModel.swift:329–338` to pass `nil` for all four new fields (keeps current behavior unchanged):

```swift
            let transaction = InsertWarehouseTransaction(
                warehouseId: warehouseId,
                productId: productId,
                transactionType: "intake",
                quantityChange: quantity,
                userId: userId,
                batchId: batchId,
                notes: batchNumber.flatMap { $0.isEmpty ? nil : "Batch: \($0)" },
                companyId: companyId,
                quantityBefore: nil,
                quantityAfter: nil,
                batchNumber: batchNumber,
                expirationDate: expirationDate
            )
```

(Bonus fix: `bookIntake` now also records `batch_number` and `expiration_date` on the transaction row, matching the web behavior. Before this change iOS intake transactions had those columns as NULL.)

- [ ] **Step 1: Add published state for the batch drilldown**

In `WarehouseViewModel.swift`, in the `// MARK: - Published State` block (top of the class, around line 9–24), add after `@Published var recentIntakes: [IntakeEntry] = []`:

```swift
    // Batch drilldown state (for ProductBatchesView)
    @Published var drilldownBatches: [WarehouseStockBatch] = []
    @Published var isLoadingBatches = false
    @Published var isAdjustingBatch = false
```

- [ ] **Step 2: Add `loadBatchesForProduct`**

Append a new MARK section after the existing `// MARK: - Book Intake` block (around line 297), before the closing `}` of the class:

```swift
    // MARK: - Batch drilldown

    /// Loads all non-empty batches for a specific product in the current warehouse,
    /// ordered by expiration date ascending (oldest first).
    /// Reuses the existing `WarehouseStockBatch` model from `Models/Warehouse.swift`.
    func loadBatchesForProduct(_ productId: UUID) async {
        guard let warehouseId = selectedWarehouseId else {
            drilldownBatches = []
            return
        }

        isLoadingBatches = true
        defer { isLoadingBatches = false }

        do {
            let batches: [WarehouseStockBatch] = try await client
                .from("warehouse_stock_batches")
                .select("id, warehouse_id, product_id, quantity, batch_number, expiration_date")
                .eq("warehouse_id", value: warehouseId.uuidString)
                .eq("product_id", value: productId.uuidString)
                .gt("quantity", value: 0)
                .order("expiration_date", ascending: true)
                .execute()
                .value

            drilldownBatches = batches
        } catch is CancellationError {
            // SwiftUI cancels refreshable tasks routinely — ignore
        } catch {
            self.error = error.localizedDescription
        }
    }
```

- [ ] **Step 3: Add `adjustBatch`**

Append directly after `loadBatchesForProduct` in the same MARK section:

```swift
    /// Adjust the quantity of a specific batch by a signed delta.
    /// `reason` MUST be one of: `adjustment_refill_return`, `adjustment_correction`,
    /// `adjustment_damage`, `adjustment_expired` — do NOT pass `intake` or `incoming`
    /// (those remain reserved for the Wareneingang flow).
    ///
    /// Quantity is clamped at zero so concurrent sales can't produce negative stock.
    /// On success, reloads batches + product summaries so callers see fresh data.
    func adjustBatch(
        batchId: UUID,
        quantityChange: Int,
        reason: String,
        notes: String?
    ) async {
        guard let warehouseId = selectedWarehouseId,
              let companyId = warehouses.first(where: { $0.id == warehouseId })?.companyId else {
            return
        }

        isAdjustingBatch = true
        error = nil
        defer { isAdjustingBatch = false }

        do {
            // 1. Fetch current batch to get quantity_before + product_id
            struct CurrentBatch: Decodable {
                let productId: UUID
                let quantity: Int
                let batchNumber: String?
                let expirationDate: String?

                enum CodingKeys: String, CodingKey {
                    case quantity
                    case productId = "product_id"
                    case batchNumber = "batch_number"
                    case expirationDate = "expiration_date"
                }
            }

            let current: CurrentBatch = try await client
                .from("warehouse_stock_batches")
                .select("product_id, quantity, batch_number, expiration_date")
                .eq("id", value: batchId.uuidString)
                .single()
                .execute()
                .value

            let quantityBefore = current.quantity
            let quantityAfter = max(0, quantityBefore + quantityChange)

            // 2. Update batch quantity
            struct BatchUpdate: Encodable { let quantity: Int }
            try await client
                .from("warehouse_stock_batches")
                .update(BatchUpdate(quantity: quantityAfter))
                .eq("id", value: batchId.uuidString)
                .execute()

            // 3. Insert transaction row (web-parity: includes before/after + batch metadata)
            let userId = try await client.auth.session.user.id
            let transaction = InsertWarehouseTransaction(
                warehouseId: warehouseId,
                productId: current.productId,
                transactionType: reason,
                quantityChange: quantityChange,
                userId: userId,
                batchId: batchId,
                notes: (notes?.isEmpty ?? true) ? nil : notes,
                companyId: companyId,
                quantityBefore: quantityBefore,
                quantityAfter: quantityAfter,
                batchNumber: current.batchNumber,
                expirationDate: current.expirationDate
            )

            try await client
                .from("warehouse_transactions")
                .insert(transaction)
                .execute()

            // 4. Reload affected state
            async let batchesTask: () = loadBatchesForProduct(current.productId)
            async let summariesTask: () = loadProductSummaries()
            _ = await (batchesTask, summariesTask)
        } catch is CancellationError {
            // ignore
        } catch {
            self.error = error.localizedDescription
        }
    }
```

Note: `InsertWarehouseTransaction` was extended in Step 0 so iOS adjustments write the same `quantity_before`, `quantity_after`, `batch_number`, `expiration_date` columns that the web composable writes. Without this, iOS-booked adjustments would show NULLs in those columns when viewed from the web transaction history.

- [ ] **Step 4: Build the iOS app — expect it to compile**

```bash
cd ios && xcodebuild -project VMflow.xcodeproj -scheme VMflow -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -20
```
Expected: "BUILD SUCCEEDED" in the output. If build fails, check that `WarehouseStockBatch` and `InsertWarehouseTransaction` are imported implicitly via the Models group (they should — same target).

- [ ] **Step 5: Commit**

```bash
git add ios/VMflow/ViewModels/WarehouseViewModel.swift
git commit -m "feat(ios/warehouse): loadBatchesForProduct + adjustBatch view-model methods"
```

---

### Task 8: Create `BatchAdjustSheet`

**Files:**
- Create: `ios/VMflow/Views/Warehouse/BatchAdjustSheet.swift`

- [ ] **Step 1: Write the sheet view**

Create a new file `ios/VMflow/Views/Warehouse/BatchAdjustSheet.swift`:

```swift
import SwiftUI

/// Bottom sheet for adjusting a warehouse batch's quantity — positive or negative.
/// Preserves batch_number + expiration_date (operates on batch_id).
struct BatchAdjustSheet: View {
    let batch: WarehouseStockBatch
    let productName: String
    let imagePath: String?
    let onSubmit: (Int, String, String?) async -> Void  // (signedDelta, reason, notes)

    @Environment(\.dismiss) private var dismiss

    enum Direction: String, Hashable { case remove, add }

    @State private var direction: Direction = .remove
    @State private var reason: String = "adjustment_damage"
    @State private var quantityText: String = ""
    @State private var notes: String = ""
    @State private var isSubmitting = false
    @FocusState private var quantityFieldFocused: Bool

    /// Reasons valid for the current direction. First entry is the default when direction flips.
    private var reasonsForDirection: [(value: String, label: String)] {
        switch direction {
        case .remove:
            return [
                ("adjustment_damage", String(localized: "Damaged")),
                ("adjustment_expired", String(localized: "Expired")),
                ("adjustment_correction", String(localized: "Inventory correction")),
            ]
        case .add:
            return [
                ("adjustment_refill_return", String(localized: "Refill return")),
                ("adjustment_correction", String(localized: "Inventory correction")),
            ]
        }
    }

    private var parsedQuantity: Int? {
        evaluateExpression(quantityText)
    }

    private var canSubmit: Bool {
        guard let q = parsedQuantity, q > 0, !isSubmitting else { return false }
        if direction == .remove { return q <= batch.quantity }
        return true
    }

    private var submitLabel: String {
        direction == .remove
            ? String(localized: "Remove stock")
            : String(localized: "Add stock")
    }

    var body: some View {
        NavigationStack {
            Form {
                // Batch info (read-only header)
                Section {
                    HStack(spacing: 12) {
                        ProductImage(imagePath: imagePath, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(productName).font(.headline)
                            HStack(spacing: 8) {
                                Text(batch.batchNumber ?? String(localized: "No batch"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let exp = batch.expirationDate {
                                    Text(exp).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                        Text("\(batch.quantity)")
                            .font(.title2.bold().monospacedDigit())
                    }
                }

                // Direction toggle
                Section {
                    Picker("Direction", selection: $direction) {
                        Text("− \(String(localized: "Remove"))").tag(Direction.remove)
                        Text("+ \(String(localized: "Add"))").tag(Direction.add)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: direction) { _, newDirection in
                        // Always reset to the first valid reason for the new direction.
                        // adjustment_correction is valid in both but we still reset —
                        // consistent with the web UX.
                        reason = reasonsForDirection.first?.value ?? "adjustment_correction"
                    }
                }

                // Reason
                Section("Reason") {
                    Picker("Reason", selection: $reason) {
                        ForEach(reasonsForDirection, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                    .pickerStyle(.menu)

                    if direction == .add && reason == "adjustment_refill_return" {
                        Text("Items returned after a refill took too much")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Quantity (supports expressions: 2*12, 100+50)
                Section {
                    HStack {
                        Text(direction == .remove
                             ? String(localized: "Quantity to remove")
                             : String(localized: "Quantity to add"))
                        Spacer()
                        TextField("e.g. 2*12", text: $quantityText)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 140)
                            .font(.body.monospacedDigit())
                            .focused($quantityFieldFocused)

                        if quantityText.contains(where: { "+-*/x×".contains($0) }),
                           let q = parsedQuantity, q > 0 {
                            Text("= \(q)")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.blue)
                        }
                    }
                    if direction == .remove,
                       let q = parsedQuantity,
                       q > batch.quantity {
                        Text("Only \(batch.quantity) available")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                // Notes
                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle(String(localized: "Adjust stock"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text(submitLabel).bold()
                        }
                    }
                    .tint(direction == .remove ? .red : .green)
                    .disabled(!canSubmit)
                }
            }
        }
    }

    private func submit() async {
        guard let q = parsedQuantity, q > 0 else { return }
        isSubmitting = true
        let signed = direction == .remove ? -q : q
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        await onSubmit(signed, reason, trimmedNotes.isEmpty ? nil : trimmedNotes)
        isSubmitting = false
        dismiss()
    }

    /// Evaluates expressions like "2*12", "100+50". Mirrors `evaluateExpression`
    /// from `WarehouseView.swift` — duplicated intentionally to keep the sheet
    /// self-contained. If a third caller shows up, extract to a shared helper.
    private func evaluateExpression(_ text: String) -> Int? {
        let cleaned = text
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "x", with: "*")
            .replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return nil }
        if let num = Int(cleaned) { return num }
        let allowed = CharacterSet(charactersIn: "0123456789+-*/.")
        guard cleaned.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard let lastChar = cleaned.last, lastChar.isNumber else { return nil }
        let expression = NSExpression(format: cleaned)
        if let result = expression.expressionValue(with: nil, context: nil) as? NSNumber {
            return result.intValue > 0 ? result.intValue : nil
        }
        return nil
    }
}
```

- [ ] **Step 2: Build the iOS app**

```bash
cd ios && xcodebuild -project VMflow.xcodeproj -scheme VMflow -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -20
```
Expected: "BUILD SUCCEEDED". `BatchAdjustSheet` is not yet referenced from any other file, so this only verifies the new file compiles.

- [ ] **Step 3: Commit**

```bash
git add ios/VMflow/Views/Warehouse/BatchAdjustSheet.swift
git commit -m "feat(ios/warehouse): BatchAdjustSheet for bidirectional batch quantity adjustment"
```

---

### Task 9: Create `ProductBatchesView`

**Files:**
- Create: `ios/VMflow/Views/Warehouse/ProductBatchesView.swift`

- [ ] **Step 1: Write the view**

Create `ios/VMflow/Views/Warehouse/ProductBatchesView.swift`:

```swift
import SwiftUI

/// Drilldown view: shows all batches for one product in the currently selected
/// warehouse, ordered by expiration date. Tapping a batch opens `BatchAdjustSheet`.
struct ProductBatchesView: View {
    let productId: UUID
    let productName: String
    let productImagePath: String?

    @EnvironmentObject private var viewModel: WarehouseViewModel
    @State private var selectedBatch: WarehouseStockBatch?

    var body: some View {
        Group {
            if viewModel.isLoadingBatches && viewModel.drilldownBatches.isEmpty {
                ProgressView("Loading batches...")
            } else if viewModel.drilldownBatches.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "shippingbox")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No batches in stock")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(viewModel.drilldownBatches) { batch in
                        Button {
                            selectedBatch = batch
                        } label: {
                            BatchRow(batch: batch)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(productName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadBatchesForProduct(productId)
        }
        .refreshable {
            await viewModel.loadBatchesForProduct(productId)
        }
        .sheet(item: $selectedBatch) { batch in
            BatchAdjustSheet(
                batch: batch,
                productName: productName,
                imagePath: productImagePath
            ) { signedDelta, reason, notes in
                await viewModel.adjustBatch(
                    batchId: batch.id,
                    quantityChange: signedDelta,
                    reason: reason,
                    notes: notes
                )
            }
        }
    }
}

/// Single batch row in the drilldown list.
private struct BatchRow: View {
    let batch: WarehouseStockBatch

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(batch.batchNumber ?? String(localized: "No batch"))
                    .font(.body)
                if let exp = batch.expirationDate {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.caption2)
                        Text(exp)
                            .font(.caption)
                    }
                    .foregroundStyle(expirationColor(exp))
                }
            }
            Spacer()
            Text("\(batch.quantity)")
                .font(.title3.bold().monospacedDigit())
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func expirationColor(_ dateString: String) -> Color {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateString) else { return .secondary }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        if days < 7 { return .red }
        if days <= 30 { return .orange }
        return .secondary
    }
}
```

**`WarehouseStockBatch` conforms to `Identifiable` already** (verified at `Models/Warehouse.swift:18`) — so `.sheet(item:)` works directly without a wrapper.

- [ ] **Step 2: Build to confirm the file compiles**

```bash
cd ios && xcodebuild -project VMflow.xcodeproj -scheme VMflow -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -20
```
Expected: "BUILD SUCCEEDED".

- [ ] **Step 3: Commit**

```bash
git add ios/VMflow/Views/Warehouse/ProductBatchesView.swift
git commit -m "feat(ios/warehouse): ProductBatchesView drilldown"
```

---

### Task 10: Wire drilldown from the Stock tab

**Files:**
- Modify: `ios/VMflow/Views/Warehouse/WarehouseView.swift:185–194`

- [ ] **Step 1: Wrap `StockSummaryRow` in `NavigationLink`**

In `WarehouseView.swift`, find the `stockOverviewTab` computed view. Lines 185–191 currently are:

```swift
            } else {
                List {
                    ForEach(viewModel.filteredSummaries) { summary in
                        StockSummaryRow(summary: summary)
                    }
                }
                .listStyle(.plain)
                .searchable(text: $viewModel.searchText, prompt: "Search products")
            }
```

Replace **only the `ForEach` body** with a `NavigationLink` wrapper — **preserve `.listStyle(.plain)` and `.searchable(...)` exactly as they are**. The final block must read:

```swift
            } else {
                List {
                    ForEach(viewModel.filteredSummaries) { summary in
                        NavigationLink {
                            ProductBatchesView(
                                productId: summary.productId,
                                productName: summary.productName,
                                productImagePath: summary.imagePath
                            )
                            .environmentObject(viewModel)
                        } label: {
                            StockSummaryRow(summary: summary)
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $viewModel.searchText, prompt: "Search products")
            }
```

Do NOT delete or move the `.listStyle(.plain)` or `.searchable(...)` modifiers — dropping them would break product search in the Stock tab and regress visual styling.

Note on the environment object: `WarehouseView` owns the view model as `@StateObject private var viewModel = WarehouseViewModel()` (line 5). `@StateObject` does NOT automatically propagate through a NavigationLink destination, so the explicit `.environmentObject(viewModel)` on the destination is required (not just defensive). `ProductBatchesView` reads it via `@EnvironmentObject private var viewModel: WarehouseViewModel`.

- [ ] **Step 2: Build and check for errors**

```bash
cd ios && xcodebuild -project VMflow.xcodeproj -scheme VMflow -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -20
```
Expected: "BUILD SUCCEEDED".

- [ ] **Step 3: Manual verification on simulator**

Run the app on the iOS simulator. Log in, navigate to Warehouse → Stock tab. Tap any product row — `ProductBatchesView` should push onto the navigation stack, showing that product's batches. Tap a batch — `BatchAdjustSheet` appears.

Test both directions:
1. **Remove −2 with reason "Damaged"**: stock decreases by 2, batch list refreshes, transaction shows up on the web side with "Damaged" badge.
2. **Add +5 with reason "Refill return"**: stock increases by 5, batch list refreshes. On the web, navigate to the same warehouse's transaction history — the new transaction appears with "Refill return" green badge (requires Chunks 1 + 2 deployed).

Sanity checks:
- Expression evaluator works: type `2*3` in quantity, result shows `= 6`.
- Max cap: in Remove mode, typing a value larger than batch quantity shows the "Only N available" hint in red and the submit button is disabled.
- No cap in Add mode.

- [ ] **Step 4: Commit**

```bash
git add ios/VMflow/Views/Warehouse/WarehouseView.swift
git commit -m "feat(ios/warehouse): wire Stock-tab drilldown to ProductBatchesView"
```

---

## Completion checklist

After all chunks are committed:

- [ ] Web tests pass: `cd management-frontend && npx vitest run`
- [ ] Web typecheck: `cd management-frontend && npx nuxi typecheck` — no new errors
- [ ] iOS build: `cd ios && xcodebuild -project VMflow.xcodeproj -scheme VMflow -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build` — BUILD SUCCEEDED
- [ ] Web manual verify: both directions work, history filter works, badges render correctly (red for damage/expired, amber for correction, green for refill return)
- [ ] iOS manual verify: drilldown + both directions work, expression evaluator works, max cap only enforced when removing
- [ ] Cross-platform: a refill-return booked on iOS appears in the web transaction history with the green "Refill return" badge

## References

- Spec: `docs/superpowers/specs/2026-04-18-batch-quantity-adjustment-design.md`
- Web test pattern: `management-frontend/app/composables/__tests__/useProductDetail.test.ts`
- iOS sheet pattern: `ios/VMflow/Views/Trays/TrayEditSheet.swift`
- iOS expression evaluator: `ios/VMflow/Views/Warehouse/WarehouseView.swift:377–406`
