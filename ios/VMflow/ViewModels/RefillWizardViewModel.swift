import Foundation
import Supabase

// MARK: - Refill Data Structures

/// A machine that needs refilling, with its trays and deficit info.
struct RefillMachine: Identifiable, Equatable {
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
struct RefillTray: Identifiable, Equatable {
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

// MARK: - Refill Steps

enum RefillStep: Int, CaseIterable {
    case packing = 0
    case refill = 1
    case summary = 2

    var title: String {
        switch self {
        case .packing: return "Pack"
        case .refill: return "Refill"
        case .summary: return "Summary"
        }
    }

    var icon: String {
        switch self {
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

    @Published var currentStep: RefillStep = .packing
    @Published var machines: [RefillMachine] = []
    @Published var warehouses: [Warehouse] = []
    @Published var selectedWarehouseId: UUID?
    @Published var warehouseStock: [WarehouseProductStock] = []
    @Published var currentMachineIndex: Int = 0
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var error: String?

    // Summary stats
    @Published var machinesVisited: Int = 0
    @Published var traysRefilled: Int = 0
    @Published var totalItemsAdded: Int = 0

    private let client = SupabaseService.shared.client

    /// Machines selected for the tour (packed or to be packed).
    var packedMachines: [RefillMachine] {
        machines.filter { $0.isPacked }
    }

    /// Current machine being refilled.
    var currentMachine: RefillMachine? {
        let refillable = machines.filter { $0.isPacked && !$0.isRefilled && !$0.isSkipped }
        guard currentMachineIndex < refillable.count else { return nil }
        return refillable[currentMachineIndex]
    }

    /// Progress fraction through machines.
    var machineProgress: (current: Int, total: Int) {
        let refillable = machines.filter { $0.isPacked }
        let done = machines.filter { $0.isPacked && ($0.isRefilled || $0.isSkipped) }.count
        return (done + 1, refillable.count)
    }

    /// Total items to pack across all packed machines.
    var totalItemsToPack: Int {
        packedMachines.reduce(0) { $0 + $1.totalDeficit }
    }

    // MARK: - Load Data

    func loadData() async {
        isLoading = true
        error = nil

        do {
            // Fetch machines with embeddeds
            let allMachines: [VendingMachine] = try await client
                .from("vendingMachine")
                .select("id, name, location_lat, location_lon, embedded, country_code, embeddeds(id, status, status_at, subdomain, mac_address, firmware_version)")
                .execute()
                .value

            // Fetch all trays
            let allTrays: [Tray] = try await client
                .from("machine_trays")
                .select("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, discontinued)")
                .order("item_number", ascending: true)
                .execute()
                .value

            let traysByMachine = Dictionary(grouping: allTrays, by: { $0.machineId })

            // Build RefillMachines, only include machines with trays that need refilling
            var refillMachines: [RefillMachine] = []

            for machine in allMachines {
                let machineTrays = traysByMachine[machine.id] ?? []
                let refillTrays = machineTrays.map { tray in
                    RefillTray(tray: tray, fillAmount: tray.deficit)
                }

                // Only include if there are trays with deficit
                if refillTrays.contains(where: { $0.deficit > 0 }) {
                    refillMachines.append(RefillMachine(machine: machine, trays: refillTrays))
                }
            }

            // Sort by urgency: machines with empty trays first, then by total deficit
            refillMachines.sort { a, b in
                let aEmpty = a.trays.filter { $0.tray.isEmpty }.count
                let bEmpty = b.trays.filter { $0.tray.isEmpty }.count
                if aEmpty != bEmpty { return aEmpty > bEmpty }
                return a.totalDeficit > b.totalDeficit
            }

            self.machines = refillMachines

            // Fetch warehouses
            warehouses = try await client
                .from("warehouses")
                .select("id, name, address, notes, company_id")
                .execute()
                .value

            if let firstWarehouse = warehouses.first {
                selectedWarehouseId = firstWarehouse.id
                await loadWarehouseStock(warehouseId: firstWarehouse.id)
            }

        } catch {
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

    func toggleMachinePacked(machineId: UUID) {
        guard let index = machines.firstIndex(where: { $0.id == machineId }) else { return }
        machines[index].isPacked.toggle()
    }

    func packAllMachines() {
        for i in machines.indices {
            machines[i].isPacked = true
        }
    }

    // MARK: - Step Navigation

    func startTour() {
        guard packedMachines.count > 0 else { return }
        currentMachineIndex = 0
        currentStep = .refill
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
    func confirmRefill(machineId: UUID) async {
        guard let mi = machines.firstIndex(where: { $0.id == machineId }) else { return }

        isSaving = true
        var itemsAdded = 0
        var traysCount = 0

        for tray in machines[mi].trays where tray.fillAmount > 0 {
            let newStock = tray.tray.currentStock + tray.fillAmount
            do {
                try await client
                    .from("machine_trays")
                    .update(["current_stock": newStock])
                    .eq("id", value: tray.tray.id.uuidString)
                    .execute()

                itemsAdded += tray.fillAmount
                traysCount += 1
            } catch {
                self.error = error.localizedDescription
            }
        }

        machines[mi].isRefilled = true
        totalItemsAdded += itemsAdded
        traysRefilled += traysCount
        machinesVisited += 1

        isSaving = false
        advanceToNextMachine()
    }

    /// Skip the current machine.
    func skipMachine(machineId: UUID) {
        guard let mi = machines.firstIndex(where: { $0.id == machineId }) else { return }
        machines[mi].isSkipped = true
        advanceToNextMachine()
    }

    private func advanceToNextMachine() {
        let remaining = machines.filter { $0.isPacked && !$0.isRefilled && !$0.isSkipped }
        if remaining.isEmpty {
            currentStep = .summary
        }
        // currentMachineIndex stays at 0 since we always look at the first remaining
        currentMachineIndex = 0
    }

    // MARK: - Reset

    func reset() {
        currentStep = .packing
        currentMachineIndex = 0
        machinesVisited = 0
        traysRefilled = 0
        totalItemsAdded = 0
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
