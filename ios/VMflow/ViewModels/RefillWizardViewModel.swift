import Foundation
import Supabase

// MARK: - Refill Data Structures

/// A machine that needs refilling, with its trays and deficit info.
struct RefillMachine: Identifiable, Equatable, Codable {
    let machine: VendingMachine
    var trays: [RefillTray]
    var isPacked: Bool = false
    var isRefilled: Bool = false
    var isSkipped: Bool = false

    var id: UUID { machine.id }

    /// Total items needed across all trays.
    var totalDeficit: Int {
        trays.reduce(0) { $0 + $1.deficit }
    }

    /// Number of trays that need refilling.
    var traysNeedingRefill: Int {
        trays.filter { $0.deficit > 0 }.count
    }

    /// Total current stock across all trays.
    var totalCurrentStock: Int {
        trays.reduce(0) { $0 + $1.tray.currentStock }
    }

    /// Total capacity across all trays.
    var totalCapacity: Int {
        trays.reduce(0) { $0 + $1.tray.capacity }
    }

    /// Overall stock percentage.
    var stockPercent: Int {
        guard totalCapacity > 0 else { return 0 }
        return Int((Double(totalCurrentStock) / Double(totalCapacity) * 100).rounded())
    }

    /// Stock health derived from tray states.
    var stockHealth: StockHealth {
        if trays.contains(where: { $0.tray.isEmpty }) { return .critical }
        if trays.contains(where: { $0.tray.isBelowMinStock }) { return .low }
        return .ok
    }

    /// Products needed with quantities (aggregated for packing).
    var productsNeeded: [PackingItem] {
        var items: [UUID: PackingItem] = [:]
        for tray in trays where tray.deficit > 0 {
            if let productId = tray.tray.productId {
                if var existing = items[productId] {
                    existing.quantity += tray.deficit
                    items[productId] = existing
                } else {
                    items[productId] = PackingItem(
                        productId: productId,
                        productName: tray.tray.productName,
                        imagePath: tray.tray.products?.imagePath,
                        quantity: tray.deficit
                    )
                }
            }
        }
        return Array(items.values).sorted { $0.productName < $1.productName }
    }
}

/// A tray within the refill flow, tracking how much to add.
struct RefillTray: Identifiable, Equatable, Codable {
    let tray: Tray
    var fillAmount: Int  // How many items to add (user can adjust)

    var id: UUID { tray.id }

    var deficit: Int { tray.deficit }
    var targetStock: Int { tray.currentStock + fillAmount }
}

/// An item to pack from the warehouse.
struct PackingItem: Identifiable, Equatable {
    let productId: UUID
    let productName: String
    let imagePath: String?
    var quantity: Int

    var id: UUID { productId }
}

// MARK: - Combined Packing Structures

/// A product grouped across all machines that need it.
struct CombinedPackingItem: Identifiable, Equatable {
    let productId: UUID
    let productName: String
    let imagePath: String?
    let totalQuantity: Int
    let machineNeeds: [MachineNeed]

    var id: UUID { productId }
}

/// One machine's need for a specific product.
struct MachineNeed: Identifiable, Equatable {
    let machineId: UUID
    let machineName: String
    let quantity: Int
    let capacity: Int

    var id: UUID { machineId }
}

// MARK: - Tour Log

/// Per-machine result entry for the tour log.
struct TourLogEntry: Equatable, Codable {
    let machineId: UUID
    let machineName: String
    let traysRefilled: Int
    let totalAdded: Int
    let skipped: Bool
}

// MARK: - Product Replacement

enum ReplacementReason: String, Codable {
    case discontinued
    case expired
    case noStock  // Product has zero warehouse stock AND tray is empty
}

/// A tray that should be reviewed before packing — product is discontinued or expired.
struct ReplacementSuggestion: Identifiable, Equatable, Codable {
    let trayId: UUID
    let machineId: UUID
    let machineName: String
    let slotNumber: Int
    let currentProductId: UUID
    let currentProductName: String
    let currentProductImage: String?
    let currentStock: Int
    let reason: ReplacementReason
    var replacementProductId: UUID?
    var isSkipped: Bool = false

    var id: UUID { trayId }
}

// MARK: - Refill Steps

enum RefillStep: Int, CaseIterable {
    case review = 0
    case packing = 1
    case refill = 2
    case summary = 3

    var title: String {
        switch self {
        case .review: return String(localized: "Review")
        case .packing: return String(localized: "Pack")
        case .refill: return String(localized: "Refill")
        case .summary: return String(localized: "Summary")
        }
    }

    var icon: String {
        switch self {
        case .review: return "exclamationmark.triangle"
        case .packing: return "archivebox"
        case .refill: return "arrow.clockwise"
        case .summary: return "checkmark.circle"
        }
    }
}

// MARK: - ViewModel

/// Multi-step refill wizard: packing -> refill per machine -> summary.
@MainActor
final class RefillWizardViewModel: ObservableObject {
    // MARK: - Published State

    @Published var currentStep: RefillStep = .review
    @Published var machines: [RefillMachine] = []
    @Published var replacements: [ReplacementSuggestion] = []
    /// All active (non-discontinued) products for the replacement picker.
    @Published var availableProducts: [Product] = []
    /// Set after review step completes, so re-loading data doesn't re-trigger review.
    private var reviewCompleted = false
    @Published var warehouses: [Warehouse] = []
    @Published var selectedWarehouseId: UUID?
    @Published var warehouseStock: [WarehouseProductStock] = []
    @Published var currentMachineIndex: Int = 0
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var error: String?

    /// Packed state: machineId → Set of productIds that have been packed for that machine.
    @Published var packedItems: [UUID: Set<UUID>] = [:]

    /// Custom packing quantities: machineId → (productId → quantity).
    /// If not set, defaults to the tray deficit.
    @Published var customQuantities: [UUID: [UUID: Int]] = [:]

    /// Per-machine results recorded during the refill step.
    @Published var tourLog: [TourLogEntry] = []

    /// Unique tour identifier, used to group activity log entries.
    private(set) var tourId: String = ""

    /// Whether we found a saved tour that can be resumed.
    @Published var hasSavedTour: Bool = false

    private let client = SupabaseService.shared.client

    // MARK: - Persistence

    /// Today's date as "YYYY-MM-DD" for expiry comparisons.
    private static func todayDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static let storageKey = "refill-tour-state"
    /// Max age of persisted state: 24 hours (matches web).
    private static let maxAgeSeconds: TimeInterval = 24 * 60 * 60

    /// Codable snapshot of tour state for persistence.
    private struct PersistedTourState: Codable {
        let currentStep: String // "packing" | "refill" | "summary"
        let machines: [RefillMachine]
        let currentMachineIndex: Int
        let selectedWarehouseId: UUID?
        let tourId: String
        let tourLog: [TourLogEntry]
        let savedAt: Date
    }

    /// Lightweight static check: is there a valid saved tour?
    static var hasSavedTourState: Bool {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return false }
        guard let state = try? JSONDecoder().decode(PersistedTourState.self, from: data) else { return false }
        if Date().timeIntervalSince(state.savedAt) > maxAgeSeconds { return false }
        return state.currentStep == "refill" || state.currentStep == "summary"
    }

    /// Check for a saved tour on launch.
    func checkForSavedTour() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else {
            hasSavedTour = false
            return
        }
        do {
            let state = try JSONDecoder().decode(PersistedTourState.self, from: data)
            // Check TTL
            if Date().timeIntervalSince(state.savedAt) > Self.maxAgeSeconds {
                Self.clearSavedTour()
                hasSavedTour = false
                return
            }
            // Only resume if in refill or summary step
            hasSavedTour = (state.currentStep == "refill" || state.currentStep == "summary")
        } catch {
            hasSavedTour = false
        }
    }

    /// Resume a previously saved tour. Returns true if successful.
    func resumeTour() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return false }
        do {
            let state = try JSONDecoder().decode(PersistedTourState.self, from: data)
            if Date().timeIntervalSince(state.savedAt) > Self.maxAgeSeconds {
                Self.clearSavedTour()
                return false
            }
            guard state.currentStep == "refill" || state.currentStep == "summary" else { return false }

            // Restore state
            machines = state.machines
            currentMachineIndex = state.currentMachineIndex
            selectedWarehouseId = state.selectedWarehouseId
            tourId = state.tourId
            tourLog = state.tourLog

            switch state.currentStep {
            case "refill": currentStep = .refill
            case "summary": currentStep = .summary
            default: return false
            }

            hasSavedTour = false
            return true
        } catch {
            print("[RefillWizard] Failed to restore tour: \(error)")
            return false
        }
    }

    /// Save current tour state to UserDefaults.
    private func saveTourState() {
        guard currentStep == .refill || currentStep == .summary else { return }

        let stepString: String
        switch currentStep {
        case .review, .packing: return // nothing to persist before tour starts
        case .refill: stepString = "refill"
        case .summary: stepString = "summary"
        }

        let state = PersistedTourState(
            currentStep: stepString,
            machines: machines,
            currentMachineIndex: currentMachineIndex,
            selectedWarehouseId: selectedWarehouseId,
            tourId: tourId,
            tourLog: tourLog,
            savedAt: Date()
        )

        do {
            let data = try JSONEncoder().encode(state)
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } catch {
            print("[RefillWizard] Failed to save tour state: \(error)")
        }
    }

    /// Clear any saved tour state.
    static func clearSavedTour() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    // MARK: - Tour Summary (computed from tourLog)

    var machinesVisited: Int { tourLog.filter { !$0.skipped }.count }
    var traysRefilled: Int { tourLog.reduce(0) { $0 + $1.traysRefilled } }
    var totalItemsAdded: Int { tourLog.reduce(0) { $0 + $1.totalAdded } }
    var machinesSkipped: Int { tourLog.filter { $0.skipped }.count }

    /// Look up warehouse stock for a product.
    func warehouseStockFor(productId: UUID) -> WarehouseProductStock? {
        warehouseStock.first { $0.productId == productId }
    }

    /// Total quantity already committed (packed) for a product across ALL machines.
    func committedQuantity(productId: UUID) -> Int {
        var total = 0
        for machine in machines {
            guard packedItems[machine.id]?.contains(productId) == true else { continue }
            total += packingQuantity(machineId: machine.id, productId: productId)
        }
        return total
    }

    /// Remaining warehouse stock for a product after subtracting committed quantities.
    func remainingWarehouseStock(productId: UUID) -> Int {
        guard let stock = warehouseStockFor(productId: productId) else { return 0 }
        return max(0, stock.totalQuantity - committedQuantity(productId: productId))
    }

    /// Whether a product is completely out of warehouse stock (nothing left to pack).
    func isOutOfWarehouseStock(productId: UUID) -> Bool {
        // If no warehouse is selected or no stock data loaded, don't restrict
        guard selectedWarehouseId != nil, !warehouseStock.isEmpty else { return false }
        return remainingWarehouseStock(productId: productId) <= 0
    }

    /// Whether a specific machine-product pair is out of remaining warehouse stock.
    /// Takes into account stock already committed by other machines.
    func isOutOfStockForMachine(machineId: UUID, productId: UUID) -> Bool {
        guard selectedWarehouseId != nil, !warehouseStock.isEmpty else { return false }
        let isPacked = isMachinePacked(machineId: machineId, productId: productId)
        if isPacked {
            // Already committed — it has its allocation
            return false
        }
        return remainingWarehouseStock(productId: productId) <= 0
    }

    // MARK: - Combined Packing List

    /// Products grouped across all machines, sorted by name.
    var combinedPackingList: [CombinedPackingItem] {
        var grouped: [UUID: (name: String, image: String?, total: Int, needs: [MachineNeed])] = [:]

        for machine in machines {
            for tray in machine.trays where tray.deficit > 0 {
                guard let productId = tray.tray.productId else { continue }
                let need = MachineNeed(
                    machineId: machine.id,
                    machineName: machine.machine.displayName,
                    quantity: tray.deficit,
                    capacity: tray.tray.capacity
                )
                if var existing = grouped[productId] {
                    // Check if this machine already has an entry (multiple trays same product)
                    if let idx = existing.needs.firstIndex(where: { $0.machineId == machine.id }) {
                        let old = existing.needs[idx]
                        existing.needs[idx] = MachineNeed(
                            machineId: machine.id,
                            machineName: machine.machine.displayName,
                            quantity: old.quantity + tray.deficit,
                            capacity: old.capacity + tray.tray.capacity
                        )
                    } else {
                        existing.needs.append(need)
                    }
                    existing.total += tray.deficit
                    grouped[productId] = existing
                } else {
                    grouped[productId] = (
                        name: tray.tray.productName,
                        image: tray.tray.products?.imagePath,
                        total: tray.deficit,
                        needs: [need]
                    )
                }
            }
        }

        return grouped.map { (productId, data) in
            CombinedPackingItem(
                productId: productId,
                productName: data.name,
                imagePath: data.image,
                totalQuantity: data.total,
                machineNeeds: data.needs.sorted { $0.machineName < $1.machineName }
            )
        }.sorted { $0.productName < $1.productName }
    }

    /// Whether a specific product is packed for a specific machine.
    func isMachinePacked(machineId: UUID, productId: UUID) -> Bool {
        packedItems[machineId]?.contains(productId) ?? false
    }

    /// Whether a product is fully packed for ALL machines that need it.
    func isProductFullyPacked(_ item: CombinedPackingItem) -> Bool {
        item.machineNeeds.allSatisfy { need in
            packedItems[need.machineId]?.contains(item.productId) ?? false
        }
    }

    /// Get the packing quantity for a machine-product pair (custom or default deficit).
    func packingQuantity(machineId: UUID, productId: UUID) -> Int {
        if let custom = customQuantities[machineId]?[productId] {
            return custom
        }
        // Default: sum of deficits for this product in this machine's trays
        guard let machine = machines.first(where: { $0.id == machineId }) else { return 0 }
        return machine.trays
            .filter { $0.tray.productId == productId && $0.deficit > 0 }
            .reduce(0) { $0 + $1.deficit }
    }

    /// Max packing quantity for a machine-product pair.
    /// Capped by both tray capacity and remaining warehouse stock.
    func maxPackingQuantity(machineId: UUID, productId: UUID) -> Int {
        guard let machine = machines.first(where: { $0.id == machineId }) else { return 0 }
        let trayMax = machine.trays
            .filter { $0.tray.productId == productId }
            .reduce(0) { $0 + max(0, $1.tray.capacity - $1.tray.currentStock) }

        // If warehouse stock is loaded, also cap by remaining stock
        guard selectedWarehouseId != nil, !warehouseStock.isEmpty else { return trayMax }
        guard let stock = warehouseStockFor(productId: productId) else { return 0 }

        // Available = total warehouse stock minus what OTHER machines have committed
        let otherCommitted = machines
            .filter { $0.id != machineId && packedItems[$0.id]?.contains(productId) == true }
            .reduce(0) { $0 + packingQuantity(machineId: $1.id, productId: productId) }
        let available = max(0, stock.totalQuantity - otherCommitted)

        return min(trayMax, available)
    }

    /// Set a custom packing quantity for a machine-product pair.
    func setPackingQuantity(machineId: UUID, productId: UUID, quantity: Int) {
        let maxQty = maxPackingQuantity(machineId: machineId, productId: productId)
        let clamped = max(0, min(maxQty, quantity))
        var machineMap = customQuantities[machineId] ?? [:]
        machineMap[productId] = clamped
        customQuantities[machineId] = machineMap
    }

    /// Toggle packed state for one machine-product pair.
    /// Skips if out of warehouse stock when trying to pack.
    func togglePackedForMachine(productId: UUID, machineId: UUID) {
        var set = packedItems[machineId] ?? Set()
        if set.contains(productId) {
            set.remove(productId)
            // Clear custom quantity so it recalculates on re-pack
            customQuantities[machineId]?[productId] = nil
        } else {
            // Don't allow packing if out of stock
            guard !isOutOfStockForMachine(machineId: machineId, productId: productId) else { return }
            set.insert(productId)
            // Auto-cap the quantity to remaining warehouse stock
            capQuantityToWarehouseStock(machineId: machineId, productId: productId)
        }
        packedItems[machineId] = set
        syncMachinePackedState()
    }

    /// Toggle packed state for a product across ALL machines that need it.
    func togglePackedAll(productId: UUID) {
        guard let item = combinedPackingList.first(where: { $0.productId == productId }) else { return }
        let allPacked = isProductFullyPacked(item)

        if allPacked {
            // Unpack all
            for need in item.machineNeeds {
                var set = packedItems[need.machineId] ?? Set()
                set.remove(productId)
                packedItems[need.machineId] = set
                customQuantities[need.machineId]?[productId] = nil
            }
        } else {
            // Pack all (with stock-aware capping, in urgency order)
            for need in item.machineNeeds {
                guard !isOutOfStockForMachine(machineId: need.machineId, productId: productId) else { continue }
                var set = packedItems[need.machineId] ?? Set()
                set.insert(productId)
                packedItems[need.machineId] = set
                capQuantityToWarehouseStock(machineId: need.machineId, productId: productId)
            }
        }
        syncMachinePackedState()
    }

    /// Pack all products for all machines (stock-aware).
    func packEverything() {
        for item in combinedPackingList {
            for need in item.machineNeeds {
                guard !isOutOfStockForMachine(machineId: need.machineId, productId: item.productId) else { continue }
                var set = packedItems[need.machineId] ?? Set()
                set.insert(item.productId)
                packedItems[need.machineId] = set
                capQuantityToWarehouseStock(machineId: need.machineId, productId: item.productId)
            }
        }
        syncMachinePackedState()
    }

    /// Cap the packing quantity for a machine-product pair to available warehouse stock.
    private func capQuantityToWarehouseStock(machineId: UUID, productId: UUID) {
        guard selectedWarehouseId != nil, !warehouseStock.isEmpty else { return }
        let maxQty = maxPackingQuantity(machineId: machineId, productId: productId)
        let currentQty = packingQuantity(machineId: machineId, productId: productId)
        if currentQty > maxQty {
            setPackingQuantity(machineId: machineId, productId: productId, quantity: maxQty)
        }
    }

    /// Sync machine isPacked flag: a machine is packed when at least one product is checked.
    private func syncMachinePackedState() {
        for i in machines.indices {
            let machine = machines[i]
            let packedProductIds = packedItems[machine.id] ?? Set()
            let neededProductIds = Set(machine.trays.compactMap { $0.tray.productId }.filter { pid in
                machine.trays.contains { $0.tray.productId == pid && $0.deficit > 0 }
            })
            machines[i].isPacked = !neededProductIds.isDisjoint(with: packedProductIds)
        }
    }

    /// Machines selected for the tour (all products packed).
    var packedMachines: [RefillMachine] {
        machines.filter { $0.isPacked }
    }

    /// Machines still remaining in the refill tour (packed, not yet done).
    var remainingMachines: [RefillMachine] {
        machines.filter { $0.isPacked && !$0.isRefilled && !$0.isSkipped }
    }

    /// Current machine being refilled.
    var currentMachine: RefillMachine? {
        let refillable = remainingMachines
        guard currentMachineIndex < refillable.count else { return nil }
        return refillable[currentMachineIndex]
    }

    /// Jump to a specific machine in the remaining list.
    func selectMachine(_ machineId: UUID) {
        let refillable = remainingMachines
        if let idx = refillable.firstIndex(where: { $0.id == machineId }) {
            currentMachineIndex = idx
        }
    }

    /// Progress fraction through machines.
    var machineProgress: (current: Int, total: Int) {
        let refillable = machines.filter { $0.isPacked }
        let done = machines.filter { $0.isPacked && ($0.isRefilled || $0.isSkipped) }.count
        return (min(done + 1, refillable.count), refillable.count)
    }

    /// Total items to pack across all packed machines (respects custom quantities).
    var totalItemsToPack: Int {
        var total = 0
        for machine in packedMachines {
            let productIds = Set(machine.trays.compactMap { $0.tray.productId })
            for productId in productIds {
                total += packingQuantity(machineId: machine.id, productId: productId)
            }
        }
        return total
    }

    // MARK: - Load Data

    func loadData() async {
        isLoading = true
        error = nil

        do {
            // Fetch machines with embeddeds
            print("[RefillWizard] Fetching machines...")
            let allMachines: [VendingMachine] = try await client
                .from("vendingMachine")
                .select("id, name, location_lat, location_lon, embedded, country_code, embeddeds(id, status, status_at, subdomain, mac_address, firmware_version)")
                .execute()
                .value
            print("[RefillWizard] Fetched \(allMachines.count) machines")

            // Fetch all trays
            print("[RefillWizard] Fetching trays...")
            let allTrays: [Tray] = try await client
                .from("machine_trays")
                .select("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, discontinued)")
                .order("item_number", ascending: true)
                .execute()
                .value
            print("[RefillWizard] Fetched \(allTrays.count) trays")

            let traysByMachine = Dictionary(grouping: allTrays, by: { $0.machineId })

            // Build RefillMachines using the same logic as the web app:
            // 1. A machine is only included if it has at least one empty or low (below min_stock) tray
            // 2. Trays included: empty + low + fill_when_below (only if machine has critical trays)
            var refillMachines: [RefillMachine] = []

            for machine in allMachines {
                let machineTrays = traysByMachine[machine.id] ?? []

                let hasEmptyOrLow = machineTrays.contains { $0.isEmpty || $0.isBelowMinStock }
                guard hasEmptyOrLow else { continue }

                // Collect trays that need refilling:
                // - Empty trays (critical)
                // - Low trays (below min_stock)
                // - Fill-when-below trays (only if machine already has critical/low trays)
                let refillTrays: [RefillTray] = machineTrays.compactMap { tray in
                    guard tray.deficit > 0 else { return nil }

                    let isCriticalOrLow = tray.isEmpty || tray.isBelowMinStock
                    let isBelowFillThreshold = tray.isBelowFillThreshold

                    guard isCriticalOrLow || isBelowFillThreshold else { return nil }
                    return RefillTray(tray: tray, fillAmount: tray.deficit)
                }

                guard !refillTrays.isEmpty else { continue }
                refillMachines.append(RefillMachine(machine: machine, trays: refillTrays))
            }

            // Sort by urgency: machines with empty trays first, then by total deficit
            refillMachines.sort { a, b in
                let aEmpty = a.trays.filter { $0.tray.isEmpty }.count
                let bEmpty = b.trays.filter { $0.tray.isEmpty }.count
                if aEmpty != bEmpty { return aEmpty > bEmpty }
                return a.totalDeficit > b.totalDeficit
            }

            self.machines = refillMachines

            // Fetch warehouses first (needed for stock-based detection)
            print("[RefillWizard] Fetching warehouses...")
            warehouses = try await client
                .from("warehouses")
                .select("id, name, address, notes, company_id")
                .execute()
                .value
            print("[RefillWizard] Fetched \(warehouses.count) warehouses")

            if let firstWarehouse = warehouses.first {
                selectedWarehouseId = firstWarehouse.id
                await loadWarehouseStock(warehouseId: firstWarehouse.id)
            }

            // Detect trays needing product replacement (only on first load, not after review)
            if !reviewCompleted {
                // Fetch available (active) products for the replacement picker
                let activeProducts: [Product] = try await client
                    .from("products")
                    .select("id, name, image_path, discontinued, sellprice, category")
                    .or("discontinued.is.null,discontinued.eq.false")
                    .order("name", ascending: true)
                    .execute()
                    .value
                self.availableProducts = activeProducts

                // Build warehouse stock lookup for "no stock" detection
                let warehouseProductIds = Set(warehouseStock.filter { $0.totalQuantity > 0 }.map(\.productId))

                // Detect expired products: all warehouse batches for a product have expired
                var expiredProductIds: Set<UUID> = []
                if let wId = selectedWarehouseId {
                    let allBatches: [WarehouseStockBatch] = try await client
                        .from("warehouse_stock_batches")
                        .select("id, warehouse_id, product_id, quantity, batch_number, expiration_date")
                        .eq("warehouse_id", value: wId.uuidString)
                        .gt("quantity", value: 0)
                        .execute()
                        .value

                    let today = Self.todayDateString()
                    let batchesByProduct = Dictionary(grouping: allBatches, by: { $0.productId })
                    for (productId, batches) in batchesByProduct {
                        let allHaveExpiry = batches.allSatisfy { $0.expirationDate != nil && !$0.expirationDate!.isEmpty }
                        let allExpired = batches.allSatisfy { batch in
                            guard let expDate = batch.expirationDate, !expDate.isEmpty else { return false }
                            return expDate < today
                        }
                        if allHaveExpiry && allExpired {
                            expiredProductIds.insert(productId)
                        }
                    }
                }

                // Scan ALL trays for replacement candidates
                var suggestions: [ReplacementSuggestion] = []
                var seenTrayIds: Set<UUID> = []

                for machine in allMachines {
                    let machineTrays = traysByMachine[machine.id] ?? []
                    for tray in machineTrays {
                        guard let productId = tray.productId else { continue }
                        guard !seenTrayIds.contains(tray.id) else { continue }

                        var reason: ReplacementReason?

                        // 1) Discontinued + empty → must replace
                        if tray.isDiscontinued && tray.currentStock == 0 {
                            reason = .discontinued
                        }
                        // 2) Expired product (all warehouse batches expired) → any stock level
                        else if expiredProductIds.contains(productId) {
                            reason = .expired
                        }
                        // 3) No warehouse stock + empty tray → can't refill, suggest replacement
                        else if tray.currentStock == 0 && !warehouseProductIds.contains(productId) {
                            reason = .noStock
                        }

                        if let reason {
                            seenTrayIds.insert(tray.id)
                            suggestions.append(ReplacementSuggestion(
                                trayId: tray.id,
                                machineId: machine.id,
                                machineName: machine.displayName,
                                slotNumber: tray.itemNumber,
                                currentProductId: productId,
                                currentProductName: tray.productName,
                                currentProductImage: tray.products?.imagePath,
                                currentStock: tray.currentStock,
                                reason: reason
                            ))
                        }
                    }
                }

                self.replacements = suggestions
                print("[RefillWizard] Found \(suggestions.count) replacement suggestions")

                // If no replacements needed, skip review step
                if suggestions.isEmpty {
                    currentStep = .packing
                } else {
                    currentStep = .review
                }
            }

        } catch {
            print("[RefillWizard] Error: \(error)")
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    /// Load stock for a specific warehouse.
    func loadWarehouseStock(warehouseId: UUID) async {
        do {
            let batches: [WarehouseStockBatch] = try await client
                .from("warehouse_stock_batches")
                .select("id, warehouse_id, product_id, quantity, batch_number, expiration_date")
                .eq("warehouse_id", value: warehouseId.uuidString)
                .gt("quantity", value: 0)
                .execute()
                .value

            // Aggregate by product
            var stockMap: [UUID: Int] = [:]
            for batch in batches {
                stockMap[batch.productId, default: 0] += batch.quantity
            }

            // Fetch product details
            let productIds = Array(stockMap.keys)
            guard !productIds.isEmpty else {
                warehouseStock = []
                return
            }

            let products: [Product] = try await client
                .from("products")
                .select("id, name, image_path, discontinued, sellprice")
                .in("id", values: productIds.map { $0.uuidString })
                .execute()
                .value

            warehouseStock = products.compactMap { product in
                guard let qty = stockMap[product.id] else { return nil }
                return WarehouseProductStock(
                    productId: product.id,
                    productName: product.name ?? "Unknown",
                    totalQuantity: qty,
                    imagePath: product.imagePath
                )
            }.sorted { $0.productName < $1.productName }

        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Packing Step Actions

    // MARK: - Review Step Actions

    /// Set a replacement product for a tray.
    func setReplacement(trayId: UUID, productId: UUID) {
        guard let idx = replacements.firstIndex(where: { $0.trayId == trayId }) else { return }
        replacements[idx].replacementProductId = productId
        replacements[idx].isSkipped = false
    }

    /// Skip replacing a specific tray.
    func skipReplacement(trayId: UUID) {
        guard let idx = replacements.firstIndex(where: { $0.trayId == trayId }) else { return }
        replacements[idx].isSkipped = true
        replacements[idx].replacementProductId = nil
    }

    /// Whether all replacements have been handled (replaced or skipped).
    var allReplacementsHandled: Bool {
        replacements.allSatisfy { $0.replacementProductId != nil || $0.isSkipped }
    }

    /// Apply replacements to the database and proceed to packing.
    func applyReplacementsAndContinue() async {
        let toReplace = replacements.filter { $0.replacementProductId != nil }
        guard allReplacementsHandled else { return }

        isSaving = true

        do {
            for suggestion in toReplace {
                guard let newProductId = suggestion.replacementProductId else { continue }
                try await client
                    .from("machine_trays")
                    .update(["product_id": newProductId.uuidString])
                    .eq("id", value: suggestion.trayId.uuidString)
                    .execute()
            }

            // Reload machine data to reflect the new products
            reviewCompleted = true
            await loadData()
            currentStep = .packing
        } catch {
            self.error = error.localizedDescription
        }

        isSaving = false
    }

    /// Skip all remaining unhandled replacements, then apply any already-chosen replacements and continue.
    func skipReview() async {
        // Mark only unhandled entries as skipped — keep already-chosen replacements
        for idx in replacements.indices {
            if replacements[idx].replacementProductId == nil && !replacements[idx].isSkipped {
                replacements[idx].isSkipped = true
            }
        }
        await applyReplacementsAndContinue()
    }

    /// Navigate back to a previous step (tapped via step indicator).
    func navigateToStep(_ step: RefillStep) {
        guard step.rawValue < currentStep.rawValue else { return }
        if step == .review {
            reviewCompleted = false
        }
        currentStep = step
    }

    func toggleMachinePacked(machineId: UUID) {
        guard let index = machines.firstIndex(where: { $0.id == machineId }) else { return }
        machines[index].isPacked.toggle()
    }

    func packAllMachines() {
        packEverything()
    }

    // MARK: - Step Navigation

    func startTour() async {
        guard packedMachines.count > 0 else { return }

        isSaving = true
        tourId = UUID().uuidString
        tourLog = []

        // Apply custom packing quantities to tray fillAmounts.
        // Trays for products that were NOT packed get fillAmount = 0.
        for mi in machines.indices {
            let machine = machines[mi]
            guard machine.isPacked else { continue }
            let packedProductIds = packedItems[machine.id] ?? Set()

            for ti in machines[mi].trays.indices {
                let tray = machines[mi].trays[ti]
                guard let productId = tray.tray.productId else { continue }

                // Zero out trays for products that were not packed
                guard packedProductIds.contains(productId) else {
                    machines[mi].trays[ti].fillAmount = 0
                    continue
                }

                // Apply custom quantity if set
                guard let machineCustom = customQuantities[machine.id],
                      let customQty = machineCustom[productId] else { continue }

                // Distribute custom quantity across trays with same product
                let productTrays = machines[mi].trays.enumerated().filter {
                    $0.element.tray.productId == productId && $0.element.deficit > 0
                }
                let totalDeficit = productTrays.reduce(0) { $0 + $1.element.deficit }
                guard totalDeficit > 0 else { continue }

                // Proportional distribution
                let ratio = Double(customQty) / Double(totalDeficit)
                for (idx, pt) in productTrays {
                    let newAmount = Int((Double(pt.deficit) * ratio).rounded())
                    let maxFill = pt.tray.capacity - pt.tray.currentStock
                    machines[mi].trays[idx].fillAmount = max(0, min(maxFill, newAmount))
                }
            }
        }

        // Deduct warehouse stock (FIFO) for all packed products — matches web startTour()
        if let warehouseId = selectedWarehouseId {
            await deductWarehouseStock(warehouseId: warehouseId)
        }

        currentMachineIndex = 0
        isSaving = false
        currentStep = .refill
        saveTourState()
    }

    /// Deduct warehouse stock via the `deduct_warehouse_stock_fifo` RPC for each packed product-machine pair.
    private func deductWarehouseStock(warehouseId: UUID) async {
        // Collect deductions from packed machines
        struct Deduction {
            let machineId: UUID
            let productId: UUID
            let quantity: Int
        }

        var deductions: [Deduction] = []
        for machine in machines where machine.isPacked {
            let productIds = Set(machine.trays.compactMap { $0.tray.productId })
            for productId in productIds {
                let qty = packingQuantity(machineId: machine.id, productId: productId)
                guard qty > 0 else { continue }
                deductions.append(Deduction(machineId: machine.id, productId: productId, quantity: qty))
            }
        }

        guard !deductions.isEmpty else { return }

        // Get user info for audit trail
        let userId: String? = await {
            try? await client.auth.session.user.id.uuidString
        }()
        let userEmail: String? = await {
            try? await client.auth.session.user.email
        }()

        // Execute deductions (non-blocking errors — warehouse deduction failure shouldn't block the tour)
        for d in deductions {
            do {
                try await client.rpc(
                    "deduct_warehouse_stock_fifo",
                    params: [
                        "p_warehouse_id": AnyJSON.string(warehouseId.uuidString),
                        "p_product_id": AnyJSON.string(d.productId.uuidString),
                        "p_quantity": AnyJSON.integer(d.quantity),
                        "p_user_id": userId.map { AnyJSON.string($0) } ?? AnyJSON.null,
                        "p_reference_id": AnyJSON.string(d.machineId.uuidString),
                        "p_notes": AnyJSON.string("Refill tour"),
                        "p_metadata": AnyJSON.object(["_user_email": userEmail.map { AnyJSON.string($0) } ?? AnyJSON.null])
                    ]
                ).execute()
            } catch {
                print("[RefillWizard] Warehouse deduction failed for product \(d.productId): \(error)")
                // Non-critical: continue tour even if deduction fails
            }
        }
    }

    /// Adjust the fill amount for a tray in the current machine.
    func adjustFillAmount(machineId: UUID, trayId: UUID, amount: Int) {
        guard let mi = machines.firstIndex(where: { $0.id == machineId }),
              let ti = machines[mi].trays.firstIndex(where: { $0.id == trayId }) else { return }

        let tray = machines[mi].trays[ti]
        let maxFill = tray.tray.capacity - tray.tray.currentStock
        machines[mi].trays[ti].fillAmount = max(0, min(maxFill, amount))
    }

    /// Fill a single tray to capacity in the wizard.
    func fillTrayToCapacity(machineId: UUID, trayId: UUID) {
        guard let mi = machines.firstIndex(where: { $0.id == machineId }),
              let ti = machines[mi].trays.firstIndex(where: { $0.id == trayId }) else { return }

        let tray = machines[mi].trays[ti]
        machines[mi].trays[ti].fillAmount = tray.tray.capacity - tray.tray.currentStock
    }

    /// Fill all trays in the current machine to capacity.
    func fillAllTrays(machineId: UUID) {
        guard let mi = machines.firstIndex(where: { $0.id == machineId }) else { return }
        for ti in machines[mi].trays.indices {
            let tray = machines[mi].trays[ti]
            machines[mi].trays[ti].fillAmount = tray.tray.capacity - tray.tray.currentStock
        }
    }

    /// Confirm refill for the current machine (writes to DB).
    /// Matches web `confirmMachineRefill()`: re-fetches fresh stock, updates trays, writes activity log.
    func confirmRefill(machineId: UUID) async {
        guard let mi = machines.firstIndex(where: { $0.id == machineId }) else { return }

        isSaving = true
        let traysToRefill = machines[mi].trays.filter { $0.fillAmount > 0 }
        let trayIds = traysToRefill.map { $0.tray.id.uuidString }
        var itemsAdded = 0
        var traysCount = 0

        // Re-fetch fresh stock to prevent data races (someone else may have refilled or a sale happened)
        var freshStockMap: [UUID: (currentStock: Int, capacity: Int)] = [:]
        if !trayIds.isEmpty {
            do {
                struct FreshTray: Decodable {
                    let id: UUID
                    let currentStock: Int
                    let capacity: Int
                    enum CodingKeys: String, CodingKey {
                        case id, capacity
                        case currentStock = "current_stock"
                    }
                }
                let freshTrays: [FreshTray] = try await client
                    .from("machine_trays")
                    .select("id, current_stock, capacity")
                    .in("id", values: trayIds)
                    .execute()
                    .value
                for ft in freshTrays {
                    freshStockMap[ft.id] = (ft.currentStock, ft.capacity)
                }
            } catch {
                print("[RefillWizard] Failed to fetch fresh stock: \(error)")
                // Fall back to stale values
            }
        }

        for tray in traysToRefill {
            let fresh = freshStockMap[tray.tray.id]
            let currentStock = fresh?.currentStock ?? tray.tray.currentStock
            let capacity = fresh?.capacity ?? tray.tray.capacity
            let newStock = min(capacity, currentStock + tray.fillAmount)
            guard newStock > currentStock else { continue }

            do {
                try await client
                    .from("machine_trays")
                    .update(["current_stock": newStock])
                    .eq("id", value: tray.tray.id.uuidString)
                    .execute()

                itemsAdded += (newStock - currentStock)
                traysCount += 1
            } catch {
                self.error = error.localizedDescription
            }
        }

        machines[mi].isRefilled = true

        // Record in tour log
        tourLog.append(TourLogEntry(
            machineId: machineId,
            machineName: machines[mi].machine.displayName,
            traysRefilled: traysCount,
            totalAdded: itemsAdded,
            skipped: false
        ))

        // Write activity log entry (non-blocking, matches web `stock_refill_tour` action)
        await writeActivityLog(
            machineId: machineId,
            machineName: machines[mi].machine.displayName,
            action: "stock_refill_tour",
            extraMetadata: [
                "trays_refilled": .integer(traysCount),
                "total_added": .integer(itemsAdded),
                "products": .array(traysToRefill.map { tray in
                    AnyJSON.object([
                        "product_id": tray.tray.productId.map { .string($0.uuidString) } ?? .null,
                        "product_name": .string(tray.tray.productName),
                        "quantity": .integer(tray.fillAmount)
                    ])
                })
            ]
        )

        isSaving = false
        advanceToNextMachine()
        saveTourState()
    }

    /// Skip the current machine.
    func skipMachine(machineId: UUID) async {
        guard let mi = machines.firstIndex(where: { $0.id == machineId }) else { return }
        machines[mi].isSkipped = true

        // Record in tour log
        tourLog.append(TourLogEntry(
            machineId: machineId,
            machineName: machines[mi].machine.displayName,
            traysRefilled: 0,
            totalAdded: 0,
            skipped: true
        ))

        // Write skip activity log entry (non-blocking)
        await writeActivityLog(
            machineId: machineId,
            machineName: machines[mi].machine.displayName,
            action: "stock_refill_tour_skip",
            extraMetadata: [:]
        )

        advanceToNextMachine()
        saveTourState()
    }

    private func advanceToNextMachine() {
        let remaining = machines.filter { $0.isPacked && !$0.isRefilled && !$0.isSkipped }
        if remaining.isEmpty {
            currentStep = .summary
        }
        // currentMachineIndex stays at 0 since we always look at the first remaining
        currentMachineIndex = 0
    }

    // MARK: - Activity Log

    /// Write an activity log entry for a refill/skip action. Non-critical — failures are silently logged.
    private func writeActivityLog(machineId: UUID, machineName: String, action: String, extraMetadata: [String: AnyJSON]) async {
        do {
            let session = try await client.auth.session
            let user = session.user
            let firstName = user.userMetadata["first_name"]?.stringValue
            let lastName = user.userMetadata["last_name"]?.stringValue
            let fullName = [firstName, lastName].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let userDisplay = fullName.isEmpty ? user.email : fullName

            // Fetch company_id from organization_members
            struct OrgMember: Decodable { let companyId: UUID; enum CodingKeys: String, CodingKey { case companyId = "company_id" } }
            let members: [OrgMember] = try await client
                .from("organization_members")
                .select("company_id")
                .eq("user_id", value: user.id.uuidString)
                .limit(1)
                .execute()
                .value
            guard let companyId = members.first?.companyId else { return }

            var metadata: [String: AnyJSON] = [
                "tour_id": .string(tourId),
                "machine_id": .string(machineId.uuidString),
                "machine_name": .string(machineName),
                "_user_email": user.email.map { .string($0) } ?? .null,
                "_user_display": userDisplay.map { .string($0) } ?? .null,
            ]
            if let warehouseId = selectedWarehouseId {
                metadata["warehouse_id"] = .string(warehouseId.uuidString)
            }
            for (key, value) in extraMetadata {
                metadata[key] = value
            }

            try await client
                .from("activity_log")
                .insert([
                    "company_id": AnyJSON.string(companyId.uuidString),
                    "user_id": AnyJSON.string(user.id.uuidString),
                    "entity_type": AnyJSON.string("stock"),
                    "entity_id": AnyJSON.string(machineId.uuidString),
                    "action": AnyJSON.string(action),
                    "metadata": AnyJSON.object(metadata)
                ])
                .execute()
        } catch {
            print("[RefillWizard] Activity log write failed: \(error)")
            // Non-critical — don't block the refill flow
        }
    }

    // MARK: - Reset

    func reset() {
        currentStep = .review
        replacements = []
        reviewCompleted = false
        currentMachineIndex = 0
        tourLog = []
        tourId = ""
        hasSavedTour = false
        packedItems = [:]
        customQuantities = [:]
        Self.clearSavedTour()
        for i in machines.indices {
            machines[i].isPacked = false
            machines[i].isRefilled = false
            machines[i].isSkipped = false
            for j in machines[i].trays.indices {
                machines[i].trays[j].fillAmount = machines[i].trays[j].tray.deficit
            }
        }
    }
}
