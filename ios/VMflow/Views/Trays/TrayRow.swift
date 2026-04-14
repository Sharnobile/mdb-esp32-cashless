import SwiftUI

/// Single tray row showing slot, product image, name, stock bar, and quick actions.
struct TrayRow: View {
    let tray: Tray
    let onAdjust: (Int) -> Void
    let onFill: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Slot Number
            Text("\(tray.itemNumber)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(slotColor))

            // Product Image
            ProductImage(imagePath: tray.products?.imagePath, size: 40)

            // Name + Stock Bar
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(tray.productName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    if let price = tray.formattedSellprice {
                        Text(price)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if tray.isDiscontinued {
                        Text("DC")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.orange.opacity(0.15)))
                    }
                }

                StockBar(
                    current: tray.currentStock,
                    capacity: tray.capacity,
                    height: 6,
                    minStock: tray.minStock,
                    fillWhenBelow: tray.fillWhenBelow
                )
            }

            Spacer(minLength: 4)

            // Quick Actions
            HStack(spacing: 6) {
                // Minus
                Button {
                    onAdjust(-1)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(tray.currentStock <= 0)

                // Plus
                Button {
                    onAdjust(1)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .disabled(tray.currentStock >= tray.capacity)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
    }

    private var slotColor: Color {
        switch tray.stockHealth {
        case .critical: return .red
        case .low: return .yellow
        case .ok: return .blue
        }
    }
}

#Preview {
    let tray = Tray(
        id: UUID(),
        machineId: UUID(),
        itemNumber: 1,
        productId: nil,
        capacity: 10,
        currentStock: 3,
        minStock: 2,
        fillWhenBelow: 5,
        products: nil
    )

    List {
        TrayRow(tray: tray, onAdjust: { _ in }, onFill: {}, onEdit: {})
    }
}
