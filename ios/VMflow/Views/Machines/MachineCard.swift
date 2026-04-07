import SwiftUI

/// Card component for the machine list showing key stats at a glance.
struct MachineCard: View {
    let stats: MachineStats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Name + Status
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stats.machine.displayName)
                        .font(.headline)
                        .lineLimit(1)

                    StatusBadge(isOnline: stats.machine.isOnline)
                }

                Spacer()

                StockHealthIndicator(health: stats.stockHealth)
            }

            Divider()

            // Stats Row
            HStack(spacing: 0) {
                // Today's Revenue
                statItem(
                    icon: "eurosign.circle",
                    label: "Today",
                    value: formatEUR(stats.todayRevenue)
                )

                Spacer()

                // Sales Count
                statItem(
                    icon: "cart",
                    label: "Sales",
                    value: "\(stats.todaySalesCount)"
                )

                Spacer()

                // Last Sale
                statItem(
                    icon: "clock",
                    label: "Last Sale",
                    value: stats.lastSaleAt.map { timeAgo(from: $0) } ?? "--"
                )
            }

            // Stock Bar
            if stats.totalTrays > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Stock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(stats.stockPercent * 100))%")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    StockBar(
                        current: Int(stats.stockPercent * 100),
                        capacity: 100,
                        showLabel: false,
                        height: 6
                    )
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

    private func statItem(icon: String, label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private func formatEUR(_ amount: Double) -> String {
        String(format: "%.2f\u{00A0}\u{20AC}", amount)
    }
}

#Preview {
    let machine = VendingMachine(
        id: UUID(),
        name: "Office Kitchen",
        locationLat: nil,
        locationLon: nil,
        embedded: nil,
        countryCode: "DE",
        embeddeds: Embedded(
            id: UUID(),
            status: "online",
            statusAt: Date(),
            subdomain: 1,
            macAddress: nil,
            firmwareVersion: "1.0.0"
        )
    )

    var stats = MachineStats(machine: machine)
    stats.todayRevenue = 42.50
    stats.todaySalesCount = 15
    stats.totalTrays = 8
    stats.lowTrays = 2
    stats.stockPercent = 0.65
    stats.lastSaleAt = Date().addingTimeInterval(-1800)

    return MachineCard(stats: stats)
        .padding()
}
