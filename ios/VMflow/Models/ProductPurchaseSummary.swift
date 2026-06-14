import Foundation

/// Per-product purchase-price aggregates from the get_product_purchase_summary RPC.
struct ProductPurchaseSummary: Codable, Identifiable {
    let productId: UUID
    let ekCount: Int
    let newestNet: Double?
    let newestGross: Double?
    let newestSupplier: String?
    let newestOn: String?
    let minGross: Double?
    let minSupplier: String?
    let minOn: String?
    let maxGross: Double?
    let effectiveTaxRate: Double?

    var id: UUID { productId }

    enum CodingKeys: String, CodingKey {
        case productId = "product_id"
        case ekCount = "ek_count"
        case newestNet = "newest_net"
        case newestGross = "newest_gross"
        case newestSupplier = "newest_supplier"
        case newestOn = "newest_on"
        case minGross = "min_gross"
        case minSupplier = "min_supplier"
        case minOn = "min_on"
        case maxGross = "max_gross"
        case effectiveTaxRate = "effective_tax_rate"
    }
}
