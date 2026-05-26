# iOS Refill Pack — Per-Machine Filter Chips

**Date**: 2026-05-26
**Status**: Design — pending user review
**Scope**: iOS native app (`ios/VMflow/`), Refill wizard **Pack** step only

## Problem

In the iOS Refill wizard, the **Pack** step ([PackingStepView.swift](../../ios/VMflow/Views/Refill/PackingStepView.swift)) currently presents a **single product-centric list** — one card per product needed across the fleet, with per-machine sub-rows for tweaking individual checkboxes and quantities. This works for users who pack a single warehouse crate that gets distributed across many machines.

It does **not** match the user's actual workflow when stock is heavy: the operator packs **one physical box per machine** and walks them out one at a time. Today, to pack a box for "Foyer Eingang", the user has to scroll the combined list and individually tick only the products that belong to Foyer's sub-rows — then repeat for the next machine. There is no way to **focus the list on one machine at a time**.

Both modes must remain available — the cross-machine view is still useful when the user wants to see "if I open the Coca-Cola crate, how do I distribute it across machines."

## Goals

- Add a horizontal **filter chip leiste** at the top of the Pack step.
- Default chip is **"Alle"** — view is identical to today (zero disruption for existing users).
- Tapping a machine chip filters the product list to **only that machine's needs** — quantities collapse to that one machine, sub-rows disappear (only one machine to choose), checkboxes commit directly for the active machine.
- Chip labels show `Name · ItemCount` (e.g. `Foyer · 23`), where ItemCount is the total number of items going into that machine's box.
- Fully-packed machines keep their chip visible and **green-checked**; the position in the chip leiste does **not** change.
- After packing a machine fully, its items **stay visible and editable** in the filtered list — so the user can react to a sale that happened during packing, dial a quantity up, or untick.
- The realtime data path (`RefillWizardView.realtimeVersion` → `refreshFromRealtime`) keeps working unchanged — chip counts and ticked state spontaneously reflect new sales without dedicated subscription code.
- Single-select only; one chip active at a time.

## Non-goals

- **No** multi-select chips (no "Foyer + Halle 2 combined" use case in the user's workflow).
- **No** smart-default chip (e.g. "start on the most-empty machine"). Always defaults to `.all`.
- **No** persistence of the active chip across tours — chip state is in-memory only. The existing `PersistedTourState` ([RefillWizardViewModel.swift:288](../../ios/VMflow/ViewModels/RefillWizardViewModel.swift#L288)) only persists from the `.refill` step onward; the Pack step is never saved, so this stays consistent.
- **No** chip reordering by deficit / urgency / tour route. Order is `.all` first, then machines in their existing `machines` array order.
- **No** changes to the underlying `RefillWizardViewModel` contract — only additive state and computed properties. All packing actions reuse existing functions.
- **No** changes to other refill steps (Review, Refill, Summary) or to `RefillWizardView`.
- **No** PWA / Android changes.
- **No** new unit tests (iOS target currently has no test bundle — adding one is out of scope).

## UI design

### Pack step — new top section

```
┌─ Refill Tour ────────────────────────────────────────┐
│  ● ─── ● ─── ○ ─── ○        (step indicator: Pack)   │
│                                                       │
│  [Lager: Hauptlager ▼]      (warehouse picker)       │
│                                                       │
│  ╔═════════════════════════════════════════════════╗ │
│  ║ [Alle · 52] [Foyer · 23] [Halle 2 · 11] [W…]   ║ │  ← NEW chip leiste
│  ╚═════════════════════════════════════════════════╝ │
│                                                       │
│  ┌─ Alle Automaten · 52 Items · 0/5 ready ───────┐  │  ← NEW header strip
│                                                       │
│  ┌── Coca-Cola 0,5L ───── 9× ──┐                    │
│  │  ☐  Foyer       3×           │   (cards stay as today
│  │  ☐  Halle 2     3×           │    in .all mode)
│  │  ☐  Werkstatt   3×           │
│  └──────────────────────────────┘
│                                                       │
│  [3 Maschinen bereit         |   Tour starten →  ]   │
└───────────────────────────────────────────────────────┘
```

### Two list templates

**`.all` mode** — bestehende `productCard` mit aufklappbaren Sub-Rows. Identisch zu heute. Quantities = Summe über alle Machines.

**`.machine(id)` mode** — flat list, eine Card pro Produkt:

```
┌── Coca-Cola 0,5L ───────────────── 3× ──┐
│  ☑  benötigt: 3 · Lager: 24      [−][3][+] │
└─────────────────────────────────────────┘
┌── Snickers ──────────────────────── 5× ──┐
│  ☑  benötigt: 5 · Lager: 40      [−][5][+] │
└─────────────────────────────────────────┘
…
```

- Round checkbox = `togglePackedForMachine(productId:, machineId: activeId)`.
- Stepper = `setPackingQuantity(machineId: activeId, productId:, quantity:)`.
- Quantity shown = `displayQuantity(machineId: activeId, productId:)`.
- Out-of-warehouse-stock disabled state mirrors today's `isOutOfStockForMachine` rule.
- Border colors mirror today's card rules (green for packed at full needed qty, orange for partial).

### Chip states

| State                                              | Visual                                                          |
| -------------------------------------------------- | --------------------------------------------------------------- |
| Inactive, machine has needs                        | white background, primary text, `Name · N`                      |
| Active (selected), machine has needs               | accent-blue background, white text, bold, soft shadow           |
| Active **and** machine fully packed                | green background, white text + `✓` instead of count             |
| Inactive **and** machine fully packed              | mint background, mint text + `✓`, slightly dimmed (opacity ~.85) |
| `.all` chip — special case: ItemCount summed over all machines; `✓` only when every machine is fully packed |

### Header strip (color follows active chip status)

- `.all`, not all done → blue strip: `Alle Automaten · 52 Items · 0/5 ready`
- `.all`, all done → green strip: `✓ Alle Boxen komplett · 52 Items gepackt`
- `.machine(id)`, mid-pack → blue strip: `Foyer Eingang · Box: 23 Items · 2/7 gepackt`
- `.machine(id)`, fully packed → green strip: `✓ Foyer Eingang · Box komplett · 7/7 gepackt`
- `.machine(id)`, packed but realtime sale increased deficit → orange strip: `⚠ Foyer · neuer Verkauf · Box jetzt 25 Items (+2)`

### "Select All" button

The existing "Select All" button in the summary header ([PackingStepView.swift:91-99](../../ios/VMflow/Views/Refill/PackingStepView.swift#L91-L99)) stays in place but its label changes contextually:

- `.all` mode → "Alle auswählen" (calls existing `packAllMachines()` — unchanged behavior; matches existing localization key)
- `.machine(id)` mode → "%@ komplett packen" with machine name (calls a new `packAllForMachine(machineId:)` helper that ticks every product for just that one machine)

### Bottom bar

Unchanged. `"%d Maschinen bereit · Tour starten →"` still reflects global state — the chip only filters the list, it does not gate the tour-start action.

## Data model & ViewModel changes

All additive. No existing function signatures change.

### New types and state in `RefillWizardViewModel.swift`

```swift
enum ChipFilter: Equatable, Hashable {
    case all
    case machine(UUID)
}

@Published var activeChip: ChipFilter = .all
```

### New computed properties / helpers

| Name                                                          | Purpose                                                                                                                   |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `var chipOrder: [ChipFilter]`                                 | `.all` first, then `machines.map { .machine($0.id) }` in their natural order                                              |
| `func chipName(_ chip: ChipFilter) -> String`                 | Localized "Alle" for `.all`, else `machines.first { $0.id == id }?.machine.name ?? ""`                                    |
| `func chipItemCount(_ chip: ChipFilter) -> Int`               | Sum of `displayQuantity(machineId:, productId:)` over every `(machine, product)` pair that has a need. `.all` → over every machine. `.machine(id)` → filtered to that machine only. This is *potential* box size (what the box would hold if fully packed), independent of which products are currently ticked. Intentionally distinct from `totalItemsToPack`, which sums only across `packedMachines` and is what the bottom bar shows. |
| `func chipIsFullyPacked(_ chip: ChipFilter) -> Bool`          | `.all` → every chip is fullyPacked. `.machine(id)` → every needed `(id, productId)` is `isMachinePacked` and at full qty |
| `var visibleItemsForActiveChip: [CombinedPackingItem]`        | `.all` → `visibleCombinedPackingList` (unchanged). `.machine(id)` → list filtered + rewritten so each item has exactly one `MachineNeed` for the active machine and `totalQuantity = need.quantity` |
| `func packAllForMachine(_ machineId: UUID)`                   | Ticks every product needed for just one machine; bounded by warehouse cap (same rule as `packAllMachines`)                |

### Reset rules

- `loadData()` → `activeChip = .all`
- `clearSavedTour()`-driven "New Tour" path → unchanged on the model side; `loadData()` is called by `RefillWizardView`, which resets `activeChip` via the line above
- `resumeTour()` → no change (chip lives only in `.packing` step; resume always lands on `.refill`)

### Edge cases

- **Active chip's machine disappears from `machines`** — cannot happen mid-tour (no machine deletion path during a tour), but defensively: if `activeChip == .machine(id)` and `id` is not in `chipOrder`, snap back to `.all` on the next computed access. (Belt-and-suspenders, no observed crash path today.)
- **Realtime sale during pack pushes a machine's deficit up** — `refreshDuringPacking()` already rebuilds the underlying list. The chip ItemCount and `chipIsFullyPacked` both flip automatically, the header strip turns orange, the just-packed product card gains an orange "Partial" indicator. Same code path that already works for the combined view.
- **Out-of-stock product** in `.machine(id)` view — card stays visible, checkbox disabled with red `xmark.square` icon, badge "No stock" — identical rules to today's `machineNeedRow` ([PackingStepView.swift:282-291](../../ios/VMflow/Views/Refill/PackingStepView.swift#L282-L291)).
- **No machines need refill at all** — chip leiste shows only `[Alle · 0]`. Existing `emptyState` view renders below.
- **Warehouse picker change** mid-pack — already triggers `loadWarehouseStock`. Chip counts re-derive on the next render. Active chip stays.

## Files affected

| File                                                                | Type                | Approx. lines |
| ------------------------------------------------------------------- | ------------------- | ------------- |
| `ios/VMflow/ViewModels/RefillWizardViewModel.swift`                 | additive            | ~50–65        |
| `ios/VMflow/Views/Refill/PackingStepView.swift`                     | refactor + new code | ~150–200      |
| `ios/VMflow/Resources/Localizable.xcstrings`                        | new keys            | ~6–8 entries  |

**Not touched**: `RefillWizardView.swift`, `ReviewStepView.swift`, `RefillStepView.swift`, `RefillSummaryView.swift`, `PersistedTourState`, all Models, all other ViewModels.

### Refactor approach for `PackingStepView.swift`

Today `body` is one large composition. Extract two child views to keep each file segment focused and readable:

```
PackingStepView
  ├── warehousePicker         (unchanged)
  ├── chipBar                  (NEW)
  ├── headerStrip              (NEW — replaces summaryHeader)
  ├── (switch on activeChip)
  │   ├── AllPackingList       (today's productCard ForEach, extracted as-is)
  │   └── MachinePackingList   (NEW, flat list with single-machine cards)
  └── bottomBar                (unchanged)
```

`AllPackingList` and `MachinePackingList` can live in the same file (`PackingStepView.swift`) as private structs — no need for new files, scope is small.

## Localization

New entries in `ios/VMflow/Resources/Localizable.xcstrings` (DE + EN):

| Key                            | EN                                          | DE                                              |
| ------------------------------ | ------------------------------------------- | ----------------------------------------------- |
| `refill.chip.all`              | `All`                                       | `Alle`                                          |
| `refill.chip.itemCountLabel`   | `%@ · %d`                                   | `%@ · %d`                                       |
| `refill.header.all.pending`    | `All machines · %d items · %d/%d ready`     | `Alle Automaten · %d Items · %d/%d ready`       |
| `refill.header.all.done`       | `✓ All boxes packed · %d items`             | `✓ Alle Boxen komplett · %d Items gepackt`      |
| `refill.header.machine.pending`| `%@ · Box: %d items · %d/%d packed`         | `%@ · Box: %d Items · %d/%d gepackt`            |
| `refill.header.machine.done`   | `✓ %@ · Box complete · %d/%d packed`        | `✓ %@ · Box komplett · %d/%d gepackt`           |
| `refill.header.machine.alert`  | `⚠ %@ · new sale · box now %d items (+%d)`  | `⚠ %@ · neuer Verkauf · Box jetzt %d Items (+%d)` |
| `refill.selectAll.machine`     | `Pack all for %@`                           | `%@ komplett packen`                            |

Existing strings (`"Select All"`, `"%d products to pack"`, `"%d of %d machines ready"`) stay — they remain in use in `.all` mode for the bottom bar.

## Testing

The iOS app currently has **no test target**. We do not add one for this feature — it would expand scope unrelated to the user's request.

Manual UAT checklist (will go into the implementation plan's verification step):

1. Open Refill → Pack. Default chip is **"Alle"**. List looks identical to before.
2. Tap a machine chip → list filters, sub-rows disappear, quantities reflect that one machine.
3. Tap "Alle" → returns to combined view, all prior ticks preserved.
4. In a filtered view, tick all products → chip turns green with ✓, header strip turns green, **items remain visible**.
5. With a chip's machine fully packed, change a stepper from N to N-1 → chip's ✓ disappears, header strip reverts to pending state.
6. With a chip's machine fully packed, **trigger a sale on that machine from the backend** → chip count updates, ✓ disappears, header strip turns orange "neuer Verkauf", the relevant product card shows Partial.
7. Change warehouse → chip counts re-derive, active chip stays selected, capped quantities apply.
8. "Select All" button label changes when a chip is active. Tapping it ticks only that machine's needs.
9. Navigate to the Refill step, then back to Pack via the step indicator (existing behavior — `canNavigateTo(.packing)` returns `true` from `.refill`) → chip resets to `.all` (no persistence, by design).
10. Resume tour (interrupt, kill, re-open) → resume always lands on Refill step. The chip state is never persisted; this is expected.

## Implementation order

1. `RefillWizardViewModel.swift`: add `ChipFilter`, `activeChip`, computed properties, `packAllForMachine`. Run app — no UI change yet, just compiles.
2. `Localizable.xcstrings`: add the 8 new keys (EN + DE).
3. `PackingStepView.swift`: extract `AllPackingList` from today's body (no behavior change), insert `chipBar` and `headerStrip`, replace `summaryHeader`. Run app — `.all` mode still default, chips visible but tapping non-all chips does nothing useful yet.
4. `PackingStepView.swift`: add `MachinePackingList`, wire the switch on `activeChip`. Run app — full flow works.
5. Polish: "Select All" label, header strip colors, fully-packed chip styling, manual UAT checklist 1–10.

## Open questions

None at this point — the user has approved each section. Implementation can proceed once this spec passes review and the user signs off.
