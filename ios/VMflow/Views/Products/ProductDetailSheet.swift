import SwiftUI
import Supabase

/// Lightweight product detail view shown from contexts where only a product id
/// is available (e.g. matched products in the Deals view). Displays the
/// product hero plus a stock breakdown across warehouses and machines, and
/// offers a tap-through to edit the full product.
struct ProductDetailSheet: View {
    let productId: UUID
    let fallbackName: String
    let fallbackImagePath: String?
    let fallbackSellprice: Double?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = ProductDetailViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    Divider()
                    warehouseSection
                    Divider()
                    machineSection
                }
                .padding(20)
            }
            .navigationTitle("Product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .task {
                await viewModel.load(productId: productId)
            }
            .refreshable {
                await viewModel.load(productId: productId)
            }
        }
    }

    private var displayName: String {
        viewModel.product?.name ?? fallbackName
    }

    private var displayImagePath: String? {
        viewModel.product?.imagePath ?? fallbackImagePath
    }

    private var displaySellprice: Double? {
        viewModel.product?.sellprice ?? fallbackSellprice
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ProductImage(imagePath: displayImagePath, size: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.title3.weight(.bold))
                    .lineLimit(3)

                if let price = displaySellprice {
                    Text(String(format: "%.2f \u{20AC}", price))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    stockTotalBadge(
                        icon: "building.2.fill",
                        value: viewModel.totalWarehouseQty,
                        color: .blue
                    )
                    stockTotalBadge(
                        icon: "shippingbox.fill",
                        value: viewModel.totalTrayStock,
                        capacity: viewModel.totalTrayCapacity,
                        color: .green
                    )
                }
            }

            Spacer()
        }
    }

    private func stockTotalBadge(icon: String, value: Int, capacity: Int? = nil, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            if let capacity, capacity > 0 {
                Text("\(value)/\(capacity)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            } else {
                Text("\(value)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(value > 0 ? color : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill((value > 0 ? color : Color.gray).opacity(0.12)))
    }

    // MARK: - Warehouse stock

    private var warehouseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "building.2.fill")
                    .foregroundStyle(.secondary)
                Text("Warehouse stock")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if viewModel.isLoading {
                    ProgressView().controlSize(.small)
                }
            }

            if viewModel.warehouseStock.isEmpty && !viewModel.isLoading {
                emptyRow("Not in any warehouse")
            } else {
                VStack(spacing: 6) {
                    ForEach(viewModel.warehouseStock) { entry in
                        HStack {
                            Text(entry.warehouseName)
                                .font(.subheadline)
                            Spacer()
                            Text("\(entry.totalQty)")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(entry.totalQty > 0 ? .primary : .secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray6)))
                    }
                }
            }
        }
    }

    // MARK: - Machines / trays

    private var machineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.secondary)
                Text("In machines")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            if viewModel.trays.isEmpty && !viewModel.isLoading {
                emptyRow("Not in any machine")
            } else {
                VStack(spacing: 6) {
                    ForEach(viewModel.trays) { entry in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.machineName)
                                    .font(.subheadline)
                                Text("Slot \(entry.itemNumber)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(entry.currentStock)/\(entry.capacity)")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(entry.currentStock > 0 ? .primary : .secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray6)))
                    }
                }
            }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .italic()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray6)))
    }
}

// MARK: - ViewModel

@MainActor
final class ProductDetailViewModel: ObservableObject {
    @Published var product: Product?
    @Published var warehouseStock: [WarehouseStockRow] = []
    @Published var trays: [TrayRow] = []
    @Published var isLoading = false

    struct WarehouseStockRow: Identifiable, Equatable {
        let warehouseId: UUID
        let warehouseName: String
        let totalQty: Int
        var id: UUID { warehouseId }
    }

    struct TrayRow: Identifiable, Equatable {
        let id: UUID
        let machineId: UUID
        let machineName: String
        let itemNumber: Int
        let currentStock: Int
        let capacity: Int
    }

    var totalWarehouseQty: Int {
        warehouseStock.reduce(0) { $0 + $1.totalQty }
    }

    var totalTrayStock: Int {
        trays.reduce(0) { $0 + $1.currentStock }
    }

    var totalTrayCapacity: Int {
        trays.reduce(0) { $0 + $1.capacity }
    }

    private var client: SupabaseClient { SupabaseService.shared.client }

    func load(productId: UUID) async {
        isLoading = true
        defer { isLoading = false }

        async let productTask: () = loadProduct(productId: productId)
        async let warehouseTask: () = loadWarehouseStock(productId: productId)
        async let traysTask: () = loadTrays(productId: productId)
        _ = await (productTask, warehouseTask, traysTask)
    }

    private func loadProduct(productId: UUID) async {
        do {
            let rows: [Product] = try await client
                .from("products")
                .select("id, name, image_path, discontinued, sellprice, category")
                .eq("id", value: productId.uuidString)
                .limit(1)
                .execute()
                .value
            product = rows.first
        } catch is CancellationError {
        } catch {
            print("[ProductDetailVM] loadProduct failed: \(error.localizedDescription)")
        }
    }

    private func loadWarehouseStock(productId: UUID) async {
        struct BatchRow: Decodable {
            let warehouseId: UUID
            let quantity: Int
            let warehouses: Named?

            enum CodingKeys: String, CodingKey {
                case warehouseId = "warehouse_id"
                case quantity, warehouses
            }
        }
        struct Named: Decodable { let name: String? }

        do {
            let rows: [BatchRow] = try await client
                .from("warehouse_stock_batches")
                .select("warehouse_id, quantity, warehouses(name)")
                .eq("product_id", value: productId.uuidString)
                .gt("quantity", value: 0)
                .execute()
                .value

            var byWarehouse: [UUID: (name: String, qty: Int)] = [:]
            for row in rows {
                let name = row.warehouses?.name ?? "—"
                let existing = byWarehouse[row.warehouseId] ?? (name: name, qty: 0)
                byWarehouse[row.warehouseId] = (name: existing.name, qty: existing.qty + row.quantity)
            }
            warehouseStock = byWarehouse
                .map { (id, v) in WarehouseStockRow(warehouseId: id, warehouseName: v.name, totalQty: v.qty) }
                .sorted { $0.warehouseName.localizedCompare($1.warehouseName) == .orderedAscending }
        } catch is CancellationError {
        } catch {
            print("[ProductDetailVM] loadWarehouseStock failed: \(error.localizedDescription)")
        }
    }

    private func loadTrays(productId: UUID) async {
        struct TrayFetchRow: Decodable {
            let id: UUID
            let machineId: UUID
            let itemNumber: Int
            let currentStock: Int
            let capacity: Int
            let vendingMachine: Named?

            enum CodingKeys: String, CodingKey {
                case id, capacity
                case machineId = "machine_id"
                case itemNumber = "item_number"
                case currentStock = "current_stock"
                case vendingMachine = "vendingMachine"
            }
        }
        struct Named: Decodable { let name: String? }

        do {
            let rows: [TrayFetchRow] = try await client
                .from("machine_trays")
                .select("id, machine_id, item_number, current_stock, capacity, vendingMachine(name)")
                .eq("product_id", value: productId.uuidString)
                .execute()
                .value

            trays = rows
                .map { r in
                    TrayRow(
                        id: r.id,
                        machineId: r.machineId,
                        machineName: r.vendingMachine?.name ?? "—",
                        itemNumber: r.itemNumber,
                        currentStock: r.currentStock,
                        capacity: r.capacity
                    )
                }
                .sorted { a, b in
                    if a.machineName != b.machineName {
                        return a.machineName.localizedCompare(b.machineName) == .orderedAscending
                    }
                    return a.itemNumber < b.itemNumber
                }
        } catch is CancellationError {
        } catch {
            print("[ProductDetailVM] loadTrays failed: \(error.localizedDescription)")
        }
    }
}
