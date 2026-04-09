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
    let expirationDate: String?

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

/// Product stock summary for warehouse overview (with batch and expiration info).
struct WarehouseProductSummary: Identifiable, Equatable {
    let productId: UUID
    let productName: String
    let imagePath: String?
    let totalQuantity: Int
    let batchCount: Int
    let earliestExpiration: String?  // date string or nil

    var id: UUID { productId }

    var isLow: Bool { totalQuantity < 10 }
    var isOutOfStock: Bool { totalQuantity == 0 }
}

/// A single stock intake entry for the recent intakes list.
struct IntakeEntry: Identifiable, Equatable {
    let id: UUID
    let productId: UUID
    let productName: String
    let imagePath: String?
    let quantity: Int
    let batchNumber: String?
    let expirationDate: String?
    let createdAt: Date
}

/// Codable wrapper for inserting a stock batch via Supabase.
struct InsertStockBatch: Codable {
    let warehouseId: UUID
    let productId: UUID
    let quantity: Int
    let batchNumber: String?
    let expirationDate: String?
    let companyId: UUID

    enum CodingKeys: String, CodingKey {
        case quantity
        case warehouseId = "warehouse_id"
        case productId = "product_id"
        case batchNumber = "batch_number"
        case expirationDate = "expiration_date"
        case companyId = "company_id"
    }
}

/// Codable wrapper for inserting a warehouse transaction via Supabase.
struct InsertWarehouseTransaction: Codable {
    let warehouseId: UUID
    let productId: UUID
    let transactionType: String
    let quantityChange: Int
    let userId: UUID
    let batchId: UUID?
    let notes: String?
    let companyId: UUID

    enum CodingKeys: String, CodingKey {
        case notes
        case warehouseId = "warehouse_id"
        case productId = "product_id"
        case transactionType = "transaction_type"
        case quantityChange = "quantity_change"
        case userId = "user_id"
        case batchId = "batch_id"
        case companyId = "company_id"
    }
}

/// Codable response for a newly inserted stock batch (to capture the generated id).
struct InsertedBatchResponse: Codable {
    let id: UUID
}
