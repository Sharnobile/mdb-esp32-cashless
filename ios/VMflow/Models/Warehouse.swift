import Foundation

/// A warehouse location. Maps to the `warehouses` table.
struct Warehouse: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let address: String?
    let notes: String?
    let companyId: UUID

    enum CodingKeys: String, CodingKey {
        case id, name, address, notes
        case companyId = "company_id"
    }
}

/// Stock batch in a warehouse (FIFO tracking). Maps to `warehouse_stock_batches`.
struct WarehouseStockBatch: Codable, Identifiable, Equatable {
    let id: UUID
    let warehouseId: UUID
    let productId: UUID
    let quantity: Int
    let batchNumber: String?
    let expirationDate: Date?

    enum CodingKeys: String, CodingKey {
        case id, quantity
        case warehouseId = "warehouse_id"
        case productId = "product_id"
        case batchNumber = "batch_number"
        case expirationDate = "expiration_date"
    }
}

/// Aggregated warehouse stock per product (sum of all batches).
struct WarehouseProductStock: Identifiable, Equatable {
    let productId: UUID
    let productName: String
    let totalQuantity: Int
    let imagePath: String?

    var id: UUID { productId }
}
