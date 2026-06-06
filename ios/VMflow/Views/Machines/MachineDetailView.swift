import SwiftUI
import Charts

/// Tabbed machine detail view: Overview (with trays), Sales.
struct MachineDetailView: View {
    let machine: VendingMachine
    let initialStats: MachineStats

    @StateObject private var viewModel: MachineDetailViewModel
    @StateObject private var trayVM: TrayViewModel
    @State private var selectedTab = 0
    @State private var showAddSheet = false
    @State private var showBatchSheet = false
    @State private var editingTray: Tray?
    @State private var selectedProduct: ProductSelection?
    @EnvironmentObject private var realtime: RealtimeService

    struct ProductSelection: Identifiable {
        let id: UUID
        let name: String
        let imagePath: String?
        let sellprice: Double?
    }

    private var realtimeVersion: Int {
        realtime.salesVersion + realtime.traysVersion
    }

    init(machine: VendingMachine, initialStats: MachineStats) {
        self.machine = machine
        self.initialStats = initialStats
        _viewModel = StateObject(wrappedValue: MachineDetailViewModel(machine: machine, stats: initialStats))
        _trayVM = StateObject(wrappedValue: TrayViewModel(machineId: machine.id))
    }

    /// Use the trayVM's trays if loaded, otherwise fall back to viewModel's trays.
    private var displayTrays: [Tray] {
        trayVM.trays.isEmpty ? viewModel.trays : trayVM.trays
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab Picker
            Picker("Section", selection: $selectedTab) {
                Text("Overview").tag(0)
                Text("Sales").tag(1)
                Text("Duplicates").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Tab Content
            TabView(selection: $selectedTab) {
                overviewTab.tag(0)
                salesTab.tag(1)
                suppressedTab.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle(machine.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadDetail()
            await trayVM.loadTrays()
        }
        .onChange(of: realtimeVersion) { _, _ in
            Task {
                await viewModel.loadDetail()
                await trayVM.loadTrays()
            }
        }
        .sheet(isPresented: $showAddSheet) {
            TrayEditSheet(
                machineId: machine.id,
                tray: nil,
                products: viewModel.products,
                onSave: { slot, productId, capacity, stock, minStock, fillBelow in
                    await trayVM.addTray(
                        itemNumber: slot,
                        productId: productId,
                        capacity: capacity,
                        currentStock: stock,
                        minStock: minStock,
                        fillWhenBelow: fillBelow
                    )
                }
            )
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showBatchSheet) {
            BatchAddTraySheet(machineId: machine.id) { start, count, capacity in
                await trayVM.batchAddTrays(startSlot: start, count: count, capacity: capacity)
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $editingTray) { tray in
            TrayEditSheet(
                machineId: machine.id,
                tray: tray,
                products: viewModel.products,
                onSave: { slot, productId, capacity, stock, minStock, fillBelow in
                    await trayVM.updateTray(
                        id: tray.id,
                        itemNumber: slot,
                        productId: productId,
                        capacity: capacity,
                        currentStock: stock,
                        minStock: minStock,
                        fillWhenBelow: fillBelow
                    )
                },
                onDelete: {
                    await trayVM.deleteTray(tray)
                }
            )
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
        .alert("Error", isPresented: .init(
            get: { trayVM.error != nil },
            set: { if !$0 { trayVM.error = nil } }
        )) {
            Button("OK") { trayVM.error = nil }
        } message: {
            Text(trayVM.error ?? "")
        }
    }

    // MARK: - Overview Tab

    private var overviewTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Status & Info
                VStack(spacing: 12) {
                    HStack {
                        StatusBadge(isOnline: machine.isOnline)
                        Spacer()
                        if let firmware = machine.embeddeds?.firmwareVersion {
                            Text("v\(firmware)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(.fill.tertiary))
                        }
                    }

                    if let mac = machine.embeddeds?.macAddress {
                        HStack {
                            Image(systemName: "network")
                                .foregroundStyle(.secondary)
                            Text(mac)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))

                // Revenue KPIs
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                    KPICard(
                        icon: "eurosign.circle.fill",
                        title: "Today",
                        value: formatEUR(viewModel.stats.todayRevenue),
                        color: .blue
                    )
                    KPICard(
                        icon: "cart.fill",
                        title: "Sales Today",
                        value: "\(viewModel.stats.todaySalesCount)",
                        color: .green
                    )
                    KPICard(
                        icon: "clock.fill",
                        title: "Yesterday",
                        value: formatEUR(viewModel.stats.yesterdayRevenue),
                        color: .orange
                    )
                    KPICard(
                        icon: "cube.box.fill",
                        title: "Stock",
                        value: viewModel.stockSummary,
                        color: viewModel.stats.stockHealth == .critical ? .red :
                               viewModel.stats.stockHealth == .low ? .yellow : .green
                    )
                }

                // Paxcounter
                if let pax = viewModel.stats.paxcounterCount {
                    HStack {
                        Image(systemName: "person.3.fill")
                            .foregroundStyle(.teal)
                        Text("Foot Traffic")
                            .font(.subheadline)
                        Spacer()
                        Text("\(pax)")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
                }

                // Trays Section
                VStack(spacing: 0) {
                    // Tray Header
                    HStack {
                        Text("\(displayTrays.count) Trays")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Menu {
                            Button {
                                showAddSheet = true
                            } label: {
                                Label("Add Single Tray", systemImage: "plus")
                            }
                            Button {
                                showBatchSheet = true
                            } label: {
                                Label("Batch Add Trays", systemImage: "plus.rectangle.on.rectangle")
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                        }
                    }
                    .padding(.vertical, 8)

                    // Tray Rows
                    if displayTrays.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "tray")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("No trays configured")
                                .foregroundStyle(.secondary)
                            Button("Add Trays") {
                                showBatchSheet = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(.top, 24)
                        .padding(.bottom, 12)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(displayTrays) { tray in
                                TrayRow(
                                    tray: tray,
                                    onAdjust: { delta in
                                        HapticFeedback.light.fire()
                                        Task {
                                            await trayVM.adjustStock(tray: tray, delta: delta)
                                        }
                                    },
                                    onFill: {
                                        HapticFeedback.medium.fire()
                                        Task {
                                            await trayVM.fillToCapacity(tray)
                                        }
                                    },
                                    onEdit: {
                                        editingTray = tray
                                    }
                                )

                                if tray.id != displayTrays.last?.id {
                                    Divider()
                                        .padding(.leading, 52)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .refreshable {
            await viewModel.loadDetail()
            await trayVM.loadTrays()
        }
    }

    // MARK: - Sales Tab

    private var salesTab: some View {
        ScrollView {
            if viewModel.recentSales.isEmpty && !viewModel.isLoading {
                VStack(spacing: 12) {
                    Image(systemName: "cart")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No sales yet")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 60)
            } else {
                LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                    let grouped = groupSalesByDay(viewModel.recentSales)
                    ForEach(grouped, id: \.date) { group in
                        Section {
                            ForEach(group.sales) { sale in
                                SaleRow(sale: sale, trays: viewModel.trays) {
                                    presentProductSheet(for: sale)
                                }
                            }
                        } header: {
                            DaySectionHeader(label: dayLabel(for: group.date), count: group.sales.count)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
        }
        .refreshable {
            await viewModel.loadDetail()
        }
    }

    // MARK: - Suppressed (Duplicates) Tab

    private var suppressedTab: some View {
        ScrollView {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    // Header
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "doc.badge.minus")
                                .foregroundStyle(.orange)
                            Text("\(viewModel.suppressedSales.count) auto-removed")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                        }
                        Text("Sales auto-dropped as suspected brownout re-reports.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))

                    if viewModel.suppressedSales.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 40))
                                .foregroundStyle(.green)
                            Text("None — no duplicates auto-removed.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                            let groups = groupSuppressedByDay(viewModel.suppressedSales)
                            ForEach(groups, id: \.date) { group in
                                Section {
                                    ForEach(group.rows) { sale in
                                        SuppressedSaleRow(sale: sale, trays: viewModel.trays)
                                    }
                                } header: {
                                    DaySectionHeader(label: dayLabel(for: group.date), count: group.rows.count, unit: "removed")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
        }
        .refreshable {
            await viewModel.loadDetail()
        }
    }

    private func formatEUR(_ amount: Double) -> String {
        String(format: "%.2f\u{00A0}\u{20AC}", amount)
    }

    /// Resolve a sale's product (snapshotted FK or tray fallback) and present the
    /// product detail sheet. No-op when no product can be determined.
    private func presentProductSheet(for sale: Sale) {
        let trayMatch = sale.itemNumber.flatMap { num in
            viewModel.trays.first { $0.itemNumber == num }
        }
        let productId = sale.productId ?? trayMatch?.productId
        guard let pid = productId else { return }
        let name = sale.products?.name ?? trayMatch?.productName ?? "Item #\(sale.itemNumber ?? 0)"
        let imagePath = sale.products?.imagePath ?? trayMatch?.products?.imagePath
        selectedProduct = ProductSelection(
            id: pid,
            name: name,
            imagePath: imagePath,
            sellprice: sale.itemPrice
        )
    }

    // MARK: - Day Grouping Helpers

    private struct DayGroup {
        let date: Date
        let sales: [Sale]
    }

    private struct SuppressedDayGroup {
        let date: Date
        let rows: [SuppressedSale]
    }

    private func groupSalesByDay(_ sales: [Sale]) -> [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: sales) { sale in
            calendar.startOfDay(for: sale.createdAt)
        }
        return grouped.keys.sorted(by: >).map { date in
            DayGroup(date: date, sales: grouped[date]!.sorted { $0.createdAt > $1.createdAt })
        }
    }

    private func groupSuppressedByDay(_ rows: [SuppressedSale]) -> [SuppressedDayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: rows) { row in
            calendar.startOfDay(for: row.receivedAt)
        }
        return grouped.keys.sorted(by: >).map { date in
            SuppressedDayGroup(date: date, rows: grouped[date]!.sorted { $0.receivedAt > $1.receivedAt })
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

// MARK: - Sale Row (Card Style)

struct SaleRow: View {
    let sale: Sale
    let trays: [Tray]
    var onTap: () -> Void = {}

    /// Find the product for this sale via tray item number (fallback for old sales without product_id).
    private var tray: Tray? {
        guard let itemNumber = sale.itemNumber else { return nil }
        return trays.first { $0.itemNumber == itemNumber }
    }

    /// Prefer snapshotted product from FK join, fallback to tray lookup for old sales.
    private var productName: String {
        sale.products?.name ?? tray?.productName ?? "Item #\(sale.itemNumber ?? 0)"
    }

    private var productImagePath: String? {
        sale.products?.imagePath ?? tray?.products?.imagePath
    }

    private var channelColor: Color {
        switch sale.channel?.lowercased() {
        case "card": return .blue
        case "cashless", "nfc": return .purple
        case "cash": return .green
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ProductImage(imagePath: productImagePath, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(productName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let channel = sale.channel {
                        Text(channel.capitalized)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(channelColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(channelColor.opacity(0.12), in: Capsule())
                    }
                    if sale.itemNumber != nil {
                        Text("Slot \(sale.itemNumber!)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(sale.formattedPrice)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(formatTime(sale.createdAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { onTap() }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Suppressed Sale Row (read-only)

struct SuppressedSaleRow: View {
    let sale: SuppressedSale
    let trays: [Tray]

    /// Prefer snapshot product name; fall back to current tray by item number; last resort "Slot N".
    private var productName: String {
        sale.products?.name
            ?? trays.first { $0.itemNumber == sale.itemNumber }?.productName
            ?? "Slot \(sale.itemNumber ?? 0)"
    }

    private var productImagePath: String? {
        sale.products?.imagePath
            ?? trays.first { $0.itemNumber == sale.itemNumber }?.products?.imagePath
    }

    private var channelColor: Color {
        switch sale.channel?.lowercased() {
        case "card": return .blue
        case "cashless", "nfc": return .purple
        case "cash": return .green
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ProductImage(imagePath: productImagePath, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(productName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let channel = sale.channel {
                        Text(channel.capitalized)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(channelColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(channelColor.opacity(0.12), in: Capsule())
                    }
                    if let slot = sale.itemNumber {
                        Text("Slot \(slot)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("likely brownout re-report")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(sale.formattedPrice)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(formatTime(sale.receivedAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Day Section Header

struct DaySectionHeader: View {
    let label: String
    let count: Int
    var unit: String = "sales"

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline.weight(.semibold))
            Text("· \(count) \(unit)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.bar)
    }
}

#Preview {
    let machine = VendingMachine(
        id: UUID(),
        name: "Test Machine",
        locationLat: nil,
        locationLon: nil,
        embedded: nil,
        countryCode: "DE",
        embeddeds: Embedded(
            id: UUID(),
            status: "online",
            statusAt: Date(),
            subdomain: 1,
            macAddress: "AA:BB:CC:DD:EE:FF",
            firmwareVersion: "1.2.3"
        )
    )
    let stats = MachineStats(machine: machine)

    NavigationStack {
        MachineDetailView(machine: machine, initialStats: stats)
    }
}
