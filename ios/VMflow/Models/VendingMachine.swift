import Foundation

/// IoT device record. Maps to the `embeddeds` table.
struct Embedded: Codable, Identifiable, Equatable {
    let id: UUID
    let status: String?
    let statusAt: Date?
    let subdomain: Int
    let macAddress: String?
    let firmwareVersion: String?

    enum CodingKeys: String, CodingKey {
        case id, status, subdomain
        case statusAt = "status_at"
        case macAddress = "mac_address"
        case firmwareVersion = "firmware_version"
    }

    /// Whether the device reported "online" status.
    var isOnline: Bool {
        status?.lowercased() == "online"
    }
}

/// Vending machine record. Maps to the `vendingMachine` table.
/// Includes a nested `embeddeds` relation for device status.
struct VendingMachine: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String?
    let locationLat: Double?
    let locationLon: Double?
    let embedded: UUID?
    let countryCode: String?
    let embeddeds: Embedded?

    enum CodingKeys: String, CodingKey {
        case id, name, embedded, embeddeds
        case locationLat = "location_lat"
        case locationLon = "location_lon"
        case countryCode = "country_code"
    }

    /// Display name, falling back to "Unnamed Machine".
    var displayName: String {
        name ?? "Unnamed Machine"
    }

    /// Whether the linked device is online.
    var isOnline: Bool {
        embeddeds?.isOnline ?? false
    }
}

// MARK: - Per-machine computed statistics (populated after batch queries)

/// Enriched machine data with aggregated stats for display.
struct MachineStats: Identifiable, Equatable {
    let machine: VendingMachine
    var todayRevenue: Double = 0
    var todaySalesCount: Int = 0
    var yesterdayRevenue: Double = 0
    var yesterdaySalesCount: Int = 0
    var thisWeekRevenue: Double = 0
    var thisWeekSalesCount: Int = 0
    var lastWeekRevenue: Double = 0
    var lastWeekSalesCount: Int = 0
    var paxcounterCount: Int?

    // Stock health
    var totalTrays: Int = 0
    var lowTrays: Int = 0
    var emptyTrays: Int = 0
    var stockPercent: Double = 0

    // Warehouse-aware stock counts
    var swapNeededCount: Int = 0   // empty trays with no warehouse stock
    var noStockCount: Int = 0      // low trays with no warehouse stock

    // Per-product deficit info for card display
    var trayDeficits: [TrayDeficit] = []

    var id: UUID { machine.id }

    /// Overall stock health classification.
    var stockHealth: StockHealth {
        if emptyTrays > 0 { return .critical }
        if lowTrays > 0 { return .low }
        return .ok
    }

    /// Sort priority: critical first, then low, then ok. Within same health, more low trays first.
    var sortPriority: Int {
        switch stockHealth {
        case .critical: return 0
        case .low: return 1000 - lowTrays
        case .ok: return 2000
        }
    }
}

/// Stock health levels with associated colors.
enum StockHealth: String, Equatable {
    case ok
    case low
    case critical
}

/// Severity level for individual tray/product stock deficits.
enum StockSeverity: Equatable, Comparable {
    case critical  // empty (currentStock == 0)
    case low       // below minStock
    case fillBelow // below fillWhenBelow
}

/// Warehouse stock availability for a product.
enum WarehouseAvailability: Equatable {
    case inStock      // Product available in warehouse (green "In Stock")
    case noStock      // Not in warehouse, tray still has some stock (dimmed "No Stock")
    case needsSwap    // Not in warehouse AND tray is empty (orange "Swap")
    case unknown      // No warehouse data available
}

/// Aggregated product deficit info for display on machine cards.
struct TrayDeficit: Equatable {
    let productName: String
    let imagePath: String?
    let deficit: Int
    let severity: StockSeverity
    let isDiscontinued: Bool
    let warehouseAvailability: WarehouseAvailability
}
