import Foundation

// MARK: - API Response

struct DealSearchResponse: Codable {
    let deals: [Deal]
    let fromCache: Bool
    let searchedProducts: Int?
    let totalDeals: Int?
}

// MARK: - Deal Model

struct Deal: Codable, Identifiable {
    let id: UUID
    let productId: UUID?
    let keywordId: UUID?
    let matchedTerm: String?
    let retailer: String
    let dealTitle: String
    let dealPrice: Double?
    let regularPrice: Double?
    let discountPct: Double?
    let validFrom: String?
    let validUntil: String?
    let imageUrl: String?
    let imageUrlLarge: String?
    let sourceUrl: String?
    let externalUrl: String?
    let matchedBy: String
    let confidence: Double
    let matchedTokens: [String]?
    let requiresApp: Bool
    let fetchedAt: String
    let offerId: String?
    let products: DealProduct?
    let dealKeywords: DealKeywordMatch?

    enum CodingKeys: String, CodingKey {
        case id, retailer, confidence, products
        case productId = "product_id"
        case keywordId = "keyword_id"
        case matchedTerm = "matched_term"
        case dealTitle = "deal_title"
        case dealPrice = "deal_price"
        case regularPrice = "regular_price"
        case discountPct = "discount_pct"
        case validFrom = "valid_from"
        case validUntil = "valid_until"
        case imageUrl = "image_url"
        case imageUrlLarge = "image_url_large"
        case sourceUrl = "source_url"
        case externalUrl = "external_url"
        case matchedBy = "matched_by"
        case matchedTokens = "matched_tokens"
        case requiresApp = "requires_app"
        case fetchedAt = "fetched_at"
        case offerId = "offer_id"
        case dealKeywords = "deal_keywords"
    }

    // MARK: - Formatted Properties

    var formattedDealPrice: String? {
        guard let price = dealPrice else { return nil }
        return String(format: "%.2f \u{20AC}", price)
    }

    var formattedRegularPrice: String? {
        guard let price = regularPrice else { return nil }
        return String(format: "%.2f \u{20AC}", price)
    }

    var formattedDiscount: String? {
        guard let pct = discountPct, pct > 0 else { return nil }
        return "-\(Int(pct))%"
    }

    var productName: String {
        if let name = products?.name { return name }
        if let label = dealKeywords?.label, !label.isEmpty { return label }
        if let firstTerm = dealKeywords?.terms?.first, !firstTerm.isEmpty { return firstTerm }
        if let firstLinked = dealKeywords?.linkedProducts.first?.name { return firstLinked }
        if let term = matchedTerm, !term.isEmpty { return term }
        return "Unknown Product"
    }

    var productImagePath: String? {
        products?.imagePath ?? dealKeywords?.linkedProducts.first?.imagePath
    }

    var productSellprice: Double? {
        products?.sellprice ?? dealKeywords?.linkedProducts.first?.sellprice
    }

    // MARK: - Validity

    enum ValidityStatus {
        case upcoming, active, expiring, expired

        var label: String {
            switch self {
            case .upcoming: return "Upcoming"
            case .active: return "Active"
            case .expiring: return "Expiring soon"
            case .expired: return "Expired"
            }
        }
    }

    var validityStatus: ValidityStatus {
        let today = Self.todayString
        guard let until = validUntil else { return .active }

        if until < today { return .expired }

        if let from = validFrom, from > today { return .upcoming }

        // Check if expiring within 2 days
        if let untilDate = Self.dateFormatter.date(from: until) {
            let daysLeft = Calendar.current.dateComponents([.day], from: Date(), to: untilDate).day ?? 0
            if daysLeft <= 2 { return .expiring }
        }

        return .active
    }

    var isValid: Bool {
        guard let until = validUntil else { return true }
        return until >= Self.todayString
    }

    var formattedValidUntil: String? {
        guard let until = validUntil,
              let date = Self.dateFormatter.date(from: until) else { return nil }
        return Self.displayFormatter.string(from: date)
    }

    var formattedValidFrom: String? {
        guard let from = validFrom,
              let date = Self.dateFormatter.date(from: from) else { return nil }
        return Self.displayFormatter.string(from: date)
    }

    // MARK: - Confidence

    enum ConfidenceLevel {
        case high, medium, low

        init(value: Double) {
            if value >= 0.85 { self = .high }
            else if value >= 0.65 { self = .medium }
            else { self = .low }
        }
    }

    var confidenceLevel: ConfidenceLevel {
        ConfidenceLevel(value: confidence)
    }

    var formattedConfidence: String {
        "\(Int(confidence * 100))%"
    }

    // MARK: - Date Helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static var todayString: String {
        dateFormatter.string(from: Date())
    }
}

// MARK: - Deal Product (joined relation)

struct DealProduct: Codable {
    let name: String?
    let imagePath: String?
    let sellprice: Double?

    enum CodingKeys: String, CodingKey {
        case name, sellprice
        case imagePath = "image_path"
    }
}

// MARK: - Deal Keyword (joined relation for keyword-match rows)

/// Keyword group info embedded via PostgREST nested select when a deal was
/// matched against a user-defined keyword group rather than a single product.
/// The `deal_keyword_products` side returns rows like `{ products: {...} }`,
/// which we flatten into `linkedProducts` for convenient access.
struct DealKeywordMatch: Codable {
    let id: UUID?
    let label: String?
    let terms: [String]?
    let linkedProducts: [DealProduct]

    private struct LinkedProductRow: Codable {
        let products: DealProduct?
    }

    enum CodingKeys: String, CodingKey {
        case id, label, terms
        case dealKeywordProducts = "deal_keyword_products"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        terms = try c.decodeIfPresent([String].self, forKey: .terms)
        let rows = try c.decodeIfPresent([LinkedProductRow].self, forKey: .dealKeywordProducts) ?? []
        linkedProducts = rows.compactMap { $0.products }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(terms, forKey: .terms)
        let rows = linkedProducts.map { LinkedProductRow(products: $0) }
        try c.encode(rows, forKey: .dealKeywordProducts)
    }
}
