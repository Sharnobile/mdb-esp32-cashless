# Batch quantity adjustment (bidirectional)

**Status:** Approved
**Date:** 2026-04-18
**Scope:** Web frontend (`management-frontend`) + iOS app (`ios/VMflow`)

## Problem

Warehouse operators occasionally take too many items out of a batch during a
refill run and need to book the surplus back into the same batch — preserving
the original batch number and expiration date. The current system supports only
negative stock adjustments (damage / expired / correction). Re-adding items to
an existing batch requires either a full fresh "intake" booking (which creates
a semantically wrong `incoming` transaction, and on iOS creates a duplicate
batch row because the iOS flow does not match on batch number + MHD).

## Goals

- Allow positive and negative quantity adjustments on a **specific existing
  batch**, without re-entering batch number or expiration date
- Make the "refill return" use case a first-class, filterable transaction type
- Ship the same capability on web and iOS

## Non-goals

- Smart-matching in the iOS Wareneingang (intake) form — the duplicate-batch
  behavior is a pre-existing issue and is out of scope for this change
- Harmonizing the pre-existing `intake` (iOS) vs `incoming` (web)
  `transaction_type` drift — iOS `bookIntake` keeps writing `intake`, web
  `bookIncoming` keeps writing `incoming`. A future cleanup can align them;
  this PR must not touch either code path so transaction-history filters and
  existing analytics queries stay stable.
- A shortcut directly from the refill-wizard summary
- Surfacing fully depleted (quantity = 0) batches for resurrection. The web
  intake flow already matches on `(warehouse + product + batch_nr +
  expiration)` and re-uses a zero-qty batch row, so depleted batches can be
  revived from the web. **On iOS the same scenario is not covered** — the
  depleted batch disappears from `ProductBatchesView` because the query
  filters `gt("quantity", 0)`, and the iOS intake form creates a new batch
  row instead of matching. Operators who hit this edge case must use the web
  UI; fixing it requires the out-of-scope iOS intake smart-matching change.

## Shared data model

- `warehouse_stock_batches` and `warehouse_transactions` schemas remain
  unchanged. `transaction_type` is a free-text column with no CHECK constraint,
  so new values can be introduced without a migration.
- **New transaction type:** `adjustment_refill_return`
  - Direction: positive (`quantity_change > 0`)
  - Purpose: distinguish "I brought items back from a refill" from generic
    inventory corrections, so operators can filter/report on it
  - Rendered with a green badge (same family as `incoming`) on both platforms
- Existing transaction types unchanged: `incoming`, `outgoing_refill`,
  `adjustment_damage`, `adjustment_expired`, `adjustment_correction`,
  `transfer_out`, `transfer_in`

The write path always targets an existing `batch_id`, so `batch_number` and
`expiration_date` are inherently preserved — they live on the batch row and are
never re-entered by the user.

## Web frontend changes

### `app/composables/useWarehouse.ts`

- Extend the `reason` union on `adjustStock()` to include
  `'adjustment_refill_return'`. The function body already accepts a signed
  `quantity_change` and clamps `quantity_after` at zero (`Math.max(0, …)`),
  which is a no-op for positive deltas.
- Extend `transactionTypeLabel()` and `transactionTypeBadgeClass()` to handle
  the new type (green badge, label keyed from i18n `warehouse.refillReturn`).

### `app/pages/warehouse/index.vue`

The adjustment modal (current location ~2294–2323) becomes bidirectional.

1. **Direction toggle** at the top — `Abbuchen` (red, minus icon) /
   `Einbuchen` (green, plus icon). Defaults to `Abbuchen` for backward
   compatibility with muscle memory.
2. **Reason dropdown** is direction-aware:
   - Abbuchen: `Beschädigt`, `Abgelaufen`, `Inventurkorrektur`
   - Einbuchen: `Rückgabe aus Refill`, `Inventurkorrektur`
3. **Quantity input** is always a positive integer (`min=1`). The `max` cap is
   applied only when direction is `Abbuchen` (capped at current batch
   quantity). Einbuchen has no upper cap — physical reality bounds it.
4. **Submit button** mirrors direction:
   - Abbuchen: red background, label "Bestand abbuchen"
   - Einbuchen: green background, label "Bestand einbuchen"
5. **`submitAdjust` handler**:
   - `const signed = direction === 'remove' ? -Math.abs(q) : Math.abs(q)`
   - Passes through to `adjustStock({ quantity_change: signed, reason, … })`
6. **Transaction history filter** dropdown gets an additional
   `adjustment_refill_return` option.

State refs added to the page component:
`adjustDirection: Ref<'remove' | 'add'>` (default `'remove'`). The existing
`adjustReason` ref keeps its current role; the default reason flips when the
direction toggles (to the first valid option for that direction).

### i18n

New keys in `management-frontend/i18n/locales/en.json` and `de.json` under
`warehouse`:

- `adjustDirectionRemove` — "Remove stock" / "Abbuchen"
- `adjustDirectionAdd` — "Add stock" / "Einbuchen"
- `refillReturn` — "Refill return" / "Rückgabe aus Refill"
- `refillReturnDescription` — "Items returned after a refill took too much" /
  "Beim Refill zu viel entnommen — wieder eingebucht"
- `addStock` — "Add stock" / "Bestand einbuchen" (submit button)
- `quantityToAdd` — "Quantity to add" / "Einzubuchende Menge"
- `refillReturnFilter` — "Refill returns" / "Rückgabe aus Refill" (history
  filter)

The existing `adjustBatchInfo` placeholder copy continues to work unchanged
for both directions. The Einbuchen "Inventurkorrektur" option reuses the
existing `warehouse.inventoryCorrection` key — no new label needed.

## iOS changes

### Rationale

The existing iOS Warehouse page has two tabs: `Stock` (aggregated product
summary) and `Incoming` (a flat intake form). There is no batch-level view.
The user requested batch selection without re-typing batch numbers or
expiration dates, which rules out integrating the feature into the Incoming
tab. Instead, we add a drilldown from the Stock tab.

### New view: `ProductBatchesView`

Opens via `NavigationLink` when the user taps a row in the Stock tab.

- Title: product name
- List of batches (filtered to the currently selected warehouse and the tapped
  product, quantity > 0), ordered by expiration date ascending
- Each row:
  - Batch number (or `"Kein Batch"` / `"No batch"` if null)
  - Expiration date with color badge (reuses the existing
    `expirationBadge`-style styling from `StockSummaryRow`)
  - Current quantity, bold monospaced
- Tap on row → presents `BatchAdjustSheet` (sheet modal)

### New view: `BatchAdjustSheet`

- Read-only header section:
  - Product name + image
  - Batch number, expiration date
  - Current quantity, large and prominent
- `Picker`/segment control: `Abbuchen` / `Einbuchen` (red / green tint,
  matches web semantics)
- `Menu` or `Picker` for reason, direction-aware (same option sets as web)
- `TextField` for quantity with the same expression evaluator the Incoming
  form uses (`2*12`, `100+50` etc.) — reuses the existing
  `evaluateExpression` helper by extracting it to a shared file or
  duplicating (smaller footprint: duplicate, one call site only)
- Optional multi-line notes field
- Submit button, tint matches direction
- Cancel button dismisses the sheet

### ViewModel: `WarehouseViewModel`

Adds:

- `loadBatchesForProduct(_ productId: UUID) async -> [WarehouseStockBatch]`
  - Queries `warehouse_stock_batches` filtered by warehouse + product,
    `gt("quantity", 0)`, ordered by `expiration_date`
  - Returns the **existing** `WarehouseStockBatch` type already defined in
    `Models/Warehouse.swift` (no new model needed — fields `id`,
    `warehouseId`, `productId`, `quantity`, `batchNumber`, `expirationDate`
    already match exactly)
- `adjustBatch(batchId: UUID, quantityChange: Int, reason: String, notes: String?) async`
  - Fetches the current batch row (`quantity`, `batch_number`,
    `expiration_date`)
  - Computes `quantityAfter = max(0, quantityBefore + quantityChange)`
  - Updates `warehouse_stock_batches.quantity`
  - Inserts a `warehouse_transactions` row with
    `transaction_type = reason` — where `reason` is one of the new adjust
    types (`adjustment_refill_return`, `adjustment_correction`,
    `adjustment_damage`, `adjustment_expired`). **Must not** use `intake`
    or `incoming` — those remain reserved for the existing Wareneingang
    flow.
  - `companyId` is looked up from the currently selected warehouse (the
    `warehouses` array already carries `companyId` on each row). Required
    for RLS and matches the existing `InsertWarehouseTransaction` struct
    (`Models/Warehouse.swift` line 100).
  - `userId` from `client.auth.session.user.id`, same as `bookIntake`
  - Passes notes through as-is (nil if empty)
  - Reloads affected state (stock summaries + the drilldown batches list
    if still visible)
  - On conflict / missing batch row (e.g. batch deleted between list fetch
    and submit), surfaces a user-facing error via the existing `error`
    published property; no retry logic needed — the user can re-open the
    list

### Model changes

None. The existing `WarehouseStockBatch` and `InsertWarehouseTransaction`
structs in `ios/VMflow/Models/Warehouse.swift` cover all required fields.

### Navigation wiring

- In `WarehouseView.swift`, wrap `StockSummaryRow` in a `NavigationLink` whose
  destination is `ProductBatchesView(productId:)`
- `ProductBatchesView` presents `BatchAdjustSheet` via `.sheet(isPresented:)`
  bound to an `@State` `selectedBatch` ref

### iOS localization

The iOS app uses `String(localized: …)` inline. Add keys matching the web i18n
(direction labels, reason labels, submit labels, quantity placeholder). No
`.strings` file exists — keep using inline `String(localized:)` for new
strings, consistent with existing code.

## Testing

### Web

New Vitest test: `management-frontend/app/composables/__tests__/useWarehouse.test.ts`
(create if absent).

- `adjustStock` with positive `quantity_change`: expects the update payload to
  carry `quantity_after = before + change` and the inserted transaction to have
  `transaction_type: 'adjustment_refill_return'` when that reason is passed
- `adjustStock` with negative `quantity_change` (regression): same path as
  today, confirms no breakage
- Mock Supabase client via the existing test helpers
  (`app/test-helpers/nuxt-stubs.ts`)

### iOS

The iOS project has no automated test target. Verify manually:

1. Open a warehouse with at least one product having multiple batches
2. Tap product → see batch list → tap batch → sheet opens
3. Einbuchen +5 → quantity increases by 5, transaction appears in web
   transaction history as "Rückgabe aus Refill" (this requires the web
   transaction-type filter dropdown update from §Web — verify both sides
   of the PR are deployed together)
4. Abbuchen −3 with reason "Beschädigt" → quantity decreases, transaction
   shows as "Damaged"
5. Empty batch (quantity goes to 0) → disappears from list per
   `gt("quantity", 0)` filter; intake flow still works unchanged

## Error handling & race conditions

- **Batch deleted between fetch and submit**: the update `UPDATE ... WHERE id
  = :batch_id` is a no-op, and the subsequent transaction insert succeeds but
  points at a missing batch. Acceptable — the web UI surfaces no error, the
  iOS UI surfaces the generic `error` banner. Operators are expected to
  refresh.
- **Concurrent sale drains the batch**: the `Math.max(0, quantity_before +
  quantity_change)` clamp in `adjustStock` (web) and `adjustBatch` (iOS)
  prevents negative stock. The transaction row still records the intended
  `quantity_change` but `quantity_after` is clamped — the history shows what
  the operator did and what the final state was, which is the correct
  behavior for an audit log.
- **No optimistic locking.** The last writer wins. This matches the existing
  `adjustStock` semantics and is acceptable because warehouse writes are
  rare, human-driven, and local to a single operator per warehouse.

## Backward compatibility

- Database schema unchanged → no migration
- Firmware / MQTT surface untouched
- Old web clients that see an `adjustment_refill_return` transaction they
  don't yet know about fall back to rendering the raw type string — acceptable
  short-term; next frontend deploy picks up the label
- Old iOS clients without the drilldown continue to work — the Stock tab just
  doesn't navigate

## Rollout

Single PR touching web + iOS + i18n. No feature flag needed; the UI additions
are independent and the backend has been unchanged. Existing operators can
keep using the old "remove only" path until they discover the direction
toggle.
