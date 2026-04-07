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

    init(id: UUID, status: String?, statusAt: Date?, subdomain: Int, macAddress: String?, firmwareVersion: String?) {
        self.id = id
        self.status = status
        self.statusAt = statusAt
        self.subdomain = subdomain
        self.macAddress = macAddress
        self.firmwareVersion = firmwareVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        statusAt = try container.decodeIfPresent(Date.self, forKey: .statusAt)
        subdomain = try container.decode(Int.self, forKey: .subdomain)
        macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress)
        firmwareVersion = try container.decodeIfPresent(String.self, forKey: .firmwareVersion)
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

    init(id: UUID, name: String?, locationLat: Double?, locationLon: Double?, embedded: UUID?, countryCode: String?, embeddeds: Embedded? = nil) {
        self.id = id
        self.name = name
        self.locationLat = locationLat
        self.locationLon = locationLon
        self.embedded = embedded
        self.countryCode = countryCode
        self.embeddeds = embeddeds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        locationLat = try container.decodeIfPresent(Double.self, forKey: .locationLat)
        locationLon = try container.decodeIfPresent(Double.self, forKey: .locationLon)
        embedded = try container.decodeIfPresent(UUID.self, forKey: .embedded)
        countryCode = try container.decodeIfPresent(String.self, forKey: .countryCode)
        embeddeds = try container.decodeIfPresent(Embedded.self, forKey: .embeddeds)
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
    var lastSaleAt: Date?
    var paxcounterCount: Int?

    // Stock health
    var totalTrays: Int = 0
    var lowTrays: Int = 0
    var emptyTrays: Int = 0
    var stockPercent: Double = 0

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
