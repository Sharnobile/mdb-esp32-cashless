import Foundation

// MARK: - Raw rows (PostgREST decoding)

/// Row from `activity_log` for the dashboard feed.
/// Only the columns/metadata keys the feed renders; metadata is decoded
/// tolerantly because old rows may carry fewer fields.
struct ActivityLogRow: Decodable, Equatable {
    let id: UUID
    let createdAt: Date
    let action: String
    let metadata: ActivityLogMetadata?

    enum CodingKeys: String, CodingKey {
        case id, action, metadata
        case createdAt = "created_at"
    }
}

struct ActivityLogMetadata: Decodable, Equatable {
    let tourId: String?
    let machineName: String?
    let traysRefilled: Int?
    let totalAdded: Int?
    let machineCount: Int?
    let machineNames: [String]?
    let warehouseName: String?
    let userDisplay: String?
    let products: [ActivityProductLine]?

    enum CodingKeys: String, CodingKey {
        case products
        case tourId = "tour_id"
        case machineName = "machine_name"
        case traysRefilled = "trays_refilled"
        case totalAdded = "total_added"
        case machineCount = "machine_count"
        case machineNames = "machine_names"
        case warehouseName = "warehouse_name"
        case userDisplay = "_user_display"
    }
}

struct ActivityProductLine: Decodable, Equatable {
    let productName: String?
    let quantity: Int?

    enum CodingKeys: String, CodingKey {
        case quantity
        case productName = "product_name"
    }
}

/// Row from `warehouse_transactions` (transaction_type = 'incoming') with
/// FK-joined product and warehouse names.
struct IntakeTransactionRow: Decodable, Equatable {
    let id: UUID
    let createdAt: Date
    let warehouseId: UUID?
    let userId: UUID?
    let quantityChange: Int
    let products: NameOnly?
    let warehouses: NameOnly?

    struct NameOnly: Decodable, Equatable { let name: String? }

    enum CodingKeys: String, CodingKey {
        case id, products, warehouses
        case createdAt = "created_at"
        case warehouseId = "warehouse_id"
        case userId = "user_id"
        case quantityChange = "quantity_change"
    }
}

// MARK: - Feed items

struct RefillActivity: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let machineName: String
    let traysRefilled: Int
    let totalAdded: Int
    let userDisplay: String?
    let tourId: String?
    let products: [(name: String, quantity: Int)]

    static func == (lhs: RefillActivity, rhs: RefillActivity) -> Bool {
        lhs.id == rhs.id && lhs.createdAt == rhs.createdAt
    }
}

struct TourActivity: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let userDisplay: String?
    let machineCount: Int
    let machineNames: [String]
    let warehouseName: String?
    let tourId: String?
}

/// One intake "session": consecutive incoming warehouse transactions by the
/// same user into the same warehouse with ≤15 min between bookings.
struct IntakeGroup: Identifiable, Equatable {
    /// Deterministic: id of the OLDEST transaction in the group — stable
    /// across reloads so row expansion state survives (spec §1).
    let id: UUID
    /// Newest transaction time in the group (used for sorting/day grouping).
    let date: Date
    let userId: UUID?
    var userDisplay: String?
    let warehouseName: String?
    let totalUnits: Int
    let products: [(name: String, quantity: Int)]

    var productCount: Int { products.count }

    static func == (lhs: IntakeGroup, rhs: IntakeGroup) -> Bool {
        lhs.id == rhs.id && lhs.date == rhs.date && lhs.userDisplay == rhs.userDisplay
    }
}

/// One entry in the dashboard "Recent Activity" timeline.
enum ActivityFeedItem: Identifiable, Equatable {
    case sale(SaleWithMachine)
    case machineRefilled(RefillActivity)
    case tourStarted(TourActivity)
    case stockIntake(IntakeGroup)

    var id: String {
        switch self {
        case .sale(let s): return "sale-\(s.id.uuidString)"
        case .machineRefilled(let r): return "refill-\(r.id.uuidString)"
        case .tourStarted(let t): return "tour-\(t.id.uuidString)"
        case .stockIntake(let g): return "intake-\(g.id.uuidString)"
        }
    }

    var date: Date {
        switch self {
        case .sale(let s): return s.sale.createdAt
        case .machineRefilled(let r): return r.createdAt
        case .tourStarted(let t): return t.createdAt
        case .stockIntake(let g): return g.date
        }
    }
}

// MARK: - Pure builders (no I/O — kept testable)

enum ActivityFeedBuilder {

    /// Max gap between two bookings that still counts as one intake session.
    static let intakeSessionGap: TimeInterval = 15 * 60

    /// Group incoming warehouse transactions into intake sessions.
    /// `rows` may arrive in any order; they are sorted ascending internally.
    /// A new group starts when the user or warehouse changes, or the gap to
    /// the previous transaction exceeds `intakeSessionGap`.
    static func groupIntakes(_ rows: [IntakeTransactionRow]) -> [IntakeGroup] {
        let sorted = rows.sorted { $0.createdAt < $1.createdAt }
        var groups: [IntakeGroup] = []
        var current: [IntakeTransactionRow] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            // Aggregate quantities per product name, preserving first-seen order.
            var order: [String] = []
            var qty: [String: Int] = [:]
            for row in current {
                let name = row.products?.name ?? "—"
                if qty[name] == nil { order.append(name) }
                qty[name, default: 0] += row.quantityChange
            }
            groups.append(IntakeGroup(
                id: first.id,
                date: last.createdAt,
                userId: first.userId,
                userDisplay: nil,
                warehouseName: first.warehouses?.name,
                totalUnits: current.reduce(0) { $0 + $1.quantityChange },
                products: order.map { (name: $0, quantity: qty[$0] ?? 0) }
            ))
            current = []
        }

        for row in sorted {
            if let prev = current.last {
                let sameSession = prev.userId == row.userId
                    && prev.warehouseId == row.warehouseId
                    && row.createdAt.timeIntervalSince(prev.createdAt) <= intakeSessionGap
                if !sameSession { flush() }
            }
            current.append(row)
        }
        flush()
        return groups
    }

    /// Map activity_log rows to feed items. Unknown actions are skipped.
    static func makeActivityItems(_ rows: [ActivityLogRow]) -> [ActivityFeedItem] {
        rows.compactMap { row in
            switch row.action {
            case "stock_refill_tour":
                return .machineRefilled(RefillActivity(
                    id: row.id,
                    createdAt: row.createdAt,
                    machineName: row.metadata?.machineName ?? "—",
                    traysRefilled: row.metadata?.traysRefilled ?? 0,
                    totalAdded: row.metadata?.totalAdded ?? 0,
                    userDisplay: row.metadata?.userDisplay,
                    tourId: row.metadata?.tourId,
                    products: (row.metadata?.products ?? []).compactMap { line in
                        guard let name = line.productName else { return nil }
                        return (name: name, quantity: line.quantity ?? 0)
                    }
                ))
            case "tour_started":
                let names = row.metadata?.machineNames ?? []
                return .tourStarted(TourActivity(
                    id: row.id,
                    createdAt: row.createdAt,
                    userDisplay: row.metadata?.userDisplay,
                    machineCount: row.metadata?.machineCount ?? names.count,
                    machineNames: names,
                    warehouseName: row.metadata?.warehouseName,
                    tourId: row.metadata?.tourId
                ))
            default:
                return nil
            }
        }
    }

    /// Merge all sources into one timeline, newest first.
    static func mergeFeed(
        sales: [SaleWithMachine],
        activityRows: [ActivityLogRow],
        intakeGroups: [IntakeGroup]
    ) -> [ActivityFeedItem] {
        var items: [ActivityFeedItem] = sales.map { .sale($0) }
        items.append(contentsOf: makeActivityItems(activityRows))
        items.append(contentsOf: intakeGroups.map { .stockIntake($0) })
        return items.sorted { $0.date > $1.date }
    }
}
