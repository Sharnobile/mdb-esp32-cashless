import Foundation

/// A supplier (Lieferant). Maps to the `suppliers` table.
struct Supplier: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String
}
