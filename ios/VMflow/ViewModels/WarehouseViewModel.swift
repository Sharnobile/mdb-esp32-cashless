import Foundation
import Supabase

/// Drives the Warehouse management page: stock overview and intake booking.
@MainActor
final class WarehouseViewModel: ObservableObject {
    // MARK: - Published State

    @Published var warehouses: [Warehouse] = []
    @Published var selectedWarehouseId: UUID?
    @Published var productSummaries: [WarehouseProductSummary] = []
    @Published var recentIntakes: [IntakeEntry] = []
    // Batch drilldown state (for ProductBatchesView)
    @Published var drilldownBatches: [WarehouseStockBatch] = []
    @Published var isLoadingBatches = false
    @Published var isAdjustingBatch = false
    @Published var products: [Product] = []  // All non-discontinued products for intake picker
    @Published var isLoading = false
    @Published var error: String?
    @Published var searchText = ""

    // Stock list filters (parity with management frontend)
    @Published var includeOutOfStock = false
    @Published var includeArchived = false
    @Published var expirationFilter: ExpirationFilterOption = .all

    /// Filter options for the stock list's expiration severity.
    enum ExpirationFilterOption: String, CaseIterable, Identifiable {
        case all, expiringSoon, critical
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .expiringSoon: return "Expiring soon"
            case .critical: return "Critical / expired"
            }
        }
    }

    /// True when any filter deviates from the default (active in-stock) view.
    var hasActiveFilters: Bool {
        includeOutOfStock || includeArchived || expirationFilter != .all
    }

    // Intake form state
    @Published var intakeProductId: UUID?
    @Published var intakeQuantity: Int = 1
    @Published var intakeBatchNumber: String = ""
    @Published var intakeExpirationDate: Date? = nil
    @Published var intakeHasExpiration: Bool = false
    @Published var isBookingIntake = false

    private let client = SupabaseService.shared.client

    // MARK: - Computed

    /// Product summaries after search + filters, sorted: archived last, then
    /// out of stock first, then low, then by name.
    var filteredSummaries: [WarehouseProductSummary] {
        var items = productSummaries

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            items = items.filter { $0.productName.lowercased().contains(query) }
        }
        if !includeArchived {
            items = items.filter { !$0.discontinued }
        }
        if !includeOutOfStock {
            items = items.filter { !$0.isOutOfStock }
        }
        switch expirationFilter {
        case .all:
            break
        case .expiringSoon:
            items = items.filter { $0.expirationStatus == .warning || $0.expirationStatus == .critical }
        case .critical:
            items = items.filter { $0.expirationStatus == .critical }
        }

        return items.sorted { lhs, rhs in
            if lhs.discontinued != rhs.discontinued { return !lhs.discontinued }
            if lhs.isOutOfStock != rhs.isOutOfStock { return lhs.isOutOfStock }
            if lhs.isLow != rhs.isLow { return lhs.isLow }
            return lhs.productName.localizedCaseInsensitiveCompare(rhs.productName) == .orderedAscending
        }
    }

    // MARK: - Load Warehouses

    func loadWarehouses() async {
        do {
            let result: [Warehouse] = try await client
                .from("warehouses")
                .select("id, name, address, notes, company_id")
                .order("name")
                .execute()
                .value

            warehouses = result

            // Auto-select first warehouse if none selected
            if selectedWarehouseId == nil, let first = result.first {
                selectedWarehouseId = first.id
            }
        } catch is CancellationError {
            // Ignore — SwiftUI cancels refreshable tasks routinely
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Load Product Summaries

    /// Builds a summary for EVERY product (incl. zero-stock and discontinued),
    /// merged with the selected warehouse's batches. Mirrors the management
    /// frontend's `fetchProductSummaries` so out-of-stock / expired / archived
    /// products can be surfaced via the stock-list filters.
    func loadProductSummaries() async {
        guard let warehouseId = selectedWarehouseId else {
            productSummaries = []
            return
        }

        do {
            struct ProductRow: Decodable {
                let id: UUID
                let name: String?
                let imagePath: String?
                let discontinued: Bool?

                enum CodingKeys: String, CodingKey {
                    case id, name, discontinued
                    case imagePath = "image_path"
                }
            }
            struct BatchRow: Decodable {
                let productId: UUID
                let quantity: Int
                let expirationDate: String?

                enum CodingKeys: String, CodingKey {
                    case quantity
                    case productId = "product_id"
                    case expirationDate = "expiration_date"
                }
            }

            async let productsRes: [ProductRow] = client
                .from("products")
                .select("id, name, image_path, discontinued")
                .order("name")
                .execute()
                .value
            async let batchesRes: [BatchRow] = client
                .from("warehouse_stock_batches")
                .select("product_id, quantity, expiration_date")
                .eq("warehouse_id", value: warehouseId.uuidString)
                .gt("quantity", value: 0)
                .execute()
                .value

            let (productRows, batchRows) = try await (productsRes, batchesRes)

            // Aggregate batches per product
            var stock: [UUID: (total: Int, count: Int, earliest: String?)] = [:]
            for batch in batchRows {
                var entry = stock[batch.productId] ?? (total: 0, count: 0, earliest: nil)
                entry.total += batch.quantity
                entry.count += 1
                if let exp = batch.expirationDate {
                    if let current = entry.earliest {
                        if exp < current { entry.earliest = exp }
                    } else {
                        entry.earliest = exp
                    }
                }
                stock[batch.productId] = entry
            }

            // Every product gets a summary (even with 0 stock)
            productSummaries = productRows.map { p in
                let s = stock[p.id]
                return WarehouseProductSummary(
                    productId: p.id,
                    productName: p.name ?? "Unknown",
                    imagePath: p.imagePath,
                    totalQuantity: s?.total ?? 0,
                    batchCount: s?.count ?? 0,
                    earliestExpiration: s?.earliest,
                    discontinued: p.discontinued ?? false,
                    expirationStatus: WarehouseProductSummary.expirationStatus(for: s?.earliest)
                )
            }
        } catch is CancellationError {
            // Ignore — SwiftUI cancels refreshable tasks routinely
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Load Products (for intake picker)

    func loadProducts() async {
        do {
            let result: [Product] = try await client
                .from("products")
                .select("id, name, image_path, discontinued, sellprice")
                .or("discontinued.is.null,discontinued.eq.false")
                .order("name")
                .execute()
                .value

            products = result
        } catch is CancellationError {
            // Ignore — SwiftUI cancels refreshable tasks routinely
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Load Recent Intakes

    func loadRecentIntakes() async {
        guard let warehouseId = selectedWarehouseId else {
            recentIntakes = []
            return
        }

        do {
            struct TransactionWithProduct: Codable {
                let id: UUID
                let productId: UUID
                let quantityChange: Int
                let createdAt: Date
                let notes: String?
                let products: TransProduct?

                struct TransProduct: Codable {
                    let name: String?
                    let imagePath: String?

                    enum CodingKeys: String, CodingKey {
                        case name
                        case imagePath = "image_path"
                    }
                }

                enum CodingKeys: String, CodingKey {
                    case id, notes, products
                    case productId = "product_id"
                    case quantityChange = "quantity_change"
                    case createdAt = "created_at"
                }
            }

            let transactions: [TransactionWithProduct] = try await client
                .from("warehouse_transactions")
                .select("id, product_id, quantity_change, created_at, notes, products(name, image_path)")
                .eq("warehouse_id", value: warehouseId.uuidString)
                .eq("transaction_type", value: "intake")
                .order("created_at", ascending: false)
                .limit(10)
                .execute()
                .value

            recentIntakes = transactions.map { tx in
                IntakeEntry(
                    id: tx.id,
                    productId: tx.productId,
                    productName: tx.products?.name ?? "Unknown",
                    imagePath: tx.products?.imagePath,
                    quantity: tx.quantityChange,
                    batchNumber: nil,
                    expirationDate: nil,
                    createdAt: tx.createdAt
                )
            }
        } catch is CancellationError {
            // Ignore — SwiftUI cancels refreshable tasks routinely
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Load All

    func loadAll() async {
        isLoading = true
        error = nil

        await loadWarehouses()
        // These depend on selectedWarehouseId being set
        async let summariesTask: () = loadProductSummaries()
        async let intakesTask: () = loadRecentIntakes()
        async let productsTask: () = loadProducts()

        _ = await (summariesTask, intakesTask, productsTask)

        isLoading = false
    }

    // MARK: - Warehouse Selection

    func selectWarehouse(_ id: UUID) async {
        selectedWarehouseId = id
        async let summariesTask: () = loadProductSummaries()
        async let intakesTask: () = loadRecentIntakes()
        _ = await (summariesTask, intakesTask)
    }

    // MARK: - Barcode Lookup

    /// Look up a product by barcode in the `product_barcodes` table.
    /// Returns the matching product_id or nil if not found.
    func lookupBarcode(_ barcode: String) async -> UUID? {
        do {
            struct BarcodeResult: Decodable {
                let productId: UUID
                enum CodingKeys: String, CodingKey { case productId = "product_id" }
            }
            let results: [BarcodeResult] = try await client
                .from("product_barcodes")
                .select("product_id")
                .eq("barcode", value: barcode)
                .limit(1)
                .execute()
                .value

            return results.first?.productId
        } catch {
            print("[Warehouse] Barcode lookup failed: \(error)")
            return nil
        }
    }

    // MARK: - Book Intake

    func bookIntake(productId: UUID, quantity: Int, batchNumber: String?, expirationDate: String?) async {
        guard let warehouseId = selectedWarehouseId,
              let companyId = warehouses.first(where: { $0.id == warehouseId })?.companyId else { return }

        isBookingIntake = true
        error = nil

        do {
            // 1. Insert new stock batch
            let newBatch = InsertStockBatch(
                warehouseId: warehouseId,
                productId: productId,
                quantity: quantity,
                batchNumber: batchNumber,
                expirationDate: expirationDate,
                companyId: companyId
            )

            let insertedBatches: [InsertedBatchResponse] = try await client
                .from("warehouse_stock_batches")
                .insert(newBatch)
                .select("id")
                .execute()
                .value

            let batchId = insertedBatches.first?.id

            // 2. Insert warehouse transaction
            let userId = try await client.auth.session.user.id

            let transaction = InsertWarehouseTransaction(
                warehouseId: warehouseId,
                productId: productId,
                transactionType: "intake",
                quantityChange: quantity,
                userId: userId,
                batchId: batchId,
                notes: batchNumber.flatMap { $0.isEmpty ? nil : "Batch: \($0)" },
                companyId: companyId,
                quantityBefore: nil,
                quantityAfter: nil,
                batchNumber: batchNumber,
                expirationDate: expirationDate
            )

            try await client
                .from("warehouse_transactions")
                .insert(transaction)
                .execute()

            // 3. Reset form
            intakeProductId = nil
            intakeQuantity = 1
            intakeBatchNumber = ""
            intakeExpirationDate = nil
            intakeHasExpiration = false

            // 4. Reload data
            async let summariesTask: () = loadProductSummaries()
            async let intakesTask: () = loadRecentIntakes()
            _ = await (summariesTask, intakesTask)
        } catch is CancellationError {
            // Ignore — SwiftUI cancels refreshable tasks routinely
        } catch {
            self.error = error.localizedDescription
        }

        isBookingIntake = false
    }

    // MARK: - Batch drilldown

    /// Allowed reasons for `adjustBatch`. String-backed so the raw value maps directly to
    /// the `warehouse_transactions.transaction_type` column. Mirrors the TypeScript
    /// reason union in `management-frontend/app/composables/useWarehouse.ts:439`.
    enum AdjustReason: String {
        case refillReturn = "adjustment_refill_return"
        case correction = "adjustment_correction"
        case damage = "adjustment_damage"
        case expired = "adjustment_expired"
    }

    /// Loads all non-empty batches for a specific product in the current warehouse,
    /// ordered by expiration date ascending (oldest first).
    /// Reuses the existing `WarehouseStockBatch` model from `Models/Warehouse.swift`.
    func loadBatchesForProduct(_ productId: UUID) async {
        guard let warehouseId = selectedWarehouseId else {
            drilldownBatches = []
            return
        }

        // Clear previous drilldown state so re-visiting a different product
        // doesn't briefly render stale rows while the new query runs.
        drilldownBatches = []
        isLoadingBatches = true
        defer { isLoadingBatches = false }

        do {
            let batches: [WarehouseStockBatch] = try await client
                .from("warehouse_stock_batches")
                .select("id, warehouse_id, product_id, quantity, batch_number, expiration_date")
                .eq("warehouse_id", value: warehouseId.uuidString)
                .eq("product_id", value: productId.uuidString)
                .gt("quantity", value: 0)
                .order("expiration_date", ascending: true)
                .execute()
                .value

            drilldownBatches = batches
        } catch is CancellationError {
            // SwiftUI cancels refreshable tasks routinely — ignore
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Adjust the quantity of a specific batch by a signed delta.
    ///
    /// `reason` is constrained to the `AdjustReason` enum so the transaction_type
    /// column only ever gets one of the four adjustment_* strings. `intake`
    /// (iOS Wareneingang) and `incoming` (web legacy) are deliberately excluded
    /// from this enum — they belong to the Wareneingang flow, not adjustments.
    ///
    /// Quantity is clamped at zero so concurrent sales can't produce negative stock.
    /// On success, reloads batches + product summaries so callers see fresh data.
    func adjustBatch(
        batchId: UUID,
        quantityChange: Int,
        reason: AdjustReason,
        notes: String?
    ) async {
        guard let warehouseId = selectedWarehouseId,
              let companyId = warehouses.first(where: { $0.id == warehouseId })?.companyId else {
            return
        }

        isAdjustingBatch = true
        error = nil
        defer { isAdjustingBatch = false }

        do {
            // 1. Fetch current batch to get quantity_before + product_id
            struct CurrentBatch: Decodable {
                let productId: UUID
                let quantity: Int
                let batchNumber: String?
                let expirationDate: String?

                enum CodingKeys: String, CodingKey {
                    case quantity
                    case productId = "product_id"
                    case batchNumber = "batch_number"
                    case expirationDate = "expiration_date"
                }
            }

            let current: CurrentBatch = try await client
                .from("warehouse_stock_batches")
                .select("product_id, quantity, batch_number, expiration_date")
                .eq("id", value: batchId.uuidString)
                .single()
                .execute()
                .value

            let quantityBefore = current.quantity
            let quantityAfter = max(0, quantityBefore + quantityChange)

            // 2. Update batch quantity
            struct BatchUpdate: Encodable { let quantity: Int }
            try await client
                .from("warehouse_stock_batches")
                .update(BatchUpdate(quantity: quantityAfter))
                .eq("id", value: batchId.uuidString)
                .execute()

            // 3. Insert transaction row (web-parity: includes before/after + batch metadata)
            let userId = try await client.auth.session.user.id
            let transaction = InsertWarehouseTransaction(
                warehouseId: warehouseId,
                productId: current.productId,
                transactionType: reason.rawValue,
                quantityChange: quantityChange,
                userId: userId,
                batchId: batchId,
                notes: (notes?.isEmpty ?? true) ? nil : notes,
                companyId: companyId,
                quantityBefore: quantityBefore,
                quantityAfter: quantityAfter,
                batchNumber: current.batchNumber,
                expirationDate: current.expirationDate
            )

            try await client
                .from("warehouse_transactions")
                .insert(transaction)
                .execute()

            // 4. Reload affected state
            async let batchesTask: () = loadBatchesForProduct(current.productId)
            async let summariesTask: () = loadProductSummaries()
            _ = await (batchesTask, summariesTask)
        } catch is CancellationError {
            // ignore
        } catch {
            self.error = error.localizedDescription
        }
    }
}
