# Refill Review — Machine Layout Grid Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a visual machine layout grid (rows × columns derived from `item_number`) to the top of `ReplacementProductPicker` in the iOS Refill wizard's Review step, so users see the physical product arrangement when picking a replacement, with tap-to-scroll behavior on the list below.

**Architecture:** Client-only feature. Layout is derived from existing `Tray.itemNumber` values (no DB migration). Two new data structs (`MachineGridSlot`, `MachineGridLayout`), two new inline SwiftUI views (`MachineLayoutGrid`, `MachineGridCell`), and modifications to `ReplacementProductPicker` to embed the grid header + a `ScrollViewReader` for scroll-to-product on grid tap. All changes live in `ios/VMflow/Views/Refill/ReviewStepView.swift` (with localized strings in `ios/VMflow/Resources/Localizable.xcstrings`).

**Tech Stack:** SwiftUI, Swift 5.9+, iOS 17+ (project target), Xcode 15+, no third-party deps.

**Spec:** [docs/superpowers/specs/2026-05-26-refill-review-machine-grid-design.md](../specs/2026-05-26-refill-review-machine-grid-design.md)

---

## Conventions for this Plan

- **No unit-test target** in the iOS project. The TDD-equivalent loop is:
  1. Write SwiftUI code.
  2. Run `xcodebuild build` to compile-check.
  3. Add or update a `#Preview` block exercising the new visual state.
  4. Open Xcode → preview canvas → verify the preview renders as described.
- The `xcodebuild` build-check command used throughout this plan is:
  ```bash
  xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug build 2>&1 | tail -30
  ```
  Expected on success: last line contains `** BUILD SUCCEEDED **`.
- Commit messages follow Conventional Commits with the `feat(refill)` / `refactor(refill)` scope.
- The implementation agent must NOT make changes outside the files listed under "Files" for each task.

---

## File Structure

All work happens in two files:

| File | Responsibility |
|---|---|
| `ios/VMflow/Views/Refill/ReviewStepView.swift` | Existing — gets new structs, helper, two inline views, and modifications to `ReplacementProductPicker`. Currently 488 lines; expected ~640–700 lines after this change. If it crosses 700, extract `MachineLayoutGrid.swift` in the same change (see Chunk 3, Task 8). |
| `ios/VMflow/Resources/Localizable.xcstrings` | Existing — add four new keys (EN + DE). |

No new files unless the 700-line threshold is hit.

---

## Chunk 1: Data Layer

This chunk introduces the pure-data structs and the layout-computation helper. No UI yet — only data and a preview that prints the layout to verify correctness.

### Task 1: Add `MachineGridSlot` and `MachineGridLayout` structs

**Files:**
- Modify: `ios/VMflow/Views/Refill/ReviewStepView.swift` (insert at the bottom of the file, before the `// MARK: - Previews` section at line ~458)

- [ ] **Step 1.1: Add the two struct definitions**

Insert this block immediately after the `ReplacementProductPicker` struct closes (after line ~456, before the `// MARK: - Previews` comment):

```swift
// MARK: - Machine Layout Grid Data

/// A single cell in the machine layout grid. Computed from a `Tray`'s
/// `itemNumber` plus knowledge of the next occupied slot in the same row.
///
/// `width > 1` means this slot physically occupies more than one column
/// (e.g. a wide product that takes 2 standard slot positions). Gaps in
/// the `item_number` sequence are interpreted as the preceding slot being
/// wider.
struct MachineGridSlot: Identifiable, Equatable {
    let id: UUID                  // tray.id
    let itemNumber: Int
    let row: Int                  // 0-indexed, clamped to 0 if itemNumber < 10
    let column: Int               // 0..9
    let width: Int                // 1..10
    let productId: UUID?
    let productImagePath: String?
    let isTarget: Bool
}

/// The full machine layout snapshot used to render `MachineLayoutGrid`.
///
/// `rowCount == 0` means the grid should not be shown at all (machine has
/// no trays, or only the target slot — see edge cases in the spec).
struct MachineGridLayout: Equatable {
    let rowCount: Int
    let columnsPerRow: Int        // hardcoded 10 for this fleet
    let slots: [MachineGridSlot]
}
```

- [ ] **Step 1.2: Compile-check**

Run:
```bash
xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 1.3: Commit**

```bash
git add ios/VMflow/Views/Refill/ReviewStepView.swift
git commit -m "feat(refill): add MachineGridSlot/Layout data structs"
```

---

### Task 2: Add `machineLayout(forTrayId:)` helper in `ReviewStepView`

**Files:**
- Modify: `ios/VMflow/Views/Refill/ReviewStepView.swift` (inside `ReviewStepView`, immediately after `existingSlots(forTrayId:)` at line ~284–299)

- [ ] **Step 2.1: Add the helper method**

Insert this method directly after the closing brace of `existingSlots(forTrayId:)` (around line 299):

```swift
    /// Compute the full machine layout for the grid header in the picker.
    ///
    /// Reads `viewModel.allTraysByMachine` (the unfiltered tray set, same
    /// as `existingSlots`). Returns `MachineGridLayout(rowCount: 0, ...)`
    /// when the machine has no trays, or only the target slot — both
    /// signal "do not render the grid section".
    ///
    /// - Row = `(itemNumber / 10) - 1`, clamped to 0 for itemNumber < 10.
    /// - Column = `itemNumber % 10`.
    /// - Width = next occupied slot in the same row's itemNumber minus
    ///   this slot's itemNumber; 1 if there is no next slot in the row.
    private func machineLayout(forTrayId trayId: UUID) -> MachineGridLayout {
        guard let suggestion = viewModel.replacements.first(where: { $0.trayId == trayId })
        else { return MachineGridLayout(rowCount: 0, columnsPerRow: 10, slots: []) }

        let allTrays = viewModel.allTraysByMachine[suggestion.machineId] ?? []

        // Skip grid entirely when the machine is empty or has only the target.
        let nonTargetCount = allTrays.filter { $0.id != trayId }.count
        guard nonTargetCount > 0 else {
            return MachineGridLayout(rowCount: 0, columnsPerRow: 10, slots: [])
        }

        // Group trays by row, sort each row by itemNumber.
        var trayByRow: [Int: [Tray]] = [:]
        for tray in allTrays {
            let row = max(0, (tray.itemNumber / 10) - 1)
            trayByRow[row, default: []].append(tray)
        }
        for key in trayByRow.keys {
            trayByRow[key]?.sort { $0.itemNumber < $1.itemNumber }
        }

        // Build slots with width = next.itemNumber - this.itemNumber.
        var slots: [MachineGridSlot] = []
        for (row, rowTrays) in trayByRow {
            for (idx, tray) in rowTrays.enumerated() {
                let nextItemNumber = idx + 1 < rowTrays.count ? rowTrays[idx + 1].itemNumber : nil
                let width = nextItemNumber.map { $0 - tray.itemNumber } ?? 1
                slots.append(
                    MachineGridSlot(
                        id: tray.id,
                        itemNumber: tray.itemNumber,
                        row: row,
                        column: tray.itemNumber % 10,
                        width: max(1, width),
                        productId: tray.productId,
                        productImagePath: tray.products?.imagePath,
                        isTarget: tray.id == trayId
                    )
                )
            }
        }

        let rowCount = (trayByRow.keys.max() ?? -1) + 1
        return MachineGridLayout(rowCount: rowCount, columnsPerRow: 10, slots: slots)
    }
```

- [ ] **Step 2.2: Compile-check**

Run the standard build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2.3: Commit**

```bash
git add ios/VMflow/Views/Refill/ReviewStepView.swift
git commit -m "feat(refill): add machineLayout helper to ReviewStepView"
```

---

### Task 3: Add data-layer preview to verify layout correctness

**Files:**
- Modify: `ios/VMflow/Views/Refill/ReviewStepView.swift` (preview section at bottom, after existing `#Preview("Picker with existing slots")` block)

- [ ] **Step 3.1: Add a debug preview that renders layout slots as text**

Append after the existing `#Preview("Picker with existing slots")` block (after line ~488):

```swift
#Preview("MachineGridLayout — wide-slot computation") {
    // Sample row 0 (slots 10, 12, 13, 15) and row 1 (slots 20, 21, 22).
    // Slot 10 has next=12 → width 2. Slot 12 has next=13 → width 1.
    // Slot 13 has next=15 → width 2. Slot 15 has no next → width 1.
    // Row 1: all width 1.
    let targetId = UUID()
    let machineId = UUID()
    let trays: [Tray] = [
        Tray(id: UUID(), machineId: machineId, itemNumber: 10, productId: UUID(),
             capacity: 10, currentStock: 5, minStock: 0, fillWhenBelow: 0,
             products: TrayProduct(name: "Mars", imagePath: nil, discontinued: false, sellprice: 2.5)),
        Tray(id: UUID(), machineId: machineId, itemNumber: 12, productId: UUID(),
             capacity: 10, currentStock: 5, minStock: 0, fillWhenBelow: 0,
             products: TrayProduct(name: "Twix", imagePath: nil, discontinued: false, sellprice: 2.5)),
        Tray(id: UUID(), machineId: machineId, itemNumber: 13, productId: UUID(),
             capacity: 10, currentStock: 5, minStock: 0, fillWhenBelow: 0,
             products: TrayProduct(name: "Cola", imagePath: nil, discontinued: false, sellprice: 2.5)),
        Tray(id: targetId, machineId: machineId, itemNumber: 15, productId: UUID(),
             capacity: 10, currentStock: 0, minStock: 0, fillWhenBelow: 0,
             products: TrayProduct(name: "Snickers", imagePath: nil, discontinued: false, sellprice: 2.5)),
        Tray(id: UUID(), machineId: machineId, itemNumber: 20, productId: UUID(),
             capacity: 10, currentStock: 5, minStock: 0, fillWhenBelow: 0,
             products: TrayProduct(name: "Bounty", imagePath: nil, discontinued: false, sellprice: 2.5)),
    ]

    // Inline the same computation so we can preview without instantiating
    // the full RefillWizardViewModel — kept structurally identical to the
    // helper above. This is debug-only.
    var trayByRow: [Int: [Tray]] = [:]
    for t in trays {
        trayByRow[max(0, (t.itemNumber / 10) - 1), default: []].append(t)
    }
    for k in trayByRow.keys { trayByRow[k]?.sort { $0.itemNumber < $1.itemNumber } }

    var slots: [MachineGridSlot] = []
    for (row, rowTrays) in trayByRow {
        for (idx, t) in rowTrays.enumerated() {
            let nextItem = idx + 1 < rowTrays.count ? rowTrays[idx + 1].itemNumber : nil
            let width = nextItem.map { $0 - t.itemNumber } ?? 1
            slots.append(MachineGridSlot(
                id: t.id, itemNumber: t.itemNumber, row: row, column: t.itemNumber % 10,
                width: max(1, width), productId: t.productId, productImagePath: nil,
                isTarget: t.id == targetId
            ))
        }
    }

    return ScrollView {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(slots.sorted { ($0.row, $0.column) < ($1.row, $1.column) }) { slot in
                Text("Slot \(slot.itemNumber): row=\(slot.row) col=\(slot.column) width=\(slot.width)\(slot.isTarget ? " ✦" : "")")
                    .font(.system(.body, design: .monospaced))
            }
        }
        .padding()
    }
}
```

- [ ] **Step 3.2: Compile-check + manually verify preview**

Run the standard build. Then in Xcode, open `ReviewStepView.swift`, switch to the canvas, and select the "MachineGridLayout — wide-slot computation" preview.

Expected output in the preview:
```
Slot 10: row=0 col=0 width=2
Slot 12: row=0 col=2 width=1
Slot 13: row=0 col=3 width=2
Slot 15: row=0 col=5 width=1 ✦
Slot 20: row=1 col=0 width=1
```

If any row's `row`/`col`/`width`/`✦` is wrong, fix `machineLayout(forTrayId:)` before continuing.

- [ ] **Step 3.3: Commit**

```bash
git add ios/VMflow/Views/Refill/ReviewStepView.swift
git commit -m "test(refill): add layout-computation preview for grid data layer"
```

---

## Chunk 2: Grid Views

This chunk introduces the visual layer: `MachineGridCell` (one cell) and `MachineLayoutGrid` (full grid header). No interaction wiring yet — that comes in Chunk 3.

### Task 4: Add `MachineGridCell` inline view

**Files:**
- Modify: `ios/VMflow/Views/Refill/ReviewStepView.swift` (insert after the `MachineGridLayout` struct definition from Task 1)

- [ ] **Step 4.1: Add the cell view**

Insert immediately after the `MachineGridLayout` struct (after the closing brace of the struct added in Task 1):

```swift
// MARK: - Machine Layout Grid Views

/// A single grid cell. Renders a product image (or placeholder), a slot-number
/// pill in the bottom-left, and — for the target slot — a 2pt accent border,
/// a pulsing opacity animation (skipped under Reduce Motion), and a ✦ overlay.
struct MachineGridCell: View {
    let slot: MachineGridSlot
    /// Base cell side length in points. The actual width is
    /// `cellSize * slot.width + interitemSpacing * (slot.width - 1)`.
    let cellSize: CGFloat
    let interitemSpacing: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        let totalWidth = cellSize * CGFloat(slot.width) + interitemSpacing * CGFloat(slot.width - 1)

        return ZStack(alignment: .bottomLeading) {
            // Background / image.
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.regularMaterial)

                if let path = slot.productImagePath, !path.isEmpty {
                    ProductImage(imagePath: path, size: cellSize - 4)
                } else {
                    Image(systemName: slot.productId == nil ? "tray" : "shippingbox")
                        .font(.system(size: cellSize * 0.4))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: totalWidth, height: cellSize)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                if slot.isTarget {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .opacity(reduceMotion ? 1.0 : (pulse ? 1.0 : 0.6))
                }
            }

            // Slot-number pill.
            Text("\(slot.itemNumber)")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(2)

            // Target ✦ overlay (top-right).
            if slot.isTarget {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "sparkle")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(3)
                    }
                    Spacer()
                }
                .frame(width: totalWidth, height: cellSize)
            }
        }
        .frame(width: totalWidth, height: cellSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            slot.productId == nil
                ? "Slot \(slot.itemNumber), empty"
                : "Slot \(slot.itemNumber)"
        )
        .accessibilityHint(accessibilityHintForSlot)
        .onAppear {
            guard slot.isTarget, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var accessibilityHintForSlot: String {
        if slot.isTarget { return String(localized: "Current target slot") }
        if slot.productId == nil { return "" }
        return String(localized: "Tap to find this product in the list")
    }
}

/// A non-interactive thin dashed placeholder for an unoccupied column
/// between two occupied slots in the same row.
struct MachineGridGap: View {
    let cellSize: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(.secondary.opacity(0.5))
            .frame(width: cellSize, height: cellSize)
            .accessibilityHidden(true)
    }
}
```

(The `String(localized:)` call sites here pre-empt the i18n step in Task 6 —
the corresponding xcstrings keys are added there.)

- [ ] **Step 4.2: Compile-check**

Run the standard build. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4.3: Add preview for the cell**

Append after the data-layer preview from Task 3:

```swift
#Preview("MachineGridCell — all visual states") {
    let basicId = UUID()
    let targetId = UUID()
    let unassignedId = UUID()

    return HStack(spacing: 8) {
        MachineGridCell(
            slot: MachineGridSlot(
                id: basicId, itemNumber: 12, row: 0, column: 2, width: 1,
                productId: UUID(), productImagePath: nil, isTarget: false
            ),
            cellSize: 32, interitemSpacing: 4
        )
        MachineGridCell(
            slot: MachineGridSlot(
                id: UUID(), itemNumber: 13, row: 0, column: 3, width: 2,
                productId: UUID(), productImagePath: nil, isTarget: false
            ),
            cellSize: 32, interitemSpacing: 4
        )
        MachineGridCell(
            slot: MachineGridSlot(
                id: targetId, itemNumber: 15, row: 0, column: 5, width: 1,
                productId: UUID(), productImagePath: nil, isTarget: true
            ),
            cellSize: 32, interitemSpacing: 4
        )
        MachineGridCell(
            slot: MachineGridSlot(
                id: unassignedId, itemNumber: 16, row: 0, column: 6, width: 1,
                productId: nil, productImagePath: nil, isTarget: false
            ),
            cellSize: 32, interitemSpacing: 4
        )
        MachineGridGap(cellSize: 32)
    }
    .padding()
}
```

Verify in Xcode preview canvas: 5 cells visible — basic (1-wide), wide (2-wide), target (with pulse + ✦), unassigned (tray icon), gap (dashed).

- [ ] **Step 4.4: Commit**

```bash
git add ios/VMflow/Views/Refill/ReviewStepView.swift
git commit -m "feat(refill): add MachineGridCell and MachineGridGap views"
```

---

### Task 5: Add `MachineLayoutGrid` container view

**Files:**
- Modify: `ios/VMflow/Views/Refill/ReviewStepView.swift` (insert after `MachineGridGap` from Task 4)

**Why no `GeometryReader`**: `MachineLayoutGrid` is embedded as a row inside a `List`
(see Task 7). `GeometryReader` is unreliable inside list rows (zero-size on first
layout, unpredictable when sections collapse/expand). To avoid that, this view
uses a **fixed 28pt cell size** that comfortably fits all supported iPhones
(375pt+ width) and iPads. 22pt row label + 10 × 28pt cells + 9 × 4pt spacing +
24pt horizontal padding = **362pt** — fits even on iPhone 13 mini (375pt). Slight
visual loss on larger devices is acceptable; the grid is a compact reference, not
a primary surface.

- [ ] **Step 5.1: Add the grid container view**

Insert immediately after the `MachineGridGap` struct:

```swift
/// Header view in the picker sheet: renders the full machine layout as a
/// grid of `MachineGridCell` + `MachineGridGap`. Cells are tappable via
/// `onSlotTap`; gaps are not.
///
/// Sizing: cells are a fixed 28pt for layout stability inside a List row
/// (no `GeometryReader` — that's flaky in list rows). Comfortably fits the
/// 10 columns + row label + padding within iPhone 13 mini's 375pt width.
///
/// When `rowCount > 5`, the grid becomes internally vertically scrollable
/// with a 200pt max height.
struct MachineLayoutGrid: View {
    let layout: MachineGridLayout
    let onSlotTap: (MachineGridSlot) -> Void

    private let cellSize: CGFloat = 28
    private let interitemSpacing: CGFloat = 4
    private let rowSpacing: CGFloat = 4
    private let rowLabelWidth: CGFloat = 22

    var body: some View {
        let content = VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(0..<layout.rowCount, id: \.self) { row in
                rowView(row: row)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

        return Group {
            if layout.rowCount > 5 {
                ScrollView(.vertical, showsIndicators: false) { content }
                    .frame(maxHeight: 200)
            } else {
                content
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Machine layout, \(layout.rowCount) rows"))
    }

    @ViewBuilder
    private func rowView(row: Int) -> some View {
        HStack(spacing: interitemSpacing) {
            Text("R\(row + 1)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: rowLabelWidth, alignment: .trailing)

            rowCells(row: row)
        }
    }

    /// Walk columns 0..9 deterministically. A slot at column c with width w
    /// emits one cell at column c and advances the cursor by w. A column
    /// between occupied positions that has no slot is emitted as a dashed
    /// gap. Columns past the last occupied position emit invisible spacers
    /// to keep rows horizontally aligned.
    @ViewBuilder
    private func rowCells(row: Int) -> some View {
        let slotsInRow = layout.slots
            .filter { $0.row == row }
            .sorted { $0.column < $1.column }
        let lastOccupiedColumn = slotsInRow.last.map { $0.column + $0.width - 1 } ?? -1

        var columnContent: [(id: Int, view: AnyView)] = []
        var c = 0
        var slotIdx = 0

        while c < layout.columnsPerRow {
            if slotIdx < slotsInRow.count, slotsInRow[slotIdx].column == c {
                let slot = slotsInRow[slotIdx]
                columnContent.append((c, AnyView(
                    Button {
                        onSlotTap(slot)
                    } label: {
                        MachineGridCell(
                            slot: slot,
                            cellSize: cellSize,
                            interitemSpacing: interitemSpacing
                        )
                    }
                    .buttonStyle(.plain)
                )))
                c += slot.width
                slotIdx += 1
            } else if c <= lastOccupiedColumn {
                columnContent.append((c, AnyView(MachineGridGap(cellSize: cellSize))))
                c += 1
            } else {
                columnContent.append((c, AnyView(
                    Color.clear.frame(width: cellSize, height: cellSize)
                )))
                c += 1
            }
        }

        HStack(spacing: interitemSpacing) {
            ForEach(columnContent, id: \.id) { entry in
                entry.view
            }
        }
    }
}
```

- [ ] **Step 5.2: Compile-check**

Run the standard build. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5.3: Add preview for the grid container**

Append after the cell preview from Task 4:

```swift
#Preview("MachineLayoutGrid — typical 3-row machine") {
    let targetId = UUID()
    let layout = MachineGridLayout(
        rowCount: 3,
        columnsPerRow: 10,
        slots: [
            MachineGridSlot(id: UUID(), itemNumber: 10, row: 0, column: 0, width: 2,
                            productId: UUID(), productImagePath: nil, isTarget: false),
            MachineGridSlot(id: UUID(), itemNumber: 12, row: 0, column: 2, width: 1,
                            productId: UUID(), productImagePath: nil, isTarget: false),
            MachineGridSlot(id: UUID(), itemNumber: 13, row: 0, column: 3, width: 2,
                            productId: UUID(), productImagePath: nil, isTarget: false),
            MachineGridSlot(id: targetId, itemNumber: 15, row: 0, column: 5, width: 1,
                            productId: UUID(), productImagePath: nil, isTarget: true),
            MachineGridSlot(id: UUID(), itemNumber: 20, row: 1, column: 0, width: 1,
                            productId: UUID(), productImagePath: nil, isTarget: false),
            MachineGridSlot(id: UUID(), itemNumber: 21, row: 1, column: 1, width: 1,
                            productId: UUID(), productImagePath: nil, isTarget: false),
            MachineGridSlot(id: UUID(), itemNumber: 22, row: 1, column: 2, width: 1,
                            productId: nil, productImagePath: nil, isTarget: false),
            MachineGridSlot(id: UUID(), itemNumber: 30, row: 2, column: 0, width: 1,
                            productId: UUID(), productImagePath: nil, isTarget: false),
        ]
    )

    return MachineLayoutGrid(layout: layout) { slot in
        print("Tapped slot \(slot.itemNumber)")
    }
    .frame(maxWidth: .infinity)
    .background(.regularMaterial)
}
```

Verify in Xcode preview canvas:
- Row 1: wide cell (slots 10–11), then slot 12, then wide (13–14), then target with pulsing border + ✦, then 4 trailing empty/clear columns.
- Row 2: slots 20, 21, 22 (22 has the unassigned icon), 7 trailing empty columns.
- Row 3: slot 30, 9 trailing empty columns.
- Row labels R1, R2, R3 on the left.

- [ ] **Step 5.4: Commit**

```bash
git add ios/VMflow/Views/Refill/ReviewStepView.swift
git commit -m "feat(refill): add MachineLayoutGrid container view"
```

---

## Chunk 3: Picker Integration

This chunk wires the grid into `ReplacementProductPicker`: adds the new `machineLayout` parameter, wraps the list in `ScrollViewReader`, adds highlight state, scrolls to product on grid tap, and pipes the layout through from `ReviewStepView`.

### Task 6: Add new localizable strings (EN + DE)

**Files:**
- Modify: `ios/VMflow/Resources/Localizable.xcstrings`

- [ ] **Step 6.1: Add four new string keys to the xcstrings file**

The file is JSON. Add these four entries inside the `"strings"` object (alphabetical order, anywhere in the existing list — JSON object key order is informational):

```json
    "Current target slot" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Aktueller Ziel-Slot"
          }
        }
      }
    },
    "Machine Layout" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Automaten-Layout"
          }
        }
      }
    },
    "Machine layout, %lld rows" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Automaten-Layout, %lld Reihen"
          }
        }
      }
    },
    "Tap to find this product in the list" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Tippe, um dieses Produkt in der Liste zu finden"
          }
        }
      }
    },
```

The view code in Tasks 4 and 5 already calls `String(localized: ...)` for these
keys — this step only adds the corresponding xcstrings entries so the lookups
resolve at runtime. The `"Machine Layout"` key is consumed by `Section(header:)`
in Task 7 (also via `Text(...)` which automatically uses xcstrings for literal
keys).

- [ ] **Step 6.2: Compile-check**

Run the standard build. Expected: `** BUILD SUCCEEDED **`.

Note: missing xcstrings keys do NOT break compilation — they just fall back to
the literal key string at runtime. So this check only verifies the JSON edit
didn't break the file. Visual verification happens in Task 7.7.

- [ ] **Step 6.3: Commit**

```bash
git add ios/VMflow/Resources/Localizable.xcstrings
git commit -m "i18n(refill): add machine layout grid strings (EN+DE)"
```

---

### Task 7: Extend `ReplacementProductPicker` with grid header + scroll-to-product

**Files:**
- Modify: `ios/VMflow/Views/Refill/ReviewStepView.swift` (the `ReplacementProductPicker` struct at lines ~380–456)

- [ ] **Step 7.1: Add the `machineLayout` parameter and new state**

In the `ReplacementProductPicker` struct's property list (currently lines ~381–385), add `machineLayout` after `existingSlotsByProduct`. Result:

```swift
struct ReplacementProductPicker: View {
    let products: [Product]
    let selectedProductId: UUID?
    let existingSlotsByProduct: [UUID: [Int]]
    let machineLayout: MachineGridLayout       // NEW
    let onSelect: (UUID) -> Void

    @State private var searchText = ""
    @State private var highlightedProductId: UUID?    // NEW

    // ... (filteredProducts, fuzzyMatch — unchanged)
```

- [ ] **Step 7.2: Replace the `body` to embed the grid + ScrollViewReader**

Replace the existing `body` (currently lines ~419–455) with:

```swift
    var body: some View {
        ScrollViewReader { proxy in
            List {
                if machineLayout.rowCount > 0 {
                    Section(header: Text("Machine Layout").textCase(nil)) {
                        MachineLayoutGrid(layout: machineLayout) { tappedSlot in
                            handleGridTap(slot: tappedSlot, proxy: proxy)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                }

                Section {
                    ForEach(filteredProducts) { product in
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
                                        .accessibilityLabel("Already in \(slots.count == 1 ? "slot" : "slots") \(slots.sorted().map(String.init).joined(separator: ", "))")
                                }
                                Spacer()
                                if selectedProductId == product.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .id(product.id)
                        .listRowBackground(
                            highlightedProductId == product.id
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear
                        )
                    }

                    if !searchText.isEmpty && filteredProducts.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search products")
            .navigationTitle("Select Replacement")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func handleGridTap(slot: MachineGridSlot, proxy: ScrollViewProxy) {
        guard let productId = slot.productId, !slot.isTarget else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(productId, anchor: .center)
        }
        highlightedProductId = productId
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if highlightedProductId == productId {
                withAnimation(.easeOut(duration: 0.4)) {
                    highlightedProductId = nil
                }
            }
        }
    }
```

- [ ] **Step 7.3: Update the `.sheet(item: $pickerTrayId)` call site in `ReviewStepView.body`**

Find the call at line ~47–62. Change:
```swift
                ReplacementProductPicker(
                    products: viewModel.availableProducts,
                    selectedProductId: viewModel.replacements.first(where: { $0.trayId == trayId })?.replacementProductId,
                    existingSlotsByProduct: existingSlots(forTrayId: trayId),
                    onSelect: { productId in
                        viewModel.setReplacement(trayId: trayId, productId: productId)
                        pickerTrayId = nil
                    }
                )
```
to:
```swift
                ReplacementProductPicker(
                    products: viewModel.availableProducts,
                    selectedProductId: viewModel.replacements.first(where: { $0.trayId == trayId })?.replacementProductId,
                    existingSlotsByProduct: existingSlots(forTrayId: trayId),
                    machineLayout: machineLayout(forTrayId: trayId),
                    onSelect: { productId in
                        viewModel.setReplacement(trayId: trayId, productId: productId)
                        pickerTrayId = nil
                    }
                )
```

- [ ] **Step 7.4: Update existing `#Preview("Picker with existing slots")` to pass the new param**

Find the existing preview (around line 460–488). It currently constructs `ReplacementProductPicker(products:selectedProductId:existingSlotsByProduct:onSelect:)`. Add the new `machineLayout:` argument. Replace:
```swift
        ReplacementProductPicker(
            products: sampleProducts,
            selectedProductId: nil,
            existingSlotsByProduct: slots,
            onSelect: { _ in }
        )
```
with:
```swift
        ReplacementProductPicker(
            products: sampleProducts,
            selectedProductId: nil,
            existingSlotsByProduct: slots,
            machineLayout: MachineGridLayout(rowCount: 0, columnsPerRow: 10, slots: []),
            onSelect: { _ in }
        )
```

(Empty layout = grid hidden, exercises the no-grid fallback.)

- [ ] **Step 7.5: Add a second `Picker with grid` preview**

Append after the existing picker preview:

```swift
#Preview("Picker with grid (typical)") {
    let targetTrayId = UUID()
    let layout = MachineGridLayout(
        rowCount: 3,
        columnsPerRow: 10,
        slots: [
            MachineGridSlot(id: UUID(), itemNumber: 10, row: 0, column: 0, width: 2,
                            productId: UUID(), productImagePath: nil, isTarget: false),
            MachineGridSlot(id: UUID(), itemNumber: 12, row: 0, column: 2, width: 1,
                            productId: UUID(), productImagePath: nil, isTarget: false),
            MachineGridSlot(id: targetTrayId, itemNumber: 15, row: 0, column: 5, width: 1,
                            productId: UUID(), productImagePath: nil, isTarget: true),
            MachineGridSlot(id: UUID(), itemNumber: 20, row: 1, column: 0, width: 1,
                            productId: UUID(), productImagePath: nil, isTarget: false),
            MachineGridSlot(id: UUID(), itemNumber: 30, row: 2, column: 0, width: 1,
                            productId: UUID(), productImagePath: nil, isTarget: false),
        ]
    )

    let products: [Product] = (1...12).map { i in
        Product(
            id: UUID(),
            name: "Product \(i)",
            imagePath: nil,
            discontinued: false,
            sellprice: 2.50,
            category: nil
        )
    }

    return NavigationStack {
        ReplacementProductPicker(
            products: products,
            selectedProductId: nil,
            existingSlotsByProduct: [:],
            machineLayout: layout,
            onSelect: { _ in }
        )
    }
}
```

- [ ] **Step 7.6: Compile-check**

Run the standard build. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7.7: Verify previews manually**

In Xcode, open `ReviewStepView.swift` and check both:
- **"Picker with existing slots"** — grid section absent; list with "Slot 3"/"Slot 1, 5, 9"/"Slot 2, 4, 6, 8, 10, 12 +3" pills as today.
- **"Picker with grid (typical)"** — grid header visible at top (Machine Layout section), 3 rows R1/R2/R3, target slot ✦ at row 1 col 5 with pulsing border. Tap on a non-target cell (e.g. slot 12) — the list below should scroll to that product slot and highlight briefly.

- [ ] **Step 7.8: Commit**

```bash
git add ios/VMflow/Views/Refill/ReviewStepView.swift
git commit -m "feat(refill): wire MachineLayoutGrid into ReplacementProductPicker"
```

---

### Task 8: File-size check and conditional extraction

**Files:**
- Maybe modify: split `ios/VMflow/Views/Refill/ReviewStepView.swift` into 2 files.

**Projection**: starting from 488 lines, this plan adds ~380 lines of code + previews
to `ReviewStepView.swift`. Expected final size: ~860–870 lines. Extraction is
therefore **likely required**. Step 8.2 confirms with the real number; Step 8.3
runs unless the file is somehow under 700 lines.

- [ ] **Step 8.1: Measure final file size**

Run:
```bash
wc -l ios/VMflow/Views/Refill/ReviewStepView.swift
```

Note the line count.

- [ ] **Step 8.2: Decide whether to split**

| Line count | Action |
|---|---|
| < 700 | Skip Steps 8.3–8.5 entirely. Mark this task complete with no commit. |
| 700–800 | Recommended. Proceed to Step 8.3. |
| > 800 | Required. Proceed to Step 8.3. |

- [ ] **Step 8.3: (Conditional) Extract grid views into a new file**

Only if line count >= 700:

Create `ios/VMflow/Views/Refill/MachineLayoutGrid.swift` and move into it:
- `MachineGridSlot` struct
- `MachineGridLayout` struct
- `MachineGridCell` struct
- `MachineGridGap` struct
- `MachineLayoutGrid` struct
- The `Array.subscript(safe:)` extension
- The relevant `#Preview` blocks (`"MachineGridLayout — wide-slot computation"`, `"MachineGridCell — all visual states"`, `"MachineLayoutGrid — typical 3-row machine"`)

Leave in `ReviewStepView.swift`:
- `ReviewStepView` (including `machineLayout(forTrayId:)`)
- `ReplacementProductPicker`
- `UUID: Identifiable` extension
- `slotBadgeLabel(_:)` function
- The two picker previews

Add `import SwiftUI` at the top of the new file. Verify build.

- [ ] **Step 8.4: Compile-check**

Run the standard build. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8.5: Commit (only if Step 8.3 ran)**

```bash
git add ios/VMflow/Views/Refill/ReviewStepView.swift ios/VMflow/Views/Refill/MachineLayoutGrid.swift
git commit -m "refactor(refill): extract MachineLayoutGrid into its own file"
```

---

## Final Verification Checklist

Before declaring the feature done, manually verify in Xcode (or on a simulator):

- [ ] All previews render without runtime crashes.
- [ ] `xcodebuild ... build` succeeds on a clean build.
- [ ] In the running app: open Refill wizard → Review step → tap **Replace** on a tray that has a current product (not unassigned). The picker opens with the grid header visible, target slot pulsing.
- [ ] Tap a non-target cell with a product → list scrolls to that product, row highlights for ~1s, no auto-select.
- [ ] Tap the target cell → no effect (silent).
- [ ] Tap an empty / gap cell → no effect.
- [ ] Search bar still filters the list correctly.
- [ ] "Already in slot X" pill still appears alongside the grid.
- [ ] Open a machine with 0 trays (or only the target tray) → grid section absent, picker behaves as before this change.
- [ ] iOS Settings → Accessibility → Reduce Motion enabled → target slot border is solid, no pulse.
- [ ] German locale: all four new strings render in German.
