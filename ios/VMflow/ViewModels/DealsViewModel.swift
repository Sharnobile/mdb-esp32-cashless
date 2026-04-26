import Foundation
import Supabase

@MainActor
final class DealsViewModel: ObservableObject {

    // MARK: - Published State

    @Published var deals: [Deal] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var fromCache = false
    @Published var searchText = ""
    @Published var groupBy: GroupMode = .retailer
    @Published var listMode: ListMode = .active

    // Settings
    @Published var dealsEnabled = false
    @Published var dealsZipCode = ""
    @Published var settingsLoading = false

    /// Per-user archive/pin state keyed by `${retailer}::${offer_id}`.
    /// Only deals the user has interacted with have an entry here.
    @Published var userStates: [String: DealUserState] = [:]

    enum GroupMode: String, CaseIterable {
        case retailer = "Retailer"
        case product = "Product"
    }

    enum ListMode: String, CaseIterable {
        case active = "Active"
        case archived = "Archived"
    }

    struct DealUserState {
        let archivedAt: String?
        let pinnedAt: String?
        var archived: Bool { archivedAt != nil }
        var pinned: Bool { pinnedAt != nil }
    }

    private var client: SupabaseClient { SupabaseService.shared.client }

    // MARK: - Computed

    /// Collapse raw deal_cache rows into one entry per (retailer, offer_id).
    /// Picks the highest-confidence row as the "primary" and aggregates the
    /// full set of matched products / keyword groups for the detail sheet.
    ///
    /// Result is sorted by `key` ascending so the order is deterministic across
    /// recomputes — Swift `Dictionary` iteration order is unspecified, so
    /// without an explicit sort items would shuffle every time `userStates`
    /// changes (e.g. after archive/pin), making downstream stable-sort ties
    /// resolve differently and visibly reorder the list.
    var dedupedDeals: [DedupedDeal] {
        let validDeals = deals.filter { $0.isValid && $0.offerId != nil }

        // Group raw rows by stable key.
        var groups: [String: [Deal]] = [:]
        for d in validDeals {
            guard let offerId = d.offerId else { continue }
            let key = Self.stateKey(retailer: d.retailer, offerId: offerId)
            groups[key, default: []].append(d)
        }

        let result: [DedupedDeal] = groups.compactMap { (key, rows) -> DedupedDeal? in
            let sorted = rows.sorted { $0.confidence > $1.confidence }
            guard let primary = sorted.first, let offerId = primary.offerId else { return nil }

            // Collect distinct matched products, picking the highest confidence per product.
            var productMap: [UUID: DedupedDeal.MatchedProduct] = [:]
            var keywordMap: [UUID: DealKeywordMatch] = [:]
            for r in sorted {
                if let p = r.products, let pid = r.productId, let name = p.name {
                    let candidate = DedupedDeal.MatchedProduct(
                        id: pid,
                        name: name,
                        imagePath: p.imagePath,
                        sellprice: p.sellprice,
                        confidence: r.confidence
                    )
                    if let existing = productMap[pid], existing.confidence >= candidate.confidence {
                        // keep existing (higher or equal confidence)
                    } else {
                        productMap[pid] = candidate
                    }
                }
                if let kw = r.dealKeywords, let kid = kw.id, keywordMap[kid] == nil {
                    keywordMap[kid] = kw
                }
            }

            let state = userStates[key]
            return DedupedDeal(
                key: key,
                retailer: primary.retailer,
                offerId: offerId,
                primary: primary,
                matchedProducts: productMap.values.sorted { $0.confidence > $1.confidence },
                matchedKeywords: Array(keywordMap.values),
                archived: state?.archived ?? false,
                pinned: state?.pinned ?? false,
                pinnedAt: state?.pinnedAt
            )
        }

        return result.sorted { $0.key < $1.key }
    }

    /// Non-archived deals with pinned ones floated to the top (most recent
    /// pin first), then sorted by discount desc. Matches the web behaviour.
    /// `key` ascending breaks ties so equal-discount or equal-pinnedAt deals
    /// don't shuffle when an unrelated archive/pin mutates `userStates`.
    var activeDeals: [DedupedDeal] {
        dedupedDeals
            .filter { !$0.archived }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned && !b.pinned }
                if a.pinned, b.pinned {
                    let pa = a.pinnedAt ?? ""
                    let pb = b.pinnedAt ?? ""
                    if pa != pb { return pa > pb }
                    return a.key < b.key
                }
                let da = a.discountPct ?? -1
                let db = b.discountPct ?? -1
                if da != db { return da > db }
                return a.key < b.key
            }
    }

    var archivedDeals: [DedupedDeal] {
        dedupedDeals
            .filter { $0.archived }
            .sorted { a, b in
                let da = a.discountPct ?? -1
                let db = b.discountPct ?? -1
                if da != db { return da > db }
                return a.key < b.key
            }
    }

    var archivedCount: Int { archivedDeals.count }

    var filteredDeals: [DedupedDeal] {
        let source = listMode == .archived ? archivedDeals : activeDeals
        guard !searchText.isEmpty else { return source }
        let query = searchText.lowercased()
        return source.filter { d in
            if d.dealTitle.lowercased().contains(query) { return true }
            if d.retailer.lowercased().contains(query) { return true }
            if d.matchedProducts.contains(where: { $0.name.lowercased().contains(query) }) { return true }
            if d.matchedKeywords.contains(where: { ($0.label ?? "").lowercased().contains(query) }) { return true }
            return false
        }
    }

    /// Pinned deals always form their own top-of-list group, independent of
    /// the retailer/product toggle. The rest stay grouped by the user's
    /// chosen dimension below. In Archived view the pinned group is omitted
    /// (the user is explicitly reviewing archived items).
    struct DealGroup: Identifiable {
        let id: String
        let label: String
        let pinned: Bool
        let deals: [DedupedDeal]
    }

    var groupedDeals: [DealGroup] {
        var result: [DealGroup] = []
        let source = filteredDeals
        let isActive = listMode == .active

        let pinnedDeals = isActive ? source.filter { $0.pinned } : []
        let rest = isActive ? source.filter { !$0.pinned } : source

        if !pinnedDeals.isEmpty {
            result.append(DealGroup(
                id: "__pinned__",
                label: "Pinned",
                pinned: true,
                deals: pinnedDeals
            ))
        }

        let grouped: [String: [DedupedDeal]]
        switch groupBy {
        case .retailer:
            grouped = Dictionary(grouping: rest) { $0.retailer }
        case .product:
            grouped = Dictionary(grouping: rest) { deal in
                deal.matchedProducts.first?.name ?? deal.matchedKeywords.first?.label ?? "—"
            }
        }

        for (key, deals) in grouped.sorted(by: { $0.key < $1.key }) {
            result.append(DealGroup(
                id: key,
                label: key,
                pinned: false,
                deals: deals
            ))
        }

        return result
    }

    var totalDeals: Int { filteredDeals.count }

    var uniqueRetailers: Int {
        Set(filteredDeals.map(\.retailer)).count
    }

    var avgDiscount: Int {
        let discounts = filteredDeals.compactMap(\.discountPct)
        guard !discounts.isEmpty else { return 0 }
        return Int(discounts.reduce(0, +) / Double(discounts.count))
    }

    // MARK: - Load All

    func loadAll() async {
        await loadSettings()
        if dealsEnabled {
            await fetchUserStates()
            await fetchDeals()
        }
    }

    // MARK: - Settings

    func loadSettings() async {
        settingsLoading = true
        defer { settingsLoading = false }

        do {
            let response: [CompanyDealSettings] = try await client
                .from("companies")
                .select("deals_enabled, deals_zip_code")
                .limit(1)
                .execute()
                .value

            if let settings = response.first {
                dealsEnabled = settings.dealsEnabled ?? false
                dealsZipCode = settings.dealsZipCode ?? ""
            }
        } catch is CancellationError {
            // SwiftUI routine — ignore
        } catch {
            self.error = error.localizedDescription
        }
    }

    func saveSettings() async {
        settingsLoading = true
        defer { settingsLoading = false }

        do {
            let params = CompanyDealUpdate(
                dealsEnabled: dealsEnabled,
                dealsZipCode: dealsZipCode.isEmpty ? "" : dealsZipCode
            )
            try await client
                .from("companies")
                .update(params)
                .not("id", operator: .is, value: "null")
                .execute()
        } catch is CancellationError {
            // ignore
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Fetch Deals

    func fetchDeals(forceRefresh: Bool = false) async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let body = DealSearchBody(forceRefresh: forceRefresh, minConfidence: 0.5)
            let response: DealSearchResponse = try await client.functions.invoke(
                "deal-search",
                options: .init(body: body)
            )

            deals = response.deals
            fromCache = response.fromCache
        } catch is CancellationError {
            // ignore
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - User state (archive / pin)

    private static func stateKey(retailer: String, offerId: String) -> String {
        "\(retailer)::\(offerId)"
    }

    private func fetchCompanyId() async throws -> UUID {
        let userId = try await client.auth.session.user.id

        struct OrgMember: Decodable {
            let companyId: UUID
            enum CodingKeys: String, CodingKey { case companyId = "company_id" }
        }

        let members: [OrgMember] = try await client
            .from("organization_members")
            .select("company_id")
            .eq("user_id", value: userId.uuidString)
            .limit(1)
            .execute()
            .value

        guard let companyId = members.first?.companyId else {
            throw NSError(domain: "DealsVM", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Could not determine company"
            ])
        }
        return companyId
    }

    func fetchUserStates() async {
        do {
            let companyId = try await fetchCompanyId()
            let userId = try await client.auth.session.user.id

            let rows: [DealUserStateRow] = try await client
                .from("deal_user_state")
                .select("retailer, offer_id, archived_at, pinned_at")
                .eq("company_id", value: companyId.uuidString)
                .eq("user_id", value: userId.uuidString)
                .execute()
                .value

            var map: [String: DealUserState] = [:]
            for row in rows {
                map[Self.stateKey(retailer: row.retailer, offerId: row.offerId)] = DealUserState(
                    archivedAt: row.archivedAt,
                    pinnedAt: row.pinnedAt
                )
            }
            userStates = map
        } catch is CancellationError {
            // ignore
        } catch {
            // Non-fatal — users without the migration applied yet (or RLS issues)
            // shouldn't break the deals list. Log to console for diagnostics.
            print("[DealsVM] fetchUserStates failed: \(error.localizedDescription)")
        }
    }

    /// Target state to write for (retailer, offer_id). Full row semantics —
    /// the caller specifies the final values of archived_at and pinned_at.
    /// Upsert writes the whole row, so one field never accidentally clobbers
    /// the other.
    private func applyUserState(
        retailer: String,
        offerId: String,
        archivedAt: String?,
        pinnedAt: String?
    ) async {
        let key = Self.stateKey(retailer: retailer, offerId: offerId)
        let prev = userStates[key] ?? DealUserState(archivedAt: nil, pinnedAt: nil)
        let next = DealUserState(archivedAt: archivedAt, pinnedAt: pinnedAt)
        userStates[key] = next  // optimistic

        do {
            let companyId = try await fetchCompanyId()
            let userId = try await client.auth.session.user.id

            let payload = DealUserStateUpsert(
                userId: userId,
                companyId: companyId,
                retailer: retailer,
                offerId: offerId,
                archivedAt: archivedAt,
                pinnedAt: pinnedAt
            )

            try await client
                .from("deal_user_state")
                .upsert(payload, onConflict: "user_id,company_id,retailer,offer_id")
                .execute()
        } catch is CancellationError {
            // ignore
        } catch {
            print("[DealsVM] applyUserState failed: \(error.localizedDescription)")
            userStates[key] = prev  // roll back
            self.error = error.localizedDescription
        }
    }

    /// Current persisted archivedAt string (if any), so we can round-trip
    /// it through an upsert without fabricating a new timestamp when we're
    /// actually just toggling the pin.
    private func currentArchivedAt(for deal: DedupedDeal) -> String? {
        let key = Self.stateKey(retailer: deal.retailer, offerId: deal.offerId)
        return userStates[key]?.archivedAt
    }

    private func currentPinnedAt(for deal: DedupedDeal) -> String? {
        let key = Self.stateKey(retailer: deal.retailer, offerId: deal.offerId)
        return userStates[key]?.pinnedAt
    }

    func archive(_ deal: DedupedDeal) async {
        let now = ISO8601DateFormatter().string(from: Date())
        await applyUserState(
            retailer: deal.retailer,
            offerId: deal.offerId,
            archivedAt: now,
            pinnedAt: currentPinnedAt(for: deal)
        )
    }

    func unarchive(_ deal: DedupedDeal) async {
        await applyUserState(
            retailer: deal.retailer,
            offerId: deal.offerId,
            archivedAt: nil,
            pinnedAt: currentPinnedAt(for: deal)
        )
    }

    func pin(_ deal: DedupedDeal) async {
        let now = ISO8601DateFormatter().string(from: Date())
        await applyUserState(
            retailer: deal.retailer,
            offerId: deal.offerId,
            archivedAt: currentArchivedAt(for: deal),
            pinnedAt: now
        )
    }

    func unpin(_ deal: DedupedDeal) async {
        await applyUserState(
            retailer: deal.retailer,
            offerId: deal.offerId,
            archivedAt: currentArchivedAt(for: deal),
            pinnedAt: nil
        )
    }
}

// MARK: - Helper Types

private struct CompanyDealSettings: Codable {
    let dealsEnabled: Bool?
    let dealsZipCode: String?

    enum CodingKeys: String, CodingKey {
        case dealsEnabled = "deals_enabled"
        case dealsZipCode = "deals_zip_code"
    }
}

private struct CompanyDealUpdate: Codable {
    let dealsEnabled: Bool
    let dealsZipCode: String

    enum CodingKeys: String, CodingKey {
        case dealsEnabled = "deals_enabled"
        case dealsZipCode = "deals_zip_code"
    }
}

private struct DealSearchBody: Codable {
    let forceRefresh: Bool
    let minConfidence: Double
}

private struct DealUserStateUpsert: Codable {
    let userId: UUID
    let companyId: UUID
    let retailer: String
    let offerId: String
    let archivedAt: String?
    let pinnedAt: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case companyId = "company_id"
        case retailer
        case offerId = "offer_id"
        case archivedAt = "archived_at"
        case pinnedAt = "pinned_at"
    }
}
