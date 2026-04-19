import SwiftUI

/// Drilldown view: shows all batches for one product in the currently selected
/// warehouse, ordered by expiration date. Tapping a batch opens `BatchAdjustSheet`.
struct ProductBatchesView: View {
    let productId: UUID
    let productName: String
    let productImagePath: String?

    @EnvironmentObject private var viewModel: WarehouseViewModel
    @State private var selectedBatch: WarehouseStockBatch?

    var body: some View {
        Group {
            if viewModel.isLoadingBatches && viewModel.drilldownBatches.isEmpty {
                ProgressView("Loading batches...")
            } else if viewModel.drilldownBatches.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "shippingbox")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No batches in stock")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(viewModel.drilldownBatches) { batch in
                        Button {
                            selectedBatch = batch
                        } label: {
                            BatchRow(batch: batch)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(productName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadBatchesForProduct(productId)
        }
        .refreshable {
            await viewModel.loadBatchesForProduct(productId)
        }
        .sheet(item: $selectedBatch) { batch in
            BatchAdjustSheet(
                batch: batch,
                productName: productName,
                imagePath: productImagePath
            ) { signedDelta, reason, notes in
                await viewModel.adjustBatch(
                    batchId: batch.id,
                    quantityChange: signedDelta,
                    reason: reason,
                    notes: notes
                )
            }
        }
    }
}

/// Single batch row in the drilldown list.
private struct BatchRow: View {
    let batch: WarehouseStockBatch

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(batch.batchNumber ?? String(localized: "No batch"))
                    .font(.body)
                if let exp = batch.expirationDate {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.caption2)
                        Text(exp)
                            .font(.caption)
                    }
                    .foregroundStyle(expirationColor(exp))
                }
            }
            Spacer()
            Text("\(batch.quantity)")
                .font(.title3.bold().monospacedDigit())
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func expirationColor(_ dateString: String) -> Color {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateString) else { return .secondary }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        if days < 7 { return .red }
        if days <= 30 { return .orange }
        return .secondary
    }
}
