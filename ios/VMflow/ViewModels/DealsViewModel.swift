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

    // Settings
    @Published var dealsEnabled = false
    @Published var dealsZipCode = ""
    @Published var settingsLoading = false

    enum GroupMode: String, CaseIterable {
        case retailer = "Retailer"
        case product = "Product"
    }

    private var client: SupabaseClient { SupabaseService.shared.client }

    // MARK: - Computed

    var filteredDeals: [Deal] {
        let validDeals = deals.filter { $0.isValid }
        guard !searchText.isEmpty else { return validDeals }
        let query = searchText.lowercased()
        return validDeals.filter {
            $0.dealTitle.lowercased().contains(query) ||
            $0.retailer.lowercased().contains(query) ||
            $0.productName.lowercased().contains(query)
        }
    }

    var groupedDeals: [(key: String, deals: [Deal])] {
        let grouped: [String: [Deal]]
        switch groupBy {
        case .retailer:
            grouped = Dictionary(grouping: filteredDeals) { $0.retailer }
        case .product:
            grouped = Dictionary(grouping: filteredDeals) { $0.productName }
        }
        return grouped.sorted { $0.key < $1.key }.map { (key: $0.key, deals: $0.value) }
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
