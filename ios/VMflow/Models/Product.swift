import Foundation

/// Represents a product in the catalogue.
/// Maps to the `products` table in Supabase.
struct Product: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String?
    let imagePath: String?
    let discontinued: Bool
    let sellprice: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, sellprice, discontinued
        case imagePath = "image_path"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath)
        discontinued = try container.decodeIfPresent(Bool.self, forKey: .discontinued) ?? false
        sellprice = try container.decodeIfPresent(Double.self, forKey: .sellprice)
    }
}

/// Lightweight product info returned from a tray query's `products(...)` relation.
struct TrayProduct: Codable, Equatable, Hashable {
    let name: String?
    let imagePath: String?
    let discontinued: Bool

    enum CodingKeys: String, CodingKey {
        case name, discontinued
        case imagePath = "image_path"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath)
        discontinued = try container.decodeIfPresent(Bool.self, forKey: .discontinued) ?? false
    }
}
