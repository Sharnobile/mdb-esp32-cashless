import Foundation

struct MatchedSaleRef: Codable, Equatable {
    let createdAt: Date
    enum CodingKeys: String, CodingKey { case createdAt = "created_at" }
}

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
    /// Matched real sale (created_at) from the matched_sale_id FK join — used for the gap in reasonText.
    let matched: MatchedSaleRef?

    enum CodingKeys: String, CodingKey {
        case id, channel, reason, products, matched
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

    /// Human-readable removal circumstances (hardcoded English, matching the tab).
    /// Clock fragment: the device clock was unsynced (always true for a suppressed
    /// row); null device_created_at means the device had no clock at all. Gap: how
    /// long after the matched sale this re-report arrived (server-arrival separation,
    /// not exact inter-vend time) — a plausibility signal.
    var reasonText: String {
        let clock = deviceCreatedAt == nil ? "Device had no clock" : "Clock not synced"
        if let m = matched?.createdAt {
            let gap = Int(abs(receivedAt.timeIntervalSince(m)).rounded())
            return "\(clock) · identical sale \(gap)s earlier"
        }
        return "\(clock) · near-duplicate of a recent sale"
    }
}
