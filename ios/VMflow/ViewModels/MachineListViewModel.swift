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

            // 2. Fetch today's sales
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: Date())
            let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let recentSales: [Sale] = try await client
                .from("sales")
                .select("id, created_at, item_price, item_number, machine_id, embedded_id, channel")
                .gte("created_at", value: formatter.string(from: startOfYesterday))
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

            // 5. Build MachineStats
            var stats: [MachineStats] = []

            for machine in machines {
                var ms = MachineStats(machine: machine)

                // Sales
                let machineSales = salesByMachine[machine.id] ?? []
                for sale in machineSales {
                    let price = sale.itemPrice ?? 0
                    if sale.createdAt >= startOfToday {
                        ms.todayRevenue += price
                        ms.todaySalesCount += 1
                    } else {
                        ms.yesterdayRevenue += price
                        ms.yesterdaySalesCount += 1
                    }
                }

                // Last sale
                ms.lastSaleAt = machineSales.max(by: { $0.createdAt < $1.createdAt })?.createdAt

                // Trays / stock
                let machineTrays = traysByMachine[machine.id] ?? []
                ms.totalTrays = machineTrays.count
                ms.emptyTrays = machineTrays.filter { $0.isEmpty }.count
                ms.lowTrays = machineTrays.filter { $0.isBelowMinStock && !$0.isEmpty }.count

                let totalCapacity = machineTrays.reduce(0) { $0 + $1.capacity }
                let totalStock = machineTrays.reduce(0) { $0 + $1.currentStock }
                ms.stockPercent = totalCapacity > 0 ? Double(totalStock) / Double(totalCapacity) : 1.0

                // Paxcounter
                if let embeddedId = machine.embedded {
                    ms.paxcounterCount = latestPax[embeddedId]
                }

                stats.append(ms)
            }

            // Sort by urgency
            self.machines = stats.sorted { $0.sortPriority < $1.sortPriority }

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
