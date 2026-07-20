import Foundation

/// A supplier (Lieferant). Maps to the `suppliers` table.
struct Supplier: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var email: String?
    var phone: String?
    var address: String?
    var customerNumber: String?

    enum CodingKeys: String, CodingKey {
        case id, name, email, phone, address
        case customerNumber = "customer_number"
    }

    init(id: UUID, name: String, email: String? = nil, phone: String? = nil,
         address: String? = nil, customerNumber: String? = nil) {
        self.id = id
        self.name = name
        self.email = email
        self.phone = phone
        self.address = address
        self.customerNumber = customerNumber
    }
}
