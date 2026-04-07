import Foundation

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

    enum CodingKeys: String, CodingKey {
        case id, channel
        case createdAt = "created_at"
        case machineId = "machine_id"
        case embeddedId = "embedded_id"
        case itemPrice = "item_price"
        case itemNumber = "item_number"
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

    var id: UUID { sale.id }
}

/// Aggregated daily sales for charting.
struct DailySales: Identifiable, Equatable {
    let date: Date
    let revenue: Double
    let count: Int

    var id: Date { date }
}
