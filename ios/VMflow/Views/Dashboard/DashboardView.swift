import SwiftUI
import Charts

/// Main dashboard with KPIs, 30-day chart, recent sales, and quick actions.
struct DashboardView: View {
    var onNavigate: (SidebarItem) -> Void = { _ in }
    @EnvironmentObject var auth: AuthService
    @StateObject private var viewModel = DashboardViewModel()
    @EnvironmentObject private var realtime: RealtimeService
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Selected date for chart drag-to-scrub. nil = no tooltip visible.
    @State private var selectedDate: Date?

    /// Sale-row product tap → presents `ProductDetailSheet`. nil = no sheet.
    @State private var selectedProduct: ProductSelection?

    /// Push CashBookView when the cash-book tile is tapped.
    @State private var showCashBook = false

    struct ProductSelection: Identifiable {
        let id: UUID
        let name: String
        let imagePath: String?
        let sellprice: Double?
    }

    private var realtimeVersion: Int {
        realtime.salesVersion + realtime.machinesVersion + realtime.embeddedVersion
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // KPI Cards
                kpiSection

                // Cash Book tile
                CashBookCard(onTap: { showCashBook = true })

                // 30-Day Chart
                chartSection

                // Recent Sales
                recentSalesSection
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .navigationDestination(isPresented: $showCashBook) {
            CashBookView()
        }
        .refreshable {
            await viewModel.loadDashboard()
        }
        .navigationTitle(auth.organization?.name ?? "Dashboard")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        Task { await auth.logout() }
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "person.circle")
                        .font(.title3)
                }
            }
        }
        .task {
            await viewModel.loadDashboard()
        }
        .onChange(of: realtimeVersion) { _, _ in
            Task { await viewModel.loadDashboard() }
        }
        .overlay {
            if viewModel.isLoading && viewModel.dailySales.isEmpty {
                ProgressView("Loading dashboard...")
            }
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

    // MARK: - KPI Cards

    private var kpiColumns: [GridItem] {
        if sizeClass == .regular {
            return Array(repeating: GridItem(.flexible()), count: 4)
        }
        return [GridItem(.flexible()), GridItem(.flexible())]
    }

    private var kpiSection: some View {
        VStack(spacing: 12) {
            // Offline-machines warning banner — only when something is wrong.
            if viewModel.machinesTotal > 0 && viewModel.machinesOnline < viewModel.machinesTotal {
                offlineMachinesBanner
            }

            LazyVGrid(columns: kpiColumns, spacing: 12) {
                RevenueKPICard(
                    icon: "sun.max.fill",
                    title: "Today",
                    currentRevenue: viewModel.todayRevenue,
                    currentSales: viewModel.todaySalesCount,
                    previousLabel: "Yesterday",
                    previousRevenue: viewModel.yesterdayRevenue,
                    previousSales: viewModel.yesterdaySalesCount,
                    color: .blue
                )

                RevenueKPICard(
                    icon: "calendar",
                    title: "This Week",
                    currentRevenue: viewModel.weekRevenue,
                    currentSales: viewModel.weekSalesCount,
                    previousLabel: "Last Week",
                    previousRevenue: viewModel.lastWeekRevenue,
                    previousSales: viewModel.lastWeekSalesCount,
                    color: .indigo
                )

                RevenueKPICard(
                    icon: "calendar.badge.clock",
                    title: "This Month",
                    currentRevenue: viewModel.monthRevenue,
                    currentSales: viewModel.monthSalesCount,
                    previousLabel: "Last Month",
                    previousRevenue: viewModel.lastMonthRevenue,
                    previousSales: viewModel.lastMonthSalesCount,
                    color: .purple
                )

                StockAlertsCard(
                    critical: viewModel.stockCriticalCount,
                    low: viewModel.stockLowCount,
                    machinesOnline: viewModel.machinesOnline,
                    machinesTotal: viewModel.machinesTotal
                )
            }
        }
    }

    /// Red banner shown above the KPI grid when not every machine is online.
    private var offlineMachinesBanner: some View {
        let offline = viewModel.machinesTotal - viewModel.machinesOnline
        return Button {
            onNavigate(.machines)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(offline) machine\(offline == 1 ? "" : "s") offline")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                    Text("Tap to view")
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.8))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.7))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.red.opacity(0.12))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.red.opacity(0.3), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

}

// MARK: - Dense KPI Cards (Dashboard-only)

/// Period-over-period revenue tile: current period (revenue + sales) on top,
/// previous period (revenue + sales) on the bottom, separated by a divider.
/// All cards are forced to the same minimum height to keep the dashboard grid
/// visually balanced regardless of which previous-period values are present.
private let kpiCardMinHeight: CGFloat = 138

private struct RevenueKPICard: View {
    let icon: String
    let title: LocalizedStringKey
    let currentRevenue: Double
    let currentSales: Int
    let previousLabel: LocalizedStringKey
    let previousRevenue: Double
    let previousSales: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }

            // Current period
            Text(currentRevenue, format: .currency(code: "EUR"))
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 4) {
                Image(systemName: "cart.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(verbatim: "\(currentSales) sales")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Divider()
                .padding(.vertical, 1)

            // Previous period
            Text(previousLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(previousRevenue, format: .currency(code: "EUR"))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(verbatim: "·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(verbatim: "\(previousSales) sales")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: kpiCardMinHeight, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }
}

/// Stock + machines tile — same visual rhythm and identical height as
/// RevenueKPICard. Top half: alert summary. Bottom half: machines online.
private struct StockAlertsCard: View {
    let critical: Int
    let low: Int
    let machinesOnline: Int
    let machinesTotal: Int

    private var alertColor: Color {
        if critical > 0 { return .red }
        if low > 0 { return .yellow }
        return .green
    }

    private var allStockClear: Bool { critical == 0 && low == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "shippingbox.fill")
                    .font(.subheadline)
                    .foregroundStyle(alertColor)
                Text("Stock")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            // Top half: stock alerts
            if allStockClear {
                Text("OK")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.green)
                Text("All machines stocked")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text(verbatim: "\(critical + low) alerts")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(alertColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 6) {
                    if critical > 0 {
                        Label(title: { Text(verbatim: "\(critical)") }, icon: {
                            Circle().fill(.red).frame(width: 6, height: 6)
                        })
                        .labelStyle(InlineDotLabelStyle())
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                    if low > 0 {
                        Label(title: { Text(verbatim: "\(low)") }, icon: {
                            Circle().fill(.yellow).frame(width: 6, height: 6)
                        })
                        .labelStyle(InlineDotLabelStyle())
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }

            Divider()
                .padding(.vertical, 1)

            // Bottom half: machines online
            Text("Machines online")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: machinesOnline == machinesTotal ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(machinesOnline == machinesTotal ? .green : .red)
                Text(verbatim: "\(machinesOnline) / \(machinesTotal)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: kpiCardMinHeight, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }
}

/// Tight `Label` layout for the stock-alert dot+number pairs so they sit
/// flush together with no extra spacing.
private struct InlineDotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - DashboardView (continuation)
//
// Chart, sales-list, and helper functions live in this extension so that
// the file-private RevenueKPICard / StockAlertsCard structs above can be
// declared between the KPI section and the rest without breaking nesting.

extension DashboardView {

    // MARK: - Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Revenue (30 days)")
                    .font(.headline)
                Spacer()
                Text(formatCurrency(viewModel.monthRevenue))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
            }

            if !viewModel.dailySales.isEmpty {
                Chart {
                    ForEach(viewModel.dailySales) { day in
                        BarMark(
                            x: .value("Date", day.date, unit: .day),
                            y: .value("Revenue", day.revenue)
                        )
                        .foregroundStyle(day.isWeekend ? Color.blue.opacity(0.45).gradient : Color.blue.gradient)
                        .cornerRadius(3)
                    }

                    if viewModel.dailyAverage > 0 {
                        RuleMark(y: .value("Avg", viewModel.dailyAverage))
                            .foregroundStyle(.orange)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                            .annotation(
                                position: .top,
                                alignment: .trailing,
                                spacing: 2,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                            ) {
                                Text("Ø \(formatCurrency(viewModel.dailyAverage))")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                    }

                    if let selectedDate, let day = selectedDay {
                        RuleMark(x: .value("Selected", day.date, unit: .day))
                            .foregroundStyle(.gray.opacity(0.35))
                            .annotation(
                                position: .top,
                                alignment: .center,
                                spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                            ) {
                                tooltipView(for: day)
                            }
                    }
                }
                .chartXSelection(value: $selectedDate)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        AxisGridLine()
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        if let revenue = value.as(Double.self) {
                            AxisValueLabel {
                                Text(formatCurrencyCompact(revenue))
                            }
                        }
                        AxisGridLine()
                    }
                }
                .frame(height: 200)
                .animation(.smooth, value: selectedDate)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray6))
                    .frame(height: 200)
                    .overlay {
                        Text("No sales data")
                            .foregroundStyle(.secondary)
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

    // MARK: - Recent Sales

    private var recentSalesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Sales")
                .font(.headline)

            if viewModel.recentSales.isEmpty && !viewModel.isLoading {
                Text("No recent sales")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                let grouped = groupDashboardSalesByDay(viewModel.recentSales)
                // LazyVStack: only the rows visible in the ScrollView's viewport are
                // instantiated. Without it, large windows (e.g. 21+ days) render
                // hundreds of RecentSaleRows eagerly, each spawning an AsyncImage
                // HTTP request — iOS kills the app under memory pressure.
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(grouped, id: \.date) { group in
                        DaySectionHeader(label: dayLabel(for: group.date), count: group.sales.count)
                        ForEach(group.sales) { item in
                            RecentSaleRow(item: item) {
                                guard let pid = item.sale.productId else { return }
                                selectedProduct = ProductSelection(
                                    id: pid,
                                    name: item.productName ?? "Item #\(item.sale.itemNumber ?? 0)",
                                    imagePath: item.productImagePath,
                                    sellprice: item.sale.itemPrice
                                )
                            }
                        }
                    }
                }
            }

            if viewModel.hasMoreSales {
                loadMoreButton
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }

    private var loadMoreButton: some View {
        // Days the *next* tap would show. Current visible window = recentSalesDaysBack + 1 days
        // (since daysBack counts back from today inclusive). Each tap adds +7 days, except the
        // very first which goes 1 → 7 (i.e. +6 days).
        let nextDaysTotal: Int = {
            if viewModel.recentSalesDaysBack == 0 { return 7 }
            return (viewModel.recentSalesDaysBack + 1) + 7
        }()

        return VStack(spacing: 4) {
            Button {
                Task { await viewModel.loadMoreRecentSales() }
            } label: {
                HStack(spacing: 6) {
                    if viewModel.isLoadingMoreSales {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                    Text("Load more")
                }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isLoadingMoreSales)

            Text("Show last \(nextDaysTotal) days")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private var selectedDay: DailySales? {
        guard let selectedDate else { return nil }
        return viewModel.dailySales.first {
            Calendar.current.isDate($0.date, inSameDayAs: selectedDate)
        }
    }

    @ViewBuilder
    private func tooltipView(for day: DailySales) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(formatTooltipDate(day.date))
                .font(.caption.weight(.semibold))
            HStack(spacing: 12) {
                Text("Revenue")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatCurrency(day.revenue))
                    .monospacedDigit()
            }
            .font(.caption2)
            HStack(spacing: 12) {
                Text("Sales")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(day.count)")
                    .monospacedDigit()
            }
            .font(.caption2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .frame(minWidth: 140)
    }

    private func formatTooltipDate(_ date: Date) -> String {
        // Date.FormatStyle is locale-aware out of the box.
        // - en: "Wed, 15 Apr"
        // - de: "Mi., 15. Apr."
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func formatCurrency(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
    }

    private func formatCurrencyCompact(_ amount: Double) -> String {
        if amount >= 1000 {
            return String(format: "%.0fk", amount / 1000)
        }
        return String(format: "%.0f", amount)
    }

    // MARK: - Day Grouping Helpers

    private struct DashboardDayGroup {
        let date: Date
        let sales: [SaleWithMachine]
    }

    private func groupDashboardSalesByDay(_ sales: [SaleWithMachine]) -> [DashboardDayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: sales) { item in
            calendar.startOfDay(for: item.sale.createdAt)
        }
        return grouped.keys.sorted(by: >).map { date in
            DashboardDayGroup(date: date, sales: grouped[date]!.sorted { $0.sale.createdAt > $1.sale.createdAt })
        }
    }

    private func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM"
        return formatter.string(from: date)
    }
}

// MARK: - Recent Sale Row

struct RecentSaleRow: View {
    let item: SaleWithMachine
    var onTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            ProductImage(imagePath: item.productImagePath, size: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.productName ?? "Item #\(item.sale.itemNumber ?? 0)")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let machineName = item.machineName {
                    Text(machineName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.sale.formattedPrice)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(formatTime(item.sale.createdAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Time Ago Helper

func timeAgo(from date: Date) -> String {
    let interval = Date().timeIntervalSince(date)

    if interval < 60 { return String(localized: "Just now") }
    if interval < 3600 { return String(localized: "\(Int(interval / 60))m ago") }
    if interval < 86400 { return String(localized: "\(Int(interval / 3600))h ago") }
    if interval < 604800 { return String(localized: "\(Int(interval / 86400))d ago") }

    let formatter = DateFormatter()
    formatter.dateStyle = .short
    return formatter.string(from: date)
}

#Preview {
    NavigationStack {
        DashboardView()
            .environmentObject(AuthService())
    }
}
