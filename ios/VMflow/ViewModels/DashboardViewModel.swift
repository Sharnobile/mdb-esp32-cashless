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

    /// Number of days back from start_of_today the recent-sales window covers.
    /// 0 = today only; 6 = last 7 days; 13 = last 14 days; 7N−1 after N "load more" taps.
    @Published var recentSalesDaysBack: Int = 0

    /// Becomes false when a "load more" tap returns no additional sales (history exhausted).
    /// Resets to true whenever a window-respecting reload brings in more sales than before
    /// (e.g. realtime delivery into the current window).
    @Published var hasMoreSales: Bool = true

    /// True while a `loadMoreRecentSales` fetch is in flight — drives the button spinner.
    @Published var isLoadingMoreSales: Bool = false

    @Published var isLoading = false
    @Published var error: String?

    /// Average daily revenue over the loaded daily-chart window, including zero-revenue days.
    /// Σ revenue / dailySales.count. The chart header says "30 days" but loadDailyChart()
    /// actually pre-populates 31 daily buckets (`for dayOffset in 0..<31`); we divide by the
    /// actual array count so the average matches what's visually rendered.
    var dailyAverage: Double {
        guard !dailySales.isEmpty else { return 0 }
        return dailySales.reduce(0) { $0 + $1.revenue } / Double(dailySales.count)
    }

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
        } catch is CancellationError {
            // Ignore — SwiftUI cancels refreshable tasks routinely
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

        // Query the earliest of the four KPI boundaries — on the 1st of a month
        // startOfYesterday is in the previous month, and a Mon-Wed early in a
        // month has its ISO-week start in the previous month too. Guarding each
        // sum with its own boundary keeps the per-KPI math correct.
        let queryLowerBound = [startOfMonth, startOfWeek, startOfYesterday].min()!

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let sales: [Sale] = try await client
            .from("sales")
            .select("id, created_at, item_price, item_number, machine_id, embedded_id, channel")
            .gte("created_at", value: formatter.string(from: queryLowerBound))
            .order("created_at", ascending: false)
            .execute()
            .value

        var todayRev = 0.0, todayCount = 0
        var yesterdayRev = 0.0
        var weekRev = 0.0, weekCount = 0
        var monthRev = 0.0

        for sale in sales {
            let price = sale.itemPrice ?? 0

            if sale.createdAt >= startOfMonth {
                monthRev += price
            }
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
            .select("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, discontinued, sellprice)")
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
        // Compute window start: start_of_today − recentSalesDaysBack days.
        // daysBack=0 → start_of_today (only today's sales since midnight, NOT last 24h).
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let windowStart = calendar.date(byAdding: .day, value: -recentSalesDaysBack, to: startOfToday)!

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Fetch sales with snapshotted product via FK join.
        let sales: [Sale] = try await client
            .from("sales")
            .select("id, created_at, item_price, item_number, machine_id, embedded_id, channel, product_id, products(name, image_path)")
            .gte("created_at", value: formatter.string(from: windowStart))
            .order("created_at", ascending: false)
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

        // Fallback: fetch tray→product lookup only for old sales without product_id
        let salesWithoutProduct = sales.filter { $0.productId == nil && $0.machineId != nil }
        var trayProductLookup: [String: (name: String?, imagePath: String?)] = [:]

        if !salesWithoutProduct.isEmpty {
            let fallbackMachineIds = Set(salesWithoutProduct.compactMap { $0.machineId })
            let trays: [Tray] = try await client
                .from("machine_trays")
                .select("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, discontinued, sellprice)")
                .in("machine_id", values: fallbackMachineIds.map { $0.uuidString })
                .execute()
                .value

            for tray in trays {
                let key = "\(tray.machineId)_\(tray.itemNumber)"
                trayProductLookup[key] = (name: tray.products?.name, imagePath: tray.products?.imagePath)
            }
        }

        let countBefore = recentSales.count
        recentSales = sales.map { sale in
            let machineName = sale.machineId.flatMap { machineNames[$0] }

            // Prefer snapshotted product from FK join, fallback to tray lookup
            var productName: String? = sale.products?.name
            var productImagePath: String? = sale.products?.imagePath

            if productName == nil, let machineId = sale.machineId, let itemNum = sale.itemNumber {
                let trayProduct = trayProductLookup["\(machineId)_\(itemNum)"]
                productName = trayProduct?.name
                productImagePath = trayProduct?.imagePath
            }

            return SaleWithMachine(sale: sale, machineName: machineName, productName: productName, productImagePath: productImagePath)
        }

        // Recovery: if a reload brought in more sales than before (e.g. realtime delivery
        // into the current window), un-exhaust the load-more button.
        if recentSales.count > countBefore {
            hasMoreSales = true
        }
    }

    // MARK: - Load More

    /// Expand the recent-sales window: today (1 day) → 7 days → 14 days → 21 days → …
    /// Each tap adds 7 more days; first tap jumps from 1 to 7 (i.e. +6 days).
    func loadMoreRecentSales() async {
        guard !isLoadingMoreSales, hasMoreSales else { return }

        let previousDaysBack = recentSalesDaysBack
        let nextDaysBack = previousDaysBack == 0 ? 6 : previousDaysBack + 7

        isLoadingMoreSales = true
        defer { isLoadingMoreSales = false }

        let countBefore = recentSales.count
        recentSalesDaysBack = nextDaysBack

        do {
            try await loadRecentSales()
            // If the wider window returned the exact same number of sales, history is exhausted.
            if recentSales.count == countBefore {
                hasMoreSales = false
            }
        } catch is CancellationError {
            // Refresh cancellation: revert window so a follow-up tap retries cleanly.
            recentSalesDaysBack = previousDaysBack
        } catch {
            // Server/network error: revert window so a follow-up tap retries.
            recentSalesDaysBack = previousDaysBack
            self.error = error.localizedDescription
        }
    }
}
