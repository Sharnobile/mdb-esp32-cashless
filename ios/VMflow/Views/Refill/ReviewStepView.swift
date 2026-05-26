import SwiftUI

/// Review step: shows discontinued/expired products and lets user pick replacements or skip.
struct ReviewStepView: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    /// Tracks which tray's picker sheet is open (by tray ID).
    @State private var pickerTrayId: UUID?
    @State private var selectedProduct: ProductSelection?

    struct ProductSelection: Identifiable {
        let id: UUID
        let name: String
        let imagePath: String?
        let sellprice: Double?
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    // Header
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title)
                            .foregroundStyle(.orange)
                        Text("Product Review")
                            .font(.title3.bold())
                        Text("The following trays need attention — discontinued, expired, out-of-stock, or unassigned products. Choose a replacement or skip.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    ForEach(viewModel.replacements) { suggestion in
                        replacementCard(suggestion)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 100)
            }

            // Bottom Bar
            bottomBar
        }
        .sheet(item: $pickerTrayId) { trayId in
            NavigationStack {
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
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { pickerTrayId = nil }
                    }
                }
            }
            .presentationDetents([.large])
        }
        .sheet(item: $selectedProduct) { sel in
            ProductDetailSheet(
                productId: sel.id,
                fallbackName: sel.name,
                fallbackImagePath: sel.imagePath,
                fallbackSellprice: sel.sellprice
            )
        }
    }

    // MARK: - Replacement Card

    private func replacementCard(_ suggestion: ReplacementSuggestion) -> some View {
        let isUnassigned = suggestion.reason == .unassigned

        return VStack(spacing: 12) {
            // Current product header
            HStack(spacing: 12) {
                // Slot badge
                Text("\(suggestion.slotNumber)")
                    .font(.caption.bold())
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(badgeColor(for: suggestion.reason)))

                if isUnassigned {
                    // Placeholder icon in lieu of a product image.
                    Image(systemName: "questionmark.square.dashed")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.currentProductName)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 6) {
                            reasonBadge(suggestion.reason)
                            Text(suggestion.machineName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if suggestion.currentStock > 0 {
                            Text("\(suggestion.currentStock) items still in machine")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Text("0 items in machine")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                    Button {
                        guard let pid = suggestion.currentProductId else { return }
                        selectedProduct = ProductSelection(
                            id: pid,
                            name: suggestion.currentProductName,
                            imagePath: suggestion.currentProductImage,
                            sellprice: nil
                        )
                    } label: {
                        HStack(spacing: 12) {
                            ProductImage(imagePath: suggestion.currentProductImage, size: 40)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.currentProductName)
                                    .font(.subheadline.weight(.semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .strikethrough(true, color: .red)
                                    .foregroundStyle(.primary)

                                HStack(spacing: 6) {
                                    reasonBadge(suggestion.reason)
                                    Text(suggestion.machineName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                if suggestion.currentStock > 0 {
                                    Text("\(suggestion.currentStock) items still in machine")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                } else {
                                    Text("0 items in machine")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }

            Divider()

            // Replacement / Skip
            if suggestion.isSkipped {
                HStack {
                    Image(systemName: "arrow.right.circle")
                        .foregroundStyle(.secondary)
                    Text(isUnassigned
                         ? "Skipped — slot stays unassigned"
                         : "Skipped — keeping current product")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo") {
                        if let idx = viewModel.replacements.firstIndex(where: { $0.trayId == suggestion.trayId }) {
                            viewModel.replacements[idx].isSkipped = false
                        }
                    }
                    .font(.subheadline.weight(.medium))
                }
            } else if let replacementId = suggestion.replacementProductId,
                      let product = viewModel.availableProducts.first(where: { $0.id == replacementId }) {
                // Already has a replacement selected — tap to change
                Button {
                    pickerTrayId = suggestion.trayId
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(.green)
                        ProductImage(imagePath: product.imagePath, size: 32)
                        Text(product.name ?? "Unknown")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.green)
                        Spacer()
                        Text("Change")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.blue)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                // Needs action — Replace/Assign or Skip
                HStack(spacing: 12) {
                    Button {
                        pickerTrayId = suggestion.trayId
                    } label: {
                        Label(
                            isUnassigned ? "Assign" : "Replace",
                            systemImage: isUnassigned ? "plus.circle" : "arrow.triangle.2.circlepath"
                        )
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        viewModel.skipReplacement(trayId: suggestion.trayId)
                    } label: {
                        Text("Skip")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }

    // MARK: - Reason Badge

    private func badgeColor(for reason: ReplacementReason) -> Color {
        switch reason {
        case .discontinued: return .red
        case .expired: return .orange
        case .noStock: return .purple
        case .unassigned: return .blue
        }
    }

    private func reasonBadge(_ reason: ReplacementReason) -> some View {
        let (text, color): (LocalizedStringKey, Color) = {
            switch reason {
            case .discontinued: return ("Discontinued", .red)
            case .expired: return ("Expired", .orange)
            case .noStock: return ("No Stock", .purple)
            case .unassigned: return ("Unassigned", .blue)
            }
        }()

        return Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    // MARK: - Existing Slots

    /// Build a map of productId → sorted slot numbers for every tray in the
    /// same machine as the tray being replaced, excluding the tray itself.
    ///
    /// Reads `viewModel.allTraysByMachine` (the unfiltered tray set) rather
    /// than `viewModel.machines[*].trays`, which only contains trays that
    /// need refill action — full/healthy trays would otherwise be missing
    /// from the picker badge even though the product is physically in the
    /// machine. Trays with `productId == nil` contribute nothing.
    private func existingSlots(forTrayId trayId: UUID) -> [UUID: [Int]] {
        guard let suggestion = viewModel.replacements.first(where: { $0.trayId == trayId })
        else { return [:] }

        let machineTrays = viewModel.allTraysByMachine[suggestion.machineId] ?? []

        var result: [UUID: [Int]] = [:]
        for tray in machineTrays where tray.id != trayId {
            guard let productId = tray.productId else { continue }
            result[productId, default: []].append(tray.itemNumber)
        }
        for key in result.keys {
            result[key]?.sort()
        }
        return result
    }

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

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                // Skip all
                Button {
                    Task { await viewModel.skipReview() }
                } label: {
                    Text("Skip Rest")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)

                Spacer()

                // Continue
                Button {
                    Task { await viewModel.applyReplacementsAndContinue() }
                } label: {
                    if viewModel.isSaving {
                        ProgressView()
                            .tint(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                    } else {
                        let hasReplacements = viewModel.replacements.contains { $0.replacementProductId != nil }
                        Label(
                            hasReplacements ? "Apply & Continue" : "Continue",
                            systemImage: "arrow.right.circle.fill"
                        )
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.allReplacementsHandled || viewModel.isSaving)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

// MARK: - UUID Identifiable for sheet(item:)

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

// MARK: - Slot Badge Label

/// Format a list of slot numbers into a compact pill label.
///
/// - 1 slot: `"Slot 3"`
/// - 2–3 slots: `"Slot 3, 7"` / `"Slot 3, 7, 9"`
/// - 4+ slots: `"Slot 3, 7, 9 +2"` — first three + remainder count
///
/// The input is sorted ascending before rendering, so callers don't have to
/// pre-sort. Returns an empty string for an empty input; callers should
/// treat that as "no pill".
func slotBadgeLabel(_ slots: [Int]) -> String {
    let sorted = slots.sorted()
    guard !sorted.isEmpty else { return "" }
    if sorted.count <= 3 {
        return "Slot \(sorted.map(String.init).joined(separator: ", "))"
    }
    let first = sorted.prefix(3).map(String.init).joined(separator: ", ")
    let extra = sorted.count - 3
    return "Slot \(first) +\(extra)"
}

// MARK: - Replacement Product Picker

struct ReplacementProductPicker: View {
    let products: [Product]
    let selectedProductId: UUID?
    let existingSlotsByProduct: [UUID: [Int]]
    let machineLayout: MachineGridLayout
    let onSelect: (UUID) -> Void

    @State private var searchText = ""
    @State private var highlightedProductId: UUID?

    private var filteredProducts: [Product] {
        guard !searchText.isEmpty else { return products }
        let query = searchText.lowercased()
        return products
            .compactMap { product -> (Product, Int)? in
                guard let name = product.name?.lowercased() else { return nil }
                if let score = fuzzyMatch(query: query, target: name) {
                    return (product, score)
                }
                return nil
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private func fuzzyMatch(query: String, target: String) -> Int? {
        var score = 0
        var targetIdx = target.startIndex
        var lastMatchIdx: String.Index?

        for ch in query {
            guard let found = target[targetIdx...].firstIndex(of: ch) else { return nil }
            let distance = target.distance(from: targetIdx, to: found)
            if lastMatchIdx != nil { score += distance }
            if lastMatchIdx == nil { score += distance }
            lastMatchIdx = found
            targetIdx = target.index(after: found)
        }
        return score
    }

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
}

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
    ///
    /// Returns an ordered array of (column-index, view) pairs ready for
    /// `ForEach`. This is a plain function (not @ViewBuilder) so the
    /// `while`/`var` imperative logic is valid.
    private func columnContent(row: Int) -> [(id: Int, view: AnyView)] {
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
                            cellSize: cellSize,
                            interitemSpacing: interitemSpacing
                        )
                    }
                    .buttonStyle(.plain)
                )))
                c += slot.width
                slotIdx += 1
            } else if c <= lastOccupiedColumn {
                result.append((c, AnyView(MachineGridGap(cellSize: cellSize))))
                c += 1
            } else {
                result.append((c, AnyView(
                    Color.clear.frame(width: cellSize, height: cellSize)
                )))
                c += 1
            }
        }
        return result
    }

    @ViewBuilder
    private func rowCells(row: Int) -> some View {
        let items = columnContent(row: row)
        HStack(spacing: interitemSpacing) {
            ForEach(items, id: \.id) { entry in
                entry.view
            }
        }
    }
}

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
            machineLayout: MachineGridLayout(rowCount: 0, columnsPerRow: 10, slots: []),
            onSelect: { _ in }
        )
    }
}

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
