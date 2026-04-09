import Foundation
import Supabase

/// Fetches all vending machines with per-machine statistics (revenue, stock health).
/// Sorts machines by stock urgency: critical > low > ok.
@MainActor
final class MachineListViewModel: ObservableObject {
    @Published var machines: [MachineStats] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var searchText = ""

    private let client = SupabaseService.shared.client

    /// Filtered machines based on search text.
    var filteredMachines: [MachineStats] {
        if searchText.isEmpty { return machines }
        let query = searchText.lowercased()
        return machines.filter { $0.machine.displayName.lowercased().contains(query) }
    }

    // MARK: - Load

    func loadMachines() async {
        isLoading = true
        error = nil

        do {
            // 1. Fetch machines with embedded relation
            let machines: [VendingMachine] = try await client
                .from("vendingMachine")
                .select("id, name, location_lat, location_lon, embedded, country_code, embeddeds(id, status, status_at, subdomain, mac_address, firmware_version)")
                .execute()
                .value

            // 2. Fetch recent sales (2 weeks for weekly stats)
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: Date())
            let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!

            // Week boundaries (Monday-based)
            let weekday = calendar.component(.weekday, from: startOfToday)
            // .weekday: 1=Sun, 2=Mon, ... 7=Sat → days since Monday
            let daysSinceMonday = (weekday + 5) % 7
            let startOfThisWeek = calendar.date(byAdding: .day, value: -daysSinceMonday, to: startOfToday)!
            let startOfLastWeek = calendar.date(byAdding: .day, value: -7, to: startOfThisWeek)!

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let recentSales: [Sale] = try await client
                .from("sales")
                .select("id, created_at, item_price, item_number, machine_id, embedded_id, channel")
                .gte("created_at", value: formatter.string(from: startOfLastWeek))
                .execute()
                .value

            // Group sales by machine
            let salesByMachine = Dictionary(grouping: recentSales, by: { $0.machineId })

            // 3. Fetch all trays for stock health
            let allTrays: [Tray] = try await client
                .from("machine_trays")
                .select("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, discontinued)")
                .execute()
                .value

            let traysByMachine = Dictionary(grouping: allTrays, by: { $0.machineId })

            // 4. Fetch paxcounter data
            let paxData: [PaxcounterEntry] = try await client
                .from("paxcounter")
                .select("id, embedded_id, count, created_at")
                .order("created_at", ascending: false)
                .execute()
                .value

            // Get latest pax per embedded
            var latestPax: [UUID: Int] = [:]
            for entry in paxData {
                if let embId = entry.embeddedId, latestPax[embId] == nil {
                    latestPax[embId] = entry.count
                }
            }

            // 5. Fetch warehouse stock batches for availability info
            let stockBatches: [WarehouseStockBatchLite] = try await client
                .from("warehouse_stock_batches")
                .select("product_id, quantity")
                .gt("quantity", value: 0)
                .execute()
                .value

            var warehouseStockMap: [UUID: Int] = [:]
            for batch in stockBatches {
                warehouseStockMap[batch.productId, default: 0] += batch.quantity
            }
            let hasWarehouses = !stockBatches.isEmpty

            // 6. Build MachineStats
            var stats: [MachineStats] = []

            for machine in machines {
                var ms = MachineStats(machine: machine)

                // Sales — classify into today, yesterday, this week, last week
                let machineSales = salesByMachine[machine.id] ?? []
                for sale in machineSales {
                    let price = sale.itemPrice ?? 0
                    if sale.createdAt >= startOfToday {
                        ms.todayRevenue += price
                        ms.todaySalesCount += 1
                    } else if sale.createdAt >= startOfYesterday {
                        ms.yesterdayRevenue += price
                        ms.yesterdaySalesCount += 1
                    }
                    // Weekly buckets (includes today/yesterday)
                    if sale.createdAt >= startOfThisWeek {
                        ms.thisWeekRevenue += price
                        ms.thisWeekSalesCount += 1
                    } else if sale.createdAt >= startOfLastWeek {
                        ms.lastWeekRevenue += price
                        ms.lastWeekSalesCount += 1
                    }
                }

                // Trays / stock
                let machineTrays = traysByMachine[machine.id] ?? []
                ms.totalTrays = machineTrays.count
                ms.emptyTrays = machineTrays.filter { $0.isEmpty }.count
                ms.lowTrays = machineTrays.filter { $0.isBelowMinStock && !$0.isEmpty }.count

                let totalCapacity = machineTrays.reduce(0) { $0 + $1.capacity }
                let totalStock = machineTrays.reduce(0) { $0 + $1.currentStock }
                ms.stockPercent = totalCapacity > 0 ? Double(totalStock) / Double(totalCapacity) : 1.0

                // Build per-product deficit list
                // Group trays by productId and aggregate deficit + worst severity
                struct ProductDeficitAccum {
                    var productName: String
                    var imagePath: String?
                    var totalDeficit: Int
                    var worstSeverity: StockSeverity
                    var isDiscontinued: Bool
                    var hasEmptyTray: Bool  // at least one tray is empty
                }

                var deficitsByProduct: [UUID: ProductDeficitAccum] = [:]
                var unassignedDeficits: [ProductDeficitAccum] = []

                for tray in machineTrays {
                    let severity: StockSeverity?
                    if tray.isEmpty {
                        severity = .critical
                    } else if tray.isBelowMinStock {
                        severity = .low
                    } else if tray.isBelowFillThreshold {
                        severity = .fillBelow
                    } else {
                        severity = nil
                    }

                    guard let sev = severity else { continue }

                    if let pid = tray.productId {
                        if var existing = deficitsByProduct[pid] {
                            existing.totalDeficit += tray.deficit
                            if sev < existing.worstSeverity { existing.worstSeverity = sev }
                            if tray.isEmpty { existing.hasEmptyTray = true }
                            deficitsByProduct[pid] = existing
                        } else {
                            deficitsByProduct[pid] = ProductDeficitAccum(
                                productName: tray.productName,
                                imagePath: tray.products?.imagePath,
                                totalDeficit: tray.deficit,
                                worstSeverity: sev,
                                isDiscontinued: tray.isDiscontinued,
                                hasEmptyTray: tray.isEmpty
                            )
                        }
                    } else {
                        unassignedDeficits.append(ProductDeficitAccum(
                            productName: tray.productName,
                            imagePath: nil,
                            totalDeficit: tray.deficit,
                            worstSeverity: sev,
                            isDiscontinued: false,
                            hasEmptyTray: tray.isEmpty
                        ))
                    }
                }

                // Classify warehouse availability per product
                func warehouseAvail(for productId: UUID?, hasEmpty: Bool) -> WarehouseAvailability {
                    guard hasWarehouses else { return .unknown }
                    guard let pid = productId else { return .unknown }
                    if warehouseStockMap[pid] != nil { return .inStock }
                    return hasEmpty ? .needsSwap : .noStock
                }

                var allDeficits = deficitsByProduct.map { (pid, accum) in
                    TrayDeficit(
                        productName: accum.productName,
                        imagePath: accum.imagePath,
                        deficit: accum.totalDeficit,
                        severity: accum.worstSeverity,
                        isDiscontinued: accum.isDiscontinued,
                        warehouseAvailability: warehouseAvail(for: pid, hasEmpty: accum.hasEmptyTray)
                    )
                }
                allDeficits += unassignedDeficits.map { accum in
                    TrayDeficit(
                        productName: accum.productName,
                        imagePath: accum.imagePath,
                        deficit: accum.totalDeficit,
                        severity: accum.worstSeverity,
                        isDiscontinued: false,
                        warehouseAvailability: .unknown
                    )
                }

                // Sort: swap/noStock first (need attention), then by severity, then deficit
                allDeficits.sort { lhs, rhs in
                    let lhsSwap = lhs.warehouseAvailability == .needsSwap ? 0 : 1
                    let rhsSwap = rhs.warehouseAvailability == .needsSwap ? 0 : 1
                    if lhsSwap != rhsSwap { return lhsSwap < rhsSwap }
                    if lhs.severity != rhs.severity { return lhs.severity < rhs.severity }
                    return lhs.deficit > rhs.deficit
                }

                ms.trayDeficits = allDeficits

                // Warehouse-aware counts
                ms.swapNeededCount = deficitsByProduct.filter { (pid, accum) in
                    hasWarehouses && warehouseStockMap[pid] == nil && accum.hasEmptyTray
                }.count
                ms.noStockCount = deficitsByProduct.filter { (pid, accum) in
                    hasWarehouses && warehouseStockMap[pid] == nil && !accum.hasEmptyTray
                }.count

                // Paxcounter
                if let embeddedId = machine.embedded {
                    ms.paxcounterCount = latestPax[embeddedId]
                }

                stats.append(ms)
            }

            // Sort by urgency
            self.machines = stats.sorted { $0.sortPriority < $1.sortPriority }

        } catch is CancellationError {
            // Ignore — SwiftUI cancels refreshable tasks routinely
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - Paxcounter Model

private struct PaxcounterEntry: Codable {
    let id: UUID
    let embeddedId: UUID?
    let count: Int
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, count
        case embeddedId = "embedded_id"
        case createdAt = "created_at"
    }
}

// MARK: - Lightweight warehouse stock batch for availability queries

private struct WarehouseStockBatchLite: Codable {
    let productId: UUID
    let quantity: Int

    enum CodingKeys: String, CodingKey {
        case quantity
        case productId = "product_id"
    }
}
