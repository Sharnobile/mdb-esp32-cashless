import Foundation

/// IoT device record. Maps to the `embeddeds` table.
struct Embedded: Codable, Identifiable, Equatable {
    let id: UUID
    let status: String?
    let statusAt: Date?
    let subdomain: Int
    let macAddress: String?
    let firmwareVersion: String?
    /// Additive fields for Device Health / MDB diagnostics — all optional with a
    /// default so existing call sites (previews) that construct `Embedded`
    /// directly keep compiling unchanged.
    let firmwareBuildDate: Date? = nil
    let mdbAddress: Int? = nil
    /// Live MDB status snapshot published by the firmware. `nil` until the
    /// device has reported at least once.
    let mdbDiagnostics: MdbDiagnostics? = nil
    let lastRestartReason: String? = nil
    let lastRestartAt: Date? = nil
    /// Timestamp the device last transitioned to "online" — start of the
    /// current uptime run, distinct from `statusAt` (last status write of any
    /// kind).
    let onlineSince: Date? = nil

    enum CodingKeys: String, CodingKey {
        case id, status, subdomain
        case statusAt = "status_at"
        case macAddress = "mac_address"
        case firmwareVersion = "firmware_version"
        case firmwareBuildDate = "firmware_build_date"
        case mdbAddress = "mdb_address"
        case mdbDiagnostics = "mdb_diagnostics"
        case lastRestartReason = "last_restart_reason"
        case lastRestartAt = "last_restart_at"
        case onlineSince = "online_since"
    }

    /// Whether the device reported "online" status.
    var isOnline: Bool {
        status?.lowercased() == "online"
    }
}

/// Live MDB status snapshot, published by the firmware into
/// `embeddeds.mdb_diagnostics` (jsonb). Keys are camelCase because this side is
/// authored by the JS/TS ingest pipeline (mqtt-webhook), not a Postgres column.
struct MdbDiagnostics: Codable, Equatable {
    let state: String?
    let addr: String?
    let vmcLevel: Int?
    let polls: Int?
    let chkErr: Int?
    let lastCmd: String?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case state, addr, vmcLevel, polls, chkErr, lastCmd
        case updatedAt = "updated_at"
    }
}

/// One ESP32 reboot event. Maps to the `device_restarts` table.
struct DeviceRestart: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let reason: String
    let uptimeSec: Int?
    let firmwareVersion: String?
    let hwReason: String?

    enum CodingKeys: String, CodingKey {
        case id, reason
        case createdAt = "created_at"
        case uptimeSec = "uptime_sec"
        case firmwareVersion = "firmware_version"
        case hwReason = "hw_reason"
    }
}

/// One MDB state transition. Maps to the `mdb_log` table.
struct MdbLogEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let state: String
    let prevState: String?
    let addr: String?
    let polls: Int?
    let chkErr: Int?
    let lastCmd: String?

    enum CodingKeys: String, CodingKey {
        case id, state, addr, polls
        case createdAt = "created_at"
        case prevState = "prev_state"
        case chkErr = "chk_err"
        case lastCmd = "last_cmd"
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
    /// Additive settings fields — optional with a default so existing call
    /// sites (previews) that construct `VendingMachine` directly keep
    /// compiling unchanged.
    let addressStreet: String? = nil
    let addressHouseNumber: String? = nil
    let addressPostalCode: String? = nil
    let addressCity: String? = nil
    let formattedAddress: String? = nil
    let nayaxMachineId: String? = nil
    let publicListing: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, embedded, embeddeds
        case locationLat = "location_lat"
        case locationLon = "location_lon"
        case countryCode = "country_code"
        case addressStreet = "address_street"
        case addressHouseNumber = "address_house_number"
        case addressPostalCode = "address_postal_code"
        case addressCity = "address_city"
        case formattedAddress = "formatted_address"
        case nayaxMachineId = "nayax_machine_id"
        case publicListing = "public_listing"
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
