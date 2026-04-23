# iOS Refill Replacement Picker — Show Existing Machine Products

**Date:** 2026-04-23
**Status:** Draft
**Owner:** Lucien Kerl

## Summary

In the iOS native refill flow, when the operator picks a replacement product
for a discontinued/expired/no-stock/unassigned tray, the picker currently
shows the alphabetical list of all active products with no indication of
what is already assigned to other slots in the same machine. The operator
has no way to avoid accidentally double-allocating the same product to two
slots without leaving the picker, opening the machine detail in another tab,
and cross-referencing manually.

This change marks every product that is already used elsewhere in the
*current* machine with a small inline `Slot N` pill on the right-hand side
of the row. Sorting and search behaviour stay unchanged, and tapping a
marked product still works on first tap — duplicates are *discouraged*, not
*blocked*, because some products legitimately occupy multiple slots
(double-stocking a popular SKU).

Scope: one Swift file
([ReviewStepView.swift](../../ios/VMflow/Views/Refill/ReviewStepView.swift)).
No ViewModel changes. No backend changes.

## Problem

In [ReviewStepView.swift:38](../../ios/VMflow/Views/Refill/ReviewStepView.swift#L38)
the `.sheet` presents `ReplacementProductPicker` with three inputs:

- `products: [Product]` — every active product in the catalogue
- `selectedProductId: UUID?` — the previously chosen replacement, if any
- `onSelect: (UUID) -> Void` — callback that writes the choice back

The picker has no awareness of the machine the tray belongs to, so an
operator replacing the product in slot 5 cannot tell that they're about to
pick the same SKU that is already in slot 3. Discovering the duplicate
requires either remembering the machine layout or navigating away from the
flow — both of which are friction the operator should not have to absorb
during a packing tour.

The Review step does already know the machine context: every
`ReplacementSuggestion` carries `machineId`, and the ViewModel's
`machines: [RefillMachine]` array contains the full tray list per machine
(see [RefillWizardViewModel.swift:7-69](../../ios/VMflow/ViewModels/RefillWizardViewModel.swift#L7-L69)).
The information is available; it just isn't surfaced.

## Goals

- The replacement picker visually marks every product that is already
  assigned to *another* tray in the same machine, with the slot number(s)
  shown.
- Sort order and `.searchable` fuzzy-matching behaviour are unchanged —
  marked products are *not* moved to a separate section, top, or bottom.
- A marked product is still selectable on the first tap (no confirmation
  dialog, no disabled state) — the marking is informational.
- The current tray's own product (if any) is excluded from the marking,
  since by construction the operator is *replacing* it.

## Non-Goals

- Marking products in any other product picker in the app
  (`ProductCombobox`, `ProductsView`, etc.). Out of scope — this change is
  scoped to the refill Review step.
- Confirmation dialogs, "are you sure?" prompts, or any flow that would add
  taps for the duplicate-allocation case.
- Re-sorting the list to push used products to the top/bottom. Variant A
  was chosen explicitly to keep the alphabetical sort stable.
- Showing slot information across machines (e.g. "also in Machine 2 slot
  3") — only the *current* machine matters for the duplicate-avoidance
  use case.

## Design

### Data flow

In `ReviewStepView`, inside the `.sheet(item: $pickerTrayId)` closure
([ReviewStepView.swift:38-55](../../ios/VMflow/Views/Refill/ReviewStepView.swift#L38-L55)):

1. Resolve the `ReplacementSuggestion` via `viewModel.replacements.first(where: { $0.trayId == trayId })`.
2. Resolve the matching `RefillMachine` via `viewModel.machines.first(where: { $0.id == suggestion.machineId })`.
3. Walk `machine.trays`, skip the row whose `tray.id == trayId` (the tray
   being replaced), and group the remaining trays by `tray.tray.productId`
   (skipping `nil` product IDs — unassigned trays don't contribute).
4. For each `productId`, collect the list of `tray.tray.itemNumber`
   values, sorted ascending.
5. Pass the resulting `[UUID: [Int]]` map to the picker as a new
   `existingSlotsByProduct` parameter.

If the suggestion or machine cannot be resolved (defensive — should not
happen since the suggestion is what triggered the sheet), the map is empty
and every row renders without a pill, matching today's behaviour.

### Picker rendering

`ReplacementProductPicker` gains one new property:

```swift
let existingSlotsByProduct: [UUID: [Int]]
```

In the row body, between `Text(product.name ...)` and the trailing
`Spacer()`/checkmark, render a pill when `existingSlotsByProduct[product.id]`
is non-empty. The pill text is built by a small helper:

- 1 slot: `"Slot 3"`
- 2–3 slots: `"Slot 3, 7"` or `"Slot 3, 7, 9"` (comma-joined)
- 4+ slots: `"Slot 3, 7, 9 +2"` (first three + remainder count)

Style — matches the existing reason badges in the same view for visual
consistency:

```swift
Text(label)
    .font(.caption2.weight(.semibold))
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(Capsule().fill(.orange.opacity(0.15)))
    .foregroundStyle(.orange)
```

The pill sits inside the existing `HStack`, before the `Spacer()`, so the
checkmark for the currently-selected replacement still anchors to the
trailing edge.

### Search and sort

The alphabetical order is established at fetch time in
`RefillWizardViewModel.loadData()` (`.order("name", ascending: true)` on
the `products` query) and merely *preserved* by the picker when no search
query is active. When a query is present, `ReplacementProductPicker`
re-sorts by `fuzzyMatch` score. Both code paths stay untouched.

The `existingSlotsByProduct` lookup happens per-row at render time, so a
search result still shows its pill when applicable — the operator
searching for "cola" sees that "Coca-Cola Zero" is already in slot 3.

## Implementation Notes

**Files touched:**
- [ios/VMflow/Views/Refill/ReviewStepView.swift](../../ios/VMflow/Views/Refill/ReviewStepView.swift) —
  build the map in the sheet closure, add the `existingSlotsByProduct`
  parameter to `ReplacementProductPicker`, render the pill in the row.

**No changes to:**
- `RefillWizardViewModel` — `machines` already exposes everything needed.
- `Product` / `Tray` / `RefillMachine` models.
- Database schema, Supabase queries, or edge functions.
- Other product pickers (`ProductCombobox`, `ProductsView`).

**Tests:** SwiftUI view testing in this repo is `#Preview`-driven only
(no XCTest harness for the wizard views). `ReviewStepView.swift` has no
`#Preview` block today; the implementer may add one for
`ReplacementProductPicker` that demonstrates the pill rendering for the
1-slot, 3-slot, and 5+ slot cases. Not strictly required, but useful for
visual verification given there is no other test scaffolding for this view.
No new test files are warranted for a UI helper of this size.

## Edge Cases

| Case | Behaviour |
|------|-----------|
| Machine has only the tray being replaced (no other trays) | Map is empty, no pills shown. |
| Same product appears in current tray *and* slot 7 | Slot 7 shown in the pill (current tray excluded by `trayId` filter, not by `productId`). |
| Tray being replaced is unassigned (`productId == nil`) | Same as above — `trayId` filter still excludes it from contributing to the map. |
| Other trays in the machine are unassigned | They contribute nothing to the map (filtered by `productId != nil`). |
| Discontinued products in other slots | Won't appear in `availableProducts` (already filtered by `discontinued.is.null,discontinued.eq.false` at fetch time), so the pill never renders for them — but the data is correctly *recorded* in the map; it just has no row to render against. Acceptable. |
| Product is in 6 slots (unrealistic but possible) | `"Slot 1, 2, 3 +3"` — the `+N` suffix keeps the pill width bounded. |
| Operator deliberately wants a duplicate | First tap selects, sheet dismisses, replacement is recorded — no friction added. |

## Out of Scope / Future Considerations

- Same treatment for the web app's replacement picker. The web has its
  own `ReviewStep.vue` which currently shares the same blind-spot; that
  is a separate change against a different file/framework.
- Marking already-used products in `ProductCombobox` (used elsewhere in
  the iOS app for tray edits outside the refill flow). The Review step
  is the high-volume entry point; other pickers can adopt the same
  pattern later if it proves useful here.
