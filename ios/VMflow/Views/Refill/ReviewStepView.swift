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
                    remainingStock: { id in
                        // Only show stock counts when a warehouse with stock
                        // data is loaded — otherwise we'd render bogus zeros.
                        guard viewModel.selectedWarehouseId != nil,
                              !viewModel.warehouseStock.isEmpty
                        else { return nil }
                        return viewModel.remainingWarehouseStock(productId: id)
                    },
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
                // Last slot in the row extends to the row's end: gap-to-end
                // is interpreted as "this slot is wider," same as mid-row gaps.
                // E.g. row ending at item 18 (col 8) with no 19 → width 2.
                let column = tray.itemNumber % 10
                let width = nextItemNumber.map { $0 - tray.itemNumber } ?? (10 - column)
                slots.append(
                    MachineGridSlot(
                        id: tray.id,
                        itemNumber: tray.itemNumber,
                        row: row,
                        column: column,
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
    /// Remaining warehouse stock for the given product, or `nil` when the
    /// caller has no warehouse context (e.g. previews, or no warehouse
    /// selected in the refill wizard). When non-nil the row shows a
    /// stock-count pill; a value of `0` additionally fades the row to mark
    /// it as a poor replacement candidate.
    var remainingStock: (UUID) -> Int? = { _ in nil }
    /// Category UUID of the product currently in the tray being replaced.
    /// `nil` if the tray is unassigned or the current product is uncategorized.
    /// When non-nil, that category is rendered first in each stock bucket.
    var currentCategoryId: UUID? = nil
    /// Category catalogue for name lookup. Empty array is valid — uncategorized
    /// products will still render; products whose `category` UUID is not
    /// present in the array fall back to the "Uncategorized" group.
    var categories: [ProductCategory] = []
    let onSelect: (UUID) -> Void

    @State private var searchText = ""
    @State private var highlightedProductId: UUID?

    // MARK: - Grouping types

    /// Top-level grouping by warehouse stock status.
    private enum StockStatus: String {
        case inStock
        case outOfStock
    }

    /// One stock bucket containing zero or more category groups.
    private struct StockBucket: Identifiable {
        let status: StockStatus
        let categories: [CategoryGroup]
        var id: String { status.rawValue }
        /// Total product count across all categories — shown in the mega-header.
        var totalCount: Int { categories.reduce(0) { $0 + $1.products.count } }
    }

    /// One category's products inside a stock bucket. `category == nil`
    /// represents the "Uncategorized" group rendered at the end.
    private struct CategoryGroup: Identifiable {
        let category: ProductCategory?
        let isCurrent: Bool
        let products: [Product]
        var id: String { category?.id.uuidString ?? "uncategorized" }
    }

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

    // MARK: - Stock buckets pipeline

    /// Visible product structure for the picker body. Computed on every
    /// re-render — depends only on `searchText`, `products`, `remainingStock`,
    /// `existingSlotsByProduct`, `currentCategoryId`, and `categories`. Pure,
    /// no side effects.
    ///
    /// Pipeline:
    /// 1. Filter by search (existing fuzzyMatch, keep score)
    /// 2. Partition by stock (nil or >0 = inStock, ==0 = outOfStock)
    /// 3. Group by category within each bucket (current first, others A-Z, uncategorized last)
    /// 4. Sort within each (stock × category) group: not-in-machine first, then
    ///    fuzzy score (search-active only), then alphabetical
    private var stockBuckets: [StockBucket] {
        // Step 1: filter by search
        let scored: [(Product, Int?)]
        if searchText.isEmpty {
            scored = products.map { ($0, nil) }
        } else {
            let query = searchText.lowercased()
            scored = products.compactMap { product -> (Product, Int?)? in
                guard let name = product.name?.lowercased() else { return nil }
                guard let s = fuzzyMatch(query: query, target: name) else { return nil }
                return (product, s)
            }
        }

        // Step 2: partition by stock
        var inStock: [(Product, Int?)] = []
        var outOfStock: [(Product, Int?)] = []
        for entry in scored {
            if remainingStock(entry.0.id) == 0 {
                outOfStock.append(entry)
            } else {
                inStock.append(entry)
            }
        }

        // Step 3+4 for each bucket
        let inStockGroups = groupByCategory(inStock)
        let outOfStockGroups = groupByCategory(outOfStock)

        return [
            StockBucket(status: .inStock, categories: inStockGroups),
            StockBucket(status: .outOfStock, categories: outOfStockGroups)
        ].filter { !$0.categories.isEmpty }
    }

    /// Group a stock-bucket's products by category, sort categories
    /// (current → alphabetical → uncategorized), and sort products within
    /// each category. Pure function.
    private func groupByCategory(_ scored: [(Product, Int?)]) -> [CategoryGroup] {
        // Index categories by UUID for fast name lookup. `reduce(into:)`
        // is crash-safe if `categories` ever contains duplicate IDs (later
        // value wins) — unlike `Dictionary(uniqueKeysWithValues:)` which
        // traps at runtime.
        let categoryById: [UUID: ProductCategory] = categories.reduce(into: [:]) {
            $0[$1.id] = $1
        }

        // Bucket products by category UUID; nil category → uncategorized bucket
        var byCategoryId: [UUID?: [(Product, Int?)]] = [:]
        for entry in scored {
            let key = entry.0.category
            byCategoryId[key, default: []].append(entry)
        }

        // Sort products within each category bucket using the multi-key sort:
        // (not-in-machine, fuzzyScore?, alphabetical)
        func sortKey(_ entry: (Product, Int?)) -> (Bool, Int, String) {
            let inMachine = existingSlotsByProduct[entry.0.id]?.isEmpty == false
            let score = entry.1 ?? 0
            let name = entry.0.name ?? ""
            // Treat empty/nil name as last by prepending a high-codepoint marker
            let nameKey = name.isEmpty ? "\u{FFFF}" : name.lowercased()
            return (inMachine, score, nameKey)
        }
        for key in byCategoryId.keys {
            byCategoryId[key]?.sort { a, b in
                let ka = sortKey(a)
                let kb = sortKey(b)
                if ka.0 != kb.0 { return !ka.0 && kb.0 }
                if ka.1 != kb.1 { return ka.1 < kb.1 }
                return ka.2.localizedCaseInsensitiveCompare(kb.2) == .orderedAscending
            }
        }

        // Build CategoryGroup list with ordering: current → A-Z → uncategorized last
        var orderedGroups: [CategoryGroup] = []

        // 1. Current category (if any and has products)
        if let curId = currentCategoryId,
           let curCat = categoryById[curId],
           let entries = byCategoryId[curId], !entries.isEmpty {
            orderedGroups.append(
                CategoryGroup(category: curCat, isCurrent: true, products: entries.map(\.0))
            )
        }

        // 2. Other named categories alphabetically
        let otherCategoryIds = byCategoryId.keys
            .compactMap { $0 } // drop the nil key (uncategorized)
            .filter { $0 != currentCategoryId }
        let sortedOthers = otherCategoryIds
            .compactMap { id -> (UUID, ProductCategory)? in
                guard let cat = categoryById[id] else { return nil }
                return (id, cat)
            }
            .sorted { $0.1.name.localizedCaseInsensitiveCompare($1.1.name) == .orderedAscending }
        for (id, cat) in sortedOthers {
            guard let entries = byCategoryId[id], !entries.isEmpty else { continue }
            orderedGroups.append(
                CategoryGroup(category: cat, isCurrent: false, products: entries.map(\.0))
            )
        }

        // 3. Unknown-category-UUID products: products whose category UUID was
        //    set but doesn't exist in `categories`. Fold into the uncategorized
        //    bucket as a safe fallback. We deliberately DON'T filter out
        //    `k == currentCategoryId` here — if the current product's category
        //    UUID also isn't in the catalogue (rare race), those products
        //    would otherwise be dropped entirely. They land in uncategorized.
        let unknownCategoryEntries: [(Product, Int?)] = byCategoryId
            .filter { key, _ in
                guard let k = key else { return false }
                return categoryById[k] == nil
            }
            .flatMap { $0.value }

        #if DEBUG
        if !unknownCategoryEntries.isEmpty {
            let ids = Set(unknownCategoryEntries.compactMap { $0.0.category })
            print("[RefillWizard] unknown category UUID(s) in picker: \(ids)")
        }
        #endif

        // 4. Uncategorized group (nil category) + any unknown-category fallback
        var uncategorizedEntries: [(Product, Int?)] = byCategoryId[nil] ?? []
        uncategorizedEntries.append(contentsOf: unknownCategoryEntries)
        if !uncategorizedEntries.isEmpty {
            // Re-sort the merged uncategorized bucket
            uncategorizedEntries.sort { a, b in
                let ka = sortKey(a)
                let kb = sortKey(b)
                if ka.0 != kb.0 { return !ka.0 && kb.0 }
                if ka.1 != kb.1 { return ka.1 < kb.1 }
                return ka.2.localizedCaseInsensitiveCompare(kb.2) == .orderedAscending
            }
            orderedGroups.append(
                CategoryGroup(category: nil, isCurrent: false, products: uncategorizedEntries.map(\.0))
            )
        }

        return orderedGroups
    }

    // MARK: - Header row helpers

    /// Mega-header rendered above an entire stock bucket. Only shown when
    /// both `stockBuckets` are present (i.e. some products are in stock AND
    /// some are out of stock). With only one bucket, the mega-header is
    /// suppressed and category sub-headers stand alone.
    @ViewBuilder
    private func stockMegaHeader(_ bucket: StockBucket) -> some View {
        let title: String = {
            switch bucket.status {
            case .inStock: return String(localized: "In Stock")
            case .outOfStock: return String(localized: "Out of Stock")
            }
        }()

        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(bucket.totalCount)")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .listRowBackground(Color(.systemGroupedBackground))
        .listRowSeparator(.hidden)
        .selectionDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(title), \(bucket.totalCount) \(bucket.totalCount == 1 ? "product" : "products")"
        )
        .accessibilityAddTraits(.isHeader)
    }

    /// Sub-header for one category within a stock bucket. Highlights the
    /// current category with accent color and an "· aktuell" suffix.
    @ViewBuilder
    private func categorySubHeader(_ group: CategoryGroup) -> some View {
        let name: String = group.category?.name ?? String(localized: "Uncategorized")
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(group.isCurrent ? Color.accentColor : .secondary)
            if group.isCurrent {
                Text(verbatim: "· ")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("current")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.lowercase)
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
        .listRowSeparator(.hidden)
        .selectionDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(group.isCurrent ? "\(name), current category" : name)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func stockPill(_ count: Int) -> some View {
        let isZero = count <= 0
        Text("\(count) in stock")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(isZero ? Color.gray.opacity(0.18) : Color.blue.opacity(0.15)))
            .foregroundStyle(isZero ? Color.secondary : Color.blue)
            .accessibilityLabel(
                isZero
                    ? String(localized: "Out of warehouse stock")
                    : String(localized: "\(count) units in warehouse stock")
            )
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

                let buckets = stockBuckets
                let showMegaHeaders = buckets.count > 1

                Section {
                    if buckets.isEmpty, !searchText.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(buckets) { bucket in
                        if showMegaHeaders {
                            stockMegaHeader(bucket)
                        }
                        ForEach(bucket.categories) { group in
                            categorySubHeader(group)
                            ForEach(Array(group.products.enumerated()), id: \.element.id) { idx, product in
                                productRow(
                                    product: product,
                                    isLastInGroup: idx == group.products.count - 1
                                )
                            }
                        }
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

    @ViewBuilder
    private func productRow(product: Product, isLastInGroup: Bool) -> some View {
        let stock = remainingStock(product.id)
        let outOfStock = stock == 0
        Button {
            onSelect(product.id)
        } label: {
            HStack(spacing: 12) {
                ProductImage(imagePath: product.imagePath, size: 36)
                    .opacity(outOfStock ? 0.45 : 1.0)
                Text(product.name ?? "Unnamed")
                    .foregroundStyle(outOfStock ? .secondary : .primary)
                if let stock {
                    stockPill(stock)
                }
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
        .listRowSeparator(isLastInGroup ? .hidden : .visible, edges: .bottom)
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
