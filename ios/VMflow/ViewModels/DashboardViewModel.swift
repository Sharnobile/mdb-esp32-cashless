import Foundation
import Supabase

/// Drives the Dashboard view with KPIs, 30-day chart data, and recent sales.
@MainActor
final class DashboardViewModel: ObservableObject {
    // MARK: - Published State

    @Published var todayRevenue: Double = 0
    @Published var todaySalesCount: Int = 0
    @Published var yesterdayRevenue: Double = 0
    @Published var weekRevenue: Double = 0
    @Published var weekSalesCount: Int = 0
    @Published var monthRevenue: Double = 0

    @Published var machinesOnline: Int = 0
    @Published var machinesTotal: Int = 0
    @Published var stockCriticalCount: Int = 0
    @Published var stockLowCount: Int = 0

    @Published var dailySales: [DailySales] = []
    @Published var recentSales: [SaleWithMachine] = []

    @Published var isLoading = false
    @Published var error: String?

    private let client = SupabaseService.shared.client

    // MARK: - Load All

    func loadDashboard() async {
        isLoading = true
        error = nil

        do {
            async let salesTask: () = loadSalesKPIs()
            async let machinesTask: () = loadMachineStats()
            async let chartTask: () = loadDailyChart()
            async let recentTask: () = loadRecentSales()

            _ = try await (salesTask, machinesTask, chartTask, recentTask)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Sales KPIs

    private func loadSalesKPIs() async throws {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!

        // Fetch all sales for this month (covers today, yesterday, week, month)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let sales: [Sale] = try await client
            .from("sales")
            .select("id, created_at, item_price, item_number, machine_id, embedded_id, channel")
            .gte("created_at", value: formatter.string(from: startOfMonth))
            .order("created_at", ascending: false)
            .execute()
            .value

        var todayRev = 0.0, todayCount = 0
        var yesterdayRev = 0.0
        var weekRev = 0.0, weekCount = 0
        var monthRev = 0.0

        for sale in sales {
            let price = sale.itemPrice ?? 0
            monthRev += price

            if sale.createdAt >= startOfWeek {
                weekRev += price
                weekCount += 1
            }
            if sale.createdAt >= startOfToday {
                todayRev += price
                todayCount += 1
            } else if sale.createdAt >= startOfYesterday && sale.createdAt < startOfToday {
                yesterdayRev += price
            }
        }

        todayRevenue = todayRev
        todaySalesCount = todayCount
        yesterdayRevenue = yesterdayRev
        weekRevenue = weekRev
        weekSalesCount = weekCount
        monthRevenue = monthRev
    }

    // MARK: - Machine Stats

    private func loadMachineStats() async throws {
        let machines: [VendingMachine] = try await client
            .from("vendingMachine")
            .select("id, name, location_lat, location_lon, embedded, country_code, embeddeds(id, status, status_at, subdomain, mac_address, firmware_version)")
            .execute()
            .value

        machinesTotal = machines.count
        machinesOnline = machines.filter { $0.isOnline }.count

        // Load all trays for stock health
        let trays: [Tray] = try await client
            .from("machine_trays")
            .select("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, discontinued)")
            .execute()
            .value

        // Group trays by machine
        let traysByMachine = Dictionary(grouping: trays, by: { $0.machineId })

        var criticalCount = 0
        var lowCount = 0

        for machine in machines {
            let machineTrays = traysByMachine[machine.id] ?? []
            let hasEmpty = machineTrays.contains { $0.isEmpty }
            let hasLow = machineTrays.contains { $0.isBelowMinStock }

            if hasEmpty { criticalCount += 1 }
            else if hasLow { lowCount += 1 }
        }

        stockCriticalCount = criticalCount
        stockLowCount = lowCount
    }

    // MARK: - Daily Chart (30 days)

    private func loadDailyChart() async throws {
        let calendar = Calendar.current
        let now = Date()
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now))!

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let sales: [Sale] = try await client
            .from("sales")
            .select("id, created_at, item_price, item_number, machine_id, embedded_id, channel")
            .gte("created_at", value: formatter.string(from: thirtyDaysAgo))
            .order("created_at", ascending: true)
            .execute()
            .value

        // Group by day
        var dailyMap: [Date: (revenue: Double, count: Int)] = [:]

        // Pre-populate all 30 days
        for dayOffset in 0..<31 {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: thirtyDaysAgo)!
            let startOfDay = calendar.startOfDay(for: day)
            dailyMap[startOfDay] = (0, 0)
        }

        for sale in sales {
            let day = calendar.startOfDay(for: sale.createdAt)
            let existing = dailyMap[day] ?? (0, 0)
            dailyMap[day] = (existing.revenue + (sale.itemPrice ?? 0), existing.count + 1)
        }

        dailySales = dailyMap
            .map { DailySales(date: $0.key, revenue: $0.value.revenue, count: $0.value.count) }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Recent Sales

    private func loadRecentSales() async throws {
        let sales: [Sale] = try await client
            .from("sales")
            .select("id, created_at, item_price, item_number, machine_id, embedded_id, channel")
            .order("created_at", ascending: false)
            .limit(20)
            .execute()
            .value

        // Fetch machine names for these sales
        let machineIds = Set(sales.compactMap { $0.machineId })
        var machineNames: [UUID: String] = [:]

        if !machineIds.isEmpty {
            let machines: [VendingMachine] = try await client
                .from("vendingMachine")
                .select("id, name, location_lat, location_lon, embedded, country_code")
                .in("id", values: machineIds.map { $0.uuidString })
                .execute()
                .value

            for m in machines {
                machineNames[m.id] = m.displayName
            }
        }

        // Fetch product names by item_number via trays
        let trays: [Tray] = try await client
            .from("machine_trays")
            .select("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, discontinued)")
            .execute()
            .value

        // Build lookup: (machineId, itemNumber) -> productName
        var productLookup: [String: String] = [:]
        for tray in trays {
            let key = "\(tray.machineId)_\(tray.itemNumber)"
            if let name = tray.products?.name {
                productLookup[key] = name
            }
        }

        recentSales = sales.map { sale in
            let machineName = sale.machineId.flatMap { machineNames[$0] }
            var productName: String? = nil
            if let machineId = sale.machineId, let itemNum = sale.itemNumber {
                productName = productLookup["\(machineId)_\(itemNum)"]
            }
            return SaleWithMachine(sale: sale, machineName: machineName, productName: productName)
        }
    }
}
