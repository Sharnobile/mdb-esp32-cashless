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
    @Published var products: [Product] = []  // All non-discontinued products for intake picker
    @Published var isLoading = false
    @Published var error: String?
    @Published var searchText = ""

    // Intake form state
    @Published var intakeProductId: UUID?
    @Published var intakeQuantity: Int = 1
    @Published var intakeBatchNumber: String = ""
    @Published var intakeExpirationDate: Date? = nil
    @Published var intakeHasExpiration: Bool = false
    @Published var isBookingIntake = false

    private let client = SupabaseService.shared.client

    // MARK: - Computed

    /// Product summaries filtered by search text, sorted: out of stock first, then low, then by name.
    var filteredSummaries: [WarehouseProductSummary] {
        let filtered: [WarehouseProductSummary]
        if searchText.isEmpty {
            filtered = productSummaries
        } else {
            let query = searchText.lowercased()
            filtered = productSummaries.filter { $0.productName.lowercased().contains(query) }
        }
        return filtered.sorted { lhs, rhs in
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

    /// Fetches stock batches for the selected warehouse, grouped by product.
    func loadProductSummaries() async {
        guard let warehouseId = selectedWarehouseId else {
            productSummaries = []
            return
        }

        do {
            // Fetch all batches for this warehouse with quantity > 0
            struct BatchWithProduct: Codable {
                let id: UUID
                let productId: UUID
                let quantity: Int
                let expirationDate: String?
                let products: BatchProduct?

                struct BatchProduct: Codable {
                    let name: String?
                    let imagePath: String?

                    enum CodingKeys: String, CodingKey {
                        case name
                        case imagePath = "image_path"
                    }
                }

                enum CodingKeys: String, CodingKey {
                    case id, quantity, products
                    case productId = "product_id"
                    case expirationDate = "expiration_date"
                }
            }

            let batches: [BatchWithProduct] = try await client
                .from("warehouse_stock_batches")
                .select("id, product_id, quantity, expiration_date, products(name, image_path)")
                .eq("warehouse_id", value: warehouseId.uuidString)
                .gt("quantity", value: 0)
                .execute()
                .value

            // Group by product_id
            var grouped: [UUID: (name: String, imagePath: String?, totalQty: Int, batchCount: Int, earliestExp: String?)] = [:]

            for batch in batches {
                let productName = batch.products?.name ?? "Unknown"
                let imagePath = batch.products?.imagePath

                if var existing = grouped[batch.productId] {
                    existing.totalQty += batch.quantity
                    existing.batchCount += 1
                    // Track earliest expiration
                    if let exp = batch.expirationDate {
                        if let currentEarliest = existing.earliestExp {
                            if exp < currentEarliest {
                                existing.earliestExp = exp
                            }
                        } else {
                            existing.earliestExp = exp
                        }
                    }
                    grouped[batch.productId] = existing
                } else {
                    grouped[batch.productId] = (
                        name: productName,
                        imagePath: imagePath,
                        totalQty: batch.quantity,
                        batchCount: 1,
                        earliestExp: batch.expirationDate
                    )
                }
            }

            productSummaries = grouped.map { productId, info in
                WarehouseProductSummary(
                    productId: productId,
                    productName: info.name,
                    imagePath: info.imagePath,
                    totalQuantity: info.totalQty,
                    batchCount: info.batchCount,
                    earliestExpiration: info.earliestExp
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
                companyId: companyId
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
}
