import Foundation

/// Represents a product in the catalogue.
/// Maps to the `products` table in Supabase.
struct Product: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String?
    let imagePath: String?
    let discontinued: Bool?
    let sellprice: Double?
    let category: UUID?

    enum CodingKeys: String, CodingKey {
        case id, name, sellprice, discontinued, category
        case imagePath = "image_path"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Product category. Maps to the `product_category` table.
/// Note: DB column is `company` (not `company_id`).
struct ProductCategory: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String
    let company: UUID

    enum CodingKeys: String, CodingKey {
        case id, name, company
    }
}

/// A barcode linked to a product. Maps to the `product_barcodes` table.
struct ProductBarcode: Codable, Identifiable, Equatable {
    let id: UUID
    let productId: UUID
    let barcode: String
    let format: String
    let companyId: UUID

    enum CodingKeys: String, CodingKey {
        case id, barcode, format
        case productId = "product_id"
        case companyId = "company_id"
    }
}

/// Lightweight product info returned from a tray query's `products(...)` relation.
struct TrayProduct: Codable, Equatable, Hashable {
    let name: String?
    let imagePath: String?
    let discontinued: Bool?
    let sellprice: Double?

    enum CodingKeys: String, CodingKey {
        case name, discontinued, sellprice
        case imagePath = "image_path"
    }
}
