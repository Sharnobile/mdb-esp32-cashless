import SwiftUI

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

// MARK: - Machine Layout Grid Views

/// A single grid cell. Renders a product image (or placeholder), a slot-number
/// pill in the bottom-left, and — for the target slot — a 2pt accent border,
/// a pulsing opacity animation (skipped under Reduce Motion), and a ✦ overlay.
struct MachineGridCell: View {
    let slot: MachineGridSlot
    /// Width of one column in points. The actual rendered width is
    /// `cellWidth * slot.width + interitemSpacing * (slot.width - 1)`.
    let cellWidth: CGFloat
    /// Cell height in points — independent of width so cells can be
    /// taller than wide, giving product images more vertical room.
    let cellHeight: CGFloat
    let interitemSpacing: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        let totalWidth = cellWidth * CGFloat(slot.width) + interitemSpacing * CGFloat(slot.width - 1)

        return ZStack(alignment: .bottomLeading) {
            // Background / image.
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.regularMaterial)

                if let path = slot.productImagePath, !path.isEmpty {
                    ProductImage(imagePath: path, width: totalWidth - 4, height: cellHeight - 4)
                } else {
                    Image(systemName: slot.productId == nil ? "tray" : "shippingbox")
                        .font(.system(size: min(cellWidth, cellHeight) * 0.4))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: totalWidth, height: cellHeight)
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
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(.black.opacity(0.6)))
                .padding(3)

            // Target ✦ overlay (top-right).
            if slot.isTarget {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "sparkle")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(3)
                    }
                    Spacer()
                }
                .frame(width: totalWidth, height: cellHeight)
            }
        }
        .frame(width: totalWidth, height: cellHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            slot.productId == nil
                ? String(localized: "Slot \(slot.itemNumber), empty")
                : String(localized: "Slot \(slot.itemNumber)")
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
    let cellWidth: CGFloat
    let cellHeight: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(.secondary.opacity(0.5))
            .frame(width: cellWidth, height: cellHeight)
            .accessibilityHidden(true)
    }
}

/// Header view in the picker sheet: renders the full machine layout as a
/// grid of `MachineGridCell` + `MachineGridGap`. Cells are tappable via
/// `onSlotTap`; gaps are not.
///
/// Sizing: cellHeight is fixed at 56pt so product icons have generous
/// vertical room. cellWidth adapts to the container width via
/// `GeometryReader` so the grid always uses the full available row width
/// on any device — no horizontal scroll, no side margins. The grid renders
/// every row at its full height; the outer `List` handles overall scroll
/// so the user never sub-scrolls within the grid itself.
struct MachineLayoutGrid: View {
    let layout: MachineGridLayout
    let onSlotTap: (MachineGridSlot) -> Void

    private let cellHeight: CGFloat = 56
    private let interitemSpacing: CGFloat = 4
    private let rowSpacing: CGFloat = 4
    private let verticalPadding: CGFloat = 8

    private var totalHeight: CGFloat {
        let rows = layout.rowCount
        let rowsHeight = CGFloat(rows) * cellHeight + CGFloat(max(0, rows - 1)) * rowSpacing
        return rowsHeight + verticalPadding * 2
    }

    var body: some View {
        GeometryReader { geo in
            let columns = max(1, layout.columnsPerRow)
            let spacingTotal = CGFloat(columns - 1) * interitemSpacing
            let cellWidth = max(0, (geo.size.width - spacingTotal) / CGFloat(columns))

            gridContent(cellWidth: cellWidth)
        }
        .frame(height: totalHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Machine layout, \(layout.rowCount) rows"))
    }

    @ViewBuilder
    private func gridContent(cellWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(0..<layout.rowCount, id: \.self) { row in
                rowView(row: row, cellWidth: cellWidth)
            }
        }
        .padding(.vertical, verticalPadding)
    }

    @ViewBuilder
    private func rowView(row: Int, cellWidth: CGFloat) -> some View {
        HStack(spacing: interitemSpacing) {
            rowCells(row: row, cellWidth: cellWidth)
        }
    }

    /// Walk columns 0..9 deterministically. A slot at column c with width w
    /// emits one cell at column c and advances the cursor by w. A column
    /// between occupied positions that has no slot is emitted as a dashed
    /// gap. Columns past the last occupied position emit invisible spacers
    /// to keep rows horizontally aligned.
    ///
    /// Returns an ordered array of (column-index, view) pairs ready for
    /// `ForEach`. This is a plain function (not @ViewBuilder) so the
    /// `while`/`var` imperative logic is valid.
    private func columnContent(row: Int, cellWidth: CGFloat) -> [(id: Int, view: AnyView)] {
        let slotsInRow = layout.slots
            .filter { $0.row == row }
            .sorted { $0.column < $1.column }
        let lastOccupiedColumn = slotsInRow.last.map { $0.column + $0.width - 1 } ?? -1

        var result: [(id: Int, view: AnyView)] = []
        var c = 0
        var slotIdx = 0

        while c < layout.columnsPerRow {
            if slotIdx < slotsInRow.count, slotsInRow[slotIdx].column == c {
                let slot = slotsInRow[slotIdx]
                result.append((c, AnyView(
                    Button {
                        onSlotTap(slot)
                    } label: {
                        MachineGridCell(
                            slot: slot,
                            cellWidth: cellWidth,
                            cellHeight: cellHeight,
                            interitemSpacing: interitemSpacing
                        )
                    }
                    .buttonStyle(.plain)
                )))
                c += slot.width
                slotIdx += 1
            } else if c <= lastOccupiedColumn {
                result.append((c, AnyView(
                    MachineGridGap(cellWidth: cellWidth, cellHeight: cellHeight)
                )))
                c += 1
            } else {
                result.append((c, AnyView(
                    Color.clear.frame(width: cellWidth, height: cellHeight)
                )))
                c += 1
            }
        }
        return result
    }

    @ViewBuilder
    private func rowCells(row: Int, cellWidth: CGFloat) -> some View {
        let items = columnContent(row: row, cellWidth: cellWidth)
        HStack(spacing: interitemSpacing) {
            ForEach(items, id: \.id) { entry in
                entry.view
            }
        }
    }
}

// MARK: - Previews

#Preview("MachineGridLayout — wide-slot computation") {
    // Sample row 0 (slots 10, 12, 13, 15) and row 1 (slot 20).
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
            cellWidth: 40, cellHeight: 56, interitemSpacing: 4
        )
        MachineGridCell(
            slot: MachineGridSlot(
                id: UUID(), itemNumber: 13, row: 0, column: 3, width: 2,
                productId: UUID(), productImagePath: nil, isTarget: false
            ),
            cellWidth: 40, cellHeight: 56, interitemSpacing: 4
        )
        MachineGridCell(
            slot: MachineGridSlot(
                id: targetId, itemNumber: 15, row: 0, column: 5, width: 1,
                productId: UUID(), productImagePath: nil, isTarget: true
            ),
            cellWidth: 40, cellHeight: 56, interitemSpacing: 4
        )
        MachineGridCell(
            slot: MachineGridSlot(
                id: unassignedId, itemNumber: 16, row: 0, column: 6, width: 1,
                productId: nil, productImagePath: nil, isTarget: false
            ),
            cellWidth: 40, cellHeight: 56, interitemSpacing: 4
        )
        MachineGridGap(cellWidth: 40, cellHeight: 56)
    }
    .padding()
}

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
