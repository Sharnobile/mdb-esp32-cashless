import SwiftUI
import Charts

/// Tabbed machine detail view: Overview, Trays, Sales.
struct MachineDetailView: View {
    let machine: VendingMachine
    let initialStats: MachineStats

    @StateObject private var viewModel: MachineDetailViewModel
    @State private var selectedTab = 0

    init(machine: VendingMachine, initialStats: MachineStats) {
        self.machine = machine
        self.initialStats = initialStats
        _viewModel = StateObject(wrappedValue: MachineDetailViewModel(machine: machine, stats: initialStats))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab Picker
            Picker("Section", selection: $selectedTab) {
                Text("Overview").tag(0)
                Text("Trays").tag(1)
                Text("Sales").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Tab Content
            TabView(selection: $selectedTab) {
                overviewTab.tag(0)
                traysTab.tag(1)
                salesTab.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle(machine.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadDetail()
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
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .refreshable {
            await viewModel.loadDetail()
        }
    }

    // MARK: - Trays Tab

    private var traysTab: some View {
        TrayListView(machineId: machine.id, trays: viewModel.trays, products: viewModel.products) {
            await viewModel.loadDetail()
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
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.recentSales) { sale in
                        SaleRow(sale: sale, trays: viewModel.trays)
                        Divider()
                            .padding(.leading, 56)
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
}

// MARK: - Sale Row

struct SaleRow: View {
    let sale: Sale
    let trays: [Tray]

    /// Find the product for this sale via tray item number.
    private var tray: Tray? {
        guard let itemNumber = sale.itemNumber else { return nil }
        return trays.first { $0.itemNumber == itemNumber }
    }

    var body: some View {
        HStack(spacing: 12) {
            ProductImage(imagePath: tray?.products?.imagePath, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(tray?.productName ?? "Item #\(sale.itemNumber ?? 0)")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let channel = sale.channel {
                        Text(channel.uppercased())
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.blue)
                    }
                    Text(timeAgo(from: sale.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(sale.formattedPrice)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.vertical, 8)
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
