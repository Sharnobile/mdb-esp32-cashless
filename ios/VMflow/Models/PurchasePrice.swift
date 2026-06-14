import Foundation

/// One recorded purchase price. The `suppliers(name)` nested join is decoded
/// via the `suppliers` relation and surfaced through `supplierName`.
struct PurchasePrice: Codable, Identifiable {
    let id: UUID
    let productId: UUID
    let supplierId: UUID
    let priceNet: Double
    let priceGross: Double
    let priceBasis: String   // "net" | "gross"
    let taxRate: Double
    let observedOn: String
    let note: String?
    let suppliers: SupplierName?

    var supplierName: String { suppliers?.name ?? "" }

    struct SupplierName: Codable { let name: String }

    enum CodingKeys: String, CodingKey {
        case id, suppliers, note
        case productId = "product_id"
        case supplierId = "supplier_id"
        case priceNet = "price_net"
        case priceGross = "price_gross"
        case priceBasis = "price_basis"
        case taxRate = "tax_rate"
        case observedOn = "observed_on"
    }
}
