# Refill Review — Machine Layout Grid in Replacement Picker

**Date**: 2026-05-26
**Status**: Design — pending user review
**Scope**: iOS native app (`ios/VMflow/`), Refill wizard Review step

## Problem

In the iOS native Refill wizard, the **Review** step shows trays that need attention (discontinued, expired, no-stock, unassigned). When the user taps **Replace** on a tray, `ReplacementProductPicker` opens — a flat searchable list of all products with a small "Slot 3, 7" pill showing where each candidate is already placed.

The pill alone doesn't give a good spatial sense of the machine: which products sit next to the target slot, which row the target is in, whether the surrounding slots are sweets vs. salty, etc. The user wants a **visual overview of the current machine layout** — arranged like the physical machine (rows × columns) — to make the replacement decision easier.

## Goals

- Show the full current machine layout as a compact grid at the top of `ReplacementProductPicker`.
- Highlight the target slot (the one being replaced) so the user immediately sees its position in context.
- Allow tapping a non-target slot to **scroll the product list to that product** (no auto-select — sequence is: tap grid → list scrolls + highlights → user taps in list to confirm).
- Preserve everything that works today: search, fuzzy matching, "already in slot X" pill, skip/assign/replace flow.

## Non-goals

- **No** new database fields, no migration, no backend change.
- **No** grid-as-picker mode (Option B from brainstorming was rejected — list with search stays primary).
- **No** changes to PWA, no changes to other Refill steps.
- **No** new behavior for "neighbor suggestions" or "similar products" heuristics — context only, decision stays with the user.
- **No** edits to other refill steps (Packing, Refill, Summary).

## Layout derivation (rows / columns from `item_number`)

Vending machines in this fleet use a fixed 10-column convention. Row/column are derived purely on the client:

- **Row** = `(item_number / 10) - 1` — so slots 10–19 = row 0, 20–29 = row 1, …
- **Column** = `item_number % 10` → range 0–9
- **Width** of a slot = `nextItemNumberInRow - thisItemNumber`, or `1` if there is no next slot in the row. Example: trays at slots 10, 12, 13, 15 in row 0 → slot 10 has width 2 (covers columns 0–1), slot 12 width 1 (column 2), slot 13 width 2 (columns 3–4), slot 15 width 1 (column 5).
- Empty columns between two occupied slots = rendered as a dashed thin placeholder (visual gap).
- `rowCount` = `max(row over all occupied trays) + 1`.
- Slots with `item_number < 10` are not expected in this fleet. If encountered, clamp `row` to `0` and proceed; do not crash.

**Known limitation**: The width heuristic cannot detect a wide slot that ends the row, because there is no "next slot" to measure against. A 4-wide slot ending at column 6 would render as 1-wide with columns 7–9 shown as dashed empty placeholders. This is cosmetic only (the picker still functions). If this becomes a real-world problem we can add an explicit width column later. Logged as accepted risk, not blocking.

## UI design

### `ReplacementProductPicker` — new layout

```
┌─ Select Replacement ─────────────────────────────┐
│  R1 │ [Mars─2x] [Twix] [⋯] [⋯] [⋯] [✦Mars] [⋯]  │
│  R2 │  [Sni]  [Bou]  [KitKat] [⋯] [⋯] [⋯] [⋯]   │
│  R3 │  [Cola─2x]  [Fanta] [Sprite] [⋯] [⋯] [⋯]  │
│                                                  │
│  [🔍 Search products...]                         │
│  ─────────────────────────────────────────       │
│  Listenitems...                                  │
└──────────────────────────────────────────────────┘
```

### Grid header — `MachineLayoutGrid`

- Position: above the searchable list, inside the picker sheet (sheet already uses `.presentationDetents([.large])`, so vertical room is fine).
- Section header label: `"Machine Layout"`.
- Row labels (`R1`, `R2`, …) on the left in `caption2.secondary`.
- Cell size: 32×32pt (1-wide), `width * 32 + (width - 1) * 4`pt for wider slots.
- On small iPhones (`geometry.size.width < 360`): fall back to 28pt cells.
- Vertical scroll inside the grid when `rowCount > 5`, `max-height ~200pt` — keeps room for the product list below.
- When the machine has **no occupied trays at all**, the grid header is hidden entirely (the picker degrades to today's behavior).

### Cell — `MachineGridCell`

- Cell content: rounded-corner product image (Thumbnail via existing `ProductImage`), or `tray` SF Symbol placeholder when `productId == nil`.
- Slot-number overlay: small pill in bottom-left, `caption2`, semi-transparent black background with white text — so the user can read the slot number without tapping.
- **Target slot** (the one being replaced): 2pt accent-blue border + pulsing opacity animation (0.6 ↔ 1.0 over 1.5s, repeating) + `✦` SF Symbol overlay in top-right. When `@Environment(\.accessibilityReduceMotion)` is true, skip the pulse — border + ✦ still convey target status statically.
- **Empty gap** between two occupied slots in the same row: dashed thin border, 0.5 opacity, no content.

### Tap interaction

- **Tap on occupied non-target cell** → list scrolls to that product (`ScrollViewReader.scrollTo(productId, anchor: .center)`) + 1-second background pulse on that list row (`accentColor.opacity(0.2)`). No auto-select.
- **Tap on target cell** → no effect.
- **Tap on empty gap cell** → no effect, no haptic (silent no-op is the conservative default; revisit if user testing shows people expect a response).

### List unchanged

- Search bar, fuzzy match, "already in slot X, Y" pill — all preserved.
- Each row gets `.id(product.id)` so the `ScrollViewReader` can target it.
- Highlight state via `@State var highlightedProductId: UUID?` controls the background color animation.

## Data model (client-only structs)

Defined inside `ReviewStepView.swift` (no separate file yet — locality wins until the file exceeds ~700 lines):

```swift
struct MachineGridSlot {
    let itemNumber: Int
    let row: Int                 // 0-indexed
    let column: Int              // 0–9
    let width: Int               // 1 or more
    let productId: UUID?
    let productImagePath: String?
    let isTarget: Bool
}

struct MachineGridLayout {
    let rowCount: Int
    let columnsPerRow: Int       // hardcoded 10 for this fleet
    let slots: [MachineGridSlot]
}
```

## Data flow

```
ReviewStepView
  └── .sheet(item: $pickerTrayId) { trayId in
        ReplacementProductPicker(
          products: viewModel.availableProducts,
          selectedProductId: ...,
          existingSlotsByProduct: existingSlots(forTrayId: trayId),     // existing
          machineLayout: machineLayout(forTrayId: trayId),               // NEW
          onSelect: ...
        )
      }
```

The target slot is identified inside the layout via `MachineGridSlot.isTarget` —
no separate `targetItemNumber` param is needed.

### New helper in `ReviewStepView`

```swift
private func machineLayout(forTrayId trayId: UUID) -> MachineGridLayout {
    guard let suggestion = viewModel.replacements.first(where: { $0.trayId == trayId })
    else { return MachineGridLayout(rowCount: 0, columnsPerRow: 10, slots: []) }

    let machineTrays = viewModel.allTraysByMachine[suggestion.machineId] ?? []
    // Group by row, sort by itemNumber, compute width via next-itemNumber diff.
    // Set isTarget = (tray.id == trayId).
    // Tray with productId == nil and id != trayId → rendered as empty gap-ish cell.
}
```

Data source: `viewModel.allTraysByMachine[machineId]` — already populated by `RefillWizardViewModel`. No new network calls, no ViewModel change.

## Edge cases

| Case | Behavior |
|---|---|
| Machine has 0 trays | Grid section hidden; picker behaves exactly like today. |
| Only the target slot exists in the machine (no other trays) | Grid section hidden — a 1-slot grid is not useful context. |
| Target slot is `unassigned` (no productId on its tray) | Slot is still rendered in the grid with the placeholder icon + ✦ overlay (we know its `itemNumber`). |
| Tray exists at a slot but has `productId == nil` (and isn't the target) | Rendered as a single empty cell with placeholder icon, distinguishable from a between-slots gap (solid faded border vs. dashed). |
| Last slot in a row with no successor | `width = 1` (heuristic limitation documented above). |
| `rowCount > 5` | Grid becomes internally vertically scrollable, capped at ~200pt. |
| Small iPhone width | Cell size shrinks to 28pt; if still too tight, grid is horizontally scrollable. |

## Files affected

| File | Change |
|---|---|
| [ReviewStepView.swift](ios/VMflow/Views/Refill/ReviewStepView.swift) | + `MachineGridSlot`, `MachineGridLayout` structs; + `machineLayout(forTrayId:)` helper; sheet passes 2 new params. |
| Same file, `ReplacementProductPicker` block | + 2 new params; wrap List in `ScrollViewReader`; add `MachineLayoutGrid` header view; add `@State highlightedProductId`; add `.id()` on each list row. |
| Same file (inline subviews) | + `MachineLayoutGrid` view + `MachineGridCell` view. |
| [Localizable.xcstrings](ios/VMflow/Localizable.xcstrings) | + `"Machine Layout"`, + `"Row %d"` (a11y), + `"Slot %d, %@"` (VoiceOver), + `"Current target slot"` (a11y hint). EN + DE. |

No new files in this iteration. `ReviewStepView.swift` is currently 487 lines; the estimated +150–200 lines puts the total at 637–687 lines — close to but under the ~700-line threshold. If the implementation ends up tighter (e.g. ~700 lines on the nose), extract `MachineLayoutGrid.swift` and `MachineGridCell.swift` in the same change rather than as a follow-up. Decision deferred to the implementation plan based on the actual line count at the end.

## Accessibility

- Each cell: `accessibilityLabel("Slot \(itemNumber), \(productName)")` — fallback `"Slot \(itemNumber), empty"` for placeholder.
- `accessibilityHint`: `"Current target slot"` for target, `"Tap to find this product in the list"` for occupied non-target, suppress for empty gaps.
- Grid container: `accessibilityElement(children: .contain)` with label `"Machine layout, \(rowCount) rows"`.

## Testing

iOS project has no unit-test target; verification is via SwiftUI Previews + on-device manual checks.

**Previews to add at bottom of `ReviewStepView.swift`** (extend the existing `#Preview("Picker with existing slots")` block):

1. `Picker with grid (typical)` — 3 rows, a few gaps, mixed widths, one target slot.
2. `Picker with grid (wide slots)` — e.g. trays at 10, 12, 15 (mix of width 2 and width 3 cases) in row 0.
3. `Picker with no grid` — empty machine, only list shows (grid header collapses).
4. `Picker with unassigned target` — target slot has no `productId`; grid shows placeholder + ✦.

**Manual on-device checks**:
- ✦ pulse animation runs and doesn't flicker.
- Tap on occupied cell scrolls list smoothly and highlights for ~1s.
- Tap on empty gap is no-op.
- VoiceOver reads slot+product correctly; target announced as "Current target slot".
- Behavior on iPhone SE/mini (small-width fallback to 28pt cells).
- Behavior on iPad (cells stay at 32pt, more horizontal whitespace).

## Risks

1. **Wide last-slot heuristic**: cosmetic only, documented above.
2. **Cell size on very narrow devices**: fallback to 28pt; if still cramped, horizontal scroll. Accept as a known limitation rather than redesigning around it.
3. **Performance**: 10×N grid renders trivially in SwiftUI; not a concern.
4. **Double UI for "already in slot X"**: the existing pill stays in the list rows alongside the grid. Redundant but useful for VoiceOver and well-tested. Removing it is out of scope; finetune later if it feels noisy.
5. **Out-of-stock/discontinued products in the grid**: the grid shows what's physically in the machine, including products flagged as discontinued. They appear as normal cells (their image is still in the bucket). The list separately handles discontinued filtering; the grid is a physical-reality view, not a catalogue view.

## Effort estimate

~150–200 lines of new Swift inside `ReviewStepView.swift`, plus 4 localized strings. One implementation session.

## Out of scope for this design (explicit follow-ups)

- "Neighbor / category suggestion" heuristics — the user explicitly said grid is a context, not a recommender.
- Auto-select on grid tap (rejected — Liste-Scroll only).
- Persisting per-machine grid layout in DB (revisit if wide-end-of-row case bites).
- Same feature in PWA or Android app.
- Extracting `MachineLayoutGrid` to its own file (revisit if `ReviewStepView.swift` exceeds ~700 lines).
