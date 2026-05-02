import Foundation

/// Product info joined from the snapshotted product_id FK on sales.
/// Available when the sales query includes `products(name, image_path)`.
struct SaleProduct: Codable, Equatable {
    let name: String?
    let imagePath: String?

    enum CodingKeys: String, CodingKey {
        case name
        case imagePath = "image_path"
    }
}

/// A vend event. Maps to the `sales` table.
/// Prices are in EUR (not cents).
struct Sale: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let machineId: UUID?
    let embeddedId: UUID?
    let itemPrice: Double?
    let itemNumber: Int?
    let channel: String?
    let productId: UUID?
    /// Nested product from PostgREST FK join (available when select includes `products(name, image_path)`)
    let products: SaleProduct?

    enum CodingKeys: String, CodingKey {
        case id, channel, products
        case createdAt = "created_at"
        case machineId = "machine_id"
        case embeddedId = "embedded_id"
        case itemPrice = "item_price"
        case itemNumber = "item_number"
        case productId = "product_id"
    }

    /// Formatted price string in EUR.
    var formattedPrice: String {
        guard let price = itemPrice else { return "--" }
        return String(format: "%.2f \u{20AC}", price)
    }
}

/// Sale with joined machine name for display in lists.
struct SaleWithMachine: Identifiable, Equatable {
    let sale: Sale
    let machineName: String?
    let productName: String?
    let productImagePath: String?

    var id: UUID { sale.id }
}

/// Aggregated daily sales for charting.
struct DailySales: Identifiable, Equatable {
    let date: Date
    let revenue: Double
    let count: Int

    var id: Date { date }
}

extension DailySales {
    /// True when the day falls on a weekend per the user's current locale
    /// (Sa+So in DE/US; respects user-preferred calendar settings).
    var isWeekend: Bool {
        Calendar.current.isDateInWeekend(date)
    }
}
