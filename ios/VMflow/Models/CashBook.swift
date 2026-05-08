import Foundation

// MARK: - CashBook

struct CashBook: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let companyId: UUID
    let name: String
    let initialBalance: Double
    let bankDepositThreshold: Double
    let trackPerMachine: Bool
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case companyId = "company_id"
        case name
        case initialBalance = "initial_balance"
        case bankDepositThreshold = "bank_deposit_threshold"
        case trackPerMachine = "track_per_machine"
        case isActive = "is_active"
    }
}

// MARK: - CashBookEntry

enum CashBookEntryType: String, Codable {
    case initial
    case withdrawal
    case correction
    case payout
    case reversal
}

struct CashBookEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let cashBookId: UUID
    let companyId: UUID
    let entryNumber: Int
    let type: CashBookEntryType
    let amount: Double
    let balanceAfter: Double
    let description: String?
    let machineId: UUID?
    let countedAmount: Double?
    let expectedAmount: Double?
    let correctsEntryId: UUID?
    let isReversed: Bool
    let createdBy: UUID
    let hash: String

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case cashBookId = "cash_book_id"
        case companyId = "company_id"
        case entryNumber = "entry_number"
        case type
        case amount
        case balanceAfter = "balance_after"
        case description
        case machineId = "machine_id"
        case countedAmount = "counted_amount"
        case expectedAmount = "expected_amount"
        case correctsEntryId = "corrects_entry_id"
        case isReversed = "is_reversed"
        case createdBy = "created_by"
        case hash
    }
}

// MARK: - TheoreticalCash (RPC payload)

struct TheoreticalCash: Codable, Hashable {
    let theoreticalBalance: Double
    let lastEntryBalance: Double
    let cashSalesSince: Double
    let lastEntryAt: Date
    let entryCount: Int
    let machines: [PerMachineCashSales]

    struct PerMachineCashSales: Codable, Hashable, Identifiable {
        var id: UUID { machineId }
        let machineId: UUID
        let machineName: String?
        let cashSales: Double

        enum CodingKeys: String, CodingKey {
            case machineId = "machine_id"
            case machineName = "machine_name"
            case cashSales = "cash_sales"
        }
    }

    enum CodingKeys: String, CodingKey {
        case theoreticalBalance = "theoretical_balance"
        case lastEntryBalance = "last_entry_balance"
        case cashSalesSince = "cash_sales_since"
        case lastEntryAt = "last_entry_at"
        case entryCount = "entry_count"
        case machines
    }
}

// MARK: - VendingMachine row used for cash-book wiring

/// A trimmed projection of `vendingMachine` that the cash-book layer needs.
/// Keeps the existing `Models/VendingMachine.swift` (used by the Machines feature)
/// untouched — that one has the full set of fields and a different `Codable`
/// shape. We use a separate, focused projection here to avoid coupling the two.
struct CashBookMachineRef: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String?
    let cashBookId: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case cashBookId = "cash_book_id"
    }
}
