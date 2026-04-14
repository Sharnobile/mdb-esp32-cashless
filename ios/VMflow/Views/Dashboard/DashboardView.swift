import SwiftUI
import Charts

/// Main dashboard with KPIs, 30-day chart, recent sales, and quick actions.
struct DashboardView: View {
    var onNavigate: (SidebarItem) -> Void = { _ in }
    @EnvironmentObject var auth: AuthService
    @StateObject private var viewModel = DashboardViewModel()
    @EnvironmentObject private var realtime: RealtimeService
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Whether a refill tour is currently saved/in-progress.
    @State private var hasActiveRefill = false

    private var realtimeVersion: Int {
        realtime.salesVersion + realtime.machinesVersion + realtime.embeddedVersion
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // KPI Cards
                kpiSection

                // Quick Actions
                quickActions

                // 30-Day Chart
                chartSection

                // Recent Sales
                recentSalesSection
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
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
        .onAppear {
            hasActiveRefill = RefillWizardViewModel.hasSavedTourState
        }
        .onChange(of: realtimeVersion) { _, _ in
            Task { await viewModel.loadDashboard() }
        }
        .overlay {
            if viewModel.isLoading && viewModel.dailySales.isEmpty {
                ProgressView("Loading dashboard...")
            }
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
        LazyVGrid(columns: kpiColumns, spacing: 12) {
            KPICard(
                icon: "eurosign.circle.fill",
                title: "Today's Revenue",
                value: formatCurrency(viewModel.todayRevenue),
                subtitle: "Yesterday: \(formatCurrency(viewModel.yesterdayRevenue))",
                color: .blue
            )

            KPICard(
                icon: "cart.fill",
                title: "Today's Sales",
                value: "\(viewModel.todaySalesCount)",
                subtitle: "This week: \(viewModel.weekSalesCount)",
                color: .green
            )

            KPICard(
                icon: "storefront.fill",
                title: "Machines",
                value: "\(viewModel.machinesOnline)/\(viewModel.machinesTotal)",
                subtitle: "Online",
                color: .teal
            )

            KPICard(
                icon: "exclamationmark.triangle.fill",
                title: "Stock Alerts",
                value: "\(viewModel.stockCriticalCount + viewModel.stockLowCount)",
                subtitle: "\(viewModel.stockCriticalCount) critical, \(viewModel.stockLowCount) low",
                color: viewModel.stockCriticalCount > 0 ? .red : (viewModel.stockLowCount > 0 ? .yellow : .green)
            )
        }
    }

    // MARK: - Quick Actions

    private var quickActions: some View {
        HStack(spacing: 12) {
            Button {
                onNavigate(.refill)
            } label: {
                Label(
                    hasActiveRefill ? "Continue Refill" : "Start Refill",
                    systemImage: hasActiveRefill ? "arrow.forward.circle.fill" : "arrow.clockwise.circle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)

            Button {
                onNavigate(.machines)
            } label: {
                Label("Machines", systemImage: "storefront.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
        }
    }

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
                Chart(viewModel.dailySales) { day in
                    BarMark(
                        x: .value("Date", day.date, unit: .day),
                        y: .value("Revenue", day.revenue)
                    )
                    .foregroundStyle(.blue.gradient)
                    .cornerRadius(3)
                }
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
                let items = Array(viewModel.recentSales.prefix(10))
                let grouped = groupDashboardSalesByDay(items)
                ForEach(grouped, id: \.date) { group in
                    DaySectionHeader(label: dayLabel(for: group.date), count: group.sales.count)
                    ForEach(group.sales) { item in
                        RecentSaleRow(item: item)
                    }
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

    // MARK: - Helpers

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

    var body: some View {
        HStack(spacing: 12) {
            ProductImage(imagePath: item.productImagePath, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.productName ?? "Item #\(item.sale.itemNumber ?? 0)")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let machineName = item.machineName {
                    Text(machineName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
