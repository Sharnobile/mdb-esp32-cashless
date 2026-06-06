import Foundation

/// An auto-dropped brownout duplicate sale. Maps to the `suppressed_sales` table.
/// Read-only: the app never mutates this table.
struct SuppressedSale: Codable, Identifiable, Equatable {
    let id: UUID
    let embeddedId: UUID
    let itemNumber: Int?
    let itemPrice: Double?
    let channel: String?
    let saleSeq: Int64?
    let deviceCreatedAt: Date?
    let receivedAt: Date
    let matchedSaleId: UUID?
    let reason: String
    let productId: UUID?
    /// Nested product from PostgREST FK join (available when select includes `products(name, image_path)`).
    let products: SaleProduct?

    enum CodingKeys: String, CodingKey {
        case id, channel, reason, products
        case embeddedId      = "embedded_id"
        case itemNumber      = "item_number"
        case itemPrice       = "item_price"
        case saleSeq         = "sale_seq"
        case deviceCreatedAt = "device_created_at"
        case receivedAt      = "received_at"
        case matchedSaleId   = "matched_sale_id"
        case productId       = "product_id"
    }

    /// Formatted price string in EUR, matching Sale.formattedPrice.
    var formattedPrice: String {
        guard let p = itemPrice else { return "--" }
        return String(format: "%.2f \u{20AC}", p)
    }
}
