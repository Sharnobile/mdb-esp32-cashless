# iOS Refill Replacement Picker — Show Existing Machine Products

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mark products already assigned to other slots in the same vending machine with an inline `Slot N` pill in the iOS refill wizard's replacement picker, so operators see duplicates at a glance while still being able to pick them with a single tap.

**Architecture:** One SwiftUI file changes
([ios/VMflow/Views/Refill/ReviewStepView.swift](../../ios/VMflow/Views/Refill/ReviewStepView.swift)).
The `.sheet` closure builds a `[UUID: [Int]]` map of productId → sorted slot
numbers from `viewModel.machines` (excluding the tray being replaced) and
passes it into `ReplacementProductPicker` as a new property. The picker
renders a small orange-tinted pill next to the product name when the lookup
returns a non-empty slot list. Sort order, `.searchable` fuzzy-matching,
and single-tap selection behaviour are preserved verbatim.

**Tech Stack:** SwiftUI, Swift 5, iOS 17+ (matches the project's existing
`@retroactive` conformance and `ContentUnavailableView` usage).

**Spec reference:** [docs/superpowers/specs/2026-04-23-ios-replacement-picker-machine-context-design.md](../specs/2026-04-23-ios-replacement-picker-machine-context-design.md)

---

## File Structure

Only one file is touched:

- **Modify:** `ios/VMflow/Views/Refill/ReviewStepView.swift`
  - Add a free function `slotBadgeLabel(_ slots: [Int]) -> String` near
    the bottom of the file (above the `ReplacementProductPicker` struct).
  - Add `existingSlotsByProduct: [UUID: [Int]]` property to
    `ReplacementProductPicker`.
  - Render the pill in the row body between the product name and the
    trailing `Spacer()`.
  - Build the map inside the existing `.sheet(item: $pickerTrayId)`
    closure and pass it to the picker.
  - Add a `#Preview` block at the bottom demonstrating pill rendering
    for 1-slot, 3-slot, and 6-slot cases.

No other files change. No new types, no ViewModel changes, no DB/edge
function changes.

---

## Chunk 1: Implementation

### Task 1: Add the slot-label helper and integrate the pill

**Files:**
- Modify: `ios/VMflow/Views/Refill/ReviewStepView.swift`

- [ ] **Step 1: Read the current state of the file**

Confirm the structure before editing. `ReviewStepView` sits at the top,
`ReplacementProductPicker` is the second struct in the file, and there is
currently no `#Preview` block.

```bash
wc -l ios/VMflow/Views/Refill/ReviewStepView.swift
```

Expected: ~343 lines.

- [ ] **Step 2: Add the `slotBadgeLabel` helper**

Insert this free function immediately above the `// MARK: - Replacement Product Picker`
marker line (currently line 275). Keep it as a file-scope function, not
a method on the struct, so it can be called from both `ReviewStepView`
previews and the picker row.

```swift
// MARK: - Slot Badge Label

/// Format a sorted list of slot numbers into a compact pill label.
///
/// - 1 slot: `"Slot 3"`
/// - 2–3 slots: `"Slot 3, 7"` / `"Slot 3, 7, 9"`
/// - 4+ slots: `"Slot 3, 7, 9 +2"` — first three + remainder count
///
/// Returns an empty string for an empty input; callers should treat that
/// as "no pill".
func slotBadgeLabel(_ slots: [Int]) -> String {
    guard !slots.isEmpty else { return "" }
    if slots.count <= 3 {
        return "Slot \(slots.map(String.init).joined(separator: ", "))"
    }
    let first = slots.prefix(3).map(String.init).joined(separator: ", ")
    let extra = slots.count - 3
    return "Slot \(first) +\(extra)"
}
```

- [ ] **Step 3: Add the `existingSlotsByProduct` property to the picker**

Modify the `ReplacementProductPicker` declaration (currently lines 277–283)
to add the new parameter between `selectedProductId` and `onSelect`:

```swift
struct ReplacementProductPicker: View {
    let products: [Product]
    let selectedProductId: UUID?
    let existingSlotsByProduct: [UUID: [Int]]
    let onSelect: (UUID) -> Void

    @State private var searchText = ""
```

- [ ] **Step 4: Render the pill in the row**

In the picker's `body`, modify the row's `HStack` (currently lines
320–330) to render a pill when `existingSlotsByProduct[product.id]` is
non-empty. The pill goes between the product name and the trailing
`Spacer()`:

```swift
Button {
    onSelect(product.id)
} label: {
    HStack(spacing: 12) {
        ProductImage(imagePath: product.imagePath, size: 36)
        Text(product.name ?? "Unnamed")
            .foregroundStyle(.primary)
        if let slots = existingSlotsByProduct[product.id], !slots.isEmpty {
            Text(slotBadgeLabel(slots))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.orange.opacity(0.15)))
                .foregroundStyle(.orange)
                .accessibilityLabel("Already in \(slots.count == 1 ? "slot" : "slots") \(slots.map(String.init).joined(separator: ", "))")
        }
        Spacer()
        if selectedProductId == product.id {
            Image(systemName: "checkmark")
                .foregroundStyle(.blue)
        }
    }
}
```

- [ ] **Step 5: Build the map in the `.sheet` closure**

Replace the `.sheet(item: $pickerTrayId)` block (currently lines 38–55) so
that it resolves the suggestion, resolves the machine, builds the
`[UUID: [Int]]` map excluding the current tray, and passes it into the
picker:

```swift
.sheet(item: $pickerTrayId) { trayId in
    NavigationStack {
        ReplacementProductPicker(
            products: viewModel.availableProducts,
            selectedProductId: viewModel.replacements.first(where: { $0.trayId == trayId })?.replacementProductId,
            existingSlotsByProduct: existingSlots(forTrayId: trayId),
            onSelect: { productId in
                viewModel.setReplacement(trayId: trayId, productId: productId)
                pickerTrayId = nil
            }
        )
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { pickerTrayId = nil }
            }
        }
    }
    .presentationDetents([.large])
}
```

- [ ] **Step 6: Add the `existingSlots(forTrayId:)` helper on the view**

Add this private helper to `ReviewStepView`. Place it alongside the
existing private helpers (`replacementCard`, `badgeColor`, `reasonBadge`,
`bottomBar`) which all sit *below* `body` — drop it in just before the
`// MARK: - Bottom Bar` section for consistency with the file's style:

```swift
/// Build a map of productId → sorted slot numbers for every tray in the
/// same machine as the tray being replaced, excluding the tray itself.
///
/// Returns an empty map when the suggestion or machine can't be resolved
/// (defensive — should not happen since the suggestion is what triggered
/// the sheet). Trays with `productId == nil` contribute nothing.
private func existingSlots(forTrayId trayId: UUID) -> [UUID: [Int]] {
    guard let suggestion = viewModel.replacements.first(where: { $0.trayId == trayId }),
          let machine = viewModel.machines.first(where: { $0.id == suggestion.machineId })
    else { return [:] }

    var result: [UUID: [Int]] = [:]
    for refillTray in machine.trays where refillTray.tray.id != trayId {
        guard let productId = refillTray.tray.productId else { continue }
        result[productId, default: []].append(refillTray.tray.itemNumber)
    }
    for key in result.keys {
        result[key]?.sort()
    }
    return result
}
```

Note: `viewModel.machines` only contains machines that currently need
refilling. The `ReplacementSuggestion` flow scans *all* machines for
trays needing review, so in principle a tray could belong to a machine
that isn't in `viewModel.machines`. In that case `existingSlots` returns
`[:]` — no pills, which matches today's behaviour. This is acceptable:
the case is rare (a tray needing product replacement in a machine that
otherwise doesn't need refilling is unusual), and the cost is just the
absence of helpful metadata, not incorrect behaviour.

- [ ] **Step 7: Add a `#Preview` block**

Append to the bottom of the file (after the closing brace of
`ReplacementProductPicker`). The `Product` struct's stored properties
are declared in the order `id, name, imagePath, discontinued, sellprice,
category` (see [ios/VMflow/Models/Product.swift](../../ios/VMflow/Models/Product.swift)),
which is what the auto-synthesised memberwise initialiser expects.

```swift
// MARK: - Previews

#Preview("Picker with existing slots") {
    let sampleProducts: [Product] = (1...8).map { i in
        Product(
            id: UUID(),
            name: "Product \(i)",
            imagePath: nil,
            discontinued: false,
            sellprice: 2.50,
            category: nil
        )
    }

    // 1 slot, 3 slots, 6 slots — verify pill formatting at each threshold.
    let slots: [UUID: [Int]] = [
        sampleProducts[0].id: [3],
        sampleProducts[1].id: [1, 5, 9],
        sampleProducts[2].id: [2, 4, 6, 8, 10, 12],
    ]

    return NavigationStack {
        ReplacementProductPicker(
            products: sampleProducts,
            selectedProductId: nil,
            existingSlotsByProduct: slots,
            onSelect: { _ in }
        )
    }
}
```

- [ ] **Step 8: Build the project**

Run an Xcode build to catch compile errors. There is no CI-runnable
build command for iOS in this repo, so this is done from Xcode directly:

```
Xcode → Product → Build (⌘B)
```

Expected: build succeeds, no warnings introduced.

If the command line is preferred and `xcodebuild` is available:

```bash
xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination "platform=iOS Simulator,name=iPhone 15" build 2>&1 | tail -80
```

Expected: `BUILD SUCCEEDED`. If the build fails, read further up in the
output (drop the `| tail -80` entirely) — Swift compile errors often
appear well before the final 80 lines.

- [ ] **Step 9: Verify visually via preview**

Open `ReviewStepView.swift` in Xcode, open the canvas (⌥⌘↵), and verify
the preview renders three rows with pills reading:

- `Slot 3` (1 slot)
- `Slot 1, 5, 9` (3 slots)
- `Slot 2, 4, 6 +3` (6 slots — first three + `+3` remainder)

Verify:
- Pill colour is the same orange tint as the existing `reasonBadge`
  (reference: `.red` / `.orange` / `.purple` / `.blue` badges at line
  202–217 of the same file).
- Pill sits between the product name and the trailing edge, not
  overlapping the checkmark area.
- Rows without a pill (products 4–8) render identically to today.
- Searching in the search bar still filters correctly; pills stay
  visible on matching rows.

- [ ] **Step 10: Manual smoke test in simulator (recommended)**

Run the app in the simulator (or on device), trigger a refill flow
where the Review step is non-empty, and tap **Replace** / **Assign** on
a suggestion. Confirm:

- Products currently assigned to other slots of the same machine show
  the `Slot N` pill.
- The current tray's product (when not unassigned) does **not** appear
  with a pill against itself.
- Tapping a pilled product still selects it on the first tap (no
  confirmation dialog appears).
- Search continues to filter the list correctly.

If no test machine with multiple occupied trays is available, this
step can be skipped — the preview already verifies rendering.

- [ ] **Step 11: Commit**

```bash
git add ios/VMflow/Views/Refill/ReviewStepView.swift
git commit -m "$(cat <<'EOF'
ios(refill): show existing machine slots in replacement picker

During the Review step of the refill wizard, mark products already
assigned to other trays in the same machine with a small "Slot N" pill.
Makes accidental double-allocation visible at a glance while still
allowing duplicates on a single tap — alphabetical sort and search
behaviour are unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Verification Summary

- **Compile:** Xcode build succeeds.
- **Visual:** `#Preview` shows pills with correct formatting at 1/3/6+
  slot thresholds and unchanged layout for products without pills.
- **Behavioural (manual):** In simulator, pilled products select on a
  single tap, current tray excluded from own machine's map, search
  works as before.
- **No regressions:** No other code paths touched; the picker still
  renders identically for callers that currently pass no map (they now
  pass `[:]` via the new required parameter — the compiler enforces
  update at the single call site).

## Out of Scope

- Web app's replacement picker (separate Vue codebase).
- Other iOS product pickers (`ProductCombobox`).
- Cross-machine slot marking.
- Confirmation dialogs or any added taps for the duplicate case.
