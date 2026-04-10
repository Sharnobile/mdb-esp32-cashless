import Foundation

/// One row of the operator inbox. Customer-submitted from /m/[machine_id].
///
/// Two source tables share this struct so the iOS Inbox screen can render
/// them in one merged list:
///   • machine_feedback (type='problem' | 'feedback')
///   • product_wishes   (type='wish')
///
/// `source` is what we hand back to PostgREST when an operator marks an item
/// reviewed/dismissed/deleted — different table, same UUID id.
struct InboxItem: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case problem
        case feedback
        case wish
    }

    enum Status: String {
        case new
        case reviewed
        case dismissed
    }

    enum Source: String {
        case machineFeedback = "machine_feedback"
        case productWishes = "product_wishes"
    }

    let id: UUID
    let source: Source
    let kind: Kind
    let message: String
    let email: String?
    let status: Status
    let createdAt: Date
    let machineId: UUID
    let machineName: String?

    var isOpen: Bool { status == .new }
}

// MARK: - PostgREST decoding helpers

/// Decoded shape of a `machine_feedback` row joined with `vendingMachine(name)`.
struct MachineFeedbackRow: Decodable {
    let id: UUID
    let type: String           // 'problem' | 'feedback'
    let message: String
    let email: String?
    let status: String         // 'new' | 'reviewed' | 'dismissed'
    let createdAt: Date
    let machineId: UUID
    let vendingMachine: NestedMachine?

    struct NestedMachine: Decodable {
        let name: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, type, message, email, status
        case createdAt = "created_at"
        case machineId = "machine_id"
        case vendingMachine
    }
}

/// Decoded shape of a `product_wishes` row joined with `vendingMachine(name)`.
struct ProductWishRow: Decodable {
    let id: UUID
    let wishText: String
    let email: String?
    let status: String
    let createdAt: Date
    let machineId: UUID
    let vendingMachine: NestedMachine?

    struct NestedMachine: Decodable {
        let name: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, email, status
        case wishText = "wish_text"
        case createdAt = "created_at"
        case machineId = "machine_id"
        case vendingMachine
    }
}

extension InboxItem {
    init?(_ row: MachineFeedbackRow) {
        guard let kind = Kind(rawValue: row.type) else { return nil }
        guard let status = Status(rawValue: row.status) else { return nil }
        self.id = row.id
        self.source = .machineFeedback
        self.kind = kind
        self.message = row.message
        self.email = row.email
        self.status = status
        self.createdAt = row.createdAt
        self.machineId = row.machineId
        self.machineName = row.vendingMachine?.name
    }

    init?(_ row: ProductWishRow) {
        guard let status = Status(rawValue: row.status) else { return nil }
        self.id = row.id
        self.source = .productWishes
        self.kind = .wish
        self.message = row.wishText
        self.email = row.email
        self.status = status
        self.createdAt = row.createdAt
        self.machineId = row.machineId
        self.machineName = row.vendingMachine?.name
    }
}
